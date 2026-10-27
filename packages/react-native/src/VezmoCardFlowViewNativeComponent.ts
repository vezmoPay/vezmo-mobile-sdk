import type * as React from 'react';
import {
  codegenNativeCommands,
  codegenNativeComponent,
  type CodegenTypes,
  type HostComponent,
  type ViewProps,
} from 'react-native';

/**
 * Cards and wallets: the platform's native card form and its express wallet buttons (Apple Pay, Google Pay), confirmed
 * through Vezmo's server like the element. It draws only the wallet buttons; the sheet draws the Card row itself and
 * opens the card form with `presentCard`. Instant ACH too: the engine's bank step, opened by the sheet's Instant ACH row
 * with `presentBank`.
 */
export interface NativeProps extends ViewProps {
  /** Keys, account, wallets, return link and appearance. A change rebuilds the card flow. */
  configJson: string;
  /** What is charged: `{ amount, currency, card, instantAch }`. A change updates the card flow in place. */
  intentJson: string;
  onLoaded?: CodegenTypes.DirectEventHandler<Readonly<{ ok: boolean }>>;
  onLoadFailed?: CodegenTypes.DirectEventHandler<Readonly<{ message: string }>>;
  /** The wallet buttons' height (0 when this phone has none). */
  onHeightChange?: CodegenTypes.DirectEventHandler<Readonly<{ height: CodegenTypes.Double }>>;
  /** The card typed in the card form: "•••• 4242" and the network's logo as a PNG data URI; empty when none. */
  onCardOptionChange?: CodegenTypes.DirectEventHandler<Readonly<{ label: string; image: string }>>;
  /**
   * Instant ACH's bank step: whether it is set up for this payment (`available`; the row shows only then) and the bank
   * account it linked, in the engine's words (`label`, empty when none): the sheet shows only its last four.
   */
  onBankChange?: CodegenTypes.DirectEventHandler<Readonly<{ available: boolean; label: string }>>;
  /** A wallet button was tapped ("apple_pay", "google_pay"): the payment has started. */
  onWalletTap?: CodegenTypes.DirectEventHandler<Readonly<{ wallet: string }>>;
  /**
   * The buyer confirmed: here is the payment method's id (`pm_…`) for our server to price and confirm, and (Android) the
   * payment engine's own return link for a method that leaves the app ('' otherwise).
   */
  onPaymentMethod?: CodegenTypes.DirectEventHandler<Readonly<{ id: string; returnUrl: string }>>;
  /** `completed`, `canceled` or `failed` (with `message`). */
  onConfirmResult?: CodegenTypes.DirectEventHandler<Readonly<{ status: string; message: string }>>;
}

interface NativeCommands {
  /** Open the native card form (the Card row, or its Change). */
  presentCard: (viewRef: React.ElementRef<HostComponent<NativeProps>>) => void;
  /** Pay with the card from the card form. The outcome arrives in `onConfirmResult`. */
  confirmCard: (viewRef: React.ElementRef<HostComponent<NativeProps>>) => void;
  /** Open Instant ACH's bank step (the Instant ACH row, or its Change). */
  presentBank: (viewRef: React.ElementRef<HostComponent<NativeProps>>) => void;
  /** Pay with the bank account the bank step linked. The outcome arrives in `onConfirmResult`. */
  confirmBank: (viewRef: React.ElementRef<HostComponent<NativeProps>>) => void;
  /** Answer `onPaymentMethod`: the intent's client secret, or an error message to show. */
  resolveConfirmation: (
    viewRef: React.ElementRef<HostComponent<NativeProps>>,
    clientSecret: string,
    errorMessage: string,
  ) => void;
  /** The app was opened with a link (after a bank app, a pay-later provider or 3D Secure): hand it to the payment. */
  handleURL: (viewRef: React.ElementRef<HostComponent<NativeProps>>, url: string) => void;
}

export const Commands: NativeCommands = codegenNativeCommands<NativeCommands>({
  supportedCommands: ['presentCard', 'confirmCard', 'presentBank', 'confirmBank', 'resolveConfirmation', 'handleURL'],
});

export default codegenNativeComponent<NativeProps>('VezmoCardFlowView') as HostComponent<NativeProps>;
