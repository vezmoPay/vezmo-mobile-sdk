import Foundation
import os
import PassKit
@_spi(STP) import StripePaymentSheet
import SwiftUI
import UIKit

/// How the engine is set up: keys and account from the session, the look, the app's return link, Apple Pay (for the
/// card flow's express button) only when the business offers it. A change rebuilds the engine.
struct EngineSettings: Equatable {
  var publishableKey: String
  var account: String?
  var merchantDisplayName: String
  var returnURL: String?
  var dark: Bool
  var palette: Palette
  var radius: CGFloat
  var fontFamily: String?
  var applePay: VezmoCheckout.ApplePay?
  /// The country of the account that processes the payment, from the session (Apple Pay's merchant country).
  var processingCountry: String? = nil
  /// A subscription in Apple Pay's sheet and the buyer's Wallet (iOS 16+); nil for a one-time payment.
  var applePayRecurring: ApplePayRecurring?
  var billingName: String?
  var billingEmail: String?
  /// Bumped to rebuild the engine (Try again after a failed load).
  var attempt: Int
}

/// What is charged: a change updates the engine in place (the buyer switched currency). Cards go to the native card
/// form (`card`), the sheet's own Card row; Instant ACH to the engine's bank step, our Instant ACH row; every other
/// method to the element's rows. A subscription saves the card (or the bank account) for its renewals: a setup (a free
/// trial, nothing charged today) or a payment kept for later use.
struct EngineIntent: Equatable {
  var amount: Int
  var currency: String
  var paymentMethodTypes: [String]
  var card: Bool
  /// Instant ACH: the engine's bank step, for our own row.
  var instantAch = false
  /// A free trial: the card is set up, nothing is charged.
  var setup: Bool
  /// A subscription: the card is kept for the renewals.
  var saveForLater: Bool

  init(charge: Charge, methods: SheetMethods, plan: SubscriptionPlan? = nil) {
    amount = charge.amountMinor
    currency = charge.currency.lowercased()
    paymentMethodTypes = methods.elementTypes.filter { $0 != "card" }
    card = methods.elementTypes.contains("card")
    instantAch = methods.instantAch
    setup = plan?.trial == true
    saveForLater = plan != nil
  }

  var mode: PaymentSheet.IntentConfiguration.Mode {
    if setup { return .setup(currency: currency, setupFutureUsage: .offSession) }
    // Our server makes every intent with automatic_async capture; the engine must say the same.
    return .payment(
      amount: amount,
      currency: currency,
      setupFutureUsage: saveForLater ? .offSession : nil,
      captureMethod: .automaticAsync,
      paymentMethodOptions: nil
    )
  }

  /// What is charged, for the element or the card flow: the payment method's id (`pm_…`) goes to `secret`, which
  /// answers with the intent's client secret from Vezmo's server. A payment method, not a confirmation token: our server
  /// confirms every intent itself (manual confirmation), which refuses a token made on the device.
  func configuration(types: [String], secret: @escaping (String) async throws -> String) -> PaymentSheet.IntentConfiguration {
    PaymentSheet.IntentConfiguration(
      mode: mode,
      paymentMethodTypes: types,
      onBehalfOf: nil,
      confirmHandler: { paymentMethod, _ in
        try await secret(paymentMethod.stripeId)
      }
    )
  }
}

/// Apple Pay's recurring payment (iOS 16+): the plan in Apple's sheet and the buyer's Wallet, with the free trial and
/// the page to manage it.
struct ApplePayRecurring: Equatable {
  var label: String
  var amount: String
  /// `day`, `week`, `month` or `year`.
  var intervalUnit: String
  var intervalCount: Int
  /// A trial's plan starts when the trial ends; nil: today, with this first payment.
  var startDate: Date?
  var trialEndDate: Date?
  var managementURL: URL
  var billingAgreement: String
  var merchant: String
  var dueToday: String

