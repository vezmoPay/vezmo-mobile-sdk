# vezmo_checkout

The Vezmo payment sheet for Flutter apps. Cards with 3D Secure, Google Pay, Apple Pay, Instant ACH, Klarna, Affirm,
Afterpay, Amazon Pay, Cash App, UPI and Pix, in the buyer's own currency, in a native sheet. Payments and
subscriptions.

Your server keeps your Vezmo API key. The app only ever receives a session's client token.

The sheet is drawn by Vezmo's native SDKs, so it looks and behaves exactly like the sheet in a native app.

## Requirements

- Flutter 3.41 or later (Dart 3.11).
- **Android**: Android 7.0 (API 24) or later, `compileSdk` 36, Kotlin 2.1 or later, Java 17. Your `MainActivity`
  extends `FlutterFragmentActivity` (below).
- **iPhone**: iOS 15.1 or later, Xcode 16 or later, with Swift Package Manager (Flutter's default).
- Your app added in the Vezmo dashboard under **Developers → Mobile apps**, with its return link (for example
  `acme://vezmo`). For Android, add it as an Android app too, with its package name (`applicationId`): Cash App and the
  pay-later methods need it there.

## Install

```sh
flutter pub add vezmo_checkout
```

### Android

The sheet reports its result through your activity, so `MainActivity` must be a `FlutterFragmentActivity` (as with
other payment plugins). In `android/app/src/main/kotlin/…/MainActivity.kt`:

```kotlin
import io.flutter.embedding.android.FlutterFragmentActivity

class MainActivity : FlutterFragmentActivity()
```

In `android/app/src/main/AndroidManifest.xml`, remove `android:taskAffinity=""` from `MainActivity` if it is there
(new Flutter apps have it). With it, the buyer can't come back from a bank app, Cash App or a pay-later provider to
the open sheet.

And in `android/app/build.gradle.kts`, at least Android 7.0:

```kotlin
android {
    defaultConfig {
        minSdk = 24
    }
}
```

Nothing else to set up: after a bank app, a pay-later provider or 3D Secure in the browser, the buyer comes back to
the open sheet by themselves.

### iPhone

The plugin uses Vezmo's iOS SDK through Swift Package Manager, which Flutter turns on by default (if your app turned
it off: `flutter config --enable-swift-package-manager`). Set the iOS version to at least 15.1 (in Xcode, Runner →
General → Minimum Deployments).

In `ios/Runner/Info.plist`, add your return link's scheme (`acme` for `acme://vezmo`) and the camera text used to
scan a card:

```xml
<key>CFBundleURLTypes</key>
<array>
  <dict>
    <key>CFBundleURLSchemes</key>
    <array><string>acme</string></array>
  </dict>
</array>
<key>NSCameraUsageDescription</key>
<string>Scan your card to fill in its details.</string>
```

The plugin hands the links that come back to the app (3D Secure, bank apps, pay-later providers) to the sheet by
itself.

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

In the app, create one `VezmoCheckout` for the screens that take payments:

```dart
import 'package:vezmo_checkout/vezmo_checkout.dart';

final vezmo = VezmoCheckout(
  configuration: const VezmoConfiguration(
    returnUrl: 'acme://vezmo', // registered under Developers → Mobile apps
    applePay: ApplePayOptions(merchantId: 'merchant.com.acme'), // Apple Pay shows only with your Merchant ID
  ),
);

Future<void> pay(String orderId) async {
  final clientToken = await myApi.createVezmoSession(orderId);

  // Loads the session; call it as soon as you have the token.
  final error = await vezmo.prepare(clientToken: clientToken);
  if (error != null) return showError(error.message);

  // Opens the sheet and completes when the buyer is done. Never throws.
  switch (await vezmo.present()) {
    case CheckoutSucceeded(:final paymentId):
      showPaid(paymentId);
    case CheckoutProcessing():
      showPaymentReceived(); // a bank debit, UPI or Pix still settling
    case CheckoutCanceled():
      break; // the buyer closed the sheet
    case CheckoutFailed(:final error):
      showError(error.message);
  }
}
```

