import { describe, expect, it, jest } from '@jest/globals';
import { VezmoApiError } from '../api';
import { CheckoutSession } from '../CheckoutSession';
import { elementConfigJson, elementIntentJson } from '../elementConfig';
import { chargeOf, configFromSubscription, intentIdOf, planPriceText, sheetMethods } from '../flow';
import { paletteFor } from '../theme';
import type { SubscriptionView } from '../types';

const view = (over: Partial<SubscriptionView> = {}): SubscriptionView => ({
  subscriptionRef: 'SUB-1',
  status: 'INCOMPLETE',
  mode: 'setup',
  publishableKey: 'pk_test_x',
  connectedAccountId: null,
  amount: 0,
  recurringAmount: 9.99,
  currency: 'USD',
  planName: 'Club',
  interval: 'MONTH',
  intervalCount: 1,
  trialDays: 7,
  merchant: { name: 'Acme', logo: null, color: null },
  customer: { email: 'ana@example.com', name: 'Ana' },
  consentText: 'I authorize Acme to charge my payment method $9.99 every month after my 7-day free trial, until I cancel.',
  localOffer: null,
  livemode: false,
  nextChargeAt: '2026-10-23T07:00:00.000Z',
  manageUrl: 'https://acme.test/manage/x',
  ...over,
});

function setup(v: SubscriptionView = view()) {
  const api = {
    subscription: jest.fn<any>().mockResolvedValue(v),
    subscriptionPay: jest.fn<any>(),
    subscriptionConfirm: jest.fn<any>(),
    checkout: jest.fn<any>(),
    pay: jest.fn<any>(),
  };
  const cardFlow = {
    presentCard: jest.fn(),
    confirmCard: jest.fn(),
    presentBank: jest.fn(),
    confirmBank: jest.fn(),
    resolveConfirmation: jest.fn(),
  };
  const session = new CheckoutSession(api as any, 'subtok', 'acme://vezmo', 'subscription');
  session.attachCardFlow(cardFlow);
  return { api, cardFlow, session };
}

const choose = (session: CheckoutSession) => {
  session.changeCard();
  session.setCard({ label: '•••• 4242', image: null });
};

