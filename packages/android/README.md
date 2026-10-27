# Vezmo Checkout for Android

The Vezmo payment sheet for native Android apps (Kotlin, Jetpack Compose or Views). Cards with 3D Secure, Google Pay,
Instant ACH, Klarna, Affirm, Afterpay, Amazon Pay, Cash App, UPI and Pix, in the buyer's own currency.

Your server keeps your Vezmo API key. The app only ever receives a session's client token.

## Requirements

- Android 7.0 (API 24) or later. Compile with SDK 36, Kotlin 2.1 or later, Java 17.
- Your activity is a `ComponentActivity` (`AppCompatActivity` and `FragmentActivity` are).
- Your app added in the Vezmo dashboard under **Developers → Mobile apps** as an Android app, with its package name
  (`applicationId`). Cash App and the pay-later methods bring the buyer back to the sheet only for a registered package.

## Install

```kotlin
// build.gradle.kts
dependencies {
    implementation("com.vezmo:vezmo-checkout:0.1.0")
}
```

The library is published to Maven Central with the release; `mavenCentral()` must be in your repositories. A release
build shrunk with R8 needs no rules of your own: the example app pays end to end minified in CI.

Nothing else to set up: after a bank app, a pay-later provider or 3D Secure in the browser, the buyer comes back to
the open sheet by itself.

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

In an activity, create `VezmoCheckout` in `onCreate` (it registers for the sheet's result, so it must exist before
the activity starts):

```kotlin
class CheckoutActivity : ComponentActivity() {
    private lateinit var vezmo: VezmoCheckout

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        vezmo = VezmoCheckout(this, VezmoConfiguration()) { result ->
            when (result) {
                is CheckoutResult.Succeeded -> showPaid(result.paymentId)
                is CheckoutResult.Processing -> showPaymentReceived() // a bank debit, UPI or Pix still settling
                CheckoutResult.Canceled -> Unit // the buyer closed the sheet
                is CheckoutResult.Failed -> showError(result.error.message)
            }
        }
    }

    private fun pay(orderId: String) = lifecycleScope.launch {
        val clientToken = myApi.createVezmoSession(orderId)
        // Loads the session; call it as soon as you have the token.
        vezmo.prepare(clientToken)?.let { error -> return@launch showError(error.message) }
        // Opens the sheet. The result arrives in the callback above.
        vezmo.present()
    }
}
```

In Compose:

```kotlin
@Composable
fun PayButton(orderId: String) {
    val scope = rememberCoroutineScope()
    val vezmo = rememberVezmoCheckout(VezmoConfiguration()) { result ->
        // the same results as above
    }
    Button(onClick = {
        scope.launch {
            val error = vezmo.prepare(myApi.createVezmoSession(orderId))
            if (error == null) vezmo.present() else showError(error.message)
        }
    }) { Text("Pay") }
}
```

Neither `prepare()` nor `present()` throws. Fulfil the order from the `payment.success` webhook, not from the result
alone. The result tells your app what to show.

### Results and errors

| Result | Meaning |
| --- | --- |
| `Succeeded` | Paid. `paymentId` and `transactionId` match the dashboard and the webhook. A subscription also has `subscription` (`ref`, `status`); `paymentId` is null when a free trial started. |
| `Processing` | Paid, money on its way (a bank debit, UPI or Pix still settling), or a UPI or Pix payment still waiting in the buyer's bank app when they closed the sheet. Wait for the webhook, which says how it ends. |
| `Canceled` | The buyer closed the sheet (or pressed Back). Not an error. |
| `Failed` | `error.code` is one of the codes below; `error.message` is written for the buyer. |

| `VezmoError.Code` | What to do |
| --- | --- |
| `Declined` | The bank said no. The buyer can try another card or method. |
| `Expired` | The session ran out. Create a new one. |
| `AlreadyPaid` | The session was already paid. Treat the order as paid. |
| `NotAvailable` | This way to pay can't be used for this session. |
| `Network` | No connection. Let the buyer try again. |
| `Config` | A setup mistake in the app (for example `present()` before `prepare()`). |
| `Unknown` | Anything else. Let the buyer try again. |

**Closing while UPI or Pix waits.** When the buyer closes the sheet while a UPI or Pix payment waits in their bank
app, the sheet asks Vezmo first. Paid meanwhile: it shows the receipt, and the result is `Succeeded`. Still waiting:
the result is `Processing`, because the buyer can still approve it; the webhook says how it ends.

**No answer while paying.** When the payment request gets no answer (a timeout, a dropped connection), the sheet
checks the session before reporting `Network`: a payment that went through all the same is the result.

**A payment in flight is never lost or doubled.** The sheet isn't recreated for a configuration change (rotation,
font size, language, dark mode). When Android recreates it anyway, or stops the app's process in the background, the
result is still that payment's.

`prepare()` returns the same `VezmoError` when the session can't be paid (expired, already paid, a bad token).

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

```kotlin
vezmo.prepare(subscriptionToken = checkoutToken)?.let { error -> return@launch showError(error.message) }
vezmo.present()

// In your result callback:
if (result is CheckoutResult.Succeeded && result.subscription != null) {
    // result.subscription: SubscriptionResult(ref = "VS7K2P9Q4FXM", status = Trialing or Active)
    // result.paymentId is the first payment, or null for a free trial (nothing charged today)
}
```

