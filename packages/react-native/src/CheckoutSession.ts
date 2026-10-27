import { VezmoApi, VezmoApiError } from './api';
import {
  chargeOf,
  configFromSubscription,
  DECLINED,
  EXPIRED,
  intentIdOf,
  isPaid,
  payFromSubscription,
  resultFromPay,
  resultFromStatus,
  resultFromSubscriptionConfirm,
  sheetMethods,
  type Charge,
  type SheetMethods,
} from './flow';
import type { CheckoutConfig, CheckoutResult, PaidMethod, PayResponse, QrBilling, QrPayment, VezmoError } from './types';

/** What the element can be asked to do (the native view's commands). */
export interface ElementPort {
  confirm(): void;
  resolveConfirmation(clientSecret: string | null, errorMessage?: string): void;
  clearSelection(): void;
}

/**
 * What the card flow can be asked to do: the card form, the bank step (Instant ACH), paying with what they chose,
 * answering its confirmation.
 */
export interface CardFlowPort {
  presentCard(): void;
  confirmCard(): void;
  presentBank(): void;
  confirmBank(): void;
  resolveConfirmation(clientSecret: string | null, errorMessage?: string): void;
}

/** The card from the native card form, for the sheet's own Card row (or the bank account linked for Instant ACH). */
export interface CardChoice {
  /** "•••• 4242". */
  label: string;
  /** The network's logo (PNG data URI) when the platform gives one. */
  image: string | null;
}

export type SessionPhase =
  | { name: 'loading' }
  | { name: 'ready'; error: VezmoError | null }
  | { name: 'paying' }
  /** UPI or Pix started: the buyer finishes in their bank app; we watch the session. */
  | { name: 'waiting'; method: 'upi' | 'pix'; qr: QrPayment }
  | { name: 'done'; result: CheckoutResult }
  /** The session can't be paid (expired, already paid, the business can't take payments). */
  | { name: 'closed'; result: CheckoutResult };

export interface SessionSnapshot {
  phase: SessionPhase;
  config: CheckoutConfig | null;
  /** The buyer chose to pay in their own currency. */
  payLocal: boolean;
  charge: Charge | null;
  methods: SheetMethods | null;
  /** The element has a method selected and can be paid. */
  canPay: boolean;
  /** The selected method as the element names it ("•••• 4242", "Klarna"). */
  option: string | null;
  /** The method the buyer paid with, kept for the receipt (the element clears its selection after paying). */
  paidWith: string | null;
  /** The same as Vezmo's server read it from the payment (the card's network for its logo). */
  paidMethod: PaidMethod | null;
  /** The element couldn't load (shown in the sheet with Try again). */
  elementError: string | null;
  /** Bumped by Try again: rebuilds the native element. */
  elementAttempt: number;
  /**
   * The selected way to pay: the sheet's Card row (`card`), one of the element's rows (`element`: wallets, pay-later),
   * our UPI or Pix row, or our Instant ACH row.
   */
  method: PayMethod;
  /** The card typed in the card form, kept when the buyer looks at another method and comes back. */
  card: CardChoice | null;
  /** The bank account linked in the engine's bank step for Instant ACH, kept the same way. */
  bank: CardChoice | null;
}

export type PayMethod = 'card' | 'element' | 'upi' | 'pix' | 'instantAch';

/** What the sheet and the receipt call an Instant ACH payment. */
export const INSTANT_ACH = 'Instant ACH';

const PRICE_CHANGED = 'The price in your currency just changed. Check the new amount and pay again.';
/** The engine failed before Vezmo was asked to take the payment: never its own words (white label; they differ by platform). */
const NOT_COMPLETED = 'Your payment couldn’t be completed. Please try again.';

/**
 * One checkout, from the session's client token (or a subscription checkout's token) to a result. The money decisions
 * are the server's: this only moves the buyer's payment method to Vezmo and the answer back to the element.
 */
