/// The Vezmo payment sheet for Flutter apps.
///
/// ```dart
/// final vezmo = VezmoCheckout(configuration: const VezmoConfiguration(returnUrl: 'acme://vezmo'));
/// final error = await vezmo.prepare(clientToken: token);
/// if (error != null) return showError(error.message);
/// switch (await vezmo.present()) {
///   case CheckoutSucceeded(:final paymentId): showPaid(paymentId);
///   case CheckoutProcessing(): showPaymentReceived();
///   case CheckoutCanceled(): break;
///   case CheckoutFailed(:final error): showError(error.message);
/// }
/// ```
library;

import 'package:flutter/services.dart';

const MethodChannel _channel = MethodChannel('vezmo_checkout');

/// The message when the native side gives none (the native SDKs' own words).
const String _fallbackMessage = 'Something went wrong. Please try again.';

/// Takes a payment, or starts a subscription, in the Vezmo payment sheet.
///
/// [prepare] loads the session (call it as soon as your server sends the token), then [present] opens the sheet and
/// completes when the buyer is done. Neither throws.
class VezmoCheckout {
  VezmoCheckout({this.configuration = const VezmoConfiguration()});

  /// This plugin's version.
  static const String version = '0.2.0';

  final VezmoConfiguration configuration;

  /// The checkout whose session the sheet holds: the last one prepared, until it is presented.
  static VezmoCheckout? _prepared;

  /// A sheet is open (there is one per app).
  static bool _presenting = false;

  /// Loads the checkout. Pass exactly one token.
  ///
  /// [clientToken]: from your server, the API checkout session's `clientToken` (a one-time payment).
  /// [subscriptionToken]: from your server, a subscription's `checkoutToken`, to start it in the app (the first
  /// payment, or a free trial with the card saved for the renewals).
  /// [merchantDisplayName]: shown at the top of the sheet. Defaults to the business name on the session.
  ///
  /// Returns null when the checkout is ready to [present], or why it can't be (expired, already paid, no
  /// connection…).
  Future<VezmoError?> prepare({String? clientToken, String? subscriptionToken, String? merchantDisplayName}) async {
    _prepared = null;
    final hasClient = clientToken?.trim().isNotEmpty ?? false;
    final hasSubscription = subscriptionToken?.trim().isNotEmpty ?? false;
    if (hasClient == hasSubscription) {
      return const VezmoError(VezmoErrorCode.config, 'Pass a clientToken or a subscriptionToken.');
    }
    try {
      final error = await _channel.invokeMapMethod<String, Object?>('prepare', {
        'configuration': configuration._toMap(),
        'clientToken': hasClient ? clientToken!.trim() : null,
        'subscriptionToken': hasSubscription ? subscriptionToken!.trim() : null,
        'merchantDisplayName': merchantDisplayName,
      });
      if (error != null) return VezmoError.fromJson(error);
      _prepared = this;
      return null;
    } on MissingPluginException {
      return _unsupported;
    } on PlatformException catch (e) {
      return VezmoError(VezmoErrorCode.unknown, e.message ?? _fallbackMessage);
    }
  }

  /// Opens the sheet and completes with the result when the buyer is done. Call [prepare] first, each time.
  Future<CheckoutResult> present() async {
    // One sheet at a time, on both platforms (iPhone would otherwise open a second sheet over the first).
    if (_presenting) {
      return const CheckoutFailed(VezmoError(VezmoErrorCode.config, 'The checkout is already open.'));
    }
    if (!identical(_prepared, this)) {
      return const CheckoutFailed(VezmoError(VezmoErrorCode.config, 'Call prepare() before present().'));
    }
    _prepared = null;
    _presenting = true;
    try {
      final result = await _channel.invokeMapMethod<String, Object?>('present');
      return CheckoutResult.fromJson(result ?? const {});
    } on MissingPluginException {
      return const CheckoutFailed(_unsupported);
    } on PlatformException catch (e) {
      return CheckoutFailed(VezmoError(VezmoErrorCode.unknown, e.message ?? _fallbackMessage));
    } finally {
      _presenting = false;
    }
  }

  static const _unsupported = VezmoError(VezmoErrorCode.config, 'Vezmo checkout runs on Android and iPhone only.');
}

/// How the Vezmo payment sheet is set up in your app.
class VezmoConfiguration {
  const VezmoConfiguration({
    this.returnUrl,
    this.applePay,
    this.googlePay,
    this.style = VezmoStyle.automatic,
    this.appearance = const VezmoAppearance(),
    this.apiBase,
  });

  /// The link that opens your app after a bank app, a pay-later provider or 3D Secure, registered in the Vezmo
  /// dashboard under Developers → Mobile apps (for example `acme://vezmo`). Needed on iPhone for redirect-based
  /// methods; on Android the buyer comes back by themselves.
  final String? returnUrl;

