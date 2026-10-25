# Changelog

## 0.1.1

The same SDK as 0.1.0, published again: 0.1.0 was removed from npm by mistake on 24 Oct 2026, and npm never lets a
removed version number be used again. Nothing changes in your app; update with `npm install @vezmopay/react-native@0.1.1`.

- **New repository address**: the source moved to `github.com/vezmoPay/vezmo-mobile-sdk` (the old
  `ACCEPT-GLOBAL-LIMITED` address redirects). Package metadata and links point to it.

## 0.1.0

The first release of the Vezmo payment sheet for React Native and Expo.

- **Payment sheet**: your business, what is being paid for and the total; the buyer's own currency where Vezmo offers
  one; light and dark; your colors, corner radius and font through `appearance`.
- **Ways to pay**: cards with 3D Secure (the Card row shows the card's own logo once typed), Apple Pay and Google Pay
  as express buttons, Klarna, Affirm, Afterpay, Amazon Pay and Cash App in the list, UPI and Pix for buyers paying in
  rupees or reais.
- **Server-side confirmation**: the app sends a confirmation token; Vezmo prices and confirms the payment. No API key
  or secret in the app.
- **Results**: `succeeded`, `processing`, `canceled` or `failed` with an error code and a message written for the
  buyer. A receipt in the sheet: who was paid, with what, and a reference.
- **Back from bank apps and pay-later providers on iPhone**: the sheet hands the app's return link to the payment
  (Cash App, Klarna, Amazon Pay, 3D Secure in the browser).
- **The payment engine's own error text is never shown**: a card form that can't open is set up again once, and
  otherwise reads in Vezmo's words (seen after switching currency on Android).
- **Wallets while switching currency**: a Google Pay or Apple Pay tap while the sheet sets the wallet up again for
  the new amount waits for it, in our words; the next tap pays.
- **Expo config plugin** for Apple Pay and the card-scanning camera text.
- **Privacy manifest** (iOS, in the pod's `VezmoReactNativePrivacy` bundle): declares what the sheet sends Vezmo to
  take the payment, as the native iOS SDK does; no tracking.
- **Subscriptions**: `prepareCheckout({ subscriptionToken })` starts a subscription in the app (the first payment,
  or a free trial with the card saved); the result carries `subscription: { ref, status }`. Apple Pay shows it as a
  recurring payment on iPhone.
- **Robust by default**: a call to Vezmo that gets no answer within 30 seconds ends as a `network` error; one sheet
  at a time (`presentCheckout()` while it is open is a `config` error); Android's back button closes the sheet; a
  decline after 3D Secure reads in Vezmo's words on both platforms, and a 3D Secure or redirect step lost on the
  device that went through anyway ends as the payment, not a decline. The sheet's text follows the buyer's text size up
  to the first accessibility size.
- **Jest mock** (`@vezmopay/react-native/jest/mock`) so your own tests run without native views or network.
- **Apple Pay and Google Pay merchant country** from the session: the country of the account that processes the
  payment (the business's own on Connect, Vezmo's on merchant of record), so non-US businesses on Connect are right
  by default. `merchantCountryCode` only overrides it; US when the server doesn't say.
- **Closing while UPI or Pix waits**: the sheet asks Vezmo first. Paid meanwhile, it shows the receipt (`succeeded`);
  still waiting in the buyer's bank app, the result is `processing`, never canceled, since the buyer can still approve it.
- **No answer while paying** (a timeout, a dropped connection): the sheet checks the session before reporting
  `network`, so a payment that went through is never reported as failed. A payment Vezmo already took
  stays the result even when the payment engine fails afterwards.
- **iPhone card form while the amount changes**: the card form and Pay wait for the card flow to be set up for the
  new amount (as on Android), where the payment engine refused them before.
- **Test-mode badge**: a darker orange behind its white text (5.2:1, up from 3.6:1), in light and dark.
- iOS 15.1+ and Android 7.0+, React Native 0.79+ with the New Architecture.
