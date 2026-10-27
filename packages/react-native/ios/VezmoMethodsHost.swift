import Foundation
import React
import StripePaymentSheet
import UIKit

/// The Vezmo methods view on iOS: the processor's native embedded element for the methods with rows of their own
/// (pay-later, Cash App…), configured from JSON that the JS layer builds and confirmed through Vezmo's server. Cards
/// and wallets are the card flow's (`VezmoCardFlowHost`); with no other method the element is left out.
///
/// Payment flow: the buyer picks a method and taps Pay → `confirm()` → the element creates a payment method and calls
/// our handler → we hand its id to JS (`paymentMethod`) → JS sends it to Vezmo's API, which prices
/// and confirms the payment → JS answers with the intent's client secret (`resolveConfirmation`) → the element
/// finishes any step left (3D Secure, a wallet, a provider) and reports `confirmResult`.
@objc(VezmoMethodsHost)
public final class VezmoMethodsHost: UIView, EmbeddedPaymentElementDelegate {
  /// (event name, body) to the component view, which turns it into a React event.
  @objc public var onEvent: ((String, [String: Any]) -> Void)?

  private var element: EmbeddedPaymentElement?
  private var elementView: UIView?
  private var configJson = ""
  private var intentJson = ""
  private var building = false
  private var pendingSecret: CheckedContinuation<String, Error>?

  public override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  // MARK: Props

  @objc public func setConfigJson(_ config: String, intentJson intent: String) {
    let rebuild = config != configJson || element == nil
    configJson = config
    intentJson = intent
    Task { @MainActor in
      if rebuild { await self.build() } else { await self.update() }
    }
  }

  // MARK: Commands

  @objc public func confirm() {
    guard let element else {
      emit("confirmResult", ["status": "failed", "message": "The payment form isn’t ready yet."])
      return
    }
    element.presentingViewController = RCTPresentedViewController()
    element.confirm { [weak self] result in
      switch result {
      case .completed:
        self?.emit("confirmResult", ["status": "completed", "message": ""])
      case .canceled:
        self?.emit("confirmResult", ["status": "canceled", "message": ""])
      case .failed(let error):
        self?.emit("confirmResult", ["status": "failed", "message": error.localizedDescription])
      }
    }
  }

  @objc public func clearSelection() {
    element?.clearPaymentOption()
  }

  @objc public func resolveConfirmation(clientSecret: String, errorMessage: String) {
    guard let continuation = pendingSecret else { return }
    pendingSecret = nil
    if !clientSecret.isEmpty {
      continuation.resume(returning: clientSecret)
    } else {
      continuation.resume(throwing: VezmoElementError(message: errorMessage))
    }
  }

  // MARK: Element

  /// Builds from the latest settings. Settings that change while a build is on its way (the buyer switched currency,
  /// the phone's theme changed) are built when it ends: they would otherwise be dropped, leaving the old amount or
  /// currency in place.
  @MainActor
  private func build() async {
    guard !building else { return }
    building = true
    defer { building = false }
    var built: (String, String)
    repeat {
      built = (configJson, intentJson)
      await buildOnce()
    } while built != (configJson, intentJson)
  }

  @MainActor
  private func buildOnce() async {
    guard let config = Self.parse(configJson), let intent = Self.parse(intentJson) else { return }
    guard let publishableKey = config["publishableKey"] as? String, !publishableKey.isEmpty else {
      emit("loadFailed", ["message": "Missing checkout keys."])
      return
    }

    STPAPIClient.shared.publishableKey = publishableKey
    STPAPIClient.shared.stripeAccount = config["stripeAccount"] as? String

    do {
      let embeddedConfiguration = configuration(from: config)
      let types = intent["paymentMethodTypes"] as? [String] ?? []
      // The element draws the other ways to pay; with none (cards only), it is left out.
      // Never an empty list (the processor would show every method on the account).
      if !types.isEmpty {
        let created = try await EmbeddedPaymentElement.create(
          intentConfiguration: intentConfiguration(from: intent, types: types),
          configuration: embeddedConfiguration
        )
        attach(created)
      } else {
        detachElement()
      }
      emit("loaded", [:])
    } catch {
      emit("loadFailed", ["message": error.localizedDescription])
    }
  }

  @MainActor
  private func update() async {
    guard let intent = Self.parse(intentJson) else { return }
    if let element {
      let types = intent["paymentMethodTypes"] as? [String] ?? []
      let result = await element.update(intentConfiguration: intentConfiguration(from: intent, types: types))
      if case .failed(let error) = result {
        emit("loadFailed", ["message": error.localizedDescription])
      }
    }
  }