  /// Apple Pay with your Apple Merchant ID. Without it the sheet shows no Apple Pay.
  final ApplePayOptions? applePay;

  /// Google Pay shows when your business offers it and the phone has it; set this to change the merchant country.
  final GooglePayOptions? googlePay;

  /// Light, dark, or follow the phone (default).
  final VezmoStyle style;

  /// Colors, corner radius and font.
  final VezmoAppearance appearance;

  /// Vezmo's API. Leave as is; for Vezmo's own testing only.
  final String? apiBase;

  Map<String, Object?> _toMap() => {
    'returnUrl': returnUrl,
    'applePay': applePay == null
        ? null
        : {'merchantId': applePay!.merchantId, 'merchantCountryCode': applePay!.merchantCountryCode},
    'googlePay': googlePay == null ? null : {'merchantCountryCode': googlePay!.merchantCountryCode},
    'style': style.name,
    'appearance': {
      'colors': {
        for (final MapEntry(:key, :value) in appearance.colors.entries)
          key.name: {'light': value.light.toARGB32(), 'dark': value.dark.toARGB32()},
      },
      'cornerRadius': appearance.cornerRadius,
      'fontFamily': appearance.fontFamily,
    },
    'apiBase': apiBase,
    // How a payment records the SDK that took it (the native SDKs' Vezmo-SDK header).
    'sdk': 'flutter/${VezmoCheckout.version}',
  };
}

/// Apple Pay in the sheet on iPhone, with your Apple Merchant ID.
class ApplePayOptions {
  const ApplePayOptions({required this.merchantId, this.merchantCountryCode});

  /// Your Apple Merchant ID (Apple Developer → Identifiers → Merchant IDs).
  final String merchantId;

  /// The country of the account that processes the payment, as two letters. Leave it null: Vezmo's session says
  /// (your business's own country on Connect, Vezmo's on merchant of record).
  final String? merchantCountryCode;
}

/// Google Pay in the sheet on Android.
class GooglePayOptions {
  const GooglePayOptions({this.merchantCountryCode});

  /// The country of the account that processes the payment, as two letters. Leave it null: Vezmo's session says
  /// (your business's own country on Connect, Vezmo's on merchant of record).
  final String? merchantCountryCode;
}

/// The sheet's look: follow the phone, or always light or dark.
enum VezmoStyle { automatic, light, dark }

/// Bring the sheet closer to your app.
class VezmoAppearance {
  const VezmoAppearance({this.colors = const {}, this.cornerRadius, this.fontFamily});

  /// Colors by key; leave a key out to keep Vezmo's. Setting your own [VezmoColorKey.accent] replaces the Vezmo
  /// gradient on the Pay button.
  final Map<VezmoColorKey, VezmoColor> colors;

  /// Corner radius of fields and payment method rows, in logical pixels. Default 14.
  final double? cornerRadius;

  /// A font in your app's native side, used for the sheet's text: on Android the name of a font resource
  /// (`android/app/src/main/res/font/inter.ttf` → `'inter'`), on iPhone its PostScript or family name.
  final String? fontFamily;
}

/// One color, or one for light and one for dark.
class VezmoColor {
  const VezmoColor(this.light, {Color? dark}) : dark = dark ?? light;

  final Color light;
  final Color dark;
}

/// The sheet's colors you may change.
enum VezmoColorKey {
  /// The Pay button, selection marks and links.
  accent,

  /// Text on the accent.
  onAccent,

  /// The sheet.
  surface,

  /// Quiet fills: the currency choice track, the code box, the receipt.
  surface2,

  /// The chosen side of the currency choice.
  raised,

  /// Behind the close button.
  fill,

  /// The Pay button before a way to pay is chosen.
  disabled,

  /// Text on the disabled Pay button.
  onDisabled,

  /// Fields and the list of ways to pay.
  field,
  fieldLine,

  /// Separators.
  line,

  /// Text, from strongest to quietest.
  ink,
  ink2,
  ink3,

  /// The accent at low strength: the waiting status, step numbers.
  accentSoft,
  good,
  bad,
  badSoft,

  /// The test-mode badge.
  warn,

  /// Time running out on a UPI or Pix code.
  warnInk,
  warnSoft,

  /// Behind the business's initial.
  logoTile,

  /// The dimmed backdrop behind the sheet.
  scrim,
}

/// The outcome of [VezmoCheckout.present]. It never throws: match on the four results.
sealed class CheckoutResult {
  const CheckoutResult();