  /// Nil for a one-time payment, or without a manage page (Apple requires one).
  init?(config: CheckoutConfig, charge: Charge, merchant: String) {
    guard let plan = config.subscription, let manage = plan.manageUrl.flatMap(URL.init(string:)) else { return nil }
    let units = ["DAY": "day", "WEEK": "week", "MONTH": "month", "YEAR": "year"]
    label = plan.planName
    amount = String(format: "%.2f", Double(recurringMinorIn(config, charge)) / 100)
    intervalUnit = units[plan.interval.uppercased()] ?? "month"
    intervalCount = plan.intervalCount
    startDate = plan.trial ? isoDate(plan.nextChargeAt) : nil
    trialEndDate = plan.trial ? isoDate(plan.nextChargeAt) : nil
    managementURL = manage
    billingAgreement = plan.consentText
    self.merchant = merchant
    dueToday = String(format: "%.2f", Double(charge.amountMinor) / 100)
  }

  /// Apple's sheet shows the plan, any free trial and when billing starts; the last line is the total due today,
  /// under the business's name.
  @available(iOS 16.0, *)
  func add(to request: PKPaymentRequest) -> PKPaymentRequest {
    let regular = PKRecurringPaymentSummaryItem(label: label, amount: NSDecimalNumber(string: amount))
    switch intervalUnit {
    case "day": regular.intervalUnit = .day
    case "week": regular.intervalUnit = .weekOfMonth
    case "year": regular.intervalUnit = .year
    default: regular.intervalUnit = .month
    }
    regular.intervalCount = intervalCount
    regular.startDate = startDate ?? Date()
    let recurring = PKRecurringPaymentRequest(paymentDescription: label, regularBilling: regular, managementURL: managementURL)
    var lines: [PKPaymentSummaryItem] = []
    if let trialEndDate {
      let trial = PKRecurringPaymentSummaryItem(label: "Free trial", amount: .zero)
      trial.endDate = trialEndDate
      recurring.trialBilling = trial
      lines.append(trial)
    }
    recurring.billingAgreement = billingAgreement
    request.recurringPaymentRequest = recurring
    lines.append(regular)
    lines.append(PKPaymentSummaryItem(label: merchant, amount: NSDecimalNumber(string: dueToday)))
    request.paymentSummaryItems = lines
    return request
  }
}

/// An error the engine shows the buyer as is (already in Vezmo's words).
struct EngineError: LocalizedError {
  let message: String
  var errorDescription: String? { message.isEmpty ? "Your payment couldn’t be completed. Please try again." : message }
}


/// Why the engine couldn't load or update, for the app's console (the buyer sees our own words).
let engineLog = Logger(subsystem: "com.vezmo.checkout", category: "engine")

private func confirmStatus(_ result: PaymentSheetResult) -> (ConfirmStatus, String) {
  switch result {
  case .completed: return (.completed, "")
  case .canceled: return (.canceled, "")
  case .failed(let error): return (.failed, error.localizedDescription)
  }
}

// MARK: - Card flow

/// Cards and Apple Pay: the engine's flow controller (the native card form, Apple Pay), confirmed through Vezmo's
/// server like the element. The sheet draws the Card row itself (with the card network's logo) and opens the card
/// form with `presentCard()`; the express Apple Pay button is the wallet flow's.
///
/// Two flow controllers: one for cards only (its sheet is just the card form, which the Card row opens) and one with
/// Apple Pay that only draws the express button. Both confirm through the same Vezmo step. A third, for Instant ACH,
/// offers only the engine's bank step (its sheet goes straight to linking a US bank account, which our Instant ACH row
/// opens).
@MainActor
final class CardFlowHost: ObservableObject, CardFlowPort {
  weak var session: CheckoutSession?
  weak var presenter: UIViewController?
  /// The flow behind the express Apple Pay button (nil: none on this session).
  @Published private(set) var walletFlow: PaymentSheet.FlowController?
  /// The wallet flow is updating for a new amount: an Apple Pay tap now would fail before Vezmo is asked.
  @Published private(set) var walletUpdating = false
  private var walletUpdates = 0
  /// Built for the current settings.
  @Published private(set) var loaded = false
  /// Set up again for a new amount (the buyer switched currency; the rows stay on screen): the engine refuses the card
  /// form and payments until it ends, so the sheet holds the Card row and Pay meanwhile.
  @Published private(set) var updating = false
  private var updates = 0

