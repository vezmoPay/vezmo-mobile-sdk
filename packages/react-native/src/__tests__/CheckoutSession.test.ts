import { beforeEach, describe, expect, it, jest } from '@jest/globals';
import { VezmoApiError } from '../api';
import { CheckoutSession } from '../CheckoutSession';
import type { CheckoutConfig } from '../types';

const config: CheckoutConfig = {
  publishableKey: 'pk_test_x',
  connectedAccountId: 'acct_1',
  livemode: false,
  amount: 49,
  amountMinor: 4900,
  currency: 'USD',
  title: 'Order',
  merchantName: 'Acme',
  enabledMethods: { card: true, klarna: true },
  bankSupported: false,
  customerName: null,
  customerEmail: null,
  theme: null,
  paymentId: 'pay_1',
  localOffer: null,
  appReturnUrl: 'acme://vezmo',
};

function setup() {
  const api = {
    checkout: jest.fn<any>().mockResolvedValue(config),
    pay: jest.fn<any>(),
    confirm: jest.fn<any>().mockResolvedValue({ payment: { id: 'pay_1', transactionId: 'VT1' } }),
    status: jest.fn<any>().mockResolvedValue({ state: 'succeeded', paymentId: 'pay_1', transactionId: 'VT1', livemode: false }),
    intent: jest.fn<any>().mockResolvedValue({ id: 'pi_7', clientSecret: 'pi_7_secret_q', connectedAccountId: 'acct_1', livemode: false }),
    startQr: jest.fn<any>().mockResolvedValue({ status: 'requires_action', qr: null, link: 'upi://pay?pa=x', code: null }),
    checkoutPageUrl: jest.fn((t: string) => `https://api.test/v1/secure-payments/${t}`),
  };
  const element = { confirm: jest.fn(), resolveConfirmation: jest.fn(), clearSelection: jest.fn() };
  const cardFlow = {
    presentCard: jest.fn(),
    confirmCard: jest.fn(),
    presentBank: jest.fn(),
    confirmBank: jest.fn(),
    resolveConfirmation: jest.fn(),
  };
  const session = new CheckoutSession(api as any, 'tok', 'acme://vezmo/return');
  session.attachElement(element);
  session.attachCardFlow(cardFlow);
  return { api, element, cardFlow, session };
}