export class CheckoutSession {
  private snapshot: SessionSnapshot = {
    phase: { name: 'loading' },
    config: null,
    payLocal: false,
    charge: null,
    methods: null,
    canPay: false,
    option: null,
    paidWith: null,
    paidMethod: null,
    elementError: null,
    elementAttempt: 0,
    method: 'element',
    card: null,
    bank: null,
  };
  private listeners = new Set<() => void>();
  private element: ElementPort | null = null;
  private cardFlow: CardFlowPort | null = null;
  /** Which native view started the payment in progress (its confirmation is answered there). */
  private confirmVia: 'element' | 'card' = 'element';
  private lastPay: PayResponse | null = null;
  private lastError: VezmoError | null = null;
  private watching: ReturnType<typeof setInterval> | null = null;
  /** A status check is on its way (the poll, Check status and the return from the bank app don't overlap). */
  private checking = false;
  private qrIntentId: string | null = null;
  /** The card form was opened by the buyer: the card it returns becomes the selection. */
  private awaitingCard = false;
  /** The bank step was opened by the buyer: the account it links becomes the selection. */
  private awaitingBank = false;
  /** Vezmo's answer when /pay itself got none (a timeout, a dropped connection) but the payment went through. */
  private recovered: CheckoutResult | null = null;
  /** The buyer asked to close and Vezmo is being asked whether a UPI or Pix payment went through. */
  private closing = false;

  constructor(
    private readonly api: VezmoApi,
    private readonly token: string,
    private readonly returnUrl: string | null,
    /** `subscription`: the token is a subscription checkout's (cards and wallets; a first payment or a free trial). */
    private readonly kind: 'payment' | 'subscription' = 'payment',
  ) {}

  private async fetchConfig(): Promise<CheckoutConfig> {
    return this.kind === 'subscription'
      ? configFromSubscription(await this.api.subscription(this.token))
      : this.api.checkout(this.token);
  }

  // ── store ──────────────────────────────────────────────────────────────
  subscribe = (listener: () => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };
  getSnapshot = () => this.snapshot;
  private set(next: Partial<SessionSnapshot>) {
    this.snapshot = { ...this.snapshot, ...next };
    this.listeners.forEach((l) => l());
  }

  attachElement(element: ElementPort | null) {
    this.element = element;
  }

  attachCardFlow(cardFlow: CardFlowPort | null) {
    this.cardFlow = cardFlow;
  }

  // ── loading and currency ───────────────────────────────────────────────
  async load(): Promise<void> {
    try {
      const config = await this.fetchConfig();
      // The buyer's own currency is offered first when there is an offer (as on the web checkout).
      this.apply(config, !!config.localOffer);
      this.set({ phase: { name: 'ready', error: null } });
    } catch (e) {
      this.close(e);
    }
  }

  /** The buyer switched between their own currency and the price's. */
  choosePayLocal(payLocal: boolean) {
    if (!this.snapshot.config || this.snapshot.phase.name === 'paying') return;
    this.apply(this.snapshot.config, payLocal);
  }

  /** The element's selected method changed (null: nothing selected). Choosing one leaves the card, UPI or Pix. */
  setOption(option: { label: string } | null) {
    const leave = !!option && this.snapshot.method !== 'element' && this.snapshot.phase.name === 'ready';
    this.set({ canPay: !!option, option: option?.label || null, ...(leave ? { method: 'element' as const } : {}) });
  }

  /** The buyer tapped the Card row: the card already typed, or the card form to type one. */
  chooseCard() {
    if (this.snapshot.phase.name !== 'ready') return;
    if (this.snapshot.card) {
      this.element?.clearSelection();
      this.set({ method: 'card', phase: { name: 'ready', error: null } });
    } else {
      this.changeCard();
    }
  }

  /** Change (or first type) the card. */
  changeCard() {
    if (this.snapshot.phase.name !== 'ready') return;
    this.awaitingCard = true;
    this.cardFlow?.presentCard();
  }

  /** The card form reported its card (or none). One the buyer just typed becomes the selection. */
  setCard(card: CardChoice | null) {
    const chosen = !!card && this.awaitingCard && this.snapshot.phase.name === 'ready';
    if (card) this.awaitingCard = false;
    if (chosen) this.element?.clearSelection();
    this.set({ card, ...(chosen ? { method: 'card' as const, phase: { name: 'ready', error: null } } : {}) });
  }

  /** The buyer tapped the Instant ACH row: the bank account already linked, or the bank step to link one. */
  chooseBank() {
    if (this.snapshot.phase.name !== 'ready') return;
    if (this.snapshot.bank) {
      this.element?.clearSelection();
      this.set({ method: 'instantAch', phase: { name: 'ready', error: null } });
    } else {
      this.changeBank();
    }
  }

