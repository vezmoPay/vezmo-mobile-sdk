# VezmoCheckout (iOS)

The Vezmo payment sheet for native iPhone apps, in Swift. Cards with 3D Secure, Apple Pay, Instant ACH, Klarna, Affirm,
Afterpay, Amazon Pay, Cash App, UPI and Pix, in the buyer's own currency, in a native sheet. UIKit and SwiftUI.

Your server keeps your Vezmo API key. The app only ever receives a session's client token.

## Requirements

- iOS 15.1 or later, Xcode 16 or later, Swift 5.9 or later. Swift 6 apps build cleanly too: `VezmoCheckout` lives on
  the main actor (create and use it from your views and view controllers), its results are `Sendable`, and
  `VezmoCheckout.handleURL` needs no `await`.
- Your app added in the Vezmo dashboard under **Developers → Mobile apps**, with its return link (for example
  `acme://vezmo`). The buyer comes back through it after 3D Secure, a bank app or a pay-later provider.

## Install

Swift Package Manager. In Xcode, **File → Add Package Dependencies…** and enter:

```
https://github.com/vezmoPay/vezmo-mobile-sdk
```

Choose the `VezmoCheckout` library. Or in your `Package.swift`:

```swift
dependencies: [
  .package(url: "https://github.com/vezmoPay/vezmo-mobile-sdk", .upToNextMinor(from: "0.1.0")),
],
targets: [
  .target(name: "MyApp", dependencies: [.product(name: "VezmoCheckout", package: "vezmo-mobile-sdk")]),
]
```

Add your return link's scheme (`acme`) under your target's **Info → URL Types**, and `NSCameraUsageDescription` to
`Info.plist` so buyers can scan a card.

## Set up

Create one `VezmoCheckout` for the screens that take payments:

```swift
import VezmoCheckout

let vezmo = VezmoCheckout(configuration: .init(
  returnURL: URL(string: "acme://vezmo"),                    // registered under Developers → Mobile apps
  applePay: .init(merchantId: "merchant.com.acme")           // Apple Pay shows only with your Merchant ID
))
```

| Setting | What it does |
| --- | --- |
| `returnURL` | Your registered return link. Needed for 3D Secure in some banks, bank apps and pay-later methods. |
| `applePay` | `.init(merchantId:merchantCountryCode:)`. Without it the sheet shows no Apple Pay. The merchant country defaults to that of the account processing the payment, read from the session (your business's own on Connect, Vezmo's on merchant of record); set it only to override that. |
| `style` | `.automatic` (follow the phone, default), `.light` or `.dark`. |
| `appearance` | Colors, corner radius and font, below. |

Hand the app the return link when it opens:

```swift
// SwiftUI
WindowGroup { RootView().onOpenURL { VezmoCheckout.handleURL($0) } }

// UIKit (scene delegate)
func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
  contexts.forEach { VezmoCheckout.handleURL($0.url) }
}
// …and, when your return link is a universal link (https):
func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
  if let url = userActivity.webpageURL { VezmoCheckout.handleURL(url) }
}

// UIKit without scenes (app delegate)
func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
  VezmoCheckout.handleURL(url)
}
```

## Take a payment

Your server creates the session (the same API checkout session as on the web) and sends
`data.securePayment.clientToken` to the app:

```http
POST https://api.vezmo.com/api/v1/merchant/secure-payments
Authorization: Bearer <access token>
Content-Type: application/json

{
  "title": "Order #1042",
  "amount": 49.00,
  "currency": "USD",
  "client": { "name": "Ana Silva", "email": "ana@example.com", "country": "US", "postalCode": "10001" }
}
```

