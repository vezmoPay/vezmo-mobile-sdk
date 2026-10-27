import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vezmo_checkout/vezmo_checkout.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('vezmo_checkout');
  final calls = <MethodCall>[];
  // What the native side answers next, per method.
  late Map<String, Object? Function(MethodCall)> answers;

  setUp(() {
    calls.clear();
    answers = {
      'prepare': (_) => null,
      'present': (_) => {'status': 'canceled'},
    };
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return answers[call.method]!(call);
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  group('results', () {
    test('succeeded with a subscription', () {
      final result = CheckoutResult.fromJson({
        'status': 'succeeded',
        'paymentId': 'pay_1',
        'transactionId': 'TX-1',
        'subscription': {'ref': 'SUB-7Q2K9WX', 'status': 'active'},
      });
      expect(result, isA<CheckoutSucceeded>());
      final ok = result as CheckoutSucceeded;
      expect(ok.paymentId, 'pay_1');
      expect(ok.transactionId, 'TX-1');
      expect(ok.subscription!.ref, 'SUB-7Q2K9WX');
      expect(ok.subscription!.status, SubscriptionStatus.active);
    });

    test('a free trial has no payment', () {
      final result = CheckoutResult.fromJson({
        'status': 'succeeded',
        'paymentId': null,
        'transactionId': null,
        'subscription': {'ref': 'SUB-1', 'status': 'trialing'},
      });
      expect(result, isA<CheckoutSucceeded>().having((r) => r.paymentId, 'paymentId', isNull));
      expect((result as CheckoutSucceeded).subscription!.status, SubscriptionStatus.trialing);
    });

    test('processing, canceled, failed', () {
      expect(
        CheckoutResult.fromJson({'status': 'processing', 'paymentId': 'pay_2'}),
        isA<CheckoutProcessing>().having((r) => r.paymentId, 'paymentId', 'pay_2'),
      );
      expect(CheckoutResult.fromJson({'status': 'canceled'}), isA<CheckoutCanceled>());
      final failed = CheckoutResult.fromJson({
        'status': 'failed',
        'error': {'code': 'already_paid', 'message': 'This was already paid.'},
      });
      expect(failed, isA<CheckoutFailed>());
      expect((failed as CheckoutFailed).error.code, VezmoErrorCode.alreadyPaid);
      expect(failed.error.message, 'This was already paid.');
    });

    test('anything unexpected is a failure, never a throw', () {
      final empty = CheckoutResult.fromJson({});
      expect((empty as CheckoutFailed).error.code, VezmoErrorCode.unknown);
      final odd = CheckoutResult.fromJson({
        'status': 'failed',
        'error': {'code': 'new_code'},
      });
      expect((odd as CheckoutFailed).error.code, VezmoErrorCode.unknown);
      expect(odd.error.message, isNotEmpty);
      final sub = SubscriptionResult.fromJson({'ref': 'SUB-1', 'status': 'paused'});
      expect(sub.status, SubscriptionStatus.incomplete);
    });

    test('every result survives toJson and back', () {
      const results = <CheckoutResult>[
        CheckoutSucceeded(
          paymentId: 'pay_1',
          transactionId: 'TX-1',
          subscription: SubscriptionResult(ref: 'SUB-1', status: SubscriptionStatus.active),
        ),
        CheckoutProcessing(paymentId: 'pay_2'),
        CheckoutCanceled(),
        CheckoutFailed(VezmoError(VezmoErrorCode.notAvailable, 'Not here.')),
      ];
      for (final r in results) {
        expect(CheckoutResult.fromJson(r.toJson()).toJson(), r.toJson());
      }
      expect(results.first.toJson()['status'], 'succeeded');
    });

    test('error codes use the same names as the other SDKs', () {
      expect(VezmoErrorCode.values.map((c) => c.wireName), [
        'declined',
        'expired',
        'already_paid',
        'not_available',
        'network',
        'config',
        'unknown',
      ]);
      for (final code in VezmoErrorCode.values) {
        expect(VezmoError.fromJson({'code': code.wireName, 'message': 'm'}).code, code);
      }
    });
  });

  group('channel', () {
    test('prepare sends the configuration and the token', () async {
      final vezmo = VezmoCheckout(
        configuration: const VezmoConfiguration(
          returnUrl: 'acme://vezmo',
          applePay: ApplePayOptions(merchantId: 'merchant.com.acme'),
          googlePay: GooglePayOptions(merchantCountryCode: 'GB'),
          style: VezmoStyle.dark,
          appearance: VezmoAppearance(
            colors: {
              VezmoColorKey.accent: VezmoColor(Color(0xFF0A84FF)),
              VezmoColorKey.surface: VezmoColor(Color(0xFFFFFFFF), dark: Color(0xFF1C1C1E)),
            },
            cornerRadius: 12,
            fontFamily: 'inter',
          ),
          apiBase: 'https://api.example.test/api/v1',
        ),
      );
      expect(await vezmo.prepare(clientToken: '  tok_1 ', merchantDisplayName: 'Acme'), isNull);
      expect(calls.single.method, 'prepare');
      expect(calls.single.arguments, {
        'configuration': {
          'returnUrl': 'acme://vezmo',
          // No country: the native SDK takes the one processing the payment from the session.
          'applePay': {'merchantId': 'merchant.com.acme', 'merchantCountryCode': null},
          'googlePay': {'merchantCountryCode': 'GB'},
          'style': 'dark',
          'appearance': {
            'colors': {
              'accent': {'light': 0xFF0A84FF, 'dark': 0xFF0A84FF},
              'surface': {'light': 0xFFFFFFFF, 'dark': 0xFF1C1C1E},
            },
            'cornerRadius': 12.0,
            'fontFamily': 'inter',
          },
          'apiBase': 'https://api.example.test/api/v1',
          'sdk': 'flutter/0.2.0',
        },
        'clientToken': 'tok_1',
        'subscriptionToken': null,
        'merchantDisplayName': 'Acme',
      });
    });

    test('payments record this package and its version as the SDK', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      expect(RegExp(r'^version: (\S+)', multiLine: true).firstMatch(pubspec)!.group(1), VezmoCheckout.version);
    });

    test('a subscription token goes as subscriptionToken', () async {
      expect(await VezmoCheckout().prepare(subscriptionToken: 'sub_tok'), isNull);
      final args = calls.single.arguments as Map;
      expect(args['clientToken'], isNull);
      expect(args['subscriptionToken'], 'sub_tok');
      expect((args['configuration'] as Map)['style'], 'automatic');
    });

    test('exactly one token, checked before the native side is called', () async {
      final vezmo = VezmoCheckout();
      expect((await vezmo.prepare())!.code, VezmoErrorCode.config);
      expect((await vezmo.prepare(clientToken: ' '))!.code, VezmoErrorCode.config);
      expect((await vezmo.prepare(clientToken: 'a', subscriptionToken: 'b'))!.code, VezmoErrorCode.config);
      expect(calls, isEmpty);
    });

    test('prepare returns the native error', () async {
      answers['prepare'] = (_) => {'code': 'expired', 'message': 'This checkout has expired.'};
      final vezmo = VezmoCheckout();
      final error = await vezmo.prepare(clientToken: 'old');
      expect(error!.code, VezmoErrorCode.expired);
      expect(error.message, 'This checkout has expired.');
      // A failed prepare leaves nothing to present.
      expect(((await vezmo.present()) as CheckoutFailed).error.code, VezmoErrorCode.config);
      expect(calls.map((c) => c.method), ['prepare']);
    });

    test('present before prepare is a config failure, without opening anything', () async {
      final result = await VezmoCheckout().present();
      expect((result as CheckoutFailed).error.code, VezmoErrorCode.config);
      expect(calls, isEmpty);
    });

    test('present returns the native result, once per prepare', () async {
      answers['present'] = (_) => {
        'status': 'succeeded',
        'paymentId': 'pay_9',
        'transactionId': 'TX-9',
        'subscription': null,
      };
      final vezmo = VezmoCheckout();
      await vezmo.prepare(clientToken: 'tok');
      final result = await vezmo.present();
      expect(result, isA<CheckoutSucceeded>().having((r) => r.paymentId, 'paymentId', 'pay_9'));
      expect((result as CheckoutSucceeded).subscription, isNull);
      expect(((await vezmo.present()) as CheckoutFailed).error.code, VezmoErrorCode.config);
      expect(calls.map((c) => c.method), ['prepare', 'present']);
    });

    test('preparing another checkout replaces the prepared one', () async {
      final a = VezmoCheckout();
      final b = VezmoCheckout();
      await a.prepare(clientToken: 'a');
      await b.prepare(clientToken: 'b');
      expect(await a.present(), isA<CheckoutFailed>());
      expect(await b.present(), isA<CheckoutCanceled>());
    });

    test('one sheet at a time: present while one is open answers at once, without opening another', () async {
      final open = Completer<Object?>();
      answers['present'] = (_) => open.future;
      final a = VezmoCheckout();
      await a.prepare(clientToken: 'a');
      final first = a.present();
      // Another checkout prepared while the sheet is open waits for it to close.
      final b = VezmoCheckout();
      await b.prepare(clientToken: 'b');
      final second = await b.present();
      expect((second as CheckoutFailed).error.message, 'The checkout is already open.');
      expect(calls.where((c) => c.method == 'present'), hasLength(1));
      open.complete({'status': 'canceled'});
      expect(await first, isA<CheckoutCanceled>());
      // Once closed, the checkout prepared meanwhile opens.
      answers['present'] = (_) => {'status': 'canceled'};
      expect(await b.present(), isA<CheckoutCanceled>());
    });

    test('a native exception becomes a failure', () async {
      answers['present'] = (_) => throw PlatformException(code: 'boom', message: 'Native trouble.');
      final vezmo = VezmoCheckout();
      await vezmo.prepare(clientToken: 'tok');
      final result = await vezmo.present();
      expect((result as CheckoutFailed).error.code, VezmoErrorCode.unknown);
      expect(result.error.message, 'Native trouble.');
    });

    test('no native side (an unsupported platform) is a config error', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
      expect((await VezmoCheckout().prepare(clientToken: 'tok'))!.code, VezmoErrorCode.config);
    });
  });
}