  /** Change (or first link) the bank account. */
  changeBank() {
    if (this.snapshot.phase.name !== 'ready') return;
    this.awaitingBank = true;
    this.cardFlow?.presentBank();
  }

  /** The bank step reported its account (or none). One the buyer just linked becomes the selection. */
  setBank(bank: CardChoice | null) {
    const ready = this.snapshot.phase.name === 'ready';
    const chosen = !!bank && this.awaitingBank && ready;
    if (bank) this.awaitingBank = false;
    if (chosen) this.element?.clearSelection();
    // The bank step went away (the sheet's look changed): pick again.
    const lost = !bank && this.snapshot.method === 'instantAch' && ready;
    this.set({
      bank,
      ...(chosen ? { method: 'instantAch' as const, phase: { name: 'ready' as const, error: null } } : {}),
      ...(lost ? { method: 'element' as const } : {}),
    });
  }

  /**
   * The Pay button can be pressed: a typed card on the Card row, a linked bank on the Instant ACH row, or a method chosen
   * in the element.
   */
  static canPay(s: SessionSnapshot): boolean {
    if (s.method === 'card') return !!s.card;
    if (s.method === 'instantAch') return !!s.bank;
    return s.method === 'element' ? s.canPay : false;
  }

  setElementError(message: string | null) {
    // The platform's own reason, for the app's developer (the buyer sees "Couldn't load payment options").
    if (message) console.warn(`[Vezmo] Payment options could not load: ${message}`);
    this.set({ elementError: message, ...(message ? { canPay: false } : {}) });
  }

  retryElement() {
    this.set({ elementError: null, elementAttempt: this.snapshot.elementAttempt + 1 });
  }

  private apply(config: CheckoutConfig, payLocal: boolean) {
    const charge = chargeOf(config, payLocal && !!config.localOffer);
    const methods = sheetMethods(config, charge);
    // A method that this currency doesn't offer falls back to the element.
    const current = this.snapshot.method;
    const method =
      (current === 'upi' && !methods.upi) || (current === 'pix' && !methods.pix) || (current === 'instantAch' && !methods.instantAch)
        ? 'element'
        : current;
    this.set({ config, payLocal: !!charge.localOffer, charge, methods, method });
  }

  /** UPI or Pix (the sheet's own rows) or back to the element; one method is selected at a time. */
  chooseMethod(method: PayMethod) {
    if (this.snapshot.phase.name !== 'ready') return;
    if (method !== 'element') this.element?.clearSelection();
    this.set({ method, phase: { name: 'ready', error: null } });
  }

  // ── UPI and Pix ────────────────────────────────────────────────────────
  /** Start UPI or Pix: the UPI app link or the Pix code comes back; then we watch the session until it is paid. */
  async payWithQr(method: 'upi' | 'pix', billing: QrBilling) {
    if (this.snapshot.phase.name !== 'ready') return;
    this.set({ phase: { name: 'paying' }, paidWith: method === 'upi' ? 'UPI' : 'Pix' });
    try {
      const intent = await this.api.intent(this.token, this.snapshot.charge?.localOffer ?? null);
      this.qrIntentId = intent.id;
      const qr = await this.api.startQr(method, {
        clientSecret: intent.clientSecret,
        connectedAccountId: intent.connectedAccountId,
        livemode: intent.livemode,
        returnUrl: this.api.checkoutPageUrl(this.token),
        billing,
      });
      this.set({ phase: { name: 'waiting', method, qr } });
      this.watch();
    } catch (e) {
      const err = e instanceof VezmoApiError ? e.toVezmoError() : { code: 'unknown' as const, message: DECLINED.message };
      if (err.code === 'expired' || err.code === 'already_paid') return this.close(e);
      // UPI and Pix are always in the buyer's currency: an offer that ran out is fetched again, not retried as is.
      if (e instanceof VezmoApiError && e.reason === 'local_price_changed') {
        this.refreshOffer();
        return this.set({ phase: { name: 'ready', error: { code: 'unknown', message: PRICE_CHANGED } } });
      }
      this.set({ phase: { name: 'ready', error: err } });
    }
  }

  /** The buyer gave up waiting: back to the sheet (a payment made meanwhile still settles). */
  stopWaiting() {
    this.unwatch();
    if (this.snapshot.phase.name === 'waiting') this.set({ phase: { name: 'ready', error: null } });
  }