  @MainActor
  private func detachElement() {
    elementView?.removeFromSuperview()
    elementView = nil
    element = nil
    emit("height", ["height": 0])
  }

  @MainActor
  private func attach(_ created: EmbeddedPaymentElement) {
    elementView?.removeFromSuperview()
    element = created
    created.delegate = self
    created.presentingViewController = RCTPresentedViewController()

    let view = created.view
    view.translatesAutoresizingMaskIntoConstraints = false
    addSubview(view)
    NSLayoutConstraint.activate([
      view.topAnchor.constraint(equalTo: topAnchor),
      view.leadingAnchor.constraint(equalTo: leadingAnchor),
      view.trailingAnchor.constraint(equalTo: trailingAnchor),
    ])
    elementView = view

    embeddedPaymentElementDidUpdateHeight(embeddedPaymentElement: created)
    embeddedPaymentElementDidUpdatePaymentOption(embeddedPaymentElement: created)
  }

  /// What is charged, for the element or the card flow: the payment method's id (`pm_…`) goes to `secret`, which
  /// answers with the intent's client secret from Vezmo's server. A payment method, not a confirmation token: our server
  /// confirms every intent itself (manual confirmation), which refuses a token made on the device.
  static func intentConfiguration(
    from intent: [String: Any],
    types: [String],
    secret: @escaping (String) async throws -> String
  ) -> PaymentSheet.IntentConfiguration {
    let amount = (intent["amount"] as? NSNumber)?.intValue ?? 0
    let currency = (intent["currency"] as? String ?? "usd").lowercased()
    // A subscription saves the card for its renewals: a free trial only sets it up; a first payment keeps it.
    let saveForLater: PaymentSheet.IntentConfiguration.SetupFutureUsage? =
      (intent["setupFutureUsage"] as? String) == "off_session" ? .offSession : nil
    let mode: PaymentSheet.IntentConfiguration.Mode =
      (intent["mode"] as? String) == "setup"
        ? .setup(currency: currency, setupFutureUsage: .offSession)
        // Our server makes every intent with automatic_async capture; the element must say the same.
        : .payment(
          amount: amount,
          currency: currency,
          setupFutureUsage: saveForLater,
          captureMethod: .automaticAsync,
          paymentMethodOptions: nil
        )
    return PaymentSheet.IntentConfiguration(
      mode: mode,
      paymentMethodTypes: types,
      onBehalfOf: nil,
      confirmHandler: { paymentMethod, _ in
        try await secret(paymentMethod.stripeId)
      }
    )
  }

  private func intentConfiguration(from intent: [String: Any], types: [String]) -> PaymentSheet.IntentConfiguration {
    Self.intentConfiguration(from: intent, types: types) { [weak self] paymentMethodId in
      guard let self else { throw VezmoElementError(message: "") }
      return try await self.clientSecret(forPaymentMethod: paymentMethodId)
    }
  }

  private func configuration(from config: [String: Any]) -> EmbeddedPaymentElement.Configuration {
    var configuration = EmbeddedPaymentElement.Configuration()
    configuration.merchantDisplayName = config["merchantDisplayName"] as? String ?? ""
    if let returnURL = config["returnURL"] as? String, !returnURL.isEmpty {
      configuration.returnURL = returnURL
    }
    // Our own Pay button confirms; the card form only collects details.
    configuration.formSheetAction = .continue
    // Vezmo is white label: no processor wallet of its own in the sheet.
    configuration.link = PaymentSheet.LinkConfiguration(display: .never)
    configuration.embeddedViewDisplaysMandateText = true
    switch config["style"] as? String {
    case "dark": configuration.style = .alwaysDark
    case "light": configuration.style = .alwaysLight
    default: configuration.style = .automatic
    }
    if let applePay = config["applePay"] as? [String: Any],
       let merchantId = applePay["merchantId"] as? String, !merchantId.isEmpty {
      configuration.applePay = PaymentSheet.ApplePayConfiguration(
        merchantId: merchantId,
        merchantCountryCode: applePay["merchantCountryCode"] as? String ?? "US"
      )
    }
    if let billing = config["billing"] as? [String: Any] {
      configuration.defaultBillingDetails.name = billing["name"] as? String
      configuration.defaultBillingDetails.email = billing["email"] as? String
    }
    if let appearance = config["appearance"] as? [String: Any] {
      configuration.appearance = Self.appearance(from: appearance)
    }
    return configuration
  }

