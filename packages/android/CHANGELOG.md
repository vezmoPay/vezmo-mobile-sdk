# Changelog

## 0.2.0 (unreleased)

- **A payment method, not a confirmation token**: every payment, subscription and free trial now sends Vezmo the
  payment method the buyer chose (`paymentMethodId`, `pm_…`) instead of a confirmation token. Vezmo's server confirms
  every card payment itself, and only a payment method can be confirmed that way. 3D Secure, Google Pay and the
  buyer's own currency work as before; nothing changes in your app. Apps on 0.1.x keep working for now: update to
  0.2.0.
- **Cash App and pay-later methods need your app registered**: the sheet now sends Vezmo its own way back into the
  sheet for a method that leaves the app, and Vezmo takes it only for an Android app added under **Developers → Mobile
  apps** with its package name (`applicationId`). Cards, Google Pay and Instant ACH work without it.
- **New repository address**: the source moved to `github.com/vezmoPay/vezmo-mobile-sdk` (the old
  `ACCEPT-GLOBAL-LIMITED` address redirects). Package metadata and links point to it.
- **Instant ACH**: buyers pay from a US bank account. When the business offers it, the sheet has an Instant ACH row
  (US dollars only, never in the buyer's own currency) that opens a secure bank-connection step; the payment confirms
  at once and the receipt reads "Paid with Instant ACH". Subscriptions save the bank account for the renewals; a free
  trial sets it up without charging. The bank step is drawn natively: the library now also brings the payment
  engine's bank-connection module (pinned to the same engine release).

## 0.1.0

The first release of the Vezmo payment sheet for native Android apps (`com.vezmo:vezmo-checkout`).

- **Payment sheet**: your business, what is being paid for and the total; the buyer's own currency where Vezmo offers
  one; light and dark; your colors, corner radius and font through `VezmoAppearance`. The same sheet, copy and
  results as the React Native package.
- **Ways to pay**: cards with 3D Secure (the Card row shows the card's own logo once typed), Google Pay as an express
  button, Klarna, Affirm, Afterpay, Amazon Pay and Cash App in the list, UPI and Pix for buyers paying in rupees or
  reais.
- **Server-side confirmation**: the app sends a confirmation token; Vezmo prices and confirms the payment. No API key
  or secret in the app.
- **Results**: `Succeeded`, `Processing`, `Canceled` or `Failed` with a `VezmoError` code and a message written for
  the buyer. A receipt in the sheet: who was paid, with what, and a reference.
- **API**: `VezmoCheckout(activity, configuration) { result -> }` for activities, `rememberVezmoCheckout` for
  Compose; `prepare(clientToken)` and `present()`.
- **Back from bank apps and pay-later providers**: the buyer returns to the open sheet by themselves; nothing to add to
  your manifest.
- **Subscriptions**: `prepare(subscriptionToken = …)` starts a subscription in the app (the first payment, or a free
  trial with the card saved); the result carries `subscription` (`ref`, `status`), and `paymentId` is null for a free
  trial. The sheet shows what is due today, the plan and the authorization the buyer gives.
- Both business models: sessions of a merchant-of-record business (no connected account) load and pay the same way.
- **Declines in Vezmo's words**: a card declined after 3D Secure shows Vezmo's reason, the same as on iPhone.
- **Switching currency**: the Card row and Pay wait the moment the sheet takes to set the payment up again in the
  other currency, and a problem there reads in Vezmo's words, never the payment engine's.
- **Google Pay while switching currency**: a Google Pay tap while the sheet sets the wallet up again for the new
  amount waits for it ("Google Pay is still loading. Try again in a moment."); the next tap pays.
- **Large font sizes**: the sheet's buttons, fields and labels grow with the phone's font size instead of clipping.
- **Google Pay merchant country** from the session: the country of the account that processes the payment (the
  business's own on Connect, Vezmo's on merchant of record). `GooglePayOptions.merchantCountryCode` is optional and
  only overrides it; US when the server doesn't say.
- **Closing while UPI or Pix waits**: the sheet asks Vezmo first. Paid meanwhile, it shows the receipt (`Succeeded`);
  still waiting in the buyer's bank app, the result is `Processing`, never canceled, since the buyer can still approve it.
- **No answer while paying** (a timeout, a dropped connection): the sheet checks the session before reporting
  `Network`, so a payment that went through is never reported as failed. A payment Vezmo already took
  stays the result even when the payment engine fails afterwards.
- **A payment in flight is never lost or doubled**: the sheet's activity is no longer recreated for a font size,
  language or other configuration change (only rotation, size and dark mode were handled), and when Android recreates
  it anyway, or the process was stopped in the background, the payment still ends as its result.
- **Test-mode badge**: a darker orange behind its white text (5.2:1, up from 3.6:1), in light and dark.
- Minified (R8) release builds need no extra rules.
- Android 7.0+ (API 24), compiled against SDK 36.
