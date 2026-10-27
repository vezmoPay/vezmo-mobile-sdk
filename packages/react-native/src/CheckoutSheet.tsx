import { useEffect, useMemo, useRef, useState, useSyncExternalStore, type ReactNode } from 'react';
import {
  Animated,
  BackHandler,
  Easing,
  KeyboardAvoidingView,
  Linking,
  Platform,
  Pressable,
  ScrollView,
  StyleSheet,
  View,
  useColorScheme,
} from 'react-native';
import { CheckoutSession, INSTANT_ACH } from './CheckoutSession';
import { elementConfigJson, elementIntentJson, type WalletOptions } from './elementConfig';
import { bankLabel, dateText, formatAmount, planPriceText } from './flow';
import { CardFlow, type CardFlowHandle } from './CardFlow';
import { MethodsView, type MethodsViewHandle } from './MethodsView';
import { QrForm, QrWaiting, type QrFormHandle } from './QrPanels';
import { DEFAULT_RADIUS, paletteFor, type SheetPalette, type VezmoAppearance } from './theme';
import { markForBrand } from './marks';
import type { CheckoutResult, PaidMethod, SubscriptionPlan } from './types';
import {
  BankTile,
  Banner,
  BrandTile,
  CardRow,
  Cross,
  makeStyles,
  MethodRow,
  PrimaryButton,
  ResultMark,
  RowsSkeleton,
  SecuredBy,
  Segmented,
  Skeleton,
  Text,
  type MarkKind,
  type Styles,
} from './ui';

/** Room for the home indicator or the navigation bar under the sheet. */
// ponytail: fixed inset; read the real one if a merchant app needs it to the point.
const BOTTOM_INSET = Platform.OS === 'ios' ? 30 : 28;

export interface CheckoutSheetProps {
  session: CheckoutSession;
  merchantDisplayName?: string;
  returnUrl: string | null;
  style?: 'automatic' | 'light' | 'dark';
  appearance?: VezmoAppearance;
  wallets?: WalletOptions;
  /** The sheet is finished: the buyer closed it, or tapped Done on the result. */
  onClose(result: CheckoutResult): void;
}

/**
 * The Vezmo payment sheet: the business and the total, the buyer's currency, one list of ways to pay (the native
 * element's rows and our own UPI or Pix), our Pay button and our result screens. Drawn as an overlay in the app's own
 * window (the element's native UI needs it).
 */