  /// Reads the result as the native side sends it (the same shape as [toJson]).
  factory CheckoutResult.fromJson(Map<String, Object?> json) {
    final subscription = json['subscription'];
    final sub = subscription is Map ? SubscriptionResult.fromJson(subscription.cast<String, Object?>()) : null;
    final error = json['error'];
    return switch (json['status']) {
      'succeeded' => CheckoutSucceeded(
        paymentId: json['paymentId'] as String?,
        transactionId: json['transactionId'] as String?,
        subscription: sub,
      ),
      'processing' => CheckoutProcessing(paymentId: json['paymentId'] as String?, subscription: sub),
      'canceled' => const CheckoutCanceled(),
      _ => CheckoutFailed(
        error is Map
            ? VezmoError.fromJson(error.cast<String, Object?>())
            : const VezmoError(VezmoErrorCode.unknown, _fallbackMessage),
      ),
    };
  }

  /// The result as JSON, in the same shape as the React Native package's.
  Map<String, Object?> toJson();
}

/// Paid. [paymentId] and [transactionId] match the Vezmo dashboard and the webhook.
final class CheckoutSucceeded extends CheckoutResult {
  const CheckoutSucceeded({this.paymentId, this.transactionId, this.subscription});

  /// The payment. Null only when a subscription's free trial started: nothing was charged today.
  final String? paymentId;
  final String? transactionId;

  /// For a subscription checkout: the subscription, now active (first payment made) or trialing.
  final SubscriptionResult? subscription;

  @override
  Map<String, Object?> toJson() => {
    'status': 'succeeded',
    'paymentId': paymentId,
    'transactionId': transactionId,
    if (subscription != null) 'subscription': subscription!.toJson(),
  };
}

/// Paid, money on its way (a bank debit, UPI or Pix still settling), or a UPI or Pix payment the buyer started and can
/// still finish in their bank app after closing the sheet: wait for the webhook, which says how it ends.
final class CheckoutProcessing extends CheckoutResult {
  const CheckoutProcessing({this.paymentId, this.subscription});

  final String? paymentId;
  final SubscriptionResult? subscription;

  @override
  Map<String, Object?> toJson() => {
    'status': 'processing',
    'paymentId': paymentId,
    if (subscription != null) 'subscription': subscription!.toJson(),
  };
}

/// The buyer closed the sheet. Not an error.
final class CheckoutCanceled extends CheckoutResult {
  const CheckoutCanceled();

  @override
  Map<String, Object?> toJson() => {'status': 'canceled'};
}

/// The checkout couldn't be paid: [error] says why, in words for the buyer.
final class CheckoutFailed extends CheckoutResult {
  const CheckoutFailed(this.error);

  final VezmoError error;

  @override
  Map<String, Object?> toJson() => {'status': 'failed', 'error': error.toJson()};
}

/// The subscription a subscription checkout started.
class SubscriptionResult {
  const SubscriptionResult({required this.ref, required this.status});

  factory SubscriptionResult.fromJson(Map<String, Object?> json) => SubscriptionResult(
    ref: json['ref'] as String? ?? '',
    status: SubscriptionStatus.values.asNameMap()[json['status']] ?? SubscriptionStatus.incomplete,
  );

  /// The subscription's reference, as in the dashboard and the webhooks.
  final String ref;
  final SubscriptionStatus status;

  Map<String, Object?> toJson() => {'ref': ref, 'status': status.name};
}

/// Where a subscription started in the sheet stands.
enum SubscriptionStatus {
  /// The first payment went through.
  active,

  /// A free trial started; the card is saved for the first charge.
  trialing,

  /// Still settling: the webhook tells your server when it is active.
  incomplete,
}

/// Something went wrong. [message] is safe to show the buyer, in Vezmo's words.
class VezmoError {
  const VezmoError(this.code, this.message);

  factory VezmoError.fromJson(Map<String, Object?> json) => VezmoError(
    VezmoErrorCode.values.firstWhere((c) => c.wireName == json['code'], orElse: () => VezmoErrorCode.unknown),
    json['message'] as String? ?? _fallbackMessage,
  );

  final VezmoErrorCode code;
  final String message;

  Map<String, Object?> toJson() => {'code': code.wireName, 'message': message};

  @override
  String toString() => 'VezmoError(${code.wireName}): $message';
}

/// What went wrong, to decide what your app does next.
enum VezmoErrorCode {
  /// The bank said no; the buyer can try another card or way to pay.
  declined('declined'),

  /// The session ran out: create a new one.
  expired('expired'),

  /// The session was already paid. Treat the order as paid.
  alreadyPaid('already_paid'),

  /// This way to pay can't be used for this session.
  notAvailable('not_available'),

  /// No connection. Let the buyer try again.
  network('network'),

  /// A setup mistake in the app (for example [VezmoCheckout.present] before [VezmoCheckout.prepare]).
  config('config'),

  /// Anything else. Let the buyer try again.
  unknown('unknown');

  const VezmoErrorCode(this.wireName);

  /// The code as the native SDKs and the React Native package name it.
  final String wireName;
}
