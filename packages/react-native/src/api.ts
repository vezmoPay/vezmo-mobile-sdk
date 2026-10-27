import { SDK_VERSION } from './version';
import type {
  CheckoutConfig,
  PayResponse,
  QrBilling,
  QrPayment,
  SessionStatus,
  SubscriptionPayResponse,
  SubscriptionView,
  VezmoError,
} from './types';

export const DEFAULT_API_BASE = 'https://api.vezmo.com/api/v1';

/**
 * How long a call may take before the buyer is told to check their connection (`network`): a hung request otherwise
 * leaves the sheet, or `prepareCheckout()`, waiting forever. The native SDKs give up after about as long (Android
 * reads for 30 s; iOS waits 60 s between packets).
 */
export const REQUEST_TIMEOUT_MS = 30_000;

const FALLBACK_MESSAGE = 'Something went wrong. Please try again.';

/** A failed call, already in Vezmo's words (the API never names its processor to a buyer). */
export class VezmoApiError extends Error {
  readonly code: VezmoError['code'];
  readonly httpStatus: number | null;
  /** The API's own error code when it sent one (e.g. `local_price_changed`). */
  readonly reason: string | null;
  constructor(
    code: VezmoError['code'],
    message: string,
    httpStatus: number | null,
    reason: string | null = null,
  ) {
    super(message);
    this.name = 'VezmoApiError';
    this.code = code;
    this.httpStatus = httpStatus;
    this.reason = reason;
  }
  toVezmoError(): VezmoError {
    return { code: this.code, message: this.message };
  }
}

type Fetch = typeof fetch;

/**
 * The buyer-side calls of an API checkout session. Everything is scoped by the session's client token; no merchant
 * key ever reaches the app.
 */
export class VezmoApi {
  constructor(
    private readonly apiBase: string = DEFAULT_API_BASE,
    private readonly integration: 'ios' | 'android',
    private readonly fetchImpl: Fetch = fetch,
  ) {}

  private async call<T>(method: 'GET' | 'POST', path: string, body?: unknown): Promise<T> {
    const abort = new AbortController();
    const timer = setTimeout(() => abort.abort(), REQUEST_TIMEOUT_MS);
    let res: Response;
    let json: any = null;
    try {
      try {
        res = await this.fetchImpl(`${this.apiBase}${path}`, {
          method,
          headers: {
            Accept: 'application/json',
            ...(body !== undefined ? { 'Content-Type': 'application/json' } : {}),
            'Vezmo-SDK': `react-native/${SDK_VERSION}`,
          },
          ...(body !== undefined ? { body: JSON.stringify(body) } : {}),
          signal: abort.signal,
        });
      } catch {
        throw new VezmoApiError('network', 'Check your connection and try again.', null);
      }
      try {
        json = await res.json();
      } catch {
        // An empty or non-JSON body; or no answer in time.
        if (abort.signal.aborted) throw new VezmoApiError('network', 'Check your connection and try again.', null);
      }
    } finally {
      clearTimeout(timer);
    }
    // A success with no readable answer is a failure (as the native SDKs read it), never a null result.
    if (res.ok && json && json.success !== false) return (json.data ?? json) as T;
    const message: string =
      (typeof json?.message === 'string' && json.message) ||
      json?.errors?.[0]?.message ||
      FALLBACK_MESSAGE;
    const reason = typeof json?.errors?.[0]?.code === 'string' ? json.errors[0].code : null;
    throw new VezmoApiError(codeFor(res.status, json), message, res.status, reason);
  }

  checkout(token: string, opts: { currency?: string } = {}) {
    const q = `redirectMethods=1${opts.currency ? `&currency=${encodeURIComponent(opts.currency)}` : ''}`;
    return this.call<CheckoutConfig>('POST', `/secure-payments/${encodeURIComponent(token)}/checkout?${q}`);
  }

  pay(
    token: string,
    body: { paymentMethodId: string; localOffer?: string | null; returnUrl?: string | null },
  ) {
    return this.call<PayResponse>('POST', `/secure-payments/${encodeURIComponent(token)}/pay`, {
      paymentMethodId: body.paymentMethodId,
      integration: this.integration,
      ...(body.localOffer ? { localOffer: body.localOffer } : {}),
      ...this.returnLink(body.returnUrl),
    });
  }

  /** The session's intent, made or reused (UPI and Pix start from it). */
  intent(token: string, localOffer: string | null) {
    return this.call<{ id: string; clientSecret: string; connectedAccountId: string | null; livemode: boolean }>(
      'POST',
      `/secure-payments/${encodeURIComponent(token)}/intent?redirectMethods=1`,
      localOffer ? { localOffer } : {},
    );
  }