  private var flow: PaymentSheet.FlowController?
  /// Instant ACH's bank step (nil: not offered, or the engine has no bank step for this payment).
  private var bankFlow: PaymentSheet.FlowController?
  /// The bank step is set up: the Instant ACH row shows only then.
  @Published private(set) var bankOn = false
  /// The bank step finished setting up (or isn't wanted): the sheet holds its placeholders until then.
  @Published private(set) var bankLoaded = true
  /// Set up again for a new amount: the engine refuses the bank step meanwhile, so the sheet holds the row and Pay.
  @Published private(set) var bankUpdating = false
  private var bankSettings: EngineSettings?
  private var bankBuilding = false
  private var bankUpdates = 0
  private var settings: EngineSettings?
  private var intent: EngineIntent?
  private var building = false
  private var pendingSecret: CheckedContinuation<String, Error>?

  func configure(_ settings: EngineSettings, _ intent: EngineIntent) {
    let newSettings = settings != self.settings
    guard newSettings || intent != self.intent else { return }
    self.settings = settings
    self.intent = intent
    if newSettings || intent.card != (flow != nil) {
      loaded = false
      Task { await build() }
    } else if intent.card {
      update()
    }
    syncBank()
  }

  /// The sheet is gone: let the engine go.
  func teardown() {
    pendingSecret?.resume(throwing: EngineError(message: ""))
    pendingSecret = nil
    flow = nil
    walletFlow = nil
    bankFlow = nil
  }

  // MARK: Commands

  func presentCard() {
    guard let flow, let presenter, !updating else { return }
    flow.presentPaymentOptions(from: presenter) { [weak self] _ in
      self?.reportCard()
    }
  }

  func confirmCard() {
    guard let flow, let presenter, !updating else {
      session?.engineNotReady()
      return
    }
    flow.confirm(from: presenter) { [weak self] result in
      self?.report(result)
    }
  }

  /// Opens the engine's bank step: the buyer links a US bank account (or picks the one linked before).
  func presentBank() {
    guard let bankFlow, let presenter, !bankUpdating else { return }
    bankFlow.presentPaymentOptions(from: presenter) { [weak self] _ in
      self?.reportBank()
    }
  }

  func confirmBank() {
    guard let bankFlow, let presenter, !bankUpdating else {
      session?.engineNotReady(bankLoading)
      return
    }
    bankFlow.confirm(from: presenter) { [weak self] result in
      self?.report(result)
    }
  }

  func resolveConfirmation(clientSecret: String?, errorMessage: String?) {
    guard let continuation = pendingSecret else { return }
    pendingSecret = nil
    if let clientSecret, !clientSecret.isEmpty {
      continuation.resume(returning: clientSecret)
    } else {
      continuation.resume(throwing: EngineError(message: errorMessage ?? ""))
    }
  }

  // MARK: Instant ACH

  /// The bank step follows the sheet: built for new settings, updated for a new amount, gone when the payment isn't in
  /// US dollars (the buyer chose their own currency).
  private func syncBank() {
    guard let settings, let intent else { return }
    if !intent.instantAch {
      bankUpdates += 1
      bankFlow = nil
      bankSettings = nil
      bankOn = false
      bankUpdating = false
      bankLoaded = true
      reportBank()
    } else if bankFlow == nil || settings != bankSettings {
      bankLoaded = false
      Task { await buildBank() }
    } else {
      updateBank(intent)
    }
  }

  /// Builds the bank step for the latest settings. One the engine can't offer for this payment (it decides which
  /// payments its bank step takes) leaves Instant ACH out; the card and the other methods are unaffected.
  private func buildBank() async {
    guard !bankBuilding else { return }
    bankBuilding = true
    defer { bankBuilding = false }
    while let settings, let intent {
      guard intent.instantAch else { return }
      bankUpdates += 1
      bankUpdating = false
      STPAPIClient.shared.publishableKey = settings.publishableKey
      STPAPIClient.shared.stripeAccount = settings.account
      var built: PaymentSheet.FlowController?
      do {
        built = try await makeFlow(intent, bankConfiguration(settings), types: ["link"])
      } catch {
        engineLog.notice("Instant ACH isn't available for this payment: \(String(describing: error), privacy: .public)")
      }
      // Kept only when it is still what the sheet wants.
      if settings == self.settings && intent == self.intent {
        bankFlow = built
        bankSettings = settings
        bankOn = built != nil
        bankLoaded = true
        reportBank()
        return
      }
    }
  }

