import Foundation
import PassKit
import React
@_spi(STP) import StripePaymentSheet
import StripeCore
import SwiftUI
import UIKit

/// Cards and wallets on iOS: the processor's flow controller (the native card form, Apple Pay), confirmed through
/// Vezmo's server like the element. It draws only the express wallet buttons; the sheet draws the Card row itself
/// (with the card network's logo) and opens the card form with `presentCard()`.
///
/// Two flow controllers: one for cards only (its sheet is just the card form, which the Card row opens) and one with
/// Apple Pay that only draws the express button. Both confirm through the same Vezmo step. A third, for Instant ACH,
/// offers only the engine's bank step (its sheet goes straight to linking a US bank account, which the sheet's Instant
/// ACH row opens with `presentBank()`).
@objc(VezmoCardFlowHost)
public final class VezmoCardFlowHost: UIView {
  /// (event name, body) to the component view, which turns it into a React event.
  @objc public var onEvent: ((String, [String: Any]) -> Void)?

  private var flow: PaymentSheet.FlowController?
  private var walletFlow: PaymentSheet.FlowController?
  /// Instant ACH's bank step (nil: not offered, or the engine has no bank step for this payment).
  private var bankFlow: PaymentSheet.FlowController?
  /// The settings the bank step was built with.
  private var bankConfig = ""
  private var bankBuilding = false
  /// Set up again for a new amount: the engine refuses the bank step meanwhile.
  private var bankUpdating = false
  private var bankUpdates = 0
  /// The wallet flow is updating for a new amount: an Apple Pay tap now would fail before Vezmo is asked.
  private var walletUpdating = false
  private var walletUpdates = 0
  /// The card flow is set up again for a new amount (the buyer switched currency, or a new price came in): the engine
  /// refuses the card form and payments until it ends, so they wait for it (as on Android, where commands queue
  /// behind the setup).
  private var updating = false
  private var updates = 0
  private var held: [() -> Void] = []
  private var wallets: UIViewController?
  /// The wallet buttons' height for a width (SwiftUI's own measure).
  private var measureWallets: ((CGFloat) -> CGFloat)?
  private var configJson = ""
  private var intentJson = ""
  private var building = false
  private var pendingSecret: CheckedContinuation<String, Error>?
  private var lastHeight: CGFloat = -1

  public override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  // MARK: Props

  @objc public func setConfigJson(_ config: String, intentJson intent: String) {
    let rebuild = config != configJson || flow == nil
    configJson = config
    intentJson = intent
    Task { @MainActor in
      self.syncBank()
      if rebuild { await self.build() } else { self.update() }
    }
  }

  // MARK: Commands

  /// The app was opened with its return link (after a bank app, a pay-later provider or 3D Secure in the browser
  /// sheet): the payment waiting on it finishes and the browser sheet closes.
  @objc(handleURL:) public func handleURL(_ url: String) {
    guard let link = URL(string: url) else { return }
    _ = StripeAPI.handleURLCallback(with: link)
  }

  @objc public func presentCard() {
    whenReady { [weak self] in self?.presentCardNow() }
  }

  @objc public func confirmCard() {
    whenReady { [weak self] in self?.confirmCardNow() }
  }

  /// Opens the engine's bank step: the buyer links a US bank account (or picks the one linked before).
  @objc public func presentBank() {
    guard let bankFlow, !bankUpdating, let presenter = RCTPresentedViewController() else { return }
    bankFlow.presentPaymentOptions(from: presenter) { [weak self] _ in
      self?.emitBank()
    }
  }

  @objc public func confirmBank() {
    guard let bankFlow, !bankUpdating, let presenter = RCTPresentedViewController() else {
      emit("confirmResult", ["status": "failed", "message": "Instant ACH is still loading. Try again in a moment."])
      return
    }
    bankFlow.confirm(from: presenter) { [weak self] result in
      self?.emitResult(result)
    }
  }

  /// Runs `command` now, or once the card flow's update in flight ends.
  private func whenReady(_ command: @escaping () -> Void) {
    if updating { held.append(command) } else { command() }
  }

  private func runHeld() {
    let commands = held
    held = []
    commands.forEach { $0() }
  }

  private func presentCardNow() {
    guard let flow, let presenter = RCTPresentedViewController() else { return }
    flow.presentPaymentOptions(from: presenter) { [weak self] _ in
      self?.emitCardOption()
    }
  }