Get an access token with your API key and secret (`POST /api/v1/merchant/api-auth/login`, headers `x-api-key` and
`x-api-secret`); see the [Secure Payments docs](https://user.vezmo.com/docs/v1/secure-payments). Add `app.returnUrl`
only if you also open Checkout for apps.

In the app (UIKit):

```swift
func pay(orderId: String) async throws {
  let clientToken = try await myAPI.createVezmoSession(orderId)

  // Loads the session; call it as soon as you have the token.
  if let error = await vezmo.prepare(clientToken: clientToken) {
    return showError(error.message)
  }

  // Opens the sheet and returns when the buyer is done. Never throws.
  switch await vezmo.present(from: self) {
  case .succeeded(let paymentId, _, _):
    showPaid(paymentId)
  case .processing:
    showPaymentReceived() // a bank debit, UPI or Pix still settling
  case .canceled:
    break // the buyer closed the sheet
  case .failed(let error):
    showError(error.message)
  }
}
```

In SwiftUI, prepare the session, then present it with the modifier:

```swift
struct CheckoutButton: View {
  let vezmo: VezmoCheckout
  @State private var showing = false

  var body: some View {
    Button("Pay") {
      Task {
        let clientToken = try await myAPI.createVezmoSession()
        if await vezmo.prepare(clientToken: clientToken) == nil { showing = true }
      }
    }
    .vezmoCheckout(vezmo, isPresented: $showing) { result in
      // .succeeded, .processing, .canceled or .failed
    }
  }
}
```

Fulfil the order from the `payment.success` webhook, not from the result alone. The result tells your app what to
show.

### Results and errors

| Result | Meaning |
| --- | --- |
| `.succeeded(paymentId, transactionId, subscription)` | Paid. Both ids match the dashboard and the webhook. `subscription` is set for a subscription checkout; `paymentId` is nil only when a free trial started (nothing charged today). |
| `.processing(paymentId, subscription)` | Paid, money on its way (a bank debit, UPI or Pix still settling), or a UPI or Pix payment still waiting in the buyer's bank app when they closed the sheet. Wait for the webhook, which says how it ends. |
| `.canceled` | The buyer closed the sheet. Not an error. |
| `.failed(error)` | `error.code` is one of the codes below; `error.message` is written for the buyer. |

| `error.code` | What to do |
| --- | --- |
| `.declined` | The bank said no. The buyer can try another card or method. |
| `.expired` | The session ran out. Create a new one. |
| `.alreadyPaid` | The session was already paid. Treat the order as paid. |
| `.notAvailable` | This way to pay can't be used for this session. |
| `.network` | No connection. Let the buyer try again. |
| `.config` | A setup mistake in the app (for example `present` before `prepare`). |
| `.unknown` | Anything else. Let the buyer try again. |

**Closing while UPI or Pix waits.** When the buyer closes the sheet while a UPI or Pix payment waits in their bank
app, the sheet asks Vezmo first. Paid meanwhile: it shows the receipt, and the result is `.succeeded`. Still waiting:
the result is `.processing`, because the buyer can still approve it; the webhook says how it ends.

**No answer while paying.** When the payment request gets no answer (a timeout, a dropped connection), the sheet
checks the session before reporting `.network`: a payment that went through all the same is the result.

## Subscriptions

Start a subscription in the app: the first payment, or a free trial with the card saved for the renewals. Your server
creates the subscription with your API key and sends its `checkoutToken` to the app:

```http
POST https://api.vezmo.com/api/v1/merchant/subscription
Authorization: Bearer <access token>
Content-Type: application/json

{ "planId": "<plan_id>", "customerEmail": "ana@example.com", "trialDays": 7 }

→ { "success": true, "data": { "subscriptionRef": "VS7K2P9Q4FXM", "status": "TRIALING", "checkoutToken": "…" } }
```

In the app, prepare with `subscriptionToken`; everything else is the same:

```swift
if let error = await vezmo.prepare(subscriptionToken: checkoutToken) { return showError(error.message) }
switch await vezmo.present(from: self) {
case .succeeded(let paymentId, _, let subscription?):
  // subscription.ref is "VS7K2P9Q4FXM"; subscription.status is .trialing or .active.
  // paymentId is the first payment, or nil for a free trial (nothing charged today).
  showSubscribed(subscription)
case .processing(_, let subscription):
  showStarting(subscription) // .incomplete until it settles; the webhook tells your server
case .canceled:
  break
case .failed(let error):
  showError(error.message)
default:
  break
}
```

The sheet shows what is due today, the plan after it ("7-day free trial, then $9.99 / month from Oct 23, 2026"), the
authorization the buyer gives, and **Start free trial** or **Subscribe**. Cards and Apple Pay; Apple Pay shows the plan
as a recurring payment (iOS 16+) and lists it in the buyer's Wallet with their page to manage it. Renewals are charged
by Vezmo; your server hears about each one from the subscription webhooks. When the buyer starts a free trial, Vezmo
sends `subscription.trial_started`; the first charge sends `subscription.activated` (or `subscription.payment_failed`).

Apple and Google require their own in-app purchase for digital goods and services used inside the app (subscriptions
to app features or content). Use Vezmo subscriptions for real-world goods and services: deliveries, memberships,
classes, rentals, services.

## What the buyer sees

- Your business, what they're paying for and the total, with a choice of their own currency where Vezmo offers one.
- Apple Pay as one tap at the top, when the phone has it and you've set it up.
- The other ways to pay as one list: **Card** (with the card's own logo once typed), **Instant ACH** (a US bank
  account), pay-later methods, Cash App, and UPI or Pix for buyers in India or Brazil.
- One Pay button, 3D Secure when the bank asks for it, and a receipt: who was paid, with what, and a reference.

### Instant ACH

When your business offers Instant ACH, the sheet has an **Instant ACH** row for payments in US dollars ($0.50 to
$7,500). The buyer links their US bank account in a secure bank-connection step, then pays. The payment confirms at
once, as `.succeeded`, and the receipt reads **Paid with Instant ACH**. A subscription saves the bank account for its
renewals (a free trial sets it up without charging). It isn't offered when the buyer pays in their own currency.

In the sandbox, choose the **Success** test bank, and enter any six digits when asked for a code.

## Appearance

The sheet follows Vezmo's checkout design in light and dark. You can bring it closer to your app:

```swift
let vezmo = VezmoCheckout(configuration: .init(
  returnURL: URL(string: "acme://vezmo"),
  appearance: .init(
    colors: [
      .accent: .systemBlue,
      .surface: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.11, alpha: 1) : .white },
    ],
    cornerRadius: 12,
    fontFamily: "Inter" // a font already in your app
  )
))
```

The main color keys: `accent`, `onAccent`, `surface`, `surface2`, `field`, `fieldLine`, `line`, `ink`, `ink2`, `ink3`,
`good`, `bad`. A dynamic `UIColor` (or one from your asset catalog) can differ between light and dark. Setting your
own `accent` replaces the Vezmo gradient on the Pay button.

The sheet's text follows the buyer's text size (Dynamic Type), up to the first accessibility size.

## Apple Pay

1. In your Apple Developer account, create a **Merchant ID** and turn on **Apple Pay Payment Processing** for your
   app's App ID with it. In Xcode, add the **Apple Pay** capability with that Merchant ID.
2. In your Vezmo dashboard, open **Developers → Mobile apps → Apple Pay in your iPhone app** and add your Apple Merchant ID.
   Download the request file we attach, create the **Apple Pay Payment Processing Certificate** with it in your Apple
   Developer account, and upload the certificate on the same page. Apple Pay works once it shows **Active** there;
   certificates last 25 months, and the page reminds you to renew.
3. Pass the Merchant ID as `applePay: .init(merchantId: "merchant.com.acme")`.

## Testing

Create the session with your sandbox API key. Pay with the test card `4242 4242 4242 4242`, any future expiry and any
CVC; 3D Secure shows a test page where you can approve or fail the payment. `4000 0000 0000 3220` always asks for 3D
Secure. `4000 0000 0000 0002` is declined. In the sandbox, Apple Pay uses the cards in the phone's wallet without
charging them.

The [example app](https://github.com/vezmoPay/vezmo-mobile-sdk/tree/main/packages/ios/Example) pays
against Vezmo's sandbox: run `xcodegen generate` in `packages/ios/Example`, open `VezmoExample.xcodeproj`, and set the
`VEZMO_DEMO_URL` and `VEZMO_API_BASE` build settings to the sandbox (or paste a client token in the app).

## Troubleshooting

- **No Apple Pay**: no `applePay` in the configuration, the Apple Pay capability is missing, no card in the phone's
  Wallet, or the Apple Pay certificate isn't set up yet.
- **The buyer doesn't come back to the app after 3D Secure or a bank app**: the `returnURL` in your configuration
  must be a link registered under Developers → Mobile apps, your app must declare that URL scheme, and it must pass
  the link to `VezmoCheckout.handleURL`.
- **`.config` from `present`**: call `prepare(clientToken:)` first, present each prepared session once, and present
  from a view controller that is on screen.
- **"Couldn't load payment options" in the sheet**: the reason is in the app's console (Xcode or Console.app,
  subsystem `com.vezmo.checkout`). The buyer can tap **Try again**.

## App Store privacy

The package's privacy manifest declares what the sheet sends to Vezmo to take the payment, for app functionality only
and never for tracking: the payment method the buyer chooses, their name and address (asked for UPI and Pix), and for
Pix their CPF or CNPJ (as other data). The payment engine inside the package declares its own. Xcode adds both to your
app's privacy report.

It declares no location: the sheet never reads the phone's location. Vezmo offers the buyer their own currency
from the country of the network connection (its IP address) on Vezmo's server, not from the device.

## Releases

Each release is a plain semver tag at the repository root (for example `0.1.0`), equal to `VezmoCheckout.version`.
While the SDK is 0.x a minor release can change the API, so the snippet above stays on one minor version.

## License

MIT