  private func updateBank(_ intent: EngineIntent) {
    guard let bankFlow else { return }
    bankUpdates += 1
    let mine = bankUpdates
    bankUpdating = true
    bankFlow.update(intentConfiguration: intentConfiguration(intent, types: ["link"])) { [weak self] error in
      guard let self, mine == self.bankUpdates else { return }
      if let error {
        // Left out rather than shown for an amount it isn't set up for.
        engineLog.error("Instant ACH failed to update: \(String(describing: error), privacy: .public)")
        self.bankFlow = nil
        self.bankSettings = nil
        self.bankOn = false
      }
      self.bankUpdating = false
      self.reportBank()
    }
  }

  /// The bank step: the engine's bank payments run on its own wallet, which must be on for them; its button is never
  /// shown (Vezmo is white label: the buyer sees our Instant ACH row and the bank step, nothing else). The buyer's email
  /// from the session is used as is, so the step asks only for the bank.
  private func bankConfiguration(_ settings: EngineSettings) -> PaymentSheet.Configuration {
    var bank = configuration(settings, wallets: false)
    bank.link = PaymentSheet.LinkConfiguration(display: .walletButtonHidden)
    bank.willUseWalletButtonsView = true
    if let email = settings.billingEmail, !email.isEmpty {
      bank.billingDetailsCollectionConfiguration.email = .never
      bank.billingDetailsCollectionConfiguration.attachDefaultsToPaymentMethod = true
    }
    return bank
  }

  /// The bank account the bank step linked, for our Instant ACH row: its last four only.
  private func reportBank() {
    let label = bankFlow.flatMap { bankLabel($0.paymentOption?.label) }
    session?.setBank(label.map { CardChoice(label: $0, image: nil) })
  }

  // MARK: Flow

  private func build() async {
    guard !building else { return }
    building = true
    defer { building = false }
    // What changes while a build runs is built next.
    while let settings, let intent {
      let built = await build(settings, intent)
      // Shown as loaded only when what was built is still what the sheet wants (a tap meanwhile would reach an
      // engine about to be replaced).
      if settings == self.settings && intent == self.intent {
        loaded = built
        return
      }
    }
  }

