import UIKit
import XCTest
@testable import VezmoCheckout

/// The API, answered by the test.
final class FakeAPI: CheckoutAPI {
  struct PayCall: Equatable {
    var token: String
    var paymentMethodId: String
    var localOffer: String?
    var returnURL: String?
  }

  var config: CheckoutConfig
  var payAnswer: () throws -> PayResponse = { throw VezmoAPIError(.unknown, "no answer") }
  /// Answered first, one per call; then `statusAnswer`.
  var statusOnce: [SessionStatus] = []
  var statusAnswer = SessionStatus(state: "succeeded", paymentId: "pay_1", transactionId: "VT1")
  var statusCalls = 0
  var checkoutError: VezmoAPIError?
  var confirmError: VezmoAPIError?
  var intentError: VezmoAPIError?

  var checkoutCalls = 0
  var payCalls: [PayCall] = []
  var confirmCalls: [[String]] = []
  /// Whether each confirm call ran in a cancelled task (a real request would be cancelled with it).
  var confirmCancelled: [Bool] = []
  var intentCalls: [[String?]] = []
  var startQrCalls: [(method: QrMethod, intent: SessionIntent, returnURL: String, billing: QrBilling)] = []

  init(config: CheckoutConfig) {
    self.config = config
  }

  func checkout(token: String) async throws -> CheckoutConfig {
    checkoutCalls += 1
    if let checkoutError { throw checkoutError }
    return config
  }

  func pay(token: String, paymentMethodId: String, localOffer: String?, returnURL: String?) async throws -> PayResponse {
    payCalls.append(PayCall(token: token, paymentMethodId: paymentMethodId, localOffer: localOffer, returnURL: returnURL))
    return try payAnswer()
  }

  func intent(token: String, localOffer: String?) async throws -> SessionIntent {
    intentCalls.append([token, localOffer])
    if let intentError { throw intentError }
    return SessionIntent(id: "pi_7", clientSecret: "pi_7_secret_q", connectedAccountId: "acct_1", livemode: false)
  }

  func startQr(_ method: QrMethod, intent: SessionIntent, returnURL: String, billing: QrBilling) async throws -> QrPayment {
    startQrCalls.append((method, intent, returnURL, billing))
    return QrPayment(status: "requires_action", qr: nil, link: "upi://pay?pa=x", code: nil)
  }

  func checkoutPageURL(token: String) -> String { "https://api.test/v1/secure-payments/\(token)" }

  func confirm(token: String, paymentIntentId: String) async throws {
    confirmCalls.append([token, paymentIntentId])
    confirmCancelled.append(Task.isCancelled)
    if let confirmError { throw confirmError }
  }

  func status(token: String) async throws -> SessionStatus {
    statusCalls += 1
    return statusOnce.isEmpty ? statusAnswer : statusOnce.removeFirst()
  }

  // Subscriptions
  var view: SubscriptionView?
  var subscriptionError: VezmoAPIError?
  var subscriptionPayAnswer: () throws -> SubscriptionPayResponse = { throw VezmoAPIError(.unknown, "no answer") }
  var subscriptionConfirmAnswer = SubscriptionConfirm(status: "active", subscriptionRef: "SUB-1", paymentId: "pay_9", transactionId: "VT9")
  var subscriptionPayCalls: [PayCall] = []
  var subscriptionConfirmCalls: [[String]] = []
  var subscriptionConfirmError: VezmoAPIError?

  func subscription(token: String) async throws -> SubscriptionView {
    if let subscriptionError { throw subscriptionError }
    return view!
  }

  func subscriptionPay(token: String, paymentMethodId: String, localOffer: String?, returnURL: String?) async throws -> SubscriptionPayResponse {
    subscriptionPayCalls.append(PayCall(token: token, paymentMethodId: paymentMethodId, localOffer: localOffer, returnURL: returnURL))
    return try subscriptionPayAnswer()
  }

  func subscriptionConfirm(token: String, intentId: String) async throws -> SubscriptionConfirm {
    subscriptionConfirmCalls.append([token, intentId])
    if let subscriptionConfirmError { throw subscriptionConfirmError }
    return subscriptionConfirmAnswer
  }
}

