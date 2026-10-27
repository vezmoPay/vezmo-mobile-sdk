import { forwardRef, useImperativeHandle, useRef, useState } from 'react';
import NativeCardFlow, { Commands } from './VezmoCardFlowViewNativeComponent';

export interface CardFlowHandle {
  /** Open the native card form. */
  presentCard(): void;
  /** Pay with the card from the card form. The outcome arrives in `onConfirmResult`. */
  confirmCard(): void;
  /** Open Instant ACH's bank step. */
  presentBank(): void;
  /** Pay with the bank account the bank step linked. The outcome arrives in `onConfirmResult`. */
  confirmBank(): void;
  /** Answer `onPaymentMethod` with the intent's client secret, or an error message to show. */
  resolveConfirmation(clientSecret: string | null, errorMessage?: string): void;
  /** The app was opened with a link: finishes a payment waiting on it (iOS; Android returns by itself). */
  handleURL(url: string): void;
}

export interface CardFlowProps {
  configJson: string;
  intentJson: string;
  onLoaded?: () => void;
  onLoadFailed?: (message: string) => void;
  /** The card typed in the card form ("•••• 4242" and the network's logo as a data URI), or null. */
  onCardOptionChange?: (card: { label: string; image: string | null } | null) => void;
  /** Instant ACH's bank step: set up for this payment or not, and the linked account in the engine's words ('' when none). */
  onBankChange?: (bank: { available: boolean; label: string }) => void;
  /** The express wallet buttons' height (0 when this phone has none). */
  onWalletsHeight?: (height: number) => void;
  /** A wallet button was tapped: the payment has started. */
  onWalletTap?: (wallet: string) => void;
  onPaymentMethod: (id: string) => void;
  onConfirmResult: (status: 'completed' | 'canceled' | 'failed', message: string) => void;
}

/** Cards and wallets: the native card form (opened from the sheet's Card row) and the express wallet buttons. */
export const CardFlow = forwardRef<CardFlowHandle, CardFlowProps>(function CardFlow(props, ref) {
  const native = useRef<React.ElementRef<typeof NativeCardFlow>>(null);
  const [height, setHeight] = useState(0);

  useImperativeHandle(ref, () => ({
    presentCard() {
      if (native.current) Commands.presentCard(native.current);
    },
    confirmCard() {
      if (native.current) Commands.confirmCard(native.current);
    },
    presentBank() {
      if (native.current) Commands.presentBank(native.current);
    },
    confirmBank() {
      if (native.current) Commands.confirmBank(native.current);
    },
    resolveConfirmation(clientSecret, errorMessage) {
      if (native.current) Commands.resolveConfirmation(native.current, clientSecret ?? '', errorMessage ?? '');
    },
    handleURL(url) {
      if (native.current) Commands.handleURL(native.current, url);
    },
  }));

  return (
    <NativeCardFlow
      ref={native}
      style={{ width: '100%', height }}
      configJson={props.configJson}
      intentJson={props.intentJson}
      onLoaded={() => props.onLoaded?.()}
      onLoadFailed={(e) => props.onLoadFailed?.(e.nativeEvent.message)}
      onHeightChange={(e) => {
        const h = Math.ceil(e.nativeEvent.height);
        setHeight(h);
        props.onWalletsHeight?.(h);
      }}
      onCardOptionChange={(e) =>
        props.onCardOptionChange?.(
          e.nativeEvent.label ? { label: e.nativeEvent.label, image: e.nativeEvent.image || null } : null,
        )
      }
      onBankChange={(e) => props.onBankChange?.({ available: e.nativeEvent.available, label: e.nativeEvent.label })}
      onWalletTap={(e) => props.onWalletTap?.(e.nativeEvent.wallet)}
      onPaymentMethod={(e) => props.onPaymentMethod(e.nativeEvent.id)}
      onConfirmResult={(e) =>
        props.onConfirmResult(e.nativeEvent.status as 'completed' | 'canceled' | 'failed', e.nativeEvent.message)
      }
    />
  );
});