  static func appearance(from params: [String: Any]) -> PaymentSheet.Appearance {
    var appearance = PaymentSheet.Appearance()
    let colors = params["colors"] as? [String: String] ?? [:]
    func color(_ key: String) -> UIColor? { colors[key].flatMap(UIColor.vezmoHex) }
    if let c = color("primary") { appearance.colors.primary = c }
    if let c = color("background") { appearance.colors.background = c }
    if let c = color("componentBackground") { appearance.colors.componentBackground = c }
    if let c = color("componentBorder") { appearance.colors.componentBorder = c }
    if let c = color("componentDivider") { appearance.colors.componentDivider = c }
    if let c = color("text") { appearance.colors.text = c }
    if let c = color("textSecondary") { appearance.colors.textSecondary = c }
    if let c = color("componentText") { appearance.colors.componentText = c }
    if let c = color("placeholderText") { appearance.colors.componentPlaceholderText = c }
    if let c = color("icon") { appearance.colors.icon = c }
    if let c = color("danger") { appearance.colors.danger = c }
    if let radius = params["cornerRadius"] as? NSNumber { appearance.cornerRadius = CGFloat(radius.doubleValue) }
    if let width = params["borderWidth"] as? NSNumber { appearance.borderWidth = CGFloat(width.doubleValue) }
    if let width = params["selectedBorderWidth"] as? NSNumber { appearance.selectedBorderWidth = CGFloat(width.doubleValue) }
    // Methods as a flat list with a checkmark, inside the sheet's own rounded group (which draws the outer edges).
    if let row = params["row"] as? [String: Any] {
      if row["style"] as? String == "checkmark" {
        appearance.embeddedPaymentElement.row.style = .flatWithCheckmark
        appearance.embeddedPaymentElement.row.flat.topSeparatorEnabled = false
        appearance.embeddedPaymentElement.row.flat.bottomSeparatorEnabled = false
      }
      if let c = (row["separatorColor"] as? String).flatMap(UIColor.vezmoHex) {
        appearance.embeddedPaymentElement.row.flat.separatorColor = c
      }
      if let insets = row["insets"] as? NSNumber { appearance.embeddedPaymentElement.row.additionalInsets = CGFloat(insets.doubleValue) }
    }
    if let family = params["fontFamily"] as? String, let font = UIFont(name: family, size: UIFont.systemFontSize) {
      appearance.font.base = font
    }
    return appearance
  }

  // MARK: Payment method → Vezmo → client secret

  private func clientSecret(forPaymentMethod paymentMethodId: String) async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.main.async {
        // A confirm still waiting is superseded by this one.
        self.pendingSecret?.resume(throwing: VezmoElementError(message: ""))
        self.pendingSecret = continuation
        self.emit("paymentMethod", ["id": paymentMethodId])
      }
    }
  }

  // MARK: EmbeddedPaymentElementDelegate

  public func embeddedPaymentElementDidUpdateHeight(embeddedPaymentElement: EmbeddedPaymentElement) {
    let view = embeddedPaymentElement.view
    let height = view.systemLayoutSizeFitting(
      CGSize(width: view.bounds.width > 0 ? view.bounds.width : bounds.width,
             height: UIView.layoutFittingCompressedSize.height)
    ).height
    emit("height", ["height": height])
  }

  public func embeddedPaymentElementDidUpdatePaymentOption(embeddedPaymentElement: EmbeddedPaymentElement) {
    let option = embeddedPaymentElement.paymentOption
    emit("paymentOption", [
      "paymentMethodType": option?.paymentMethodType ?? "",
      "label": option?.label ?? "",
    ])
  }

  // MARK: Helpers

  private func emit(_ name: String, _ body: [String: Any]) {
    if Thread.isMainThread {
      onEvent?(name, body)
    } else {
      DispatchQueue.main.async { self.onEvent?(name, body) }
    }
  }

  static func parse(_ json: String) -> [String: Any]? {
    guard !json.isEmpty, let data = json.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
  }
}

/// An error the element shows the buyer as is (already in Vezmo's words).
struct VezmoElementError: LocalizedError {
  let message: String
  var errorDescription: String? { message.isEmpty ? "Your payment couldn’t be completed. Please try again." : message }
}

extension UIColor {
  /// `#RRGGBB` or `#RRGGBBAA`.
  static func vezmoHex(_ hex: String) -> UIColor? {
    var s = hex.trimmingCharacters(in: .whitespaces)
    if s.hasPrefix("#") { s.removeFirst() }
    guard s.count == 6 || s.count == 8, let value = UInt64(s, radix: 16) else { return nil }
    let hasAlpha = s.count == 8
    let r = CGFloat((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
    let g = CGFloat((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
    let b = CGFloat((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
    let a = hasAlpha ? CGFloat(value & 0xFF) / 255 : 1
    return UIColor(red: r, green: g, blue: b, alpha: a)
  }
}
