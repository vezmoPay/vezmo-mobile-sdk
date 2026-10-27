import type * as React from 'react';
import {
  codegenNativeCommands,
  codegenNativeComponent,
  type CodegenTypes,
  type HostComponent,
  type ViewProps,
} from 'react-native';

/**
 * The native methods view: the methods with rows of their own (pay-later, Cash App…), drawn by the platform's own
 * UI. Cards and wallets are the card flow's (`VezmoCardFlowViewNativeComponent`). Inputs are JSON so the native side
 * stays a thin host (see `elementConfig.ts`).
 */
export interface NativeProps extends ViewProps {
  /** Keys, account, wallets, return link and appearance. A change rebuilds the element. */
  configJson: string;
  /** What is charged: `{ amount, currency, paymentMethodTypes }`. A change updates the element in place. */
  intentJson: string;
  onLoaded?: CodegenTypes.DirectEventHandler<Readonly<{ ok: boolean }>>;
  onLoadFailed?: CodegenTypes.DirectEventHandler<Readonly<{ message: string }>>;
  onHeightChange?: CodegenTypes.DirectEventHandler<Readonly<{ height: CodegenTypes.Double }>>;
  onPaymentOptionChange?: CodegenTypes.DirectEventHandler<
    Readonly<{ paymentMethodType: string; label: string }>
  >;
  /**
   * The buyer confirmed: here is the payment method's id (`pm_…`) for our server to price and confirm, and (Android) the
   * payment engine's own return link for a method that leaves the app ('' otherwise).
   */
  onPaymentMethod?: CodegenTypes.DirectEventHandler<Readonly<{ id: string; returnUrl: string }>>;
  /** `completed`, `canceled` or `failed` (with `message`). */
  onConfirmResult?: CodegenTypes.DirectEventHandler<Readonly<{ status: string; message: string }>>;
}

interface NativeCommands {
  /** Pay with the selected method (opens 3D Secure, a wallet or a provider when needed). */
  confirm: (viewRef: React.ElementRef<HostComponent<NativeProps>>) => void;
  /** Answer `onPaymentMethod`: the intent's client secret, or an error message to show. */
  resolveConfirmation: (
    viewRef: React.ElementRef<HostComponent<NativeProps>>,
    clientSecret: string,
    errorMessage: string,
  ) => void;
  /** Unselect the element's method (the buyer chose one of the sheet's own: the card, UPI or Pix). */
  clearSelection: (viewRef: React.ElementRef<HostComponent<NativeProps>>) => void;
}

export const Commands: NativeCommands = codegenNativeCommands<NativeCommands>({
  supportedCommands: ['confirm', 'resolveConfirmation', 'clearSelection'],
});

export default codegenNativeComponent<NativeProps>(
  'VezmoMethodsView',
) as HostComponent<NativeProps>;
