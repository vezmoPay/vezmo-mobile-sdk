/** Where the session runs: from the checkout config, never guessed from a key. */
export type VezmoEnvironment = 'live' | 'sandbox';

/** The outcome `presentCheckout()` resolves with. It never throws. */
export type CheckoutResult =
  | {
      status: 'succeeded';
      /** The payment. Null only when a subscription's free trial started: nothing was charged today. */
      paymentId: string | null;
      transactionId: string | null;
      /** For a subscription checkout: the subscription, now `active` (first payment made) or `trialing`. */
      subscription?: SubscriptionResult;
    }
  /**
   * Paid, money on its way (a bank debit, UPI or Pix still settling), or a UPI or Pix payment the buyer started and can
   * still finish in their bank app after closing the sheet: wait for the webhook, which says how it ends.
   */
  | { status: 'processing'; paymentId: string | null; subscription?: SubscriptionResult }
  /** The buyer closed the sheet. Not an error. */
  | { status: 'canceled' }
  | { status: 'failed'; error: VezmoError };

export interface SubscriptionResult {
  /** The subscription's reference, as in the dashboard and the webhooks. */
  ref: string;
  /** `active` (the first payment went through), `trialing` (a free trial started), or `incomplete` while settling. */
  status: 'active' | 'trialing' | 'incomplete';
}

export interface VezmoError {
  /**
   * `declined` (the bank said no; the buyer can try another card), `expired` (the session ran out: create a new
   * one), `already_paid`, `not_available` (this way to pay can't be used here), `network`, `config` (a setup
   * mistake in the app), `unknown`.
   */
  code:
    | 'declined'
    | 'expired'
    | 'already_paid'
    | 'not_available'
    | 'network'
    | 'config'
    | 'unknown';
  /** Safe to show the buyer, in Vezmo's words. */
  message: string;
}

/** The buyer's own currency, offered beside the price. */
export interface LocalOffer {
  currency: string;
  amount: number;
  amountMinor: number;
  price: number;
  rate: number;
  markupPercent: number;
  usdPerUnit: number;
  expiresAt: string;
  country: string | null;
  choices?: string[];
  /** Methods offered when paying in this currency, e.g. ['upi'] for INR, ['pix'] for BRL. */
  methods?: string[];
  /** Sealed; sent back to pay in this currency. */
  token: string;
}

/** What GET …/checkout returns that the sheet uses (Vezmo API checkout config). */
export interface CheckoutConfig {
  publishableKey: string;
  /** Null for a merchant-of-record business: the platform account. */
  connectedAccountId: string | null;
  livemode: boolean;
  amount: number;
  amountMinor: number;
  currency: string;
  title: string;
  merchantName: string | null;
  enabledMethods: Partial<Record<MethodKey, boolean>>;
  bankSupported: boolean;
  customerName: string | null;
  customerEmail: string | null;
  theme: 'light' | 'dark' | 'auto' | null;
  paymentId: string;
  localOffer: LocalOffer | null;
  appReturnUrl: string | null;
  /** A subscription checkout: the plan, and what starting it means. Absent for a one-time payment. */
  subscription?: SubscriptionPlan | null;
  /**
   * The country of the account that processes the payment (the business's own on Connect, Vezmo's on merchant of
   * record): Apple Pay's and Google Pay's merchant country. Absent from a server that doesn't say.
   */
  processingCountry?: string | null;
}

/** What the buyer subscribes to (from the subscription checkout). */
export interface SubscriptionPlan {
  ref: string;
  /** `payment`: the first period is charged now. `setup`: a free trial; the card is saved, nothing is charged today. */
  mode: 'payment' | 'setup';
  planName: string;
  /** The price of each period, in the plan's currency (major units). */
  recurringAmount: number;
  currency: string;
  /** `HOUR`, `DAY`, `WEEK`, `MONTH` or `YEAR`. */
  interval: string;
  intervalCount: number;
  trialDays: number | null;
  /** When the plan's price is next charged: the trial's end, or the end of the first period. */
  nextChargeAt: string | null;
  /** The buyer's page to view or cancel the subscription. */
  manageUrl: string | null;
  /** The recurring authorization the buyer agrees to by subscribing. */
  consentText: string;
}

/** GET /subscription-checkout/:token — the subscription checkout as the API returns it. */
export interface SubscriptionView {
  subscriptionRef: string;
  status: string;
  mode: 'payment' | 'setup';
  publishableKey: string | null;
  connectedAccountId: string | null;
  amount: number;
  recurringAmount: number;
  currency: string;
  planName: string;
  interval: string;
  intervalCount: number;
  trialDays: number | null;
  merchant: { name: string; logo: string | null; color: string | null };
  customer: { email: string; name: string | null };
  consentText: string;
  localOffer: LocalOffer | null;
  livemode: boolean;
  nextChargeAt: string | null;
  manageUrl: string | null;
  /** See `CheckoutConfig.processingCountry`. */
  processingCountry?: string | null;
  /** The business offers Instant ACH for this plan (US dollars). */
  instantAchEnabled?: boolean;
}

export type MethodKey =
  | 'card'
  | 'ach'
  | 'cashapp'
  | 'applePay'
  | 'googlePay'
  | 'klarna'
  | 'affirm'
  | 'afterpayClearpay'
  | 'amazonPay'
  | 'upi'
  | 'pix'
  | 'instantAch';

/** POST …/pay — what the server did with the buyer's payment method. */
export type PayResponse = (
  | { state: 'succeeded'; paymentId: string | null; transactionId: string | null; clientSecret: string | null }
  | { state: 'processing'; paymentId: string | null; clientSecret: string | null }
  | { state: 'requires_action'; paymentId: string | null; clientSecret: string }
) & {
  /** What the buyer paid with (for the receipt): the card's network and last four, or the method. */
  method?: PaidMethod | null;
  /** A subscription checkout's subscription. */
  subscription?: SubscriptionResult;
};

/** POST /subscription-checkout/:token/pay — the subscription twin of `PayResponse`. */
export type SubscriptionPayResponse = {
  subscriptionRef: string;
  method: PaidMethod | null;
  clientSecret: string | null;
} & (
  | { state: 'succeeded'; subscriptionStatus: string; paymentId: string | null; transactionId: string | null }
  | { state: 'processing'; paymentId: string | null }
  | { state: 'requires_action'; intentId: string; clientSecret: string }
);

export interface PaidMethod {
  type: string;
  brand: string | null;
  last4: string | null;
  wallet: string | null;
}

export type SessionState =
  | 'open'
  | 'requires_action'
  | 'processing'
  | 'succeeded'
  | 'failed'
  | 'canceled';

export interface SessionStatus {
  state: SessionState;
  paymentId: string;
  transactionId: string | null;
  livemode: boolean;
}

/** Who pays with UPI or Pix (Pix also needs the CPF or CNPJ). */
export interface QrBilling {
  name: string;
  line1: string;
  city?: string;
  postalCode?: string;
  country?: string;
  email?: string;
  taxId?: string;
}

/** A started UPI or Pix payment. */
export interface QrPayment {
  status: string;
  qr: { svg: string | null; png: string | null; expiresAt: number | null } | null;
  /** UPI: opens the buyer's UPI app on this phone. */
  link: string | null;
  /** Pix: the code to paste in a bank app. */
  code: string | null;
}