@MainActor
final class FakeElement: ElementPort {
  var confirms = 0
  var clears = 0
  var resolutions: [[String?]] = []
  func confirm() { confirms += 1 }
  func clearSelection() { clears += 1 }
  func resolveConfirmation(clientSecret: String?, errorMessage: String?) { resolutions.append([clientSecret, errorMessage]) }
}

@MainActor
final class FakeCardFlow: CardFlowPort {
  var presents = 0
  var confirms = 0
  var bankPresents = 0
  var bankConfirms = 0
  var resolutions: [[String?]] = []
  func presentCard() { presents += 1 }
  func confirmCard() { confirms += 1 }
  func presentBank() { bankPresents += 1 }
  func confirmBank() { bankConfirms += 1 }
  func resolveConfirmation(clientSecret: String?, errorMessage: String?) { resolutions.append([clientSecret, errorMessage]) }
}

private let sessionConfig = makeConfig(enabled: ["card": true, "klarna": true], localOffer: nil)

private let rupees = LocalOffer(currency: "INR", amountMinor: 420000, rate: 85.7, country: "IN", methods: ["upi"], token: "offer")

@MainActor
final class CheckoutSessionTests: XCTestCase {
  private var api: FakeAPI!
  private var element: FakeElement!
  private var cardFlow: FakeCardFlow!
  private var session: CheckoutSession!

  private func start(_ config: CheckoutConfig = sessionConfig) async {
    api = FakeAPI(config: config)
    element = FakeElement()
    cardFlow = FakeCardFlow()
    session = CheckoutSession(api: api, token: "tok", returnURL: "acme://vezmo/return")
    session.attachElement(element)
    session.attachCardFlow(cardFlow)
    await session.load()
  }

  private var snap: SessionSnapshot { session.snapshot }

  func testLoadsTheSessionAndOffersCardPlusTheEnabledMethods() async {
    await start()
    XCTAssertEqual(snap.phase, .ready(error: nil))
    XCTAssertEqual(snap.charge, Charge(amountMinor: 4900, currency: "USD", localOffer: nil))
    XCTAssertEqual(snap.methods?.elementTypes, ["card", "klarna"])
  }

  func testASessionThatCantBePaidClosesWithTheReason() async {
    api = FakeAPI(config: sessionConfig)
    api.checkoutError = VezmoAPIError(.expired, "Secure-payments token has expired", httpStatus: 410)
    session = CheckoutSession(api: api, token: "tok", returnURL: nil)
    await session.load()
    XCTAssertEqual(snap.phase, .closed(.failed(expiredError)))
  }

  func testACardPaidByTheServerHandsTheElementTheSecretAndTheResultIsTheServers() async {
    await start()
    let method = PaidMethod(type: "card", brand: "visa", last4: "4242", wallet: nil)
    api.payAnswer = { PayResponse(state: "succeeded", paymentId: "pay_1", transactionId: "VT1", clientSecret: "pi_1_secret_a", method: method) }
    session.setOption("•••• 4242")
    session.pay()
    XCTAssertEqual(element.confirms, 1)
    await session.onPaymentMethod("pm_1")
    // The receipt's Visa mark and last four come from the server's reading of the payment.
    XCTAssertEqual(snap.paidMethod, method)
    XCTAssertEqual(api.payCalls, [.init(token: "tok", paymentMethodId: "pm_1", localOffer: nil, returnURL: "acme://vezmo/return")])
    XCTAssertEqual(element.resolutions, [["pi_1_secret_a", nil]])
    await session.onConfirmResult(.completed, message: "")
    XCTAssertEqual(snap.phase, .done(.succeeded(paymentId: "pay_1", transactionId: "VT1", subscription: nil)))
    XCTAssertTrue(api.confirmCalls.isEmpty)
  }

  func test3DSecureFinishedOnTheDeviceIsRecordedWithConfirmThenReadBack() async {
    await start()
    api.payAnswer = { PayResponse(state: "requires_action", paymentId: "pay_1", clientSecret: "pi_9_secret_b") }
    session.setOption("•••• 4242")
    session.pay()
    await session.onPaymentMethod("pm_1")
    await session.onConfirmResult(.completed, message: "")
    XCTAssertEqual(api.confirmCalls, [["tok", "pi_9"]])
    XCTAssertEqual(snap.phase, .done(.succeeded(paymentId: "pay_1", transactionId: "VT1", subscription: nil)))
  }