  private func confirmCardNow() {
    guard let flow, let presenter = RCTPresentedViewController() else {
      emit("confirmResult", ["status": "failed", "message": "The payment form isn’t ready yet."])
      return
    }
    flow.confirm(from: presenter) { [weak self] result in
      self?.emitResult(result)
    }
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

  // MARK: Flow

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
    // A new flow: an update of the old one in flight no longer counts; what waited for it runs once this one is built.
    updates += 1
    updating = false
    defer { runHeld() }
    guard let config = VezmoMethodsHost.parse(configJson),
          let intent = VezmoMethodsHost.parse(intentJson) else { return }
    guard intent["card"] as? Bool == true else {
      removeWallets()
      flow = nil
      walletUpdates += 1
      walletUpdating = false
      walletFlow = nil
      emitCardOption()
      emit("loaded", [:])
      return
    }
    guard let publishableKey = config["publishableKey"] as? String, !publishableKey.isEmpty else {
      emit("loadFailed", ["message": "Missing checkout keys."])
      return
    }

    STPAPIClient.shared.publishableKey = publishableKey
    STPAPIClient.shared.stripeAccount = config["stripeAccount"] as? String

    do {
      flow = try await makeFlow(intent: intent, configuration: sheetConfiguration(from: config, wallets: false))
      let withWallets = sheetConfiguration(from: config, wallets: true)
      if withWallets.applePay != nil {
        let wallets = try await makeFlow(intent: intent, configuration: withWallets)
        walletUpdates += 1
        walletUpdating = false
        walletFlow = wallets
        showWallets(wallets)
      } else {
        walletUpdates += 1
        walletUpdating = false
        walletFlow = nil
        removeWallets()
      }
      emitCardOption()
      emit("loaded", [:])
    } catch {
      emit("loadFailed", ["message": error.localizedDescription])
    }
  }

  @MainActor
  private func makeFlow(
    intent: [String: Any],
    configuration: PaymentSheet.Configuration,
    types: [String] = ["card"]
  ) async throws -> PaymentSheet.FlowController {
    try await withCheckedThrowingContinuation { continuation in
      PaymentSheet.FlowController.create(
        intentConfiguration: intentConfiguration(from: intent, types: types),
        configuration: configuration
      ) { continuation.resume(with: $0) }
    }
  }

  // MARK: Instant ACH

  /// The bank step follows the props: built for new settings, updated for a new amount, gone when the payment isn't in
  /// US dollars (the buyer chose their own currency).
  @MainActor
  private func syncBank() {
    guard let intent = VezmoMethodsHost.parse(intentJson) else { return }
    if intent["instantAch"] as? Bool != true {
      bankUpdates += 1
      bankFlow = nil
      bankConfig = ""
      bankUpdating = false
      emitBank()
    } else if bankFlow == nil || bankConfig != configJson {
      Task { await buildBank() }
    } else {
      updateBank(intent)
    }
  }

  /// Builds the bank step for the latest props. One the engine can't offer for this payment (it decides which payments
  /// its bank step takes) leaves Instant ACH out; the card and the other methods are unaffected.
  @MainActor
  private func buildBank() async {
    guard !bankBuilding else { return }
    bankBuilding = true
    defer { bankBuilding = false }
    while true {
      let built = (configJson, intentJson)
      guard let config = VezmoMethodsHost.parse(configJson), let intent = VezmoMethodsHost.parse(intentJson),
            intent["instantAch"] as? Bool == true,
            let publishableKey = config["publishableKey"] as? String, !publishableKey.isEmpty else {
        // Whatever the sheet waits for is answered: no bank step.
        bankFlow = nil
        emitBank()
        return
      }
      bankUpdates += 1
      bankUpdating = false
      STPAPIClient.shared.publishableKey = publishableKey
      STPAPIClient.shared.stripeAccount = config["stripeAccount"] as? String
      var made: PaymentSheet.FlowController?
      do {
        made = try await makeFlow(intent: intent, configuration: bankConfiguration(from: config), types: ["link"])
      } catch {
        NSLog("[Vezmo] Instant ACH isn't available for this payment: %@", String(describing: error))
      }
      // Kept only when it is still what the sheet wants.
      if built == (configJson, intentJson) {
        bankFlow = made
        bankConfig = configJson
        emitBank()
        return
      }
    }
  }

  @MainActor
  private func updateBank(_ intent: [String: Any]) {
    guard let bankFlow else { return }
    bankUpdates += 1
    let mine = bankUpdates
    bankUpdating = true
    bankFlow.update(intentConfiguration: intentConfiguration(from: intent, types: ["link"])) { [weak self] error in
      guard let self, mine == self.bankUpdates else { return }
      if error != nil {
        // Left out rather than shown for an amount it isn't set up for.
        self.bankFlow = nil
        self.bankConfig = ""
      }
      self.bankUpdating = false
      self.emitBank()
    }
  }