Neither `prepare()` nor `present()` throws. Fulfil the order from the `payment.success` webhook, not from the result
alone. The result tells your app what to show.

| `VezmoConfiguration` | What it does |
| --- | --- |
| `returnUrl` | Your registered return link. On iPhone it brings the buyer back after 3D Secure, a bank app or a pay-later provider; Android needs no link. |
| `applePay` | `ApplePayOptions(merchantId: …)`. Without it the sheet shows no Apple Pay. The merchant country defaults to that of the account processing the payment, read from the session (your business's own on Connect, Vezmo's on merchant of record); set `merchantCountryCode` only to override that. |
| `googlePay` | `GooglePayOptions()`. Google Pay shows when your business offers it and the phone has it. The merchant country comes from the session, as for Apple Pay. |
| `style` | `VezmoStyle.automatic` (follow the phone, default), `light` or `dark`. |
| `appearance` | Colors, corner radius and font, below. |

### Results and errors

`present()` completes with one of four results (a sealed class, so a `switch` covers them all):

| Result | Meaning |
| --- | --- |
| `CheckoutSucceeded` | Paid. `paymentId` and `transactionId` match the dashboard and the webhook. A subscription also has `subscription` (`ref`, `status`); `paymentId` is null when a free trial started. |
| `CheckoutProcessing` | Paid, money on its way (a bank debit, UPI or Pix still settling), or a UPI or Pix payment still waiting in the buyer's bank app when they closed the sheet. Wait for the webhook, which says how it ends. |
| `CheckoutCanceled` | The buyer closed the sheet (or pressed Back). Not an error. |
| `CheckoutFailed` | `error.code` is one of the codes below; `error.message` is written for the buyer. |

| `VezmoErrorCode` | What to do |
| --- | --- |
| `declined` | The bank said no. The buyer can try another card or method. |
| `expired` | The session ran out. Create a new one. |
| `alreadyPaid` | The session was already paid. Treat the order as paid. |
| `notAvailable` | This way to pay can't be used for this session. |
| `network` | No connection. Let the buyer try again. |
| `config` | A setup mistake in the app (for example `present()` before `prepare()`, or while the sheet is already open). |
| `unknown` | Anything else. Let the buyer try again. |

**Closing while UPI or Pix waits.** When the buyer closes the sheet while a UPI or Pix payment waits in their bank
app, the sheet asks Vezmo first. Paid meanwhile: it shows the receipt, and the result is `CheckoutSucceeded`. Still waiting:
the result is `CheckoutProcessing`, because the buyer can still approve it; the webhook says how it ends.

**No answer while paying.** When the payment request gets no answer (a timeout, a dropped connection), the sheet
checks the session before reporting `network`: a payment that went through all the same is the result.

**A payment in flight is never lost or doubled (Android).** The sheet isn't recreated for a configuration change
(rotation, font size, language, dark mode). When Android recreates it anyway, or stops the app's process in the
background, the result is still that payment's.

`prepare()` returns the same `VezmoError` when the session can't be paid (expired, already paid, a bad token).
`result.toJson()` gives the result in the same JSON shape as Vezmo's React Native package, for your logs.

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

In the app, pass it as `subscriptionToken`; everything else is the same:

```dart
final error = await vezmo.prepare(subscriptionToken: checkoutToken);
if (error != null) return showError(error.message);
final result = await vezmo.present();
if (result case CheckoutSucceeded(:final paymentId, :final subscription?)) {
  // subscription.ref: 'VS7K2P9Q4FXM'; subscription.status: SubscriptionStatus.trialing or .active
  // paymentId is the first payment, or null for a free trial (nothing charged today)
}
```

The sheet shows what is due today, the plan after it ("7-day free trial, then $9.99 / month from Oct 23, 2026"), the
authorization the buyer gives, and **Start free trial** or **Subscribe**. Cards, Google Pay and Apple Pay (on iPhone,
Apple Pay shows the plan as a recurring payment). Renewals are charged by Vezmo; your server hears about each one from
the subscription webhooks. When the buyer starts a free trial, Vezmo sends `subscription.trial_started`; the first
charge sends `subscription.activated` (or `subscription.payment_failed`).

