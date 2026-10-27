# Changelog

## 0.2.0 (unreleased)

- **A payment method, not a confirmation token**: the plugin now runs on the native SDKs 0.2.0
  (`com.vezmo:vezmo-checkout` 0.2.0 and the Swift package `VezmoCheckout` 0.2.0), which send Vezmo the payment method
  the buyer chose (`paymentMethodId`, `pm_…`) instead of a confirmation token, for every payment, subscription and
  free trial. Vezmo's server confirms every card payment itself, and only a payment method can be confirmed that way.
  Nothing changes in your app. Apps on 0.1.x keep working for now: update to 0.2.0.
- **New repository address**: the source moved to `github.com/vezmoPay/vezmo-mobile-sdk` (the old
  `ACCEPT-GLOBAL-LIMITED` address redirects). Package metadata and links point to it.
- **Instant ACH**: buyers pay from a US bank account. When the business offers it, the sheet has an Instant ACH row
  (US dollars only, never in the buyer's own currency) that opens a secure bank-connection step; the payment confirms
  at once and the receipt reads "Paid with Instant ACH". Subscriptions save the bank account for the renewals; a free
  trial sets it up without charging. It comes with the native SDKs the plugin runs on; nothing to change in
  your app.

## 0.1.0

The first release of the Vezmo payment sheet for Flutter apps (`vezmo_checkout`), on Vezmo's native SDKs.

- **API**: `VezmoCheckout(configuration: …)`, `prepare(clientToken: …)` or `prepare(subscriptionToken: …)`, then
  `present()`. Neither throws. Results are a sealed class: `CheckoutSucceeded`, `CheckoutProcessing`,
  `CheckoutCanceled`, `CheckoutFailed` with a `VezmoError` (`VezmoErrorCode` and a message written for the buyer).
  One sheet at a time: `present()` while it is open is a `config` error.
- **Android**: the native Vezmo Android SDK's sheet (`com.vezmo:vezmo-checkout` 0.1.0): cards with 3D Secure, Google
  Pay, Klarna, Affirm, Afterpay, Amazon Pay, Cash App, UPI and Pix, the buyer's own currency, light and dark. The
  buyer comes back from bank apps and pay-later providers by themselves. Needs a `FlutterFragmentActivity`. A
  session prepared before the activity is recreated (a configuration change) is prepared again on the new one, so
  `present()` still opens it.
- **Subscriptions**: `prepare(subscriptionToken: …)` starts a subscription (the first payment, or a free trial with
  the card saved); the result carries `subscription` (`ref`, `status`), and `paymentId` is null for a free trial.
- **Appearance**: your colors (one, or light and dark), corner radius and a native font through `VezmoAppearance`.
- **iPhone**: the native Vezmo iOS SDK's sheet (Swift package `VezmoCheckout` 0.1.0, through Swift Package Manager):
  cards with 3D Secure, Apple Pay, pay-later methods, Cash App, UPI and Pix. The plugin hands links back into the
  app to the sheet by itself. Subscriptions too.
- **Apple Pay and Google Pay merchant country** from the session: the country of the account that processes the
  payment (the business's own on Connect, Vezmo's on merchant of record). `merchantCountryCode` on
  `ApplePayOptions` and `GooglePayOptions` is optional and only overrides it.
- **Closing while UPI or Pix waits**: the sheet asks Vezmo first. Paid meanwhile, it shows the receipt (`CheckoutSucceeded`);
  still waiting in the buyer's bank app, the result is `CheckoutProcessing`, never canceled, since the buyer can still approve it.
- **No answer while paying** (a timeout, a dropped connection): the sheet checks the session before reporting
  `network`, so a payment that went through is never reported as failed. A payment Vezmo already took
  stays the result even when the payment engine fails afterwards.
- **Android**: a payment in flight is never lost or doubled when the phone's settings change or the process is stopped.
- **Test-mode badge**: a darker orange behind its white text (5.2:1, up from 3.6:1), in light and dark.
- Android 7.0+ (API 24), iOS 15.1+; Flutter 3.41+.