  /// The bank step: the engine's bank payments run on its own wallet, which must be on for them; its button is never
  /// shown (Vezmo is white label: the buyer sees the Instant ACH row and the bank step, nothing else). The buyer's email
  /// from the session is used as is, so the step asks only for the bank.
  private func bankConfiguration(from config: [String: Any]) -> PaymentSheet.Configuration {
    var bank = sheetConfiguration(from: config, wallets: false)
    bank.link = PaymentSheet.LinkConfiguration(display: .walletButtonHidden)
    bank.willUseWalletButtonsView = true
    if let email = (config["billing"] as? [String: Any])?["email"] as? String, !email.isEmpty {
      bank.billingDetailsCollectionConfiguration.email = .never
      bank.billingDetailsCollectionConfiguration.attachDefaultsToPaymentMethod = true
    }
    return bank
  }

  /// Whether the bank step is set up, and the account it linked in the engine's words (the sheet shows its last four).
  private func emitBank() {
    emit("bankChange", ["available": bankFlow != nil, "label": bankFlow?.paymentOption?.label ?? ""])
  }

  @MainActor
  private func update() {
    guard let flow, let intent = VezmoMethodsHost.parse(intentJson) else { return }
    updates += 1
    let mine = updates
    updating = true
    // Only the latest update answers for the hold (the engine drops one superseded by another).
    flow.update(intentConfiguration: intentConfiguration(from: intent)) { [weak self] error in
      guard let self else { return }
      if let error { self.emit("loadFailed", ["message": error.localizedDescription]) }
      self.emitCardOption()
      if mine == self.updates {
        self.updating = false
        self.runHeld()
      }
    }
    if let walletFlow {
      walletUpdates += 1
      let mine = walletUpdates
      walletUpdating = true
      walletFlow.update(intentConfiguration: intentConfiguration(from: intent)) { [weak self] _ in
        if mine == self?.walletUpdates { self?.walletUpdating = false }
      }
    }
  }

  private func intentConfiguration(from intent: [String: Any], types: [String] = ["card"]) -> PaymentSheet.IntentConfiguration {
    VezmoMethodsHost.intentConfiguration(from: intent, types: types) { [weak self] paymentMethodId in
      guard let self else { throw VezmoElementError(message: "") }
      return try await self.clientSecret(forPaymentMethod: paymentMethodId)
    }
  }

  /// A subscription in Apple Pay (iOS 16+): Apple's sheet shows the plan, any free trial and when billing starts, and
  /// the buyer's Wallet lists it with the page to manage it.
  static func addRecurring(_ plan: [String: Any], to request: PKPaymentRequest) -> PKPaymentRequest {
    guard #available(iOS 16.0, *),
          let amount = plan["amount"] as? String,
          let link = URL(string: plan["managementUrl"] as? String ?? "")
    else { return request }
    let dates = ISO8601DateFormatter()
    dates.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    func date(_ key: String) -> Date? { (plan[key] as? String).flatMap { dates.date(from: $0) } }

    let label = plan["label"] as? String ?? ""
    let regular = PKRecurringPaymentSummaryItem(label: label, amount: NSDecimalNumber(string: amount))
    switch plan["intervalUnit"] as? String {
    case "day": regular.intervalUnit = .day
    case "week": regular.intervalUnit = .weekOfMonth
    case "year": regular.intervalUnit = .year
    default: regular.intervalUnit = .month
    }
    regular.intervalCount = (plan["intervalCount"] as? NSNumber)?.intValue ?? 1
    if let start = date("startDate") { regular.startDate = start }

    let recurring = PKRecurringPaymentRequest(
      paymentDescription: plan["description"] as? String ?? label,
      regularBilling: regular,
      managementURL: link
    )
    var lines: [PKPaymentSummaryItem] = []
    if let trialEnd = date("trialEndDate") {
      let trial = PKRecurringPaymentSummaryItem(label: "Free trial", amount: .zero)
      trial.endDate = trialEnd
      recurring.trialBilling = trial
      lines.append(trial)
    }
    recurring.billingAgreement = plan["billingAgreement"] as? String
    request.recurringPaymentRequest = recurring
    lines.append(regular)
    // Apple's last line is the total due today, under the business's name.
    lines.append(PKPaymentSummaryItem(
      label: plan["merchant"] as? String ?? label,
      amount: NSDecimalNumber(string: plan["dueToday"] as? String ?? "0")
    ))
    request.paymentSummaryItems = lines
    return request
  }