  /// Builds the engine for these settings; false when it couldn't load (the session shows why).
  private func build(_ settings: EngineSettings, _ intent: EngineIntent) async -> Bool {
    // A new flow: an update of the old one in flight no longer counts (it may never answer).
    updates += 1
    updating = false
    walletUpdates += 1
    walletUpdating = false
    guard intent.card else {
      flow = nil
      walletFlow = nil
      reportCard()
      return true
    }
    STPAPIClient.shared.publishableKey = settings.publishableKey
    STPAPIClient.shared.stripeAccount = settings.account
    do {
      flow = try await makeFlow(intent, configuration(settings, wallets: false))
      // The express button needs iOS 16; without Apple Pay set up there is none.
      if #available(iOS 16.0, *), settings.applePay != nil {
        walletFlow = try await makeFlow(intent, configuration(settings, wallets: true))
      } else {
        walletFlow = nil
      }
      reportCard()
      return true
    } catch {
      engineLog.error("Card flow failed to load: \(String(describing: error), privacy: .public)")
      session?.setElementError(error.localizedDescription.isEmpty ? "load failed" : error.localizedDescription)
      return false
    }
  }

  private func makeFlow(
    _ intent: EngineIntent,
    _ configuration: PaymentSheet.Configuration,
    types: [String] = ["card"]
  ) async throws -> PaymentSheet.FlowController {
    try await withCheckedThrowingContinuation { continuation in
      PaymentSheet.FlowController.create(
        intentConfiguration: intentConfiguration(intent, types: types),
        configuration: configuration
      ) { continuation.resume(with: $0) }
    }
  }

  private func update() {
    guard let flow, let intent else { return }
    updates += 1
    let mine = updates
    updating = true
    // Only the latest update answers (the engine drops one superseded by another).
    flow.update(intentConfiguration: intentConfiguration(intent)) { [weak self] error in
      if mine == self?.updates { self?.updating = false }
      if let error {
        engineLog.error("Card flow failed to update: \(String(describing: error), privacy: .public)")
        self?.session?.setElementError(error.localizedDescription)
      }
      self?.reportCard()
    }
    if let walletFlow {
      walletUpdates += 1
      let mineWallet = walletUpdates
      walletUpdating = true
      walletFlow.update(intentConfiguration: intentConfiguration(intent)) { [weak self] _ in
        if mineWallet == self?.walletUpdates { self?.walletUpdating = false }
      }
    }
  }

  private func intentConfiguration(_ intent: EngineIntent, types: [String] = ["card"]) -> PaymentSheet.IntentConfiguration {
    intent.configuration(types: types) { [weak self] paymentMethodId in
      guard let self else { throw EngineError(message: "") }
      return try await self.clientSecret(forPaymentMethod: paymentMethodId)
    }
  }

  /// The same business, look and billing details as the element; Apple Pay only for the wallet flow.
  private func configuration(_ settings: EngineSettings, wallets: Bool) -> PaymentSheet.Configuration {
    var configuration = PaymentSheet.Configuration()
    configuration.merchantDisplayName = settings.merchantDisplayName
    if let returnURL = settings.returnURL, !returnURL.isEmpty {
      configuration.returnURL = returnURL
    }
    // Vezmo is white label: no processor wallet of its own.
    configuration.link = PaymentSheet.LinkConfiguration(display: .never)
    configuration.paymentMethodLayout = .vertical
    configuration.style = settings.dark ? .alwaysDark : .alwaysLight
    if wallets, let applePay = settings.applePay, !applePay.merchantId.isEmpty {
      var handlers: PaymentSheet.ApplePayConfiguration.Handlers?
      if #available(iOS 16.0, *), let plan = settings.applePayRecurring {
        handlers = PaymentSheet.ApplePayConfiguration.Handlers(paymentRequestHandler: { request in plan.add(to: request) })
      }
      configuration.applePay = PaymentSheet.ApplePayConfiguration(
        merchantId: applePay.merchantId,
        merchantCountryCode: merchantCountry(applePay.merchantCountryCode, session: settings.processingCountry),
        customHandlers: handlers
      )
    }
    configuration.defaultBillingDetails.name = settings.billingName
    configuration.defaultBillingDetails.email = settings.billingEmail
    configuration.appearance = settings.palette.engineAppearance(radius: settings.radius, fontFamily: settings.fontFamily)
    return configuration
  }

  // MARK: Results

  /// The card from the card form, for the sheet's own Card row: its label and the network's logo.
  private func reportCard() {
    if let option = flow?.paymentOption, option.paymentMethodType == "card" {
      session?.setCard(CardChoice(label: option.label, image: option.image))
    } else {
      session?.setCard(nil)
    }
  }

  fileprivate func report(_ result: PaymentSheetResult) {
    let (status, message) = confirmStatus(result)
    Task { await session?.onConfirmResult(status, message: message) }
  }

  /// Whether the wallet may start: not while it is updating for a new amount (our words instead; the next tap pays).
  fileprivate func walletTapped(_ wallet: String) -> Bool {
    if walletUpdating {
      session?.engineNotReady(walletLoading)
      return false
    }
    session?.walletStarted(wallet)
    return true
  }

  // MARK: Payment method → Vezmo → client secret

  private func clientSecret(forPaymentMethod paymentMethodId: String) async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
      // A confirm still waiting is superseded by this one.
      pendingSecret?.resume(throwing: EngineError(message: ""))
      pendingSecret = continuation
      Task { await session?.onPaymentMethod(paymentMethodId) }
    }
  }
}

/// The express Apple Pay button (the engine's own, as the platform requires).
@available(iOS 16.0, *)
struct WalletButtons: View {
  let host: CardFlowHost
  let flow: PaymentSheet.FlowController

  var body: some View {
    let host = self.host
    return WalletButtonsView(
      flowController: flow,
      confirmHandler: { result in host.report(result) },
      clickHandler: { wallet in host.walletTapped(wallet) }
    )
    .id(ObjectIdentifier(flow))
  }
}

// MARK: - Element