  func testADeclineGoesBackToTheElementInOurWordsAndLeavesTheSheetReadyToRetry() async {
    await start()
    api.payAnswer = { throw VezmoAPIError(.declined, "Your bank declined this card.", httpStatus: 400) }
    session.setOption("•••• 4242")
    session.pay()
    await session.onPaymentMethod("pm_1")
    XCTAssertEqual(element.resolutions, [[nil, "Your bank declined this card."]])
    await session.onConfirmResult(.failed, message: "processor text")
    XCTAssertEqual(snap.phase, .ready(error: VezmoError(code: .declined, message: "Your bank declined this card.")))
  }

  func testADeclineAfter3DSecureOnTheDeviceIsInTheServersWordsRecordedByItsConfirmStep() async {
    await start()
    api.payAnswer = { PayResponse(state: "requires_action", paymentId: "pay_1", clientSecret: "pi_9_secret_b") }
    api.statusAnswer = SessionStatus(state: "failed", paymentId: "pay_1", transactionId: nil)
    api.confirmError = VezmoAPIError(.declined, "Payment declined by your bank (issuer).", httpStatus: 400)
    session.setOption("Klarna")
    session.pay()
    await session.onPaymentMethod("pm_1")
    // The engine's own words differ by platform ("Your card was declined." here, another on Android).
    await session.onConfirmResult(.failed, message: "Your card was declined.")
    XCTAssertEqual(api.confirmCalls, [["tok", "pi_9"]])
    XCTAssertEqual(snap.phase, .ready(error: VezmoError(code: .declined, message: "Payment declined by your bank (issuer).")))

    // The confirm step can't say why (offline): the engine's words, as before.
    await start()
    api.payAnswer = { PayResponse(state: "requires_action", paymentId: "pay_1", clientSecret: "pi_9_secret_b") }
    api.statusAnswer = SessionStatus(state: "failed", paymentId: "pay_1", transactionId: nil)
    api.confirmError = VezmoAPIError(.network, "Check your connection and try again.")
    session.setOption("Klarna")
    session.pay()
    await session.onPaymentMethod("pm_1")
    await session.onConfirmResult(.failed, message: "engine text")
    XCTAssertEqual(snap.phase, .ready(error: VezmoError(code: .declined, message: "engine text")))
  }

  func testAFailureBeforeVezmoWasAskedNeverReadsInTheEnginesWordsNorTheEngineNotSetUp() async {
    await start()
    session.setOption("Klarna")
    session.pay()
    // The engine refused (it was being set up again after a currency switch): no /pay was made.
    await session.onConfirmResult(.failed, message: "confirmPayment was called with an update API call in progress.")
    XCTAssertEqual(snap.phase, .ready(error: VezmoError(code: .unknown, message: notCompleted)))
    XCTAssertTrue(api.confirmCalls.isEmpty)
    session.engineNotReady()
    XCTAssertEqual(snap.phase, .ready(error: VezmoError(code: .unknown, message: engineLoading)))
  }

  func testTheEngineLosingAStepItFinishedOnTheDeviceTheServersAnswerWins() async {
    await start()
    api.payAnswer = { PayResponse(state: "requires_action", paymentId: "pay_1", clientSecret: "pi_9_secret_b") }
    session.setOption("Cash App Pay")
    session.pay()
    await session.onPaymentMethod("pm_1")
    await session.onConfirmResult(.failed, message: "engine text")
    XCTAssertEqual(snap.phase, .done(.succeeded(paymentId: "pay_1", transactionId: "VT1", subscription: nil)))

    // Not paid after all (still open): the buyer can try again.
    await start()
    api.payAnswer = { PayResponse(state: "requires_action", paymentId: "pay_1", clientSecret: "pi_9_secret_b") }
    api.statusAnswer = SessionStatus(state: "open", paymentId: "pay_1", transactionId: nil)
    session.setOption("Cash App Pay")
    session.pay()
    await session.onPaymentMethod("pm_1")
    await session.onConfirmResult(.failed, message: "")
    XCTAssertEqual(snap.phase, .ready(error: declinedError))
    XCTAssertTrue(api.confirmCalls.isEmpty)
  }