  /** Start UPI or Pix on the intent: the UPI app link, or the Pix code to paste in a bank app. */
  startQr(
    method: 'upi' | 'pix',
    body: {
      clientSecret: string;
      connectedAccountId: string | null;
      livemode: boolean;
      returnUrl: string;
      billing: QrBilling;
    },
  ) {
    return this.call<QrPayment>('POST', `/checkout/${method}`, {
      clientSecret: body.clientSecret,
      ...(body.connectedAccountId ? { connectedAccountId: body.connectedAccountId } : {}),
      livemode: body.livemode,
      returnUrl: body.returnUrl,
      billing: body.billing,
    });
  }

  /** The session's own checkout page (https): where UPI and Pix send a buyer who comes back by browser. */
  checkoutPageUrl(token: string) {
    return `${this.apiBase}/secure-payments/${encodeURIComponent(token)}`;
  }

  /** Records a payment that finished on the device (after 3D Secure or a redirect). */
  confirm(token: string, paymentIntentId: string) {
    return this.call<{ payment?: { id: string; transactionId: string | null }; pending?: boolean }>(
      'POST',
      `/secure-payments/${encodeURIComponent(token)}/confirm`,
      { paymentIntentId, integration: this.integration },
    );
  }

  status(token: string) {
    return this.call<SessionStatus>('GET', `/secure-payments/${encodeURIComponent(token)}/status`);
  }

  /**
   * Where a bank app or pay-later provider sends the buyer back. iOS: the app's own link (the sheet hands it to the
   * payment). Android: none, as in 0.1.x (a card, 3D Secure included, and Google Pay need none); the app's link there
   * would open the app but leave the payment waiting.
   * TODO(0.2.0, before release): bank apps and pay-later providers on Android need the payment engine's own return
   * link, which a confirmation token carried and a payment method doesn't; send it once Vezmo's API accepts it.
   */
  private returnLink(returnUrl?: string | null) {
    return returnUrl && this.integration === 'ios' ? { returnUrl } : {};
  }

  // ── subscriptions (a subscription checkout's token) ─────────────────────
  /** The subscription checkout: plan, first charge or free trial, keys. A used or unknown link reads as expired. */
  async subscription(token: string, opts: { currency?: string } = {}) {
    const q = opts.currency ? `?currency=${encodeURIComponent(opts.currency)}` : '';
    try {
      return await this.call<SubscriptionView>('GET', `/subscription-checkout/${encodeURIComponent(token)}${q}`);
    } catch (e) {
      if (e instanceof VezmoApiError && e.httpStatus === 404) {
        throw new VezmoApiError('expired', 'This subscription link is no longer valid.', 404);
      }
      if (e instanceof VezmoApiError && e.httpStatus === 400 && /already set up/i.test(e.message)) {
        throw new VezmoApiError('already_paid', 'This subscription is already set up.', 400);
      }
      throw e;
    }
  }

  /** Subscribe: our server confirms the first payment, or a free trial's card, with the payment method (`pm_…`). */
  subscriptionPay(token: string, body: { paymentMethodId: string; localOffer?: string | null; returnUrl?: string | null }) {
    return this.call<SubscriptionPayResponse>('POST', `/subscription-checkout/${encodeURIComponent(token)}/pay`, {
      paymentMethodId: body.paymentMethodId,
      integration: this.integration,
      ...(body.localOffer ? { localOffer: body.localOffer } : {}),
      ...this.returnLink(body.returnUrl),
    });
  }

  /** Records a subscription start finished on the device (after 3D Secure). */
  subscriptionConfirm(token: string, intentId: string) {
    return this.call<{ status: string; subscriptionRef: string; paymentId?: string; transactionId?: string | null }>(
      'POST',
      `/subscription-checkout/${encodeURIComponent(token)}/confirm`,
      { paymentIntentId: intentId },
    );
  }
}

function codeFor(status: number, json: any): VezmoError['code'] {
  const reason = json?.errors?.[0]?.code;
  // The app's return link isn't registered for this business (iPhone), or this way to pay is off for it.
  if (reason === 'return_url_not_registered') return 'config';
  if (reason === 'method_unavailable') return 'not_available';
  if (status === 410) return 'expired';
  if (status === 409) return reason === 'local_price_changed' ? 'unknown' : 'already_paid';
  if (status === 400 || status === 402) return 'declined';
  if (status === 401 || status === 403 || status === 404) return 'config';
  return 'unknown';
}