/// The engine's embedded element for the methods with rows of their own (pay-later, Cash App…). Cards and wallets are
/// the card flow's; with no other method the element is left out.
///
/// Payment flow: the buyer picks a method and taps Pay → `confirm()` → the element creates a payment method and calls
/// our handler → the session sends its id to Vezmo's API, which prices and confirms the payment → the session
/// answers with the intent's client secret (`resolveConfirmation`) → the element finishes any step left (3D Secure, a
/// provider) and reports the result.
@MainActor
final class MethodsHost: ObservableObject, ElementPort, EmbeddedPaymentElementDelegate {
  weak var session: CheckoutSession?
  weak var presenter: UIViewController?
  @Published private(set) var element: EmbeddedPaymentElement?
  @Published private(set) var height: CGFloat = 0
  /// Built for the current settings.
  @Published private(set) var loaded = false
  /// Set up again for a new amount: the engine refuses payments until it ends (see `CardFlowHost.updating`).
  @Published private(set) var updating = false
  private var updates = 0

  private var settings: EngineSettings?
  private var intent: EngineIntent?
  private var building = false
  private var pendingSecret: CheckedContinuation<String, Error>?
  private var width: CGFloat = 0

  func configure(_ settings: EngineSettings, _ intent: EngineIntent) {
    let newSettings = settings != self.settings
    guard newSettings || intent != self.intent else { return }
    self.settings = settings
    self.intent = intent
    // Never an empty list (the engine would show every method on the account): with none, the element goes away.
    let needsElement = !intent.paymentMethodTypes.isEmpty
    if newSettings || needsElement != (element != nil) {
      loaded = false
      Task { await build() }
    } else if needsElement {
      Task { await update() }
    }
  }

  /// The sheet is gone: let the engine go.
  func teardown() {
    pendingSecret?.resume(throwing: EngineError(message: ""))
    pendingSecret = nil
    element?.presentingViewController = nil
    element = nil
  }

  // MARK: Commands

  func confirm() {
    guard let element, !updating else {
      session?.engineNotReady()
      return
    }
    element.presentingViewController = presenter
    element.confirm { [weak self] result in
      let (status, message) = confirmStatus(result)
      Task { await self?.session?.onConfirmResult(status, message: message) }
    }
  }

  func clearSelection() {
    element?.clearPaymentOption()
  }

  func resolveConfirmation(clientSecret: String?, errorMessage: String?) {
    guard let continuation = pendingSecret else { return }
    pendingSecret = nil
    if let clientSecret, !clientSecret.isEmpty {
      continuation.resume(returning: clientSecret)
    } else {
      continuation.resume(throwing: EngineError(message: errorMessage ?? ""))
    }
  }

  // MARK: Element

  private func build() async {
    guard !building else { return }
    building = true
    defer { building = false }
    while let settings, let intent {
      let built = await build(settings, intent)
      // Shown as loaded only when what was built is still what the sheet wants (a tap meanwhile would reach an
      // engine about to be replaced).
      if settings == self.settings && intent == self.intent {
        loaded = built
        return
      }
    }
  }

  /// Builds the engine for these settings; false when it couldn't load (the session shows why).
  private func build(_ settings: EngineSettings, _ intent: EngineIntent) async -> Bool {
    // A new element: an update of the old one in flight no longer counts.
    updates += 1
    updating = false
    STPAPIClient.shared.publishableKey = settings.publishableKey
    STPAPIClient.shared.stripeAccount = settings.account
    do {
      // The element draws the other ways to pay; with none (cards only), it is left out.
      if !intent.paymentMethodTypes.isEmpty {
        let created = try await EmbeddedPaymentElement.create(
          intentConfiguration: intentConfiguration(intent),
          configuration: configuration(settings)
        )
        created.delegate = self
        created.presentingViewController = presenter
        element = created
        measure()
        embeddedPaymentElementDidUpdatePaymentOption(embeddedPaymentElement: created)
      } else {
        element = nil
        height = 0
      }
      return true
    } catch {
      engineLog.error("Element failed to load: \(String(describing: error), privacy: .public)")
      session?.setElementError(error.localizedDescription.isEmpty ? "load failed" : error.localizedDescription)
      return false
    }
  }