## What the buyer sees

- Your business, what they're paying for and the total, with a choice of their own currency where Vezmo offers one.
- Google Pay (or Apple Pay) as one tap at the top, when the phone has it.
- The other ways to pay as one list: **Card** (with the card's own logo once typed), **Instant ACH** (a US bank
  account), pay-later methods, Cash App, and UPI or Pix for buyers in India or Brazil.
- One Pay button, 3D Secure when the bank asks for it, and a receipt: who was paid, with what, and a reference.

### Instant ACH

When your business offers Instant ACH, the sheet has an **Instant ACH** row for payments in US dollars ($0.50 to
$7,500). The buyer links their US bank account in a secure bank-connection step, then pays. The payment confirms at
once, as `CheckoutSucceeded`, and the receipt reads **Paid with Instant ACH**. A subscription saves the bank account for its
renewals (a free trial sets it up without charging). It isn't offered when the buyer pays in their own currency.

In the sandbox, choose the **Success** test bank, and enter any six digits when asked for a code.

## Appearance

The sheet follows Vezmo's checkout design in light and dark. You can bring it closer to your app:

```dart
const VezmoConfiguration(
  returnUrl: 'acme://vezmo',
  appearance: VezmoAppearance(
    colors: {
      VezmoColorKey.accent: VezmoColor(Color(0xFF0A84FF)),
      VezmoColorKey.surface: VezmoColor(Color(0xFFFFFFFF), dark: Color(0xFF1C1C1E)),
    },
    cornerRadius: 12,
    fontFamily: 'inter',
  ),
)
```

The main color keys: `accent`, `onAccent`, `surface`, `surface2`, `field`, `fieldLine`, `line`, `ink`, `ink2`, `ink3`,
`good`, `bad`. Each takes one color, or one for light and one for dark. Setting your own `accent` replaces the Vezmo
gradient on the Pay button.

The sheet is native, so `fontFamily` names a font on the native side, not a Flutter asset: on Android a font resource
(`android/app/src/main/res/font/inter.ttf` → `'inter'`; keep it in release builds with
`tools:keep="@font/inter"` in `res/raw/keep.xml`), on iPhone the font's PostScript or family name.

## Google Pay

Google Pay needs no code: the plugin turns on the Google Pay API in your app's manifest, and the button shows when
your business offers Google Pay and the phone has it. In the sandbox it uses Google's test environment and the cards
in the phone's Google Wallet, without charging them. Before your app takes live Google Pay payments, ask Google for
production access in the **Google Pay & Wallet Console**: add your app, choose the **gateway** integration when asked
how you take payments, and send the screenshots of your checkout that Google asks for.

## Apple Pay

1. In your Apple Developer account, create a **Merchant ID** and turn on **Apple Pay Payment Processing** for your
   app's App ID with it. In Xcode, add the **Apple Pay** capability to the Runner target with that Merchant ID.
2. In your Vezmo dashboard, open **Developers → Mobile apps → Apple Pay in your iPhone app** and add your Apple Merchant ID.
   Download the request file we attach, create the **Apple Pay Payment Processing Certificate** with it in your Apple
   Developer account, and upload the certificate on the same page. Apple Pay works once it shows **Active** there;
   certificates last 25 months, and the page reminds you to renew.
3. Pass the Merchant ID as `applePay: ApplePayOptions(merchantId: 'merchant.com.acme')`.

## Testing

Create the session with your sandbox API key. Pay with the test card `4242 4242 4242 4242`, any future expiry and any
CVC; 3D Secure shows a test page where you can approve or fail the payment. `4000 0000 0000 3220` always asks for 3D
Secure. `4000 0000 0000 0002` is declined.

