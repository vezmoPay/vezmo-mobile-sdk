# @vezmopay/react-native

The Vezmo payment sheet for React Native and Expo apps. Cards with 3D Secure, Apple Pay, Google Pay, Instant ACH,
Klarna, Affirm, Afterpay, Amazon Pay, Cash App, UPI and Pix, in the buyer's own currency, drawn natively on iPhone and
Android.

Your server keeps your Vezmo API key. The app only ever receives a session's client token.

Full guide: [Vezmo docs → Mobile → React Native SDK](https://user.vezmo.com/docs/v1/mobile/react-native)

## Requirements

- React Native 0.79 or later with the **New Architecture**. Expo SDK 53 or later (React Native 0.79) with a
  development build (not Expo Go).
- iOS 15.1 or later. Android 7.0 (API 24) or later.
- Your app added in the Vezmo dashboard under **Developers → Mobile apps**, with its return link (for example
  `acme://vezmo`). The buyer comes back through it after 3D Secure, a bank app or a pay-later provider.

## Install

```sh
npx expo install @vezmopay/react-native
# or, in a bare React Native app
npm install @vezmopay/react-native && cd ios && pod install
```

In Expo, add the config plugin. It turns on Apple Pay with your Apple Merchant ID and adds the camera text used to scan
a card:

```json
{
  "expo": {
    "scheme": "acme",
    "plugins": [["@vezmopay/react-native", { "merchantIdentifier": "merchant.com.acme" }]]
  }
}
```

In a bare app, add the Apple Pay capability with your Merchant ID in Xcode and `NSCameraUsageDescription` to
`Info.plist`. Add your return link's scheme (for example `acme`) under the target's **Info → URL Types**, and hand
the links that open your app to React Native in `AppDelegate`:

```swift
import React

func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
  RCTLinkingManager.application(app, open: url, options: options)
}
```

## Set up

Wrap your app (or the screens that take payments) once. The sheet is drawn inside the provider, so put it high in
the tree. If the provider unmounts while the sheet is open, `presentCheckout()` resolves with `canceled`.

```tsx
import { VezmoProvider } from '@vezmopay/react-native';

export default function App() {
  return (
    <VezmoProvider
      returnUrl="acme://vezmo" // registered under Developers → Mobile apps
      applePay={{ merchantId: 'merchant.com.acme' }} // Apple Pay shows only with your Merchant ID
    >
      <Root />
    </VezmoProvider>
  );
}
```

| Prop | What it does |
| --- | --- |
| `returnUrl` | Your registered return link (iPhone; Android brings the buyer back by itself). Needed for 3D Secure in some banks, bank apps and pay-later methods. |
| `applePay` | `{ merchantId, merchantCountryCode? }`. Without it the sheet shows no Apple Pay. The merchant country defaults to that of the account processing the payment, read from the session (your business's own on Connect, Vezmo's on merchant of record); set it only to override that. |
| `googlePay` | `{ merchantCountryCode? }`. Google Pay shows on phones that have it; sandbox sessions use Google's test environment. The merchant country comes from the session, as for Apple Pay. |
| `style` | `'automatic'` (follow the phone, default), `'light'` or `'dark'`. |
| `appearance` | Colors, corner radius and font, below. |

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

In the app:

```tsx
import { useVezmoCheckout } from '@vezmopay/react-native';

function PayButton({ orderId }: { orderId: string }) {
  const { prepareCheckout, presentCheckout } = useVezmoCheckout();

  const pay = async () => {
    const { clientToken } = await myApi.createVezmoSession(orderId);

    // Loads the session; call it as soon as you have the token.
    const prep = await prepareCheckout({ clientToken });
    if (prep.error) return showError(prep.error.message);

    // Opens the sheet and resolves when the buyer is done. Never throws.
    const result = await presentCheckout();
    switch (result.status) {
      case 'succeeded':
        return showPaid(result.paymentId);
      case 'processing':
        return showPaymentReceived(); // a bank debit, UPI or Pix still settling
      case 'canceled':
        return; // the buyer closed the sheet
      case 'failed':
        return showError(result.error.message);
    }
  };

  return <Button title="Pay" onPress={pay} />;
}
```

Fulfil the order from the `payment.success` webhook, not from the result alone. The result tells your app what to
show.

### Results and errors

| `result.status` | Meaning |
| --- | --- |
| `succeeded` | Paid. `paymentId` and `transactionId` match the dashboard and the webhook. A subscription also has `subscription` (`ref`, `status`); `paymentId` is null when a free trial started. |
| `processing` | Paid, money on its way (a bank debit, UPI or Pix still settling), or a UPI or Pix payment still waiting in the buyer's bank app when they closed the sheet. Wait for the webhook, which says how it ends. |
| `canceled` | The buyer closed the sheet (or pressed Back on Android). Not an error. |
| `failed` | `error.code` is one of the codes below; `error.message` is written for the buyer. |

| `error.code` | What to do |
| --- | --- |
| `declined` | The bank said no. The buyer can try another card or method. |
| `expired` | The session ran out. Create a new one. |
| `already_paid` | The session was already paid. Treat the order as paid. |
| `not_available` | This way to pay can't be used for this session. |
| `network` | No connection, or Vezmo didn't answer within 30 seconds. Let the buyer try again. |
| `config` | A setup mistake in the app (for example `presentCheckout()` before `prepareCheckout()`, or while the sheet is already open). |
| `unknown` | Anything else. Let the buyer try again. |

**Closing while UPI or Pix waits.** When the buyer closes the sheet while a UPI or Pix payment waits in their bank
app, the sheet asks Vezmo first. Paid meanwhile: it shows the receipt, and the result is `succeeded`. Still waiting:
the result is `processing`, because the buyer can still approve it; the webhook says how it ends.

**No answer while paying.** When the payment request gets no answer (a timeout, a dropped connection), the sheet
checks the session before reporting `network`: a payment that went through all the same is the result.

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

```tsx
const prep = await prepareCheckout({ subscriptionToken: checkoutToken });
if (prep.error) return showError(prep.error.message);
const result = await presentCheckout();
if (result.status === 'succeeded') {
  // result.subscription: { ref: 'VS7K2P9Q4FXM', status: 'trialing' | 'active' }
  // result.paymentId is the first payment, or null for a free trial (nothing charged today)
}
```

The sheet shows what is due today, the plan after it ("7-day free trial, then $9.99 / month from Oct 23, 2026"), the
authorization the buyer gives, and **Start free trial** or **Subscribe**. Cards, Apple Pay and Google Pay; on iPhone,
Apple Pay shows the plan as a recurring payment and lists it in the buyer's Wallet with their page to manage it.
Renewals are charged by Vezmo; your server hears about each one from the subscription webhooks. When the buyer
starts a free trial, Vezmo sends `subscription.trial_started`; the first charge sends `subscription.activated` (or
`subscription.payment_failed`).

Apple and Google require their own in-app purchase for digital goods and services used inside the app (subscriptions
to app features or content). Use Vezmo subscriptions for real-world goods and services: deliveries, memberships,
classes, rentals, services.

## What the buyer sees

- Your business, what they're paying for and the total, with a choice of their own currency where Vezmo offers one.
- Apple Pay or Google Pay as one tap at the top, when the phone has it and you've set it up.
- The other ways to pay as one list: **Card** (with the card's own logo once typed), **Instant ACH** (a US bank
  account), pay-later methods, Cash App, and UPI or Pix for buyers in India or Brazil.
- One Pay button, 3D Secure when the bank asks for it, and a receipt: who was paid, with what, and a reference.
- Light or dark, and their own text size (the sheet's text grows up to the first accessibility size).

### Instant ACH

When your business offers Instant ACH, the sheet has an **Instant ACH** row for payments in US dollars ($0.50 to
$7,500). The buyer links their US bank account in a secure bank-connection step, then pays. The payment confirms at
once, as `succeeded`, and the receipt reads **Paid with Instant ACH**. A subscription saves the bank account for its
renewals (a free trial sets it up without charging). It isn't offered when the buyer pays in their own currency.

In the sandbox, choose the **Success** test bank, and enter any six digits when asked for a code.

## Appearance

The sheet follows Vezmo's checkout design in light and dark. You can bring it closer to your app:

```tsx
<VezmoProvider
  returnUrl="acme://vezmo"
  appearance={{
    colors: { accent: '#0A84FF', surface: { light: '#FFFFFF', dark: '#1C1C1E' } },
    cornerRadius: 12,
    fontFamily: 'Inter', // a font already loaded in your app
  }}
>
```

The main color keys: `accent`, `onAccent`, `surface`, `surface2`, `field`, `fieldLine`, `line`, `ink`, `ink2`, `ink3`, `good`,
`bad`. Each takes one color or `{ light, dark }`. Setting your own `accent` replaces the Vezmo gradient on the Pay
button.

## Apple Pay

1. In your Apple Developer account, create a **Merchant ID** and turn on **Apple Pay Payment Processing** for your
   app's App ID with it.
2. In your Vezmo dashboard, open **Developers → Mobile apps → Apple Pay in your iPhone app** and add your Apple Merchant ID.
   Download the request file we attach, create the **Apple Pay Payment Processing Certificate** with it in your Apple
   Developer account, and upload the certificate on the same page. Apple Pay works once it shows **Active** there;
   certificates last 25 months, and the page reminds you to renew.
3. Pass the Merchant ID to `VezmoProvider` (`applePay.merchantId`) and, in Expo, to the plugin.

## Google Pay

Google Pay shows on Android phones where the buyer has it; sandbox sessions use Google's test environment, with
nothing to set up. Before your app takes live Google Pay payments, ask Google for production access in the **Google
Pay & Wallet Console**: add your app, choose the **gateway** integration when asked how you take payments, and send the
screenshots of your checkout that Google asks for.

## Testing

Create the session with your sandbox API key. Pay with the test card `4242 4242 4242 4242`, any future expiry and any
CVC; 3D Secure shows a test page where you can approve or fail the payment. `4000 0000 0000 3220` always asks for 3D
Secure. `4000 0000 0000 0002` is declined. In the sandbox, Apple Pay and Google Pay use the cards in the phone's wallet
without charging them.

The [example app](https://github.com/vezmoPay/vezmo-mobile-sdk/tree/main/packages/react-native/example)
pays against Vezmo's sandbox with no setup.

### In your Jest tests

The package ships a mock with no native views and no network. `presentCheckout()` resolves with a successful payment
unless you pick another result:

```ts
jest.mock('@vezmopay/react-native', () => require('@vezmopay/react-native/jest/mock'));

import * as vezmo from '@vezmopay/react-native';

beforeEach(() => (vezmo as any).mockReset());

it('shows the canceled state', async () => {
  (vezmo as any).mockNextResult({ status: 'canceled' });
  // render your screen and press Pay…
});
```

`mockPrepareError({ code, message })` makes `prepareCheckout()` fail. Both hook functions are `jest.fn()`s.

## Troubleshooting

- **"VezmoMethodsView was not found in the UIManager"**: the app runs the old architecture, or is Expo Go. Turn
  on the New Architecture and use a development build.
- **No Apple Pay**: no `applePay.merchantId` on the provider, no card in the phone's Wallet, or the Apple Pay
  certificate isn't set up yet.
- **The buyer doesn't come back to the app after 3D Secure or a bank app (iPhone)**: the `returnUrl` on
  `VezmoProvider` must be a link registered under Developers → Mobile apps, and your app must open that scheme (in a
  bare app: URL Types and `RCTLinkingManager`, above).

## App Store privacy

The package's privacy manifest (in its pod) declares what the sheet sends to Vezmo to take the payment, for app
functionality only and never for tracking: the payment method the buyer chooses, their name and address (asked for UPI
and Pix), and for Pix their CPF or CNPJ (as other data). The payment engine's pod declares its own. Xcode adds both to
your app's privacy report.

It declares no location: the sheet never reads the phone's location. Vezmo offers the buyer their own currency
from the country of the network connection (its IP address) on Vezmo's server, not from the device.

## License

MIT