  private func update() async {
    guard let element, let intent else { return }
    updates += 1
    let mine = updates
    updating = true
    let result = await element.update(intentConfiguration: intentConfiguration(intent))
    if mine == updates { updating = false }
    if case .failed(let error) = result {
      engineLog.error("Element failed to update: \(String(describing: error), privacy: .public)")
      session?.setElementError(error.localizedDescription)
    }
  }

  private func intentConfiguration(_ intent: EngineIntent) -> PaymentSheet.IntentConfiguration {
    intent.configuration(types: intent.paymentMethodTypes) { [weak self] paymentMethodId in
      guard let self else { throw EngineError(message: "") }
      return try await self.clientSecret(forPaymentMethod: paymentMethodId)
    }
  }

  private func configuration(_ settings: EngineSettings) -> EmbeddedPaymentElement.Configuration {
    var configuration = EmbeddedPaymentElement.Configuration()
    configuration.merchantDisplayName = settings.merchantDisplayName
    if let returnURL = settings.returnURL, !returnURL.isEmpty {
      configuration.returnURL = returnURL
    }
    // Our own Pay button confirms; the card form only collects details.
    configuration.formSheetAction = .continue
    // Vezmo is white label: no processor wallet of its own in the sheet.
    configuration.link = PaymentSheet.LinkConfiguration(display: .never)
    configuration.embeddedViewDisplaysMandateText = true
    configuration.style = settings.dark ? .alwaysDark : .alwaysLight
    configuration.defaultBillingDetails.name = settings.billingName
    configuration.defaultBillingDetails.email = settings.billingEmail
    configuration.appearance = settings.palette.engineAppearance(radius: settings.radius, fontFamily: settings.fontFamily)
    return configuration
  }

  /// The element's height at the width the sheet gives it.
  fileprivate func measure(width: CGFloat? = nil) {
    if let width, width > 0 { self.width = width }
    guard let view = element?.view else { return }
    let fitted = view.systemLayoutSizeFitting(
      CGSize(width: self.width > 0 ? self.width : view.bounds.width, height: UIView.layoutFittingCompressedSize.height),
      withHorizontalFittingPriority: self.width > 0 ? .required : .fittingSizeLevel,
      verticalFittingPriority: .fittingSizeLevel
    ).height
    guard abs(fitted - height) > 0.5 else { return }
    // Not during the sheet's own layout pass.
    DispatchQueue.main.async { self.height = fitted }
  }

  // MARK: Payment method → Vezmo → client secret

  private func clientSecret(forPaymentMethod paymentMethodId: String) async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
      pendingSecret?.resume(throwing: EngineError(message: ""))
      pendingSecret = continuation
      Task { await session?.onPaymentMethod(paymentMethodId) }
    }
  }

  // MARK: EmbeddedPaymentElementDelegate

  func embeddedPaymentElementDidUpdateHeight(embeddedPaymentElement: EmbeddedPaymentElement) {
    measure()
  }

  func embeddedPaymentElementDidUpdatePaymentOption(embeddedPaymentElement: EmbeddedPaymentElement) {
    let option = embeddedPaymentElement.paymentOption
    session?.setOption(option.map { $0.label })
  }
}

/// The element's rows, in the sheet's group.
struct ElementView: UIViewRepresentable {
  @ObservedObject var host: MethodsHost

  func makeUIView(context: Context) -> ElementContainer {
    let container = ElementContainer()
    container.host = host
    container.show(host.element?.view)
    return container
  }

  func updateUIView(_ container: ElementContainer, context: Context) {
    container.show(host.element?.view)
  }
}

final class ElementContainer: UIView {
  weak var host: MethodsHost?
  private weak var shown: UIView?

  func show(_ view: UIView?) {
    guard view !== shown || view?.superview !== self else { return }
    shown?.removeFromSuperview()
    shown = view
    guard let view else { return }
    view.removeFromSuperview()
    view.translatesAutoresizingMaskIntoConstraints = false
    addSubview(view)
    NSLayoutConstraint.activate([
      view.topAnchor.constraint(equalTo: topAnchor),
      view.leadingAnchor.constraint(equalTo: leadingAnchor),
      view.trailingAnchor.constraint(equalTo: trailingAnchor),
    ])
    setNeedsLayout()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    host?.measure(width: bounds.width)
  }
}