export function CheckoutSheet(props: CheckoutSheetProps) {
  const { session } = props;
  const snap = useSyncExternalStore(session.subscribe, session.getSnapshot);
  const element = useRef<MethodsViewHandle>(null);
  const cardFlow = useRef<CardFlowHandle>(null);
  const systemScheme = useColorScheme();
  const scheme: 'light' | 'dark' =
    props.style === 'light' || props.style === 'dark'
      ? props.style
      : snap.config?.theme === 'light' || snap.config?.theme === 'dark'
        ? snap.config.theme
        : systemScheme === 'dark'
          ? 'dark'
          : 'light';
  const radius = props.appearance?.cornerRadius ?? DEFAULT_RADIUS;
  const p = useMemo(() => paletteFor(scheme, props.appearance), [scheme, props.appearance]);
  const s = useMemo(() => makeStyles(p, radius, props.appearance?.fontFamily), [p, radius, props.appearance]);

  // The sheet rises over a fading scrim.
  const enter = useRef(new Animated.Value(0)).current;
  useEffect(() => {
    Animated.timing(enter, { toValue: 1, duration: 320, easing: Easing.out(Easing.cubic), useNativeDriver: true }).start();
  }, [enter]);

  useEffect(() => {
    session.attachElement({
      confirm: () => element.current?.confirm(),
      resolveConfirmation: (secret, message) => element.current?.resolveConfirmation(secret, message),
      clearSelection: () => element.current?.clearSelection(),
    });
    session.attachCardFlow({
      presentCard: () => cardFlow.current?.presentCard(),
      confirmCard: () => cardFlow.current?.confirmCard(),
      presentBank: () => cardFlow.current?.presentBank(),
      confirmBank: () => cardFlow.current?.confirmBank(),
      resolveConfirmation: (secret, message) => cardFlow.current?.resolveConfirmation(secret, message),
    });
    // Back from a bank app, a pay-later provider or 3D Secure in the browser: the payment waiting on the app's
    // return link finishes.
    const links = Linking.addEventListener('url', ({ url }) => cardFlow.current?.handleURL(url));
    return () => {
      links.remove();
      session.attachElement(null);
      session.attachCardFlow(null);
      session.dispose();
    };
  }, [session]);

  const { config, charge, methods, phase } = snap;
  const merchant = props.merchantDisplayName ?? config?.merchantName ?? '';
  const settings = useMemo(
    () =>
      config && charge && methods
        ? {
            config,
            methods,
            merchantDisplayName: merchant,
            returnUrl: props.returnUrl,
            scheme,
            palette: p,
            appearance: props.appearance,
            wallets: props.wallets,
            charge,
            attempt: snap.elementAttempt,
          }
        : null,
    // The element is rebuilt only for new keys, wallets or look, never for a new amount.
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [config?.publishableKey, config?.connectedAccountId, methods?.applePay, methods?.googlePay, charge?.currency, scheme, p, merchant, props.returnUrl, snap.elementAttempt],
  );
  // The element draws the other methods' rows; the card flow the card form and the express wallet buttons.
  const configJson = useMemo(() => (settings ? elementConfigJson(settings) : ''), [settings]);
  const cardConfigJson = useMemo(() => (settings ? elementConfigJson({ ...settings, withWallets: true }) : ''), [settings]);
  const intentJson = useMemo(
    () => (charge && methods ? elementIntentJson(charge, methods, config) : ''),
    [charge, methods, config],
  );
  // The native views take a moment to load: placeholder rows hold their place until both report in.
  const [loadedConfig, setLoadedConfig] = useState('');
  const [loadedCardConfig, setLoadedCardConfig] = useState('');
  // Instant ACH's bank step: whether it is set up for this payment, and for which settings it last reported.
  const bankKey = methods?.instantAch ? cardConfigJson : '';
  const [bankState, setBankState] = useState({ key: '', available: false });
  const elementLoading =
    (loadedConfig !== configJson || loadedCardConfig !== cardConfigJson || (!!bankKey && bankState.key !== bankKey)) &&
    !snap.elementError;
  const [walletsHeight, setWalletsHeight] = useState(0);

  const close = (result: CheckoutResult) => props.onClose(result);
  // The buyer closes the sheet. A UPI or Pix payment started here may still go through: the session asks Vezmo first
  // (null: it shows the receipt instead of closing).
  const { onClose } = props;
  const requestClose = useMemo(
    () => () => void session.closeRequested().then((result) => result && onClose(result)),
    [session, onClose],
  );

  // Android's back button closes the sheet, as on the native sheet (it would otherwise go back in the app beneath):
  // the result once there is one; a payment on its way finishes first.
  useEffect(() => {
    const sub = BackHandler.addEventListener('hardwareBackPress', () => {
      if (phase.name === 'done' || phase.name === 'closed') onClose(phase.result);
      else if (phase.name !== 'paying') requestClose();
      return true;
    });
    return () => sub.remove();
  }, [phase, onClose, requestClose]);

  const amount = charge ? formatAmount(charge.amountMinor, charge.currency) : '';
  // A subscription checkout: what is due today, the plan after it, and a button that says what it starts.
  const plan = config?.subscription ?? null;
  const payLabel = plan ? (plan.mode === 'setup' ? 'Start free trial' : `Subscribe · ${amount}`) : `Pay ${amount}`;
  const paying = phase.name === 'paying';
  const finished = phase.name === 'done' || phase.name === 'closed';
  const own = methods?.upi ? ('upi' as const) : methods?.pix ? ('pix' as const) : null;
  const qrForm = useRef<QrFormHandle>(null);
  // The Card row is the sheet's own; the element draws the other methods and this phone's wallet when offered.
  const cardOn = !!methods?.elementTypes.includes('card');
  const elementRows = !!methods && methods.elementTypes.some((t) => t !== 'card');
  // Instant ACH, in US dollars, when the engine's bank step is set up for this payment.
  const bankOn = !!methods?.instantAch && bankState.key === bankKey && bankState.available;
  // Placeholders for the rows about to load (the Card row, the Instant ACH row and the element's).
  const expectedRows = methods ? Math.max(1, methods.elementTypes.length + (methods.instantAch ? 1 : 0)) : 3;
  // A hairline over the pinned bottom only while content scrolls under it.
  const [scroll, setScroll] = useState({ content: 0, frame: 0 });
  const scrolls = scroll.content > scroll.frame + 1;

  return (
    <View style={StyleSheet.absoluteFill} accessibilityViewIsModal>
      <Animated.View style={[s.scrim, { opacity: enter }]} />
      <KeyboardAvoidingView behavior={Platform.OS === 'ios' ? 'padding' : undefined} style={s.stage} pointerEvents="box-none">
        <Animated.View
          style={[
            s.sheet,
            { paddingBottom: BOTTOM_INSET, transform: [{ translateY: enter.interpolate({ inputRange: [0, 1], outputRange: [80, 0] }) }] },
          ]}
        >
          {!finished && <View style={s.glow} pointerEvents="none" />}
          <View style={s.grabber} />
          {/* The result has its own way out. */}
          {!finished && (
            <Pressable
              accessibilityRole="button"
              accessibilityLabel="Close"
              disabled={paying}
              onPress={requestClose}
              style={[s.close, paying && { opacity: 0.4 }]}
              hitSlop={12}
            >
              <Cross color={p.ink2} size={11} />
            </Pressable>
          )}

          {phase.name === 'loading' && <Skeleton s={s} />}

          {finished && (
            <ResultView
              result={phase.result}
              amount={amount}
              merchant={merchant}
              plan={plan}
              paidWith={snap.paidWith}
              paidMethod={snap.paidMethod}
              s={s}
              p={p}
              onDone={() => close(phase.result)}
            />
          )}

          {!finished && phase.name !== 'loading' && config && charge && methods && (
            <>
            <ScrollView
              style={{ flexShrink: 1 }}
              keyboardShouldPersistTaps="handled"
              bounces={false}
              onLayout={(e) => {
                const frame = e.nativeEvent.layout.height;
                setScroll((v) => (v.frame === frame ? v : { ...v, frame }));
              }}
              onContentSizeChange={(_, content) => setScroll((v) => (v.content === content ? v : { ...v, content }))}
            >
              <View style={s.header}>
                <View style={s.who}>
                  <View style={s.logo}>
                    <Text style={s.logoText}>{(merchant.trim()[0] ?? '•').toUpperCase()}</Text>
                  </View>
                  <View style={s.whoText}>
                    <View style={s.merchantRow}>
                      <Text style={s.merchant} numberOfLines={1}>
                        {merchant}
                      </Text>
                      {!config.livemode && (
                        <View style={s.badge}>
                          <Text style={s.badgeText}>TEST MODE</Text>
                        </View>
                      )}
                    </View>
                    {!!config.title && (
                      <Text style={s.title} numberOfLines={1}>
                        {config.title}
                      </Text>
                    )}
                  </View>
                </View>
                <View style={{ gap: 2 }}>
                  <Text style={s.label}>{plan ? 'Due today' : 'Total'}</Text>
                  <Text style={s.amount}>{amount}</Text>
                </View>
                {plan && <PlanSummary plan={plan} s={s} />}
              </View>

              <View style={s.body}>
                {phase.name === 'waiting' ? (
                  <QrWaiting session={session} method={phase.method} qr={phase.qr} amount={amount} p={p} s={s} />
                ) : (
                  <>
                    {config.localOffer && (
                      <View style={s.section}>
                        <Text style={s.label}>Pay in</Text>
                        <Segmented
                          label="Pay in"
                          s={s}
                          disabled={paying}
                          value={snap.payLocal ? 'local' : 'price'}
                          onChange={(k) => session.choosePayLocal(k === 'local')}
                          items={[
                            {
                              key: 'local',
                              label: formatAmount(config.localOffer.amountMinor, config.localOffer.currency),
                              sub: config.localOffer.currency.toUpperCase(),
                            },
                            { key: 'price', label: formatAmount(config.amountMinor, config.currency), sub: config.currency.toUpperCase() },
                          ]}
                        />
                        {snap.payLocal && (
                          <Text style={s.hint}>
                            1 {config.currency.toUpperCase()} = {config.localOffer.rate.toFixed(4)} {config.localOffer.currency.toUpperCase()}
                          </Text>
                        )}
                      </View>
                    )}

                    {/* Express: the official Apple Pay / Google Pay button, when this phone and the business have one. */}
                    {/* Without wallet buttons it stays mounted (it holds the card form) but takes no room or gap. */}
                    <View style={walletsHeight > 1 ? s.section : { height: 0, overflow: 'hidden', marginBottom: -24 }}>
                      <CardFlow
                        ref={cardFlow}
                        configJson={cardConfigJson}
                        intentJson={intentJson}
                        onLoaded={() => setLoadedCardConfig(cardConfigJson)}
                        onLoadFailed={(message) => session.setElementError(message || 'load failed')}
                        onCardOptionChange={(card) => session.setCard(card)}
                        onBankChange={(bank) => {
                          setBankState({ key: bankKey, available: bank.available });
                          const label = bankLabel(bank.label);
                          session.setBank(bank.available && label ? { label, image: null } : null);
                        }}
                        onWalletsHeight={setWalletsHeight}
                        onWalletTap={(wallet) => session.walletStarted(wallet)}
                        onPaymentMethod={(id, returnUrl) => void session.onPaymentMethod(id, returnUrl)}
                        onConfirmResult={(status, message) => void session.onConfirmResult(status, message)}
                      />
                      {walletsHeight > 1 && (
                        <View style={s.orRow}>
                          <View style={s.orLine} />
                          <Text style={s.orText}>or pay another way</Text>
                          <View style={s.orLine} />
                        </View>
                      )}
                    </View>

                    <View style={s.section}>
                      <View style={s.labelRow}>
                        <Text style={s.label}>Payment method</Text>
                        {/* The card networks, as their real marks (the card row itself shows a plain card). */}
                        <View style={s.marks} accessible accessibilityLabel="Visa, Mastercard, American Express and Discover accepted">
                          <BrandTile mark="visa" s={s} />
                          <BrandTile mark="mastercard" s={s} />
                          <BrandTile mark="amex" s={s} />
                          <BrandTile mark="discover" s={s} />
                        </View>
                      </View>
                      <View style={s.group} accessibilityRole="radiogroup" accessibilityLabel="Payment method">
                        {elementLoading && <RowsSkeleton s={s} rows={expectedRows} />}
                        {cardOn && !elementLoading && !snap.elementError && (
                          <CardRow
                            card={snap.card}
                            selected={snap.method === 'card'}
                            disabled={paying}
                            onPress={() => session.chooseCard()}
                            onChange={() => session.changeCard()}
                            s={s}
                            p={p}
                          />
                        )}
                        {bankOn && !elementLoading && !snap.elementError && (
                          <CardRow
                            bank
                            line={cardOn}
                            card={snap.bank}
                            selected={snap.method === 'instantAch'}
                            disabled={paying}
                            onPress={() => session.chooseBank()}
                            onChange={() => session.changeBank()}
                            s={s}
                            p={p}
                          />
                        )}
                        <View style={(cardOn || bankOn) && elementRows && !elementLoading && !snap.elementError ? s.rowLine : undefined}>
                          <MethodsView
                            ref={element}
                            configJson={configJson}
                            intentJson={intentJson}
                            onPaymentOptionChange={(option) => session.setOption(option)}
                            onLoaded={() => {
                              setLoadedConfig(configJson);
                              session.setElementError(null);
                            }}
                            onLoadFailed={(message) => session.setElementError(message || 'load failed')}
                            onPaymentMethod={(id, returnUrl) => void session.onPaymentMethod(id, returnUrl)}
                            onConfirmResult={(status, message) => void session.onConfirmResult(status, message)}
                          />
                        </View>
                        {!!snap.elementError && (
                          <View style={s.empty} accessibilityLiveRegion="polite">
                            <Text testID="vezmo-element-error" style={s.emptyTitle}>
                              Couldn’t load payment options
                            </Text>
                            <Text style={s.emptyBody}>Check your connection and try again.</Text>
                          </View>
                        )}
                        {own && (
                          <MethodRow
                            icon={<BrandTile mark={own} s={s} large />}
                            title={own === 'upi' ? 'UPI' : 'Pix'}
                            sub={own === 'upi' ? 'Pay from your UPI app' : 'Instant transfer from your bank app'}
                            selected={snap.method === own}
                            disabled={paying}
                            onPress={() => session.chooseMethod(own)}
                            s={s}
                            p={p}
                          />
                        )}
                      </View>
                    </View>

                    {snap.method === 'upi' || snap.method === 'pix' ? (
                      <QrForm
                        ref={qrForm}
                        method={snap.method}
                        defaultName={config.customerName ?? ''}
                        country={config.localOffer?.country ?? null}
                        busy={paying}
                        error={phase.name === 'ready' ? (phase.error?.message ?? null) : null}
                        p={p}
                        s={s}
                        onPay={(billing) => void session.payWithQr(snap.method as 'upi' | 'pix', billing)}
                      />
                    ) : (
                      phase.name === 'ready' && phase.error && <Banner text={phase.error.message} s={s} p={p} />
                    )}
                  </>
                )}
              </View>
            </ScrollView>

            <View style={[s.dock, scrolls && s.dockLine]}>
              {phase.name === 'waiting' ? null : snap.method === 'upi' || snap.method === 'pix' ? (
                <PrimaryButton
                  lock
                  label={snap.method === 'upi' ? `Pay ${amount} with UPI` : `Get Pix code for ${amount}`}
                  busy={paying}
                  onPress={() => qrForm.current?.submit()}
                  s={s}
                  p={p}
                />
              ) : snap.elementError ? (
                <PrimaryButton testID="vezmo-retry" label="Try again" onPress={() => session.retryElement()} s={s} p={p} />
              ) : (
                <PrimaryButton
                  testID="vezmo-pay"
                  label={payLabel}
                  lock
                  disabled={!CheckoutSession.canPay(snap)}
                  busy={paying}
                  onPress={() => session.pay()}
                  s={s}
                  p={p}
                />
              )}
              {plan && phase.name !== 'waiting' && <Text style={s.consent}>{plan.consentText}</Text>}
              <SecuredBy s={s} dark={scheme === 'dark'} />
            </View>
            </>
          )}
        </Animated.View>
      </KeyboardAvoidingView>
    </View>
  );
}