  func testAChangedLocalPriceRefreshesTheOfferAndAsksTheBuyerToPayAgain() async {
    await start()
    api.payAnswer = { throw VezmoAPIError(.unknown, "Price changed", httpStatus: 409, reason: "local_price_changed") }
    session.setOption("•••• 4242")
    session.pay()
    await session.onPaymentMethod("pm_1")
    XCTAssertEqual(element.resolutions.count, 1)
    XCTAssertTrue((element.resolutions[0][1] ?? "").contains("price in your currency"))
    XCTAssertEqual(api.checkoutCalls, 2)
  }

  func testCancelingTheElementReturnsToTheSheetAnExpiredSessionClosesIt() async {
    await start()
    session.pay()
    await session.onConfirmResult(.canceled, message: "")
    XCTAssertEqual(snap.phase, .ready(error: nil))

    api.payAnswer = { throw VezmoAPIError(.expired, "Secure-payments token has expired", httpStatus: 410) }
    session.pay()
    await session.onPaymentMethod("pm_2")
    XCTAssertEqual(snap.phase, .closed(.failed(expiredError)))
  }

  func testTheBuyersOwnCurrencyTheChargeAndMethodsFollowTheChoice() async {
    await start(makeConfig(enabled: ["card": true, "klarna": true], localOffer: rupees))
    XCTAssertEqual(snap.charge, Charge(amountMinor: 420000, currency: "INR", localOffer: "offer"))
    XCTAssertEqual(snap.methods?.elementTypes, ["card"])
    session.choosePayLocal(false)
    XCTAssertEqual(snap.charge?.currency, "USD")
    XCTAssertEqual(snap.methods?.elementTypes, ["card", "klarna"])
  }

  func testOneMethodAtATime() async {
    await start()
    session.setOption("Visa •••• 4242")
    XCTAssertTrue(snap.canPay)
    XCTAssertEqual(snap.option, "Visa •••• 4242")
    XCTAssertEqual(snap.method, .element)
    // UPI unselects the element
    session.chooseMethod(.upi)
    XCTAssertGreaterThan(element.clears, 0)
    session.setOption(nil) // the element reports the cleared selection
    XCTAssertFalse(snap.canPay)
    XCTAssertNil(snap.option)
    XCTAssertEqual(snap.method, .upi)
    // picking an element method leaves UPI
    session.setOption("Klarna")
    XCTAssertTrue(snap.canPay)
    XCTAssertEqual(snap.method, .element)
    // The receipt keeps what was paid with, though the element clears its selection after paying.
    session.pay()
    session.setOption(nil)
    XCTAssertEqual(snap.paidWith, "Klarna")
  }

  func testTheCardRowOpensTheCardFormTheTypedCardBecomesTheSelectionAndPaysThroughTheCardForm() async {
    await start()
    session.chooseCard()
    XCTAssertEqual(cardFlow.presents, 1)
    XCTAssertFalse(CheckoutSession.canPay(snap))
    let card = CardChoice(label: "•••• 4242", image: nil)
    session.setCard(card)
    XCTAssertEqual(snap.method, .card)
    XCTAssertEqual(snap.card, card)
    XCTAssertGreaterThan(element.clears, 0)
    // Another method in the element leaves the card row but keeps the card for later.
    session.setOption("Klarna")
    XCTAssertEqual(snap.method, .element)
    XCTAssertEqual(snap.card, card)
    // A re-sent card (the amount changed) does not take the selection back.
    session.setCard(card)
    XCTAssertEqual(snap.method, .element)
    session.chooseCard()
    XCTAssertEqual(snap.method, .card)
    session.pay()
    XCTAssertEqual(cardFlow.confirms, 1)
    XCTAssertEqual(element.confirms, 0)
    XCTAssertEqual(snap.paidWith, "•••• 4242")
  }