describe('subscriptions in the sheet', () => {
  it('a free trial: nothing due today, cards and wallets only, a setup intent saved for later', () => {
    const config = configFromSubscription(view());
    const charge = chargeOf(config, false);
    const methods = sheetMethods(config, charge);
    expect(charge.amountMinor).toBe(0);
    expect(methods).toMatchObject({ elementTypes: ['card'], applePay: true, googlePay: true, upi: false, pix: false });
    expect(JSON.parse(elementIntentJson(charge, methods, config))).toMatchObject({
      amount: 0,
      mode: 'setup',
      setupFutureUsage: 'off_session',
      paymentMethodTypes: [],
    });
    expect(planPriceText(config.subscription!)).toBe('$9.99 / month');
    expect(planPriceText({ ...config.subscription!, intervalCount: 3 })).toBe('$9.99 every 3 months');
  });

  it('Instant ACH when the business offers it for the plan: set up for a trial, kept for the renewals', () => {
    const trial = configFromSubscription(view({ instantAchEnabled: true }));
    const trialCharge = chargeOf(trial, false);
    expect(JSON.parse(elementIntentJson(trialCharge, sheetMethods(trial, trialCharge), trial))).toMatchObject({
      instantAch: true,
      mode: 'setup',
      setupFutureUsage: 'off_session',
    });
    const paid = configFromSubscription(view({ mode: 'payment', amount: 9.99, trialDays: null, instantAchEnabled: true }));
    const charge = chargeOf(paid, false);
    expect(JSON.parse(elementIntentJson(charge, sheetMethods(paid, charge), paid))).toMatchObject({
      instantAch: true,
      mode: 'payment',
      setupFutureUsage: 'off_session',
    });
    expect(sheetMethods(configFromSubscription(view()), trialCharge).instantAch).toBe(false);
  });

  it('a first payment keeps the card for renewals; a one-time payment does not', () => {
    const config = configFromSubscription(view({ mode: 'payment', amount: 9.99, trialDays: null }));
    const charge = chargeOf(config, false);
    expect(JSON.parse(elementIntentJson(charge, sheetMethods(config, charge), config))).toMatchObject({
      amount: 999,
      mode: 'payment',
      setupFutureUsage: 'off_session',
    });
    const oneTime = { ...config, subscription: null };
    expect(JSON.parse(elementIntentJson(charge, sheetMethods(oneTime, charge), oneTime))).toMatchObject({
      mode: 'payment',
      setupFutureUsage: null,
    });
  });

  it('Apple Pay gets the plan as a recurring payment, with the trial and the page to manage it', () => {
    const config = configFromSubscription(view());
    const charge = chargeOf(config, false);
    const json = JSON.parse(
      elementConfigJson({
        config,
        methods: sheetMethods(config, charge),
        merchantDisplayName: 'Acme',
        returnUrl: null,
        scheme: 'light',
        palette: paletteFor('light'),
        wallets: { applePay: { merchantId: 'merchant.com.acme' } },
        charge,
        withWallets: true,
      }),
    );
    expect(json.applePay.recurring).toMatchObject({
      label: 'Club',
      amount: '9.99',
      intervalUnit: 'month',
      intervalCount: 1,
      startDate: '2026-10-23T07:00:00.000Z',
      trialEndDate: '2026-10-23T07:00:00.000Z',
      managementUrl: 'https://acme.test/manage/x',
      dueToday: '0.00',
    });
  });

  it('Apple Pay and Google Pay take the processing country from the session; the app’s own wins; US without one', () => {
    const base = configFromSubscription({ ...view(), processingCountry: 'AE' });
    const json = (config: typeof base, wallets: Parameters<typeof elementConfigJson>[0]['wallets']) => {
      const charge = chargeOf(config, false);
      return JSON.parse(
        elementConfigJson({
          config,
          methods: sheetMethods(config, charge),
          merchantDisplayName: 'Acme',
          returnUrl: null,
          scheme: 'light',
          palette: paletteFor('light'),
          wallets,
          charge,
          withWallets: true,
        }),
      );
    };
    const fromSession = json(base, { applePay: { merchantId: 'merchant.com.acme' } });
    expect(fromSession.applePay.merchantCountryCode).toBe('AE');
    expect(fromSession.googlePay.merchantCountryCode).toBe('AE');
    const own = json(base, { applePay: { merchantId: 'merchant.com.acme', merchantCountryCode: 'gb' }, googlePay: { merchantCountryCode: 'GB' } });
    expect(own.applePay.merchantCountryCode).toBe('GB');
    expect(own.googlePay.merchantCountryCode).toBe('GB');
    const older = json(configFromSubscription(view()), { applePay: { merchantId: 'merchant.com.acme' } });
    expect(older.applePay.merchantCountryCode).toBe('US');
    expect(older.googlePay.merchantCountryCode).toBe('US');
  });

  it('starts a free trial: our server confirms it, the result names the subscription', async () => {
    const t = setup();
    await t.session.load();
    choose(t.session);
    t.api.subscriptionPay.mockResolvedValue({
      state: 'succeeded',
      subscriptionRef: 'SUB-1',
      subscriptionStatus: 'trialing',
      paymentId: null,
      transactionId: null,
      clientSecret: 'seti_1_secret_a',
      method: { type: 'card', brand: 'visa', last4: '4242', wallet: null },
    });
    t.session.pay();
    expect(t.cardFlow.confirmCard).toHaveBeenCalled();
    await t.session.onPaymentMethod('pm_1');
    expect(t.api.subscriptionPay).toHaveBeenCalledWith('subtok', {
      paymentMethodId: 'pm_1',
      localOffer: null,
      returnUrl: 'acme://vezmo',
      engineReturnUrl: null,
    });
    expect(t.cardFlow.resolveConfirmation).toHaveBeenCalledWith('seti_1_secret_a', undefined);
    await t.session.onConfirmResult('completed', '');
    expect(t.session.getSnapshot().phase).toEqual({
      name: 'done',
      result: {
        status: 'succeeded',
        paymentId: null,
        transactionId: null,
        subscription: { ref: 'SUB-1', status: 'trialing' },
      },
    });
    expect(t.api.pay).not.toHaveBeenCalled();
  });

  it('3D Secure on the first payment: finished on the device, then recorded with /confirm', async () => {
    const t = setup(view({ mode: 'payment', amount: 9.99, trialDays: null }));
    await t.session.load();
    choose(t.session);
    t.api.subscriptionPay.mockResolvedValue({
      state: 'requires_action',
      subscriptionRef: 'SUB-1',
      intentId: 'pi_9',
      clientSecret: 'pi_9_secret_b',
      method: null,
    });
    t.api.subscriptionConfirm.mockResolvedValue({ status: 'active', subscriptionRef: 'SUB-1', paymentId: 'pay_9', transactionId: 'VT9' });
    t.session.pay();
    await t.session.onPaymentMethod('pm_1');
    expect(t.cardFlow.resolveConfirmation).toHaveBeenCalledWith('pi_9_secret_b', undefined);
    await t.session.onConfirmResult('completed', '');
    expect(t.api.subscriptionConfirm).toHaveBeenCalledWith('subtok', 'pi_9');
    expect(t.session.getSnapshot().phase).toEqual({
      name: 'done',
      result: { status: 'succeeded', paymentId: 'pay_9', transactionId: 'VT9', subscription: { ref: 'SUB-1', status: 'active' } },
    });
  });

  it('a decline at our /confirm after 3D Secure (the engine completed) leaves the sheet ready, in our words', async () => {
    const t = setup(view({ mode: 'payment', amount: 9.99, trialDays: null }));
    await t.session.load();
    choose(t.session);
    t.api.subscriptionPay.mockResolvedValue({
      state: 'requires_action',
      subscriptionRef: 'SUB-1',
      clientSecret: 'pi_9_secret_b',
      method: null,
    });
    t.api.subscriptionConfirm.mockRejectedValue(new VezmoApiError('declined', 'Payment declined by your bank (issuer).', 400));
    t.session.pay();
    await t.session.onPaymentMethod('pm_1');
    await t.session.onConfirmResult('completed', '');
    expect(t.api.subscriptionConfirm).toHaveBeenCalledWith('subtok', 'pi_9');
    expect(t.session.getSnapshot().phase).toEqual({
      name: 'ready',
      error: { code: 'declined', message: 'Payment declined by your bank (issuer).' },
    });
  });

  it('a used or unknown subscription link closes the sheet as expired', async () => {
    const t = setup();
    t.api.subscription.mockRejectedValue(new VezmoApiError('expired', 'This subscription link is no longer valid.', 404));
    await t.session.load();
    expect(t.session.getSnapshot().phase).toMatchObject({ name: 'closed', result: { status: 'failed', error: { code: 'expired' } } });
  });

  it('reads a free trial’s setup intent for /confirm', () => {
    expect(intentIdOf('seti_1AbC_secret_xyz')).toBe('seti_1AbC');
    expect(intentIdOf('pi_1AbC_secret_xyz')).toBe('pi_1AbC');
  });
});