  /// The same business, look and billing details as the element; Apple Pay only for the wallet flow.
  private func sheetConfiguration(from config: [String: Any], wallets: Bool) -> PaymentSheet.Configuration {
    var configuration = PaymentSheet.Configuration()
    configuration.merchantDisplayName = config["merchantDisplayName"] as? String ?? ""
    if let returnURL = config["returnURL"] as? String, !returnURL.isEmpty {
      configuration.returnURL = returnURL
    }
    // Vezmo is white label: no processor wallet of its own.
    configuration.link = PaymentSheet.LinkConfiguration(display: .never)
    configuration.paymentMethodLayout = .vertical
    switch config["style"] as? String {
    case "dark": configuration.style = .alwaysDark
    case "light": configuration.style = .alwaysLight
    default: configuration.style = .automatic
    }
    if wallets, let applePay = config["applePay"] as? [String: Any],
       let merchantId = applePay["merchantId"] as? String, !merchantId.isEmpty {
      let recurring = applePay["recurring"] as? [String: Any]
      configuration.applePay = PaymentSheet.ApplePayConfiguration(
        merchantId: merchantId,
        merchantCountryCode: applePay["merchantCountryCode"] as? String ?? "US",
        customHandlers: recurring.map { plan in
          PaymentSheet.ApplePayConfiguration.Handlers(paymentRequestHandler: { request in
            Self.addRecurring(plan, to: request)
          })
        }
      )
    }
    if let billing = config["billing"] as? [String: Any] {
      configuration.defaultBillingDetails.name = billing["name"] as? String
      configuration.defaultBillingDetails.email = billing["email"] as? String
    }
    if let appearance = config["appearance"] as? [String: Any] {
      configuration.appearance = VezmoMethodsHost.appearance(from: appearance)
    }
    return configuration
  }

  // MARK: Wallet buttons

  @MainActor
  private func showWallets(_ flow: PaymentSheet.FlowController) {
    removeWallets()
    guard #available(iOS 16.0, *) else { return }
    let buttons = WalletButtonsView(
      flowController: flow,
      confirmHandler: { [weak self] result in self?.emitResult(result) },
      clickHandler: { [weak self] wallet in
        guard let self else { return false }
        if self.walletUpdating {
          // Still being set up for this amount or currency: our words, and the next tap pays.
          self.emit("confirmResult", ["status": "failed", "message": "Apple Pay is still loading. Try again in a moment."])
          return false
        }
        self.emit("walletTap", ["wallet": wallet])
        return true
      }
    )
    let host = UIHostingController(rootView: buttons)
    host.view.backgroundColor = .clear
    host.view.translatesAutoresizingMaskIntoConstraints = false
    addSubview(host.view)
    NSLayoutConstraint.activate([
      host.view.topAnchor.constraint(equalTo: topAnchor),
      host.view.leadingAnchor.constraint(equalTo: leadingAnchor),
      host.view.trailingAnchor.constraint(equalTo: trailingAnchor),
    ])
    wallets = host
    measureWallets = { [weak host] width in
      host?.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height ?? 0
    }
    reportHeight()
  }

  private func removeWallets() {
    wallets?.view.removeFromSuperview()
    wallets = nil
    measureWallets = nil
    reportHeight()
  }

  public override func layoutSubviews() {
    super.layoutSubviews()
    reportHeight()
  }

  /// The wallet buttons' height (0 when there are none on this phone).
  private func reportHeight() {
    var height: CGFloat = 0
    if let measureWallets {
      height = measureWallets(bounds.width > 0 ? bounds.width : UIScreen.main.bounds.width - 40)
    }
    guard abs(height - lastHeight) > 0.5 else { return }
    lastHeight = height
    emit("height", ["height": height])
  }

  // MARK: Results

  /// The card from the card form, for the sheet's own Card row: its label and the network's logo.
  private func emitCardOption() {
    var body: [String: Any] = ["label": "", "image": ""]
    if let option = flow?.paymentOption, option.paymentMethodType == "card" {
      body["label"] = option.label
      if let png = option.image.pngData() {
        body["image"] = "data:image/png;base64," + png.base64EncodedString()
      }
    }
    emit("cardOption", body)
  }

  private func emitResult(_ result: PaymentSheetResult) {
    switch result {
    case .completed:
      emit("confirmResult", ["status": "completed", "message": ""])
    case .canceled:
      emit("confirmResult", ["status": "canceled", "message": ""])
    case .failed(let error):
      emit("confirmResult", ["status": "failed", "message": error.localizedDescription])
    }
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

  private func emit(_ name: String, _ body: [String: Any]) {
    if Thread.isMainThread {
      onEvent?(name, body)
    } else {
      DispatchQueue.main.async { self.onEvent?(name, body) }
    }
  }
}