  func testTheInstantACHRowOpensTheBankStepTheLinkedAccountBecomesTheSelectionAndPaysThroughIt() async {
    await start(makeConfig(enabled: ["card": true, "klarna": true, "instantAch": true], localOffer: rupees))
    // In the buyer's own currency there is no Instant ACH; in dollars there is.
    XCTAssertEqual(snap.methods?.instantAch, false)
    session.choosePayLocal(false)
    XCTAssertEqual(snap.methods?.instantAch, true)
    session.chooseBank()
    XCTAssertEqual(cardFlow.bankPresents, 1)
    XCTAssertFalse(CheckoutSession.canPay(snap))
    // The bank step closed without a bank: nothing chosen.
    session.setBank(nil)
    XCTAssertNotEqual(snap.method, .instantAch)
    let bank = CardChoice(label: "•••• 6789", image: nil)
    session.setBank(bank)
    XCTAssertEqual(snap.method, .instantAch)
    XCTAssertEqual(snap.bank, bank)
    XCTAssertGreaterThan(element.clears, 0)
    XCTAssertTrue(CheckoutSession.canPay(snap))
    api.payAnswer = {
      PayResponse(state: "succeeded", paymentId: "pay_1", transactionId: "VT1", clientSecret: "pi_1_secret_b",
                  method: PaidMethod(type: "instantAch", brand: nil, last4: "6789", wallet: nil))
    }
    session.pay()
    XCTAssertEqual(cardFlow.bankConfirms, 1)
    XCTAssertEqual(cardFlow.confirms, 0)
    XCTAssertEqual(element.confirms, 0)
    XCTAssertEqual(snap.paidWith, "Instant ACH")
    await session.onPaymentMethod("pm_b")
    // The card flow holds the bank step, so it answers the confirmation.
    XCTAssertEqual(cardFlow.resolutions, [["pi_1_secret_b", nil]])
    XCTAssertEqual(api.payCalls.map(\.paymentMethodId), ["pm_b"])
    await session.onConfirmResult(.completed, message: "")
    XCTAssertEqual(snap.phase, .done(.succeeded(paymentId: "pay_1", transactionId: "VT1", subscription: nil)))
    XCTAssertEqual(snap.paidMethod?.type, "instantAch")
  }

  func testInstantACHLeavesWhenTheBuyerPaysInTheirOwnCurrency() async {
    await start(makeConfig(enabled: ["card": true, "instantAch": true], localOffer: rupees))
    session.choosePayLocal(false)
    session.chooseBank()
    session.setBank(CardChoice(label: "•••• 6789", image: nil))
    XCTAssertEqual(snap.method, .instantAch)
    session.choosePayLocal(true)
    XCTAssertEqual(snap.method, .element)
    XCTAssertFalse(CheckoutSession.canPay(snap))
  }

  func testTheCardFlowAnswersItsOwnConfirmationTheElementItsOwn() async {
    await start()
    api.payAnswer = { PayResponse(state: "requires_action", paymentId: "pay_1", clientSecret: "pi_1_secret_w") }
    session.walletStarted("apple_pay")
    XCTAssertEqual(snap.phase, .paying)
    XCTAssertEqual(snap.paidWith, "Apple Pay")
    await session.onPaymentMethod("pm_w")
    XCTAssertEqual(cardFlow.resolutions, [["pi_1_secret_w", nil]])
    XCTAssertTrue(element.resolutions.isEmpty)
  }

  func testUPIStartsOnTheSessionIntentWaitsForTheBankAppAndRecordsItWhenPaid() async {
    await start(makeConfig(enabled: ["card": true, "upi": true], localOffer: rupees))
    XCTAssertEqual(snap.methods?.upi, true)
    session.chooseMethod(.upi)
    api.statusOnce = [SessionStatus(state: "requires_action", paymentId: "pay_1", transactionId: nil)]

    let billing = QrBilling(name: "Asha Rao", line1: "12 MG Road", country: "IN")
    await session.payWithQr(.upi, billing: billing)
    XCTAssertEqual(api.intentCalls, [["tok", "offer"]])
    XCTAssertEqual(api.startQrCalls.count, 1)
    XCTAssertEqual(api.startQrCalls.first?.method, .upi)
    XCTAssertEqual(api.startQrCalls.first?.intent.clientSecret, "pi_7_secret_q")
    XCTAssertEqual(api.startQrCalls.first?.returnURL, "https://api.test/v1/secure-payments/tok")
    XCTAssertEqual(api.startQrCalls.first?.billing, billing)
    guard case .waiting(.upi, let qr) = snap.phase else { return XCTFail("waiting for the UPI app") }
    XCTAssertEqual(qr.link, "upi://pay?pa=x")

    await session.checkNow() // still in the bank app
    XCTAssertTrue(snap.phase.isWaiting)
    await session.checkNow() // paid
    XCTAssertEqual(api.confirmCalls, [["tok", "pi_7"]])
    XCTAssertEqual(snap.phase, .done(.succeeded(paymentId: "pay_1", transactionId: "VT1", subscription: nil)))
    session.dispose()
  }