describe('CheckoutSession', () => {
  let t: ReturnType<typeof setup>;
  beforeEach(async () => {
    t = setup();
    await t.session.load();
  });

  it('loads the session and offers card plus the enabled methods', () => {
    const s = t.session.getSnapshot();
    expect(s.phase).toEqual({ name: 'ready', error: null });
    expect(s.charge).toEqual({ amountMinor: 4900, currency: 'USD', localOffer: null });
    expect(s.methods?.elementTypes).toEqual(['card', 'klarna']);
  });

  it('a card paid by the server: hands the element the secret, the result is the server’s', async () => {
    const method = { type: 'card', brand: 'visa', last4: '4242', wallet: null };
    t.api.pay.mockResolvedValue({ state: 'succeeded', paymentId: 'pay_1', transactionId: 'VT1', clientSecret: 'pi_1_secret_a', method });
    t.session.setOption({ label: '•••• 4242' });
    t.session.pay();
    expect(t.element.confirm).toHaveBeenCalled();
    // Android hands the engine's own way back for a method that leaves the app; the API client picks the platform's.
    await t.session.onPaymentMethod('pm_1', 'stripesdk://payment_return_url/com.acme.shop');
    // The receipt's Visa mark and last four come from the server's reading of the payment.
    expect(t.session.getSnapshot().paidMethod).toEqual(method);
    expect(t.api.pay).toHaveBeenCalledWith('tok', {
      paymentMethodId: 'pm_1',
      localOffer: null,
      returnUrl: 'acme://vezmo/return',
      engineReturnUrl: 'stripesdk://payment_return_url/com.acme.shop',
    });
    expect(t.element.resolveConfirmation).toHaveBeenCalledWith('pi_1_secret_a', undefined);
    await t.session.onConfirmResult('completed', '');
    expect(t.session.getSnapshot().phase).toEqual({
      name: 'done',
      result: { status: 'succeeded', paymentId: 'pay_1', transactionId: 'VT1' },
    });
    expect(t.api.confirm).not.toHaveBeenCalled();
  });

  it('3D Secure finished on the device is recorded with /confirm, then read back', async () => {
    t.api.pay.mockResolvedValue({ state: 'requires_action', paymentId: 'pay_1', clientSecret: 'pi_9_secret_b' });
    t.session.pay();
    await t.session.onPaymentMethod('pm_1');
    await t.session.onConfirmResult('completed', '');
    expect(t.api.confirm).toHaveBeenCalledWith('tok', 'pi_9');
    expect(t.session.getSnapshot().phase).toMatchObject({ name: 'done', result: { status: 'succeeded', transactionId: 'VT1' } });
  });

  it('a decline at our /confirm after 3D Secure (the engine completed) leaves the sheet ready, in our words', async () => {
    // A card our server confirms (manual confirmation): back from 3D Secure the engine reports completed, and the bank's
    // answer comes from our confirm step.
    t.api.pay.mockResolvedValue({ state: 'requires_action', paymentId: 'pay_1', clientSecret: 'pi_9_secret_b' });
    t.api.status.mockResolvedValue({ state: 'failed', paymentId: 'pay_1', transactionId: null, livemode: false });
    t.api.confirm.mockRejectedValue(new VezmoApiError('declined', 'Payment declined by your bank (issuer).', 400));
    t.session.pay();
    await t.session.onPaymentMethod('pm_1');
    await t.session.onConfirmResult('completed', '');
    expect(t.api.confirm).toHaveBeenCalledWith('tok', 'pi_9');
    expect(t.session.getSnapshot().phase).toEqual({
      name: 'ready',
      error: { code: 'declined', message: 'Payment declined by your bank (issuer).' },
    });
    // A step still running: the status says how it stands, as before.
    t.api.status.mockResolvedValue({ state: 'succeeded', paymentId: 'pay_1', transactionId: 'VT1', livemode: false });
    t.api.confirm.mockRejectedValue(new VezmoApiError('declined', 'Still verifying.', 400, 'requires_action'));
    t.session.pay();
    await t.session.onPaymentMethod('pm_2');
    await t.session.onConfirmResult('completed', '');
    expect(t.session.getSnapshot().phase).toMatchObject({ name: 'done', result: { status: 'succeeded' } });
  });

  it('a decline goes back to the element in our words and leaves the sheet ready to retry', async () => {
    t.api.pay.mockRejectedValue(new VezmoApiError('declined', 'Your bank declined this card.', 400));
    t.session.pay();
    await t.session.onPaymentMethod('pm_1');
    expect(t.element.resolveConfirmation).toHaveBeenCalledWith(null, 'Your bank declined this card.');
    await t.session.onConfirmResult('failed', 'processor text');
    expect(t.session.getSnapshot().phase).toEqual({
      name: 'ready',
      error: { code: 'declined', message: 'Your bank declined this card.' },
    });
  });

  it('a changed local price refreshes the offer and asks the buyer to pay again', async () => {
    t.api.pay.mockRejectedValue(new VezmoApiError('unknown', 'Price changed', 409, 'local_price_changed'));
    t.session.pay();
    await t.session.onPaymentMethod('pm_1');
    expect(t.element.resolveConfirmation).toHaveBeenCalledWith(null, expect.stringMatching(/price in your currency/));
    expect(t.api.checkout).toHaveBeenCalledTimes(2);
  });

  it('a decline after 3D Secure on the device reads in Vezmo’s words (the same on both platforms) and is recorded', async () => {
    t.api.pay.mockResolvedValue({ state: 'requires_action', paymentId: 'pay_1', clientSecret: 'pi_5_secret_d' });
    t.api.status.mockResolvedValue({ state: 'failed', paymentId: 'pay_1', transactionId: null, livemode: false });
    t.api.confirm.mockRejectedValue(new VezmoApiError('declined', 'Your card was declined.', 400));
    t.session.setOption({ label: 'Visa •••• 0002' });
    t.session.pay();
    await t.session.onPaymentMethod('pm_1');
    // The platform's own text ("Your payment method was declined.") is not what the buyer reads.
    await t.session.onConfirmResult('failed', 'Your payment method was declined.');
    expect(t.api.confirm).toHaveBeenCalledWith('tok', 'pi_5');
    expect(t.session.getSnapshot().phase).toEqual({
      name: 'ready',
      error: { code: 'declined', message: 'Your card was declined.' },
    });
    // Without an answer from Vezmo, the platform's text stands.
    t.api.confirm.mockRejectedValue(new VezmoApiError('network', 'Check your connection and try again.', null));
    t.session.pay();
    await t.session.onPaymentMethod('pm_2');
    await t.session.onConfirmResult('failed', 'Your payment method was declined.');
    expect(t.session.getSnapshot().phase).toMatchObject({ error: { message: 'Your payment method was declined.' } });
  });

  it('a failure before Vezmo was asked to take the payment never reads in the engine’s words', async () => {
    t.session.setOption({ label: 'Visa •••• 4242' });
    t.session.pay();
    // The card flow refused (it was being set up again): no /pay was made.
    await t.session.onConfirmResult('failed', 'FlowController is not configured, or has a configuration update in flight.');
    expect(t.session.getSnapshot().phase).toEqual({
      name: 'ready',
      error: { code: 'unknown', message: 'Your payment couldn’t be completed. Please try again.' },
    });
    expect(t.api.status).not.toHaveBeenCalled();
    // Not paying: the card form couldn't open, in the native side's (our) words.
    await t.session.onConfirmResult('failed', 'The card form is still loading. Try again in a moment.');
    expect(t.session.getSnapshot().phase).toEqual({
      name: 'ready',
      error: { code: 'unknown', message: 'The card form is still loading. Try again in a moment.' },
    });
  });

  it('a step lost on the device that went through anyway is the payment, as on iOS and Android', async () => {
    t.api.pay.mockResolvedValue({ state: 'requires_action', paymentId: 'pay_1', clientSecret: 'pi_6_secret_l' });
    // The bank app came back late: the device reports a failure, Vezmo has the payment.
    t.api.status.mockResolvedValue({ state: 'succeeded', paymentId: 'pay_1', transactionId: 'VT6', livemode: false });
    t.session.setOption({ label: 'Visa •••• 4242' });
    t.session.pay();
    await t.session.onPaymentMethod('pm_1');
    await t.session.onConfirmResult('failed', 'Your payment method was declined.');
    expect(t.session.getSnapshot().phase).toEqual({
      name: 'done',
      result: { status: 'succeeded', paymentId: 'pay_1', transactionId: 'VT6' },
    });
    expect(t.api.confirm).not.toHaveBeenCalled();
  });

  it('canceling the element returns to the sheet; an expired session closes it', async () => {
    t.session.pay();
    await t.session.onConfirmResult('canceled', '');
    expect(t.session.getSnapshot().phase).toEqual({ name: 'ready', error: null });

    t.api.pay.mockRejectedValue(new VezmoApiError('expired', 'Secure-payments token has expired', 410));
    t.session.pay();
    await t.session.onPaymentMethod('pm_2');
    expect(t.session.getSnapshot().phase).toMatchObject({ name: 'closed', result: { status: 'failed', error: { code: 'expired' } } });
  });

  it("the buyer's own currency: the charge and methods follow the choice", async () => {
    const local = {
      ...config,
      localOffer: {
        currency: 'INR', amount: 4200, amountMinor: 420000, price: 49, rate: 85.7, markupPercent: 2,
        usdPerUnit: 0.0117, expiresAt: '2026-10-16T00:00:00Z', country: 'IN', methods: ['upi'], token: 'offer',
      },
    };
    const u = setup();
    u.api.checkout.mockResolvedValue(local);
    await u.session.load();
    expect(u.session.getSnapshot().charge).toEqual({ amountMinor: 420000, currency: 'INR', localOffer: 'offer' });
    expect(u.session.getSnapshot().methods?.elementTypes).toEqual(['card']);
    u.session.choosePayLocal(false);
    expect(u.session.getSnapshot().charge?.currency).toBe('USD');
    expect(u.session.getSnapshot().methods?.elementTypes).toEqual(['card', 'klarna']);
  });

  it('one method at a time: UPI unselects the element, picking an element method leaves UPI', () => {
    t.session.setOption({ label: 'Visa •••• 4242' });
    expect(t.session.getSnapshot()).toMatchObject({ canPay: true, option: 'Visa •••• 4242', method: 'element' });
    t.session.chooseMethod('upi');
    expect(t.element.clearSelection).toHaveBeenCalled();
    t.session.setOption(null); // the element reports the cleared selection
    expect(t.session.getSnapshot()).toMatchObject({ canPay: false, option: null, method: 'upi' });
    t.session.setOption({ label: 'Klarna' });
    expect(t.session.getSnapshot()).toMatchObject({ canPay: true, option: 'Klarna', method: 'element' });
    // The receipt keeps what was paid with, though the element clears its selection after paying.
    t.session.pay();
    t.session.setOption(null);
    expect(t.session.getSnapshot().paidWith).toBe('Klarna');
  });

  it('the Card row: opens the card form, the typed card becomes the selection, and pays through the card form', () => {
    t.session.chooseCard();
    expect(t.cardFlow.presentCard).toHaveBeenCalled();
    expect(CheckoutSession.canPay(t.session.getSnapshot())).toBe(false);
    const card = { label: '•••• 4242', image: 'data:image/png;base64,AA==' };
    t.session.setCard(card);
    expect(t.session.getSnapshot()).toMatchObject({ method: 'card', card });
    expect(t.element.clearSelection).toHaveBeenCalled();
    // Another method in the element leaves the card row but keeps the card for later.
    t.session.setOption({ label: 'Klarna' });
    expect(t.session.getSnapshot()).toMatchObject({ method: 'element', card });
    // A re-sent card (the amount changed) does not take the selection back.
    t.session.setCard(card);
    expect(t.session.getSnapshot().method).toBe('element');
    t.session.chooseCard();
    expect(t.session.getSnapshot().method).toBe('card');
    t.session.pay();
    expect(t.cardFlow.confirmCard).toHaveBeenCalled();
    expect(t.element.confirm).not.toHaveBeenCalled();
    expect(t.session.getSnapshot().paidWith).toBe('•••• 4242');
  });

  it('the Instant ACH row: opens the bank step, the linked account becomes the selection, and pays through it', async () => {
    const rupees = {
      currency: 'INR',
      amount: 4200,
      amountMinor: 420000,
      price: 49,
      rate: 85.7,
      markupPercent: 2,
      usdPerUnit: 0.0117,
      expiresAt: '2026-10-16T00:00:00Z',
      country: 'IN',
      token: 'offer',
    };
    t.api.checkout.mockResolvedValue({ ...config, enabledMethods: { card: true, klarna: true, instantAch: true }, localOffer: rupees });
    await t.session.load();
    // In the buyer's own currency there is no Instant ACH; in dollars there is.
    expect(t.session.getSnapshot().methods?.instantAch).toBe(false);
    t.session.choosePayLocal(false);
    expect(t.session.getSnapshot().methods?.instantAch).toBe(true);
    t.session.chooseBank();
    expect(t.cardFlow.presentBank).toHaveBeenCalled();
    expect(CheckoutSession.canPay(t.session.getSnapshot())).toBe(false);
    // The bank step closed without a bank: nothing chosen.
    t.session.setBank(null);
    expect(t.session.getSnapshot().method).not.toBe('instantAch');
    const bank = { label: '•••• 6789', image: null };
    t.session.setBank(bank);
    expect(t.session.getSnapshot()).toMatchObject({ method: 'instantAch', bank });
    expect(t.element.clearSelection).toHaveBeenCalled();
    t.api.pay.mockResolvedValue({
      state: 'succeeded',
      paymentId: 'pay_1',
      transactionId: 'VT1',
      clientSecret: 'pi_1_secret_b',
      method: { type: 'instantAch', brand: null, last4: '6789', wallet: null },
    });
    t.session.pay();
    expect(t.cardFlow.confirmBank).toHaveBeenCalled();
    expect(t.cardFlow.confirmCard).not.toHaveBeenCalled();
    expect(t.element.confirm).not.toHaveBeenCalled();
    expect(t.session.getSnapshot().paidWith).toBe('Instant ACH');
    await t.session.onPaymentMethod('pm_b');
    // The card flow holds the bank step, so it answers the confirmation.
    expect(t.cardFlow.resolveConfirmation).toHaveBeenCalledWith('pi_1_secret_b', undefined);
    expect(t.api.pay).toHaveBeenCalledWith('tok', expect.objectContaining({ paymentMethodId: 'pm_b' }));
    await t.session.onConfirmResult('completed', '');
    expect(t.session.getSnapshot().phase).toEqual({
      name: 'done',
      result: { status: 'succeeded', paymentId: 'pay_1', transactionId: 'VT1' },
    });
    expect(t.session.getSnapshot().paidMethod?.type).toBe('instantAch');
  });

  it('Instant ACH leaves when the buyer pays in their own currency', async () => {
    const rupees = {
      currency: 'INR',
      amount: 4200,
      amountMinor: 420000,
      price: 49,
      rate: 85.7,
      markupPercent: 2,
      usdPerUnit: 0.0117,
      expiresAt: '2026-10-16T00:00:00Z',
      country: 'IN',
      token: 'offer',
    };
    t.api.checkout.mockResolvedValue({ ...config, enabledMethods: { card: true, instantAch: true }, localOffer: rupees });
    await t.session.load();
    t.session.choosePayLocal(false);
    t.session.chooseBank();
    t.session.setBank({ label: '•••• 6789', image: null });
    expect(t.session.getSnapshot().method).toBe('instantAch');
    t.session.choosePayLocal(true);
    expect(t.session.getSnapshot().method).toBe('element');
    expect(CheckoutSession.canPay(t.session.getSnapshot())).toBe(false);
  });

  it('the card flow answers its own confirmation (card form or wallet), the element its own', async () => {
    t.api.pay.mockResolvedValue({ state: 'requires_action', paymentId: 'pay_1', clientSecret: 'pi_1_secret_w' });
    t.session.walletStarted('apple_pay');
    expect(t.session.getSnapshot()).toMatchObject({ phase: { name: 'paying' }, paidWith: 'Apple Pay' });
    await t.session.onPaymentMethod('pm_w');
    expect(t.cardFlow.resolveConfirmation).toHaveBeenCalledWith('pi_1_secret_w', undefined);
    expect(t.element.resolveConfirmation).not.toHaveBeenCalled();
  });

  it('UPI: starts on the session intent, waits for the bank app, records it when paid', async () => {
    const local = {
      ...config,
      enabledMethods: { card: true, upi: true },
      localOffer: {
        currency: 'INR', amount: 4200, amountMinor: 420000, price: 49, rate: 85.7, markupPercent: 2,
        usdPerUnit: 0.0117, expiresAt: '2026-10-16T00:00:00Z', country: 'IN', methods: ['upi'], token: 'offer',
      },
    };
    const u = setup();
    u.api.checkout.mockResolvedValue(local);
    await u.session.load();
    expect(u.session.getSnapshot().methods?.upi).toBe(true);
    u.session.chooseMethod('upi');
    u.api.status.mockResolvedValueOnce({ state: 'requires_action', paymentId: 'pay_1', transactionId: null, livemode: false });

    await u.session.payWithQr('upi', { name: 'Asha Rao', line1: '12 MG Road', country: 'IN' });
    expect(u.api.intent).toHaveBeenCalledWith('tok', 'offer');
    expect(u.api.startQr).toHaveBeenCalledWith('upi', {
      clientSecret: 'pi_7_secret_q',
      connectedAccountId: 'acct_1',
      livemode: false,
      returnUrl: 'https://api.test/v1/secure-payments/tok',
      billing: { name: 'Asha Rao', line1: '12 MG Road', country: 'IN' },
    });
    expect(u.session.getSnapshot().phase).toMatchObject({ name: 'waiting', method: 'upi', qr: { link: 'upi://pay?pa=x' } });

    await u.session.checkNow(); // still in the bank app
    expect(u.session.getSnapshot().phase.name).toBe('waiting');
    await u.session.checkNow(); // paid
    expect(u.api.confirm).toHaveBeenCalledWith('tok', 'pi_7');
    expect(u.session.getSnapshot().phase).toMatchObject({ name: 'done', result: { status: 'succeeded' } });
    u.session.dispose();
  });

  describe('closing while UPI or Pix may still be paid', () => {
    async function upi() {
      const u = setup();
      u.api.checkout.mockResolvedValue({
        ...config,
        enabledMethods: { card: true, upi: true },
        localOffer: {
          currency: 'INR', amount: 4200, amountMinor: 420000, price: 49, rate: 85.7, markupPercent: 2,
          usdPerUnit: 0.0117, expiresAt: '2026-10-16T00:00:00Z', country: 'IN', methods: ['upi'], token: 'offer',
        },
      });
      await u.session.load();
      u.session.chooseMethod('upi');
      await u.session.payWithQr('upi', { name: 'Asha Rao', line1: '12 MG Road', country: 'IN' });
      expect(u.session.getSnapshot().phase.name).toBe('waiting');
      return u;
    }
    const pending = { state: 'requires_action', paymentId: 'pay_1', transactionId: null, livemode: false };

    it('still waiting on the bank app: processing, never canceled', async () => {
      const u = await upi();
      u.api.status.mockResolvedValue(pending);
      await expect(u.session.closeRequested()).resolves.toEqual({ status: 'processing', paymentId: 'pay_1' });
      expect(u.api.confirm).not.toHaveBeenCalled();
    });

    it('paid meanwhile: the sheet shows the receipt instead of closing', async () => {
      const u = await upi();
      await expect(u.session.closeRequested()).resolves.toBeNull();
      expect(u.api.confirm).toHaveBeenCalledWith('tok', 'pi_7');
      expect(u.session.getSnapshot().phase).toMatchObject({ name: 'done', result: { status: 'succeeded', transactionId: 'VT1' } });
    });

    it('after giving up on it: canceled, unless it was paid meanwhile', async () => {
      const u = await upi();
      u.session.stopWaiting();
      u.api.status.mockResolvedValue(pending);
      await expect(u.session.closeRequested()).resolves.toEqual({ status: 'canceled' });
      u.api.status.mockResolvedValue({ state: 'processing', paymentId: 'pay_1', transactionId: null, livemode: false });
      await expect(u.session.closeRequested()).resolves.toBeNull();
      expect(u.session.getSnapshot().phase).toMatchObject({ name: 'done', result: { status: 'processing' } });
    });

    it('no UPI or Pix started: canceled, without asking Vezmo', async () => {
      await expect(t.session.closeRequested()).resolves.toEqual({ status: 'canceled' });
      expect(t.api.status).not.toHaveBeenCalled();
    });
  });

  it('an engine failure after Vezmo took the payment is the payment, never the engine’s words', async () => {
    t.api.pay.mockResolvedValue({ state: 'succeeded', paymentId: 'pay_1', transactionId: 'VT1', clientSecret: 'pi_1_secret_a' });
    t.session.setOption({ label: 'Klarna' });
    t.session.pay();
    await t.session.onPaymentMethod('pm_1');
    await t.session.onConfirmResult('failed', 'No launcher for a was found, did you call register?');
    expect(t.session.getSnapshot().phase).toEqual({
      name: 'done',
      result: { status: 'succeeded', paymentId: 'pay_1', transactionId: 'VT1' },
    });
  });

  describe('no answer from /pay', () => {
    const network = new VezmoApiError('network', 'Check your connection and try again.', null);

    it('a payment that went through all the same is the result, not a failure', async () => {
      t.api.pay.mockRejectedValue(network);
      t.session.setOption({ label: 'Klarna' });
      t.session.pay();
      await t.session.onPaymentMethod('pm_1');
      expect(t.element.resolveConfirmation).toHaveBeenCalledWith(null, '');
      await t.session.onConfirmResult('failed', 'engine text');
      expect(t.session.getSnapshot().phase).toEqual({
        name: 'done',
        result: { status: 'succeeded', paymentId: 'pay_1', transactionId: 'VT1' },
      });
    });

    it('one that didn’t go through is the network error, and the next try starts clean', async () => {
      t.api.pay.mockRejectedValue(network);
      t.api.status.mockResolvedValue({ state: 'open', paymentId: 'pay_1', transactionId: null, livemode: false });
      t.session.setOption({ label: 'Klarna' });
      t.session.pay();
      await t.session.onPaymentMethod('pm_1');
      expect(t.api.status).toHaveBeenCalledTimes(1);
      expect(t.element.resolveConfirmation).toHaveBeenCalledWith(null, network.message);
      await t.session.onConfirmResult('failed', 'engine text');
      expect(t.session.getSnapshot().phase).toEqual({ name: 'ready', error: network.toVezmoError() });

      t.api.pay.mockResolvedValue({ state: 'succeeded', paymentId: 'pay_1', transactionId: 'VT2', clientSecret: 'pi_1_secret_a' });
      t.session.pay();
      await t.session.onPaymentMethod('pm_2');
      await t.session.onConfirmResult('completed', '');
      expect(t.session.getSnapshot().phase).toMatchObject({ name: 'done', result: { status: 'succeeded', transactionId: 'VT2' } });
    });
  });

  it('UPI: an offer that ran out is fetched again (not retried as is), and status checks never overlap', async () => {
    const offer = {
      currency: 'INR', amount: 4200, amountMinor: 420000, price: 49, rate: 85.7, markupPercent: 2,
      usdPerUnit: 0.0117, expiresAt: '2026-10-16T00:00:00Z', country: 'IN', methods: ['upi'], token: 'offer',
    };
    const u = setup();
    u.api.checkout.mockResolvedValue({ ...config, enabledMethods: { card: true, upi: true }, localOffer: offer });
    await u.session.load();
    u.session.chooseMethod('upi');
    const billing = { name: 'Asha Rao', line1: '12 MG Road', country: 'IN' };

    u.api.intent.mockRejectedValueOnce(new VezmoApiError('unknown', 'Price changed', 409, 'local_price_changed'));
    u.api.checkout.mockResolvedValue({
      ...config,
      enabledMethods: { card: true, upi: true },
      localOffer: { ...offer, amountMinor: 421000, token: 'offer2' },
    });
    await u.session.payWithQr('upi', billing);
    expect(u.session.getSnapshot().phase).toEqual({
      name: 'ready',
      error: { code: 'unknown', message: expect.stringMatching(/price in your currency/) },
    });
    await new Promise((r) => setTimeout(r, 0));
    expect(u.session.getSnapshot().charge).toEqual({ amountMinor: 421000, currency: 'INR', localOffer: 'offer2' });
    await u.session.payWithQr('upi', billing);
    expect(u.api.intent).toHaveBeenLastCalledWith('tok', 'offer2');
    expect(u.session.getSnapshot().phase.name).toBe('waiting');

    // The poll and the buyer's Check status at once: one request, one confirm.
    let answer: (s: unknown) => void = () => undefined;
    u.api.status.mockReturnValueOnce(new Promise((r) => (answer = r)));
    const first = u.session.checkNow();
    const second = u.session.checkNow();
    answer({ state: 'succeeded', paymentId: 'pay_1', transactionId: 'VT1', livemode: false });
    await Promise.all([first, second]);
    expect(u.api.status).toHaveBeenCalledTimes(1);
    expect(u.api.confirm).toHaveBeenCalledTimes(1);
    expect(u.session.getSnapshot().phase).toMatchObject({ name: 'done', result: { status: 'succeeded' } });
    u.session.dispose();
  });
});
