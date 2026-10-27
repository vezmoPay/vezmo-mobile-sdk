# Changelog

## 0.2.0 (unreleased)

- **A payment method, not a confirmation token**: every payment, subscription and free trial now sends Vezmo the
  payment method the buyer chose (`paymentMethodId`, `pm_…`) instead of a confirmation token. Vezmo's server confirms
  every card payment itself, and only a payment method can be confirmed that way. 3D Secure, Apple Pay, the return
  link and the buyer's own currency work as before; nothing changes in your app. Apps on 0.1.x keep working for now:
  update to 0.2.0.
- **New repository address**: the source moved to `github.com/vezmoPay/vezmo-mobile-sdk` (the old
  `ACCEPT-GLOBAL-LIMITED` address redirects). Package metadata and links point to it.
- **Instant ACH**: buyers pay from a US bank account. When the business offers it, the sheet has an Instant ACH row
  (US dollars only, never in the buyer's own currency) that opens a secure bank-connection step; the payment confirms
  at once and the receipt reads "Paid with Instant ACH". Subscriptions save the bank account for the renewals; a free
  trial sets it up without charging. The bank step is drawn natively: the package now also brings the
  payment engine's bank-connection module (pinned to the same engine release).

## 0.1.0

The first release of the Vezmo payment sheet for native iOS apps (Swift Package Manager, `VezmoCheckout`).

- **Payment sheet**: your business, what is being paid for and the total; the buyer's own currency where Vezmo offers
  one; light and dark; your colors, corner radius and font through `appearance`. The same screens and design as the
  React Native SDK.
- **Ways to pay**: cards with 3D Secure (the Card row shows the card's own logo once typed), Apple Pay as an express
  button, Klarna, Affirm, Afterpay, Amazon Pay and Cash App in the list, UPI and Pix for buyers paying in rupees or
  reais.
- **Server-side confirmation**: the app sends a confirmation token; Vezmo prices and confirms the payment. No API key
  or secret in the app.
- **Results**: `.succeeded`, `.processing`, `.canceled` or `.failed` with an error code and a message written for the
  buyer. A receipt in the sheet: who was paid, with what, and a reference.
- **Subscriptions**: `prepare(subscriptionToken:)` starts a subscription in the app (the first payment, or a free
  trial with the card saved); `.succeeded` and `.processing` carry the `SubscriptionResult` (`ref`, `status`). The
  sheet shows what is due today, the plan and the authorization; Apple Pay shows it as a recurring payment (iOS 16+).
- **Dynamic Type**: the sheet's text follows the buyer's text size, up to the first accessibility size.
- **Declines in Vezmo's words**: a card declined after 3D Secure shows Vezmo's reason, the same as on Android.
- **Switching currency**: the Card row and Pay wait the moment the sheet takes to set the payment up again in the
  other currency, and a problem there reads in Vezmo's words, never the payment engine's.
- **Apple Pay while switching currency**: a Apple Pay tap while the sheet sets the wallet up again for the new
  amount waits for it ("Apple Pay is still loading. Try again in a moment."); the next tap pays.
- **Privacy manifest**: declares what the sheet sends Vezmo to take the payment (no tracking).
- **UIKit and SwiftUI**: `prepare(clientToken:)` and `present(from:)` with async/await, the `.vezmoCheckout` view
  modifier, and `VezmoCheckout.handleURL` for links back into the app.
- **Swift 6**: `VezmoCheckout` lives on the main actor, its results, errors and settings are `Sendable`, and
  `VezmoCheckout.handleURL` and `VezmoCheckout.version` need no `await`, so apps in Swift 6 language mode
  build cleanly (the example app does, in CI). The `.vezmoCheckout` modifier calls `onCompletion` on the main actor.
- **Apple Pay merchant country** from the session: the country of the account that processes the payment (the
  business's own on Connect, Vezmo's on merchant of record). `ApplePay.merchantCountryCode` is optional and only
  overrides it; US when the server doesn't say.
- **Closing while UPI or Pix waits**: the sheet asks Vezmo first. Paid meanwhile, it shows the receipt (`.succeeded`);
  still waiting in the buyer's bank app, the result is `.processing`, never canceled, since the buyer can still approve it.
- **No answer while paying** (a timeout, a dropped connection): the sheet checks the session before reporting
  `.network`, so a payment that went through is never reported as failed. A payment Vezmo already took
  stays the result even when the payment engine fails afterwards.
- **Test-mode badge**: a darker orange behind its white text (5.2:1, up from 3.6:1), in light and dark.
- iOS 15.1+.