  func testUPIWithAnOfferThatRanOutFetchesTheNewOfferThenPaysWithItNeverTheStaleOne() async {
    await start(makeConfig(enabled: ["card": true, "upi": true], localOffer: rupees))
    session.chooseMethod(.upi)
    api.intentError = VezmoAPIError(.unknown, "Price changed", httpStatus: 409, reason: "local_price_changed")
    var fresh = rupees
    fresh.amountMinor = 421000
    fresh.token = "offer_new"
    api.config = makeConfig(enabled: ["card": true, "upi": true], localOffer: fresh)
    let billing = QrBilling(name: "Asha Rao", line1: "12 MG Road", country: "IN")
    await session.payWithQr(.upi, billing: billing)
    guard case .ready(let error?) = snap.phase else { return XCTFail("ready, with the reason") }
    XCTAssertTrue(error.message.contains("price in your currency"))
    XCTAssertEqual(snap.charge, Charge(amountMinor: 421000, currency: "INR", localOffer: "offer_new"))
    XCTAssertEqual(snap.method, .upi)

    api.intentError = nil
    await session.payWithQr(.upi, billing: billing)
    XCTAssertEqual(api.intentCalls, [["tok", "offer"], ["tok", "offer_new"]])
    XCTAssertTrue(snap.phase.isWaiting)
    session.dispose()
  }

  func testTheUPIWatcherRecordsThePaymentItFindsWithoutCancellingTheRecord() async throws {
    await start(makeConfig(enabled: ["card": true, "upi": true], localOffer: rupees))
    session.chooseMethod(.upi)
    await session.payWithQr(.upi, billing: QrBilling(name: "Asha Rao", line1: "12 MG Road", country: "IN"))
    XCTAssertTrue(snap.phase.isWaiting)
    // The watcher checks every 2 seconds by itself; the session reads as paid.
    for _ in 0..<60 {
      if case .done = snap.phase { break }
      try await Task.sleep(nanoseconds: 100_000_000)
    }
    XCTAssertEqual(snap.phase, .done(.succeeded(paymentId: "pay_1", transactionId: "VT1", subscription: nil)))
    XCTAssertEqual(api.confirmCalls, [["tok", "pi_7"]])
    XCTAssertEqual(api.confirmCancelled, [false])
    session.dispose()
  }

  // MARK: Closing while UPI or Pix may still be paid

  private func startUPI() async {
    await start(makeConfig(enabled: ["card": true, "upi": true], localOffer: rupees))
    session.choosePayLocal(true)
    session.chooseMethod(.upi)
    await session.payWithQr(.upi, billing: QrBilling(name: "Asha Rao", line1: "12 MG Road", country: "IN"))
  }

  func testClosingWhileUPIWaitsOnTheBankAppIsProcessingNeverCanceled() async {
    await startUPI()
    XCTAssertTrue(snap.phase.isWaiting)
    api.statusAnswer = SessionStatus(state: "requires_action", paymentId: "pay_1", transactionId: nil)
    let result = await session.closeRequested()
    // The buyer can still approve it in their UPI app: the merchant waits for the webhook.
    XCTAssertEqual(result, .processing(paymentId: "pay_1", subscription: nil))
    XCTAssertTrue(api.confirmCalls.isEmpty)
  }

  func testClosingAfterTheUPIPaymentWentThroughShowsTheReceiptInstead() async {
    await startUPI()
    api.statusAnswer = SessionStatus(state: "succeeded", paymentId: "pay_1", transactionId: "VT1")
    let result = await session.closeRequested()
    XCTAssertNil(result) // the sheet stays open, on the receipt
    XCTAssertEqual(snap.phase, .done(.succeeded(paymentId: "pay_1", transactionId: "VT1", subscription: nil)))
    XCTAssertEqual(api.confirmCalls, [["tok", "pi_7"]])
  }