The [example app](https://github.com/vezmoPay/vezmo-mobile-sdk/tree/main/packages/flutter/example) pays
against Vezmo's sandbox with no setup: `cd example && flutter run`. In the sandbox, Apple Pay and Google Pay use the
cards in the phone's wallet without charging them.

In your own widget tests, there is no native side: `prepare()` returns a `config` error. Put `VezmoCheckout` behind
your own interface, or answer the `vezmo_checkout` method channel with
`TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler`: `prepare` answers
`null` (ready) and `present` answers a result as `CheckoutResult.toJson()` writes it.

## Store rules

Apple and Google require their own in-app purchase for digital goods and services used inside the app (subscriptions
to app features or content, in-game items). Use Vezmo for real-world goods and services: deliveries, memberships,
classes, rentals, services.

## App Store privacy

On iPhone the plugin runs on the iOS SDK, whose privacy manifest declares what the sheet sends to Vezmo to take the
payment, for app functionality only and never for tracking: the payment method the buyer chooses, their name and
address (asked for UPI and Pix), and for Pix their CPF or CNPJ (as other data). Xcode adds it, and the payment
engine's own, to your app's privacy report.

It declares no location: the sheet never reads the phone's location. Vezmo offers the buyer their own currency
from the country of the network connection (its IP address) on Vezmo's server, not from the device.

## Troubleshooting

- **The `config` error "Vezmo checkout needs a FlutterFragmentActivity"**: your `MainActivity` extends
  `FlutterActivity`. Make it extend `FlutterFragmentActivity`.
- **The `config` error "Vezmo checkout must be set up while your activity is created"** (Android, an app that adds
  Flutter to an existing screen): the Flutter engine was attached to the activity after it started. Attach it in the
  activity's `onCreate`.
- **The `config` error "Call prepare() before present()"**: `present()` needs a successful `prepare()` first, each
  time, on the same `VezmoCheckout`.
- **After Cash App, a bank app or a pay-later provider the buyer stays in the browser**: remove
  `android:taskAffinity=""` from `MainActivity` in `AndroidManifest.xml`.
- **No Google Pay**: the business doesn't offer it yet, or the phone has no Google Wallet card.
- **No Apple Pay**: no `applePay` in the configuration, the Apple Pay capability is missing on the Runner target, no
  card in the phone's Wallet, or the Apple Pay certificate isn't set up yet.
- **iOS build: "plugin vezmo_checkout does not support CocoaPods"**: turn Swift Package Manager back on with
  `flutter config --enable-swift-package-manager`.

## Development

```sh
cd packages/flutter
flutter analyze && flutter test
cd example && flutter run
```

To build the Android side against this repository's Android SDK rather than a release, build it into Maven local
first (`gradle -p packages/android :checkout:publishToMavenLocal`, Gradle 8.14, JDK 17) and set
`ORG_GRADLE_PROJECT_vezmoMavenLocal=true` when you build the example.

On iPhone, Xcode needs the plugin's folder to be named `vezmo_checkout` (as it is when installed from pub.dev). To run
the example on an iPhone from this repository, reach the plugin through such a folder first:

```sh
ln -s flutter ../vezmo_checkout   # from packages/flutter
printf 'dependency_overrides:\n  vezmo_checkout:\n    path: ../../vezmo_checkout\n' > example/pubspec_overrides.yaml
```

To build the iPhone side against a commit of this repository's iOS SDK rather than a release, set
`VEZMO_IOS_SDK_REVISION` to that commit (pushed to GitHub): `VEZMO_IOS_SDK_REVISION=$(git rev-parse HEAD) flutter build
ios --simulator`.

CI (`.github/workflows/flutter.yml`) runs the analysis and tests, then pays end to end from the example app with
Maestro (`e2e/maestro`), on an Android emulator and an iPhone simulator alike. On both business models (Connect and
merchant of record): a card with 3D Secure, a decline, a payment and a subscription in AED, and a subscription's free
trial and its first payment. Once: cancel, a bad token, Cash App and Instant ACH on the merchant-of-record business,
and the sheet in dark mode.

To release, push a tag `flutter-v<version>` after the Android and iOS SDKs it pins are out; the release order and
every place the version lives are in
[RELEASING.md](https://github.com/vezmoPay/vezmo-mobile-sdk/blob/main/RELEASING.md). `release-flutter.yml` publishes
to pub.dev from GitHub Actions, with no stored secret.

## License

MIT