  /** Check now (the buyer came back from their bank app). */
  async checkNow() {
    if (this.snapshot.phase.name !== 'waiting' || this.checking) return;
    this.checking = true;
    try {
      let status;
      try {
        status = await this.api.status(this.token);
      } catch {
        return;
      }
      const result = resultFromStatus(status);
      if (!result || this.snapshot.phase.name !== 'waiting') return;
      this.unwatch();
      if (result.status === 'failed') {
        this.set({ phase: { name: 'ready', error: { code: 'declined', message: 'The payment didn’t go through. Try again.' } } });
        return;
      }
      // Recorded now rather than when the webhook arrives (as the web checkout does).
      if (this.qrIntentId) await this.api.confirm(this.token, this.qrIntentId).catch(() => undefined);
      this.set({ phase: { name: 'done', result } });
    } finally {
      this.checking = false;
    }
  }

  private watch() {
    this.unwatch();
    const started = Date.now();
    this.watching = setInterval(() => {
      // A code lasts 10 minutes; stop watching a little after.
      if (Date.now() - started > 11 * 60_000) return this.stopWaiting();
      void this.checkNow();
    }, 2000);
  }

  private unwatch() {
    if (this.watching) clearInterval(this.watching);
    this.watching = null;
  }

  /** The sheet is going away. */
  dispose() {
    this.unwatch();
  }

  // ── paying ─────────────────────────────────────────────────────────────
  pay() {
    if (this.snapshot.phase.name !== 'ready' || !CheckoutSession.canPay(this.snapshot)) return;
    const method = this.snapshot.method;
    // Cards and Instant ACH are the card flow's; the rest the element's.
    const viaCard = method === 'card' || method === 'instantAch';
    if (viaCard ? !this.cardFlow : !this.element) return;
    this.lastPay = null;
    this.lastError = null;
    this.recovered = null;
    this.confirmVia = viaCard ? 'card' : 'element';
    const paidWith =
      method === 'card' ? (this.snapshot.card?.label ?? null) : method === 'instantAch' ? INSTANT_ACH : this.snapshot.option;
    this.set({ phase: { name: 'paying' }, paidWith });
    if (method === 'card') this.cardFlow!.confirmCard();
    else if (method === 'instantAch') this.cardFlow!.confirmBank();
    else this.element!.confirm();
  }

  /** An express wallet button was tapped (Apple Pay, Google Pay): its payment has started in the card flow. */
  walletStarted(wallet: string) {
    if (this.snapshot.phase.name !== 'ready') return;
    this.lastPay = null;
    this.lastError = null;
    this.recovered = null;
    this.confirmVia = 'card';
    const name = wallet === 'apple_pay' ? 'Apple Pay' : wallet === 'google_pay' ? 'Google Pay' : wallet;
    this.set({ phase: { name: 'paying' }, paidWith: name });
  }

  /** The native view that started the payment in progress. */
  private confirmer(): { resolveConfirmation(clientSecret: string | null, errorMessage?: string): void } | null {
    return this.confirmVia === 'card' ? this.cardFlow : this.element;
  }

  /** The element made a payment method (`pm_…`): Vezmo prices and confirms the payment with it. */
  async onPaymentMethod(id: string) {
    const charge = this.snapshot.charge;
    try {
      const body = { paymentMethodId: id, localOffer: charge?.localOffer ?? null, returnUrl: this.returnUrl };
      const res =
        this.kind === 'subscription'
          ? payFromSubscription(await this.api.subscriptionPay(this.token, body))
          : await this.api.pay(this.token, body);
      this.lastPay = res;
      if (res.method) this.set({ paidMethod: res.method });
      this.confirmer()?.resolveConfirmation(res.clientSecret ?? null, res.clientSecret ? undefined : DECLINED.message);
    } catch (e) {
      const err = e instanceof VezmoApiError ? e : null;
      // No answer (a timeout, a dropped connection): the payment may have gone through all the same. Vezmo says.
      if (err?.code === 'network') {
        const landed = await this.paidAfterNoAnswer();
        if (landed) {
          this.recovered = landed;
          this.confirmer()?.resolveConfirmation(null, '');
          return;
        }
      }
      if (err?.reason === 'local_price_changed') {
        this.lastError = { code: 'unknown', message: PRICE_CHANGED };
        this.refreshOffer();
      } else {
        this.lastError = err?.toVezmoError() ?? { code: 'unknown', message: DECLINED.message };
      }
      this.confirmer()?.resolveConfirmation(null, this.lastError.message);
      if (err && (err.code === 'expired' || err.code === 'already_paid')) this.close(err);
    }
  }