  func testClosingAfterGivingUpOnUPIIsCanceledUnlessItWasPaidMeanwhile() async {
    await startUPI()
    session.stopWaiting()
    api.statusAnswer = SessionStatus(state: "requires_action", paymentId: "pay_1", transactionId: nil)
    let notPaid = await session.closeRequested()
    XCTAssertEqual(notPaid, .canceled)
    api.statusAnswer = SessionStatus(state: "processing", paymentId: "pay_1", transactionId: nil)
    let paid = await session.closeRequested()
    XCTAssertNil(paid)
    XCTAssertEqual(snap.phase, .done(.processing(paymentId: "pay_1", subscription: nil)))
  }

  func testClosingWithoutUPIOrPixIsCanceledWithoutAskingVezmo() async {
    await start()
    let result = await session.closeRequested()
    XCTAssertEqual(result, .canceled)
    XCTAssertEqual(api.statusCalls, 0)
  }

  // MARK: No answer from /pay

  func testAPayThatGotNoAnswerButWentThroughIsThePaymentNotAFailure() async {
    await start()
    api.payAnswer = { throw VezmoAPIError(.network, "Check your connection and try again.") }
    api.statusAnswer = SessionStatus(state: "succeeded", paymentId: "pay_1", transactionId: "VT1")
    session.setOption("Klarna")
    session.pay()
    await session.onPaymentMethod("pm_1")
    XCTAssertEqual(element.resolutions, [[nil, ""]])
    await session.onConfirmResult(.failed, message: "engine text")
    XCTAssertEqual(snap.phase, .done(.succeeded(paymentId: "pay_1", transactionId: "VT1", subscription: nil)))
  }

  func testAnEngineFailureAfterVezmoTookThePaymentIsThePaymentNeverTheEnginesWords() async {
    await start()
    api.payAnswer = { PayResponse(state: "succeeded", paymentId: "pay_1", transactionId: "VT1", clientSecret: "pi_1_secret_a") }
    session.setOption("Klarna")
    session.pay()
    await session.onPaymentMethod("pm_1")
    await session.onConfirmResult(.failed, message: "No launcher for a was found, did you call register?")
    XCTAssertEqual(snap.phase, .done(.succeeded(paymentId: "pay_1", transactionId: "VT1", subscription: nil)))
  }

  func testAPayThatGotNoAnswerAndDidntGoThroughIsTheNetworkError() async {
    await start()
    let network = VezmoAPIError(.network, "Check your connection and try again.")
    api.payAnswer = { throw network }
    api.statusAnswer = SessionStatus(state: "open", paymentId: "pay_1", transactionId: nil)
    session.setOption("Klarna")
    session.pay()
    await session.onPaymentMethod("pm_1")
    XCTAssertEqual(api.statusCalls, 1)
    await session.onConfirmResult(.failed, message: "engine text")
    XCTAssertEqual(snap.phase, .ready(error: network.vezmoError))
    // The next try starts clean.
    session.pay()
    api.payAnswer = { PayResponse(state: "succeeded", paymentId: "pay_1", transactionId: "VT2", clientSecret: "pi_1_secret_a") }
    await session.onPaymentMethod("pm_2")
    await session.onConfirmResult(.completed, message: "")
    XCTAssertEqual(snap.phase, .done(.succeeded(paymentId: "pay_1", transactionId: "VT2", subscription: nil)))
  }

  func testAPixCodeNeedsTheBuyersCPFOrCNPJ() {
    let form = QrFormModel()
    form.name = "Ana Silva"
    form.line1 = "Rua A, 1"
    XCTAssertNil(form.billing(.pix, country: "BR"))
    XCTAssertEqual(form.problem(.pix), "Enter your CPF (11 digits) or CNPJ (14 digits).")
    form.taxId = "123.456.789-09"
    XCTAssertEqual(form.billing(.pix, country: "BR")?.taxId, "123.456.789-09")
    XCTAssertNil(form.billing(.upi, country: "IN")?.taxId)
  }
}