The sheet shows what is due today, the plan after it ("7-day free trial, then $9.99 / month from Oct 23, 2026"), the
authorization the buyer gives, and **Start free trial** or **Subscribe**. Cards and Google Pay. Renewals are charged
by Vezmo; your server hears about each one from the subscription webhooks. When the buyer starts a free trial, Vezmo
sends `subscription.trial_started`; the first charge sends `subscription.activated` (or `subscription.payment_failed`).

Apple and Google require their own in-app purchase for digital goods and services used inside the app (subscriptions
to app features or content). Use Vezmo subscriptions for real-world goods and services: deliveries, memberships,
classes, rentals, services.

## Configuration

| `VezmoConfiguration` | What it does |
| --- | --- |
| `returnUrl` | Not used on Android: the buyer returns to the open sheet by themselves. |
| `googlePay` | `GooglePayOptions(merchantCountryCode = …)`. Google Pay shows when your business offers it and the phone has it, with or without this; sandbox sessions use Google's test environment. The merchant country defaults to that of the account processing the payment, read from the session (your business's own on Connect, Vezmo's on merchant of record); set it only to override that. |
| `style` | `VezmoStyle.Automatic` (follow the phone, default), `Light` or `Dark`. |
| `appearance` | Colors, corner radius and font, below. |

## What the buyer sees

- Your business, what they're paying for and the total, with a choice of their own currency where Vezmo offers one.
- Google Pay as one tap at the top, when the phone has it.
- The other ways to pay as one list: **Card** (with the card's own logo once typed), **Instant ACH** (a US bank
  account), pay-later methods, Cash App, and UPI or Pix for buyers in India or Brazil.
- One Pay button, 3D Secure when the bank asks for it, and a receipt: who was paid, with what, and a reference.

### Instant ACH

When your business offers Instant ACH, the sheet has an **Instant ACH** row for payments in US dollars ($0.50 to
$7,500). The buyer links their US bank account in a secure bank-connection step, then pays. The payment confirms at
once, as `Succeeded`, and the receipt reads **Paid with Instant ACH**. A subscription saves the bank account for its
renewals (a free trial sets it up without charging). It isn't offered when the buyer pays in their own currency.

In the sandbox, choose the **Success** test bank, and enter any six digits when asked for a code.

## Appearance

The sheet follows Vezmo's checkout design in light and dark. You can bring it closer to your app:

```kotlin
VezmoConfiguration(
    appearance = VezmoAppearance(
        colors = VezmoColors(
            accent = VezmoColor(0xFF0A84FF.toInt()),
            surface = VezmoColor(light = 0xFFFFFFFF.toInt(), dark = 0xFF1C1C1E.toInt()),
        ),
        cornerRadius = 12f,
        fontResId = R.font.inter, // a font or font family in your app
    ),
)
```

The main color keys: `accent`, `onAccent`, `surface`, `surface2`, `field`, `fieldLine`, `line`, `ink`, `ink2`, `ink3`,
`good`, `bad`. Each takes one color or a light and a dark one. Setting your own `accent` replaces the Vezmo gradient on
the Pay button.

## Google Pay

Google Pay needs no code: the library turns on the Google Pay API in your app's manifest, and the button shows when
your business offers Google Pay and the phone has it. In the sandbox it uses Google's test environment and the cards
in the phone's Google Wallet, without charging them.

Before your app takes live Google Pay payments, ask Google for production access in the **Google Pay & Wallet
Console**: add your app, choose the **gateway** integration when asked how you take payments, and send the screenshots
of your checkout that Google asks for.

## Testing

Create the session with your sandbox API key. Pay with the test card `4242 4242 4242 4242`, any future expiry and any
CVC; 3D Secure shows a test page where you can approve or fail the payment. `4000 0000 0000 3220` always asks for 3D
Secure. `4000 0000 0000 0002` is declined.

The [example app](https://github.com/vezmoPay/vezmo-mobile-sdk/tree/main/packages/android/example)
pays against Vezmo's sandbox with no setup.

## Troubleshooting

- **"LifecycleOwner … is attempting to register while current state is RESUMED"**: `VezmoCheckout(activity, …)` was
  created after `onCreate`. Create it in `onCreate`, or use `rememberVezmoCheckout` in Compose.
- **The `Config` error "Call prepare() before present()"**: `present()` needs a successful `prepare()` first, each
  time.
- **No Google Pay**: the business doesn't offer it yet, or the phone has no Google Wallet card.

## Development

```sh
cd packages/android
gradle :checkout:testDebugUnitTest :checkout:lintRelease   # unit tests and lint (Gradle 8.14, JDK 17)
gradle :example:installRelease                             # the example app on a connected phone
```

CI (`.github/workflows/android.yml`) runs the tests, lint and a local Maven publish, then pays end to end on an
Android emulator with Maestro (`e2e/maestro`): on both business models (Connect and merchant of record), a card with
3D Secure, a decline, a payment and a subscription in AED, and a subscription's free trial and its first payment; once,
cancel, a bad token, Cash App and Instant ACH on the merchant-of-record business, dark-mode screenshots, and screenshots
of the UPI, Pix, Instant ACH, subscription and result states (`checkout/src/androidTest`).

To release, set `VERSION_NAME` in `gradle.properties` and push a tag `android-v<version>` (first of the four SDKs;
see [RELEASING.md](https://github.com/vezmoPay/vezmo-mobile-sdk/blob/main/RELEASING.md)).
`release-android.yml` signs and uploads to Maven Central (needs the `MAVEN_CENTRAL_USERNAME`,
`MAVEN_CENTRAL_PASSWORD`, `SIGNING_KEY` and `SIGNING_KEY_PASSWORD` secrets); release the validated upload in the
Central Portal.

## License

MIT