  /** The element finished: completed (maybe after 3D Secure), canceled, or failed. */
  async onConfirmResult(status: 'completed' | 'canceled' | 'failed', message: string) {
    if (this.snapshot.phase.name === 'closed') return;
    if (status === 'canceled') {
      this.set({ phase: { name: 'ready', error: null } });
      return;
    }
    if (status === 'failed') {
      // The engine gave up for want of Vezmo's answer, but the payment went through; or it failed after Vezmo had
      // already taken the payment. Either way the payment is the result, never the engine's words.
      const paid = this.recovered ?? (this.lastPay ? resultFromPay(this.lastPay) : null);
      if (paid) {
        this.set({ phase: { name: 'done', result: paid } });
        return;
      }
      const answer = this.lastError ? null : await this.afterDeviceFailure();
      if (answer && 'result' in answer) {
        this.set({ phase: { name: 'done', result: answer.result } });
        return;
      }
      // Without Vezmo's answer, the engine's words only for a payment Vezmo handed it. Not paying at all, the card
      // form couldn't open, and the native side says so in our words.
      const fallback: VezmoError = this.lastPay
        ? { code: 'declined', message: message || DECLINED.message }
        : this.snapshot.phase.name === 'paying'
          ? { code: 'unknown', message: NOT_COMPLETED }
          : { code: 'unknown', message: message || NOT_COMPLETED };
      const error = this.lastError ?? answer?.error ?? fallback;
      this.set({ phase: { name: 'ready', error } });
      return;
    }
    // Completed. A payment our server already recorded is done; one finished on the device (3D Secure, a redirect)
    // is recorded now, then read back.
    const fromPay = this.lastPay ? resultFromPay(this.lastPay) : null;
    if (fromPay) {
      this.set({ phase: { name: 'done', result: fromPay } });
      return;
    }
    const intentId = intentIdOf(this.lastPay?.clientSecret);
    if (this.kind === 'subscription') {
      this.set({ phase: { name: 'done', result: await this.startedSubscription(intentId) } });
      return;
    }
    try {
      if (intentId) await this.api.confirm(this.token, intentId);
    } catch {
      /* the webhook records it either way; the status below is the answer */
    }
    this.set({ phase: { name: 'done', result: await this.settledResult() } });
  }

  /** The buyer's currency offer no longer holds: fetch the new one; the buyer sees the new amount before paying again. */
  private refreshOffer() {
    this.fetchConfig()
      .then((config) => this.apply(config, this.snapshot.payLocal))
      .catch(() => undefined);
  }

  /**
   * A payment Vezmo handed to the device (3D Secure, a redirect) that then failed there: Vezmo has the answer. A step
   * lost on the device can still have gone through (a bank app that came back late): then that is the result, as on
   * iOS and Android. Otherwise Vezmo's own words for the decline (the platforms word it differently), recorded now.
   * Null when Vezmo has no answer.
   */
  private async afterDeviceFailure(): Promise<{ result: CheckoutResult } | { error: VezmoError } | null> {
    const intentId = this.lastPay?.state === 'requires_action' ? intentIdOf(this.lastPay.clientSecret) : null;
    if (!intentId) return null;
    try {
      if (this.kind === 'subscription') {
        // Answers only when the subscription started (paid, or the trial's card saved); anything else is a 400.
        return { result: resultFromSubscriptionConfirm(await this.api.subscriptionConfirm(this.token, intentId)) };
      }
      const now = await this.api
        .status(this.token)
        .then(resultFromStatus)
        .catch(() => null);
      if (now && now.status !== 'failed') return { result: now };
      // Answers only when the payment went through or is on its way; a decline is a 400 in our words.
      await this.api.confirm(this.token, intentId);
      return { result: await this.settledResult() };
    } catch (e) {
      return e instanceof VezmoApiError && e.code === 'declined' ? { error: e.toVezmoError() } : null;
    }
  }