/** The plan under the total: "7-day free trial · Today", then "$9.99 / month · From 23 Oct 2026". */
function PlanSummary({ plan, s }: { plan: SubscriptionPlan; s: Styles }) {
  const trial = plan.mode === 'setup';
  const next = dateText(plan.nextChargeAt);
  const price = planPriceText(plan);
  const trialText = plan.trialDays ? `${plan.trialDays}-day free trial` : 'Free trial';
  const when = next ? (trial ? `From ${next}` : `Renews ${next}`) : '';
  return (
    <View
      style={s.plan}
      accessible
      accessibilityLabel={[trial ? `${trialText}, starting today` : '', `${price}`, when].filter(Boolean).join('. ')}
    >
      {trial && (
        <View style={s.planRow}>
          <Text style={s.planTitle}>{trialText}</Text>
          <Text style={s.planSub}>Today</Text>
        </View>
      )}
      <View style={[s.planRow, trial && s.rowLine]}>
        <Text style={s.planTitle}>{price}</Text>
        {!!when && <Text style={s.planSub}>{when}</Text>}
      </View>
    </View>
  );
}

function ResultView(props: {
  result: CheckoutResult;
  amount: string;
  merchant: string;
  plan: SubscriptionPlan | null;
  paidWith: string | null;
  paidMethod: PaidMethod | null;
  s: Styles;
  p: SheetPalette;
  onDone(): void;
}) {
  const { result, s, p, plan } = props;
  const expired = result.status === 'failed' && result.error.code === 'expired';
  const sub = result.status === 'succeeded' || result.status === 'processing' ? result.subscription : undefined;
  const trialing = sub?.status === 'trialing';
  const next = dateText(plan?.nextChargeAt);
  const copy: { title: string; body: string; kind: MarkKind; action: string } =
    result.status === 'succeeded' && sub
      ? trialing
        ? { title: 'Your free trial has started', body: next ? `Nothing is charged until ${next}.` : '', kind: 'good', action: 'Done' }
        : { title: 'You’re subscribed', body: '', kind: 'good', action: 'Done' }
      : result.status === 'succeeded'
      ? { title: 'Payment successful', body: '', kind: 'good', action: 'Done' }
      : result.status === 'processing'
        ? { title: sub ? 'Subscription received' : 'Payment received', body: 'Your payment is on its way. You’ll get a confirmation when it clears.', kind: 'wait', action: 'Done' }
        : expired
          ? { title: 'Checkout expired', body: `Return to ${props.merchant || 'the app'} to start again.`, kind: 'neutral', action: 'Close' }
          : result.status === 'failed' && result.error.code === 'already_paid'
            ? { title: 'Already paid', body: result.error.message, kind: 'good', action: 'Done' }
            : result.status === 'failed'
              ? { title: 'Payment not completed', body: result.error.message, kind: 'bad', action: 'Close' }
              : { title: 'Payment canceled', body: '', kind: 'neutral', action: 'Close' };
  const paymentId = (result.status === 'succeeded' || result.status === 'processing' ? result.paymentId : '') ?? '';
  // The short reference the buyer can quote: the subscription's, else the transaction's, else the payment's own id.
  const reference = sub?.ref || (result.status === 'succeeded' && result.transactionId) || paymentId;
  // Paid with: the network's mark and last four from Vezmo's server, else the element's own label (or UPI / Pix).
  // Instant ACH: its bank and its name, whatever the account's last four.
  const bank = props.paidMethod?.type === 'instantAch' || props.paidWith === INSTANT_ACH;
  const mark = bank
    ? null
    : (markForBrand(props.paidMethod?.brand) ?? (props.paidWith === 'UPI' ? 'upi' : props.paidWith === 'Pix' ? 'pix' : null));
  const last4 = props.paidMethod?.last4;
  const paidText = bank ? INSTANT_ACH : last4 ? `•••• ${last4}` : mark === 'upi' || mark === 'pix' ? '' : (props.paidWith ?? '');
  const paidLogo = bank ? <BankTile s={s} p={p} /> : mark ? <BrandTile mark={mark} s={s} /> : null;
  const rows: [string, string, ReactNode?][] = sub
    ? [
        ['Plan', plan ? `${plan.planName} · ${planPriceText(plan)}` : ''],
        [trialing ? 'First charge' : 'Next charge', next],
        [trialing ? (bank ? 'Bank account' : 'Card') : 'Paid with', paidText || (mark ?? ''), paidLogo],
        ['Reference', reference],
      ]
    : [
        ['Paid to', props.merchant],
        ['Paid with', paidText || (mark ?? ''), paidLogo],
        ['Reference', reference],
      ];
  const shown = rows.filter(([, v]) => !!v);
  return (
    <View style={s.result}>
      <ResultMark kind={copy.kind} p={p} />
      <Text testID="vezmo-result-title" style={s.resultTitle} accessibilityRole="header">
        {copy.title}
      </Text>
      {result.status === 'succeeded' && !!props.amount && !trialing && <Text style={s.amount}>{props.amount}</Text>}
      {!!copy.body && <Text style={s.resultBody}>{copy.body}</Text>}
      {(!!paymentId || !!sub) && (
        <View style={s.receipt}>
          {shown.map(([k, v, logo], i) => (
            <View key={k} style={[s.receiptRow, i > 0 && s.rowLine]}>
              <Text style={s.receiptKey}>{k}</Text>
              <View style={{ flexDirection: 'row', alignItems: 'center', gap: 8, flexShrink: 1 }}>
                {logo}
                {!(logo && v === mark) && (
                  <Text style={s.receiptValue} numberOfLines={1} ellipsizeMode="middle" selectable>
                    {v}
                  </Text>
                )}
              </View>
            </View>
          ))}
        </View>
      )}
      <View style={{ alignSelf: 'stretch', marginTop: 24 }}>
        <PrimaryButton testID="vezmo-done" label={copy.action} ink onPress={props.onDone} s={s} p={p} />
      </View>
    </View>
  );
}
