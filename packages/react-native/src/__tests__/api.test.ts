import { describe, expect, it, jest } from '@jest/globals';
import { REQUEST_TIMEOUT_MS, VezmoApi, VezmoApiError } from '../api';

const ok = (data: unknown) =>
  ({ ok: true, status: 200, json: async () => ({ success: true, data }) }) as unknown as Response;
const fail = (status: number, body: unknown) =>
  ({ ok: false, status, json: async () => body }) as unknown as Response;

describe('VezmoApi', () => {
  it('pays with the payment method, our integration and SDK header; unwraps the data', async () => {
    const fetchImpl = jest
      .fn<typeof fetch>()
      .mockResolvedValue(ok({ state: 'processing', paymentId: 'p', clientSecret: null }));
    const api = new VezmoApi('https://api.test/v1', 'android', fetchImpl);
    const res = await api.pay('tok/1', {
      paymentMethodId: 'pm_1',
      localOffer: 'o',
      returnUrl: 'acme://vezmo',
      engineReturnUrl: 'stripesdk://payment_return_url/com.acme.shop',
    });
    expect(res.state).toBe('processing');
    const [url, init] = fetchImpl.mock.calls[0]!;
    expect(url).toBe('https://api.test/v1/secure-payments/tok%2F1/pay');
    expect(init?.method).toBe('POST');
    expect((init?.headers as Record<string, string>)['Vezmo-SDK']).toMatch(/^react-native\/\d+\.\d+\.\d+/);
    // A payment method, never a confirmation token. Android: the engine's own way back, never the app's link.
    expect(JSON.parse(init?.body as string)).toEqual({
      paymentMethodId: 'pm_1',
      integration: 'android',
      localOffer: 'o',
      returnUrl: 'stripesdk://payment_return_url/com.acme.shop',
    });
    // A card on Android: no return link at all.
    await api.pay('t', { paymentMethodId: 'pm_2', returnUrl: 'acme://vezmo', engineReturnUrl: null });
    expect(JSON.parse(fetchImpl.mock.calls[1]![1]?.body as string)).toEqual({ paymentMethodId: 'pm_2', integration: 'android' });
  });

  it("sends the app's return link from iOS, where the sheet hands it to the payment", async () => {
    const fetchImpl = jest
      .fn<typeof fetch>()
      .mockResolvedValue(ok({ state: 'processing', paymentId: 'p', clientSecret: null }));
    await new VezmoApi('https://api.test/v1', 'ios', fetchImpl).subscriptionPay('sub', {
      paymentMethodId: 'pm_1',
      returnUrl: 'acme://vezmo',
    });
    const [url, init] = fetchImpl.mock.calls[0]!;
    expect(url).toBe('https://api.test/v1/subscription-checkout/sub/pay');
    expect(JSON.parse(init?.body as string)).toEqual({
      paymentMethodId: 'pm_1',
      integration: 'ios',
      returnUrl: 'acme://vezmo',
    });
  });

  it("turns failures into Vezmo's own codes and words", async () => {
    const api = (r: Response) =>
      new VezmoApi('https://api.test/v1', 'ios', jest.fn<typeof fetch>().mockResolvedValue(r));
    await expect(api(fail(410, { message: 'Secure-payments token has expired' })).status('t')).rejects.toMatchObject({
      code: 'expired',
    });
    await expect(
      api(fail(400, { message: 'Your bank declined this card.' })).pay('t', { paymentMethodId: 'c' }),
    ).rejects.toMatchObject({ code: 'declined', message: 'Your bank declined this card.' });
    const priceChanged = (await api(
      fail(409, { message: 'Price changed', errors: [{ code: 'local_price_changed', message: 'x' }] }),
    )
      .pay('t', { paymentMethodId: 'c' })
      .catch((e: unknown) => e)) as VezmoApiError;
    expect(priceChanged.reason).toBe('local_price_changed');
    await expect(
      api(
        fail(400, {
          message: 'Bad Request',
          errors: [{ code: 'return_url_not_registered', message: 'Register acme://vezmo for this business.' }],
        }),
      ).pay('t', { paymentMethodId: 'c', returnUrl: 'acme://vezmo' }),
    ).rejects.toMatchObject({ code: 'config', reason: 'return_url_not_registered' });
    await expect(
      api(
        fail(400, { errors: [{ code: 'method_unavailable', message: 'This way to pay is not available.' }] }),
      ).subscriptionPay('t', { paymentMethodId: 'c' }),
    ).rejects.toMatchObject({ code: 'not_available', message: 'This way to pay is not available.' });
    const offline = new VezmoApi(
      'https://api.test/v1',
      'ios',
      jest.fn<typeof fetch>().mockRejectedValue(new TypeError('x')),
    );
    await expect(offline.status('t')).rejects.toMatchObject({ code: 'network' });
    // A 200 with no readable answer is an error, never a null result.
    const empty = { ok: true, status: 200, json: async () => { throw new SyntaxError('x'); } } as unknown as Response;
    await expect(api(empty).status('t')).rejects.toMatchObject({ code: 'unknown' });
  });

  it('gives up on a call that never answers: a network error, and the request is aborted', async () => {
    jest.useFakeTimers();
    try {
      let signal: AbortSignal | undefined;
      const fetchImpl = jest.fn<typeof fetch>((_url, init) => {
        signal = init?.signal ?? undefined;
        // Hangs until aborted, as a real fetch does.
        return new Promise((_resolve, reject) => signal?.addEventListener('abort', () => reject(new Error('aborted'))));
      });
      const call = new VezmoApi('https://api.test/v1', 'ios', fetchImpl).checkout('tok');
      const outcome = call.catch((e: unknown) => e);
      jest.advanceTimersByTime(REQUEST_TIMEOUT_MS - 1);
      expect(signal?.aborted).toBe(false);
      jest.advanceTimersByTime(1);
      expect(signal?.aborted).toBe(true);
      expect(await outcome).toMatchObject({ code: 'network', message: 'Check your connection and try again.' });
      // An answer in time leaves no timer behind.
      await new VezmoApi('https://api.test/v1', 'ios', jest.fn<typeof fetch>().mockResolvedValue(ok({ state: 'open' }))).status('t');
      expect(jest.getTimerCount()).toBe(0);
    } finally {
      jest.useRealTimers();
    }
  });
});