  /** A subscription started on the device (after 3D Secure): Vezmo records it and says how it stands. */
  private async startedSubscription(intentId: string | null): Promise<CheckoutResult> {
    const ref = this.snapshot.config?.subscription?.ref ?? '';
    try {
      if (intentId) return resultFromSubscriptionConfirm(await this.api.subscriptionConfirm(this.token, intentId));
    } catch {
      /* recorded from the processor's notice instead; the merchant's webhook tells them */
    }
    return { status: 'processing', paymentId: null, subscription: { ref, status: 'incomplete' } };
  }

  /**
   * /pay got no answer: whether the payment went through anyway, from the session's status (a subscription: whether it
   * is set up). A few tries while the connection comes back; null when Vezmo says it didn't, or can't be reached (the
   * buyer sees the network error and can pay again: Vezmo never charges a session twice).
   */
  private async paidAfterNoAnswer(): Promise<CheckoutResult | null> {
    for (let attempt = 0; attempt < 3; attempt++) {
      if (attempt > 0) await new Promise((r) => setTimeout(r, 1500));
      try {
        if (this.kind === 'subscription') {
          await this.api.subscription(this.token);
          return null; // still open: not started
        }
        const result = resultFromStatus(await this.api.status(this.token));
        return isPaid(result) ? result : null;
      } catch (e) {
        if (e instanceof VezmoApiError && e.code === 'network') continue;
        if (this.kind === 'subscription' && e instanceof VezmoApiError && e.code === 'already_paid') {
          // Started; the webhook says how (trialing or active).
          const ref = this.snapshot.config?.subscription?.ref ?? '';
          return { status: 'processing', paymentId: null, subscription: { ref, status: 'incomplete' } };
        }
        return null;
      }
    }
    return null;
  }

  /** The session's state, polled briefly while the server catches up with a payment just made. */
  private async settledResult(): Promise<CheckoutResult> {
    for (let i = 0; i < 5; i++) {
      try {
        const result = resultFromStatus(await this.api.status(this.token));
        if (result) return result;
      } catch {
        /* retry */
      }
      await new Promise((r) => setTimeout(r, 1500));
    }
    // Paid on the device and not yet visible: the webhook will tell the merchant's server.
    return { status: 'processing', paymentId: this.snapshot.config?.paymentId ?? '' };
  }

  // ── closing ────────────────────────────────────────────────────────────
  /**
   * The buyer closed the sheet. A UPI or Pix payment started here may still go through in their bank app, so Vezmo is
   * asked first. Paid: the sheet shows the receipt and stays open (null). Still waiting on the bank app: `processing`
   * (the webhook says how it ends). Otherwise `canceled`.
   */
  async closeRequested(): Promise<CheckoutResult | null> {
    const phase = this.snapshot.phase.name;
    if (!this.qrIntentId || (phase !== 'ready' && phase !== 'waiting')) return { status: 'canceled' };
    // A second tap while Vezmo is asked waits for the first.
    if (this.closing) return null;
    this.closing = true;
    try {
      const waiting = phase === 'waiting';
      this.unwatch();
      const result = await this.statusSoon().then((s) => (s ? resultFromStatus(s) : null));
      if (result) {
        if (!isPaid(result)) return { status: 'canceled' };
        await this.api.confirm(this.token, this.qrIntentId).catch(() => undefined);
        this.set({ phase: { name: 'done', result } });
        return null;
      }
      // No verdict yet: the buyer can still pay in their bank app (or Vezmo couldn't be reached).
      return waiting ? { status: 'processing', paymentId: this.snapshot.config?.paymentId ?? null } : { status: 'canceled' };
    } finally {
      this.closing = false;
    }
  }

  /** The session's status, or null when it takes more than a few seconds (the buyer is waiting for the sheet to close). */
  private statusSoon() {
    let timer: ReturnType<typeof setTimeout> | undefined;
    return Promise.race([
      this.api.status(this.token).catch(() => null),
      new Promise<null>((resolve) => {
        timer = setTimeout(() => resolve(null), 5000);
      }),
    ]).finally(() => clearTimeout(timer));
  }

  private close(e: unknown) {
    const err = e instanceof VezmoApiError ? e.toVezmoError() : { code: 'network' as const, message: 'Check your connection and try again.' };
    const error: VezmoError = err.code === 'expired' ? EXPIRED : err;
    this.set({ phase: { name: 'closed', result: { status: 'failed', error } } });
  }
}
