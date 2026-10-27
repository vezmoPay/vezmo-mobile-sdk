import PassKit
import UIKit
import XCTest
@testable import VezmoCheckout

private func view(
  mode: String = "setup",
  amount: Double = 0,
  trialDays: Int? = 7,
  manageUrl: String? = "https://acme.test/manage/x",
  instantAch: Bool? = nil
) -> SubscriptionView {
  SubscriptionView(
    subscriptionRef: "SUB-1",
    mode: mode,
    publishableKey: "pk_test_x",
    connectedAccountId: nil,
    amount: amount,
    recurringAmount: 9.99,
    currency: "USD",
    planName: "Club",
    interval: "MONTH",
    intervalCount: 1,
    trialDays: trialDays,
    merchant: .init(name: "Acme"),
    customer: .init(email: "ana@example.com", name: "Ana"),
    consentText: "I authorize Acme to charge my payment method $9.99 every month after my 7-day free trial, until I cancel.",
    localOffer: nil,
    livemode: false,
    nextChargeAt: "2026-10-23T12:00:00.000Z",
    manageUrl: manageUrl,
    instantAchEnabled: instantAch
  )
}

private let firstPayment = view(mode: "payment", amount: 9.99, trialDays: nil)
private let usd = Locale(identifier: "en_US")

final class SubscriptionFlowTests: XCTestCase {
  func testAFreeTrialChargesNothingTodayCardsAndWalletsOnlyASetupSavedForLater() throws {
    let config = configFromSubscription(view())
    let charge = chargeOf(config, payLocal: false)
    let methods = sheetMethods(config, charge)
    XCTAssertEqual(charge.amountMinor, 0)
    XCTAssertEqual(methods, SheetMethods(elementTypes: ["card"], applePay: true, googlePay: true, upi: false, pix: false))
    let intent = EngineIntent(charge: charge, methods: methods, plan: config.subscription)
    XCTAssertEqual(intent.amount, 0)
    XCTAssertTrue(intent.setup)
    XCTAssertTrue(intent.saveForLater)
    XCTAssertEqual(intent.paymentMethodTypes, [])
    let plan = try XCTUnwrap(config.subscription)
    XCTAssertEqual(planPriceText(plan, locale: usd), "$9.99 / month")
    var quarterly = plan
    quarterly.intervalCount = 3
    XCTAssertEqual(planPriceText(quarterly, locale: usd), "$9.99 every 3 months")
  }

  func testInstantACHWhenTheBusinessOffersItForThePlanSavedForTheRenewalsOrSetUpForATrial() {
    let trial = configFromSubscription(view(instantAch: true))
    let trialMethods = sheetMethods(trial, chargeOf(trial, payLocal: false))
    XCTAssertTrue(trialMethods.instantAch)
    let setup = EngineIntent(charge: chargeOf(trial, payLocal: false), methods: trialMethods, plan: trial.subscription)
    XCTAssertTrue(setup.instantAch)
    XCTAssertTrue(setup.setup)
    let paid = configFromSubscription(view(mode: "payment", amount: 9.99, trialDays: nil, instantAch: true))
    let intent = EngineIntent(charge: chargeOf(paid, payLocal: false), methods: sheetMethods(paid, chargeOf(paid, payLocal: false)), plan: paid.subscription)
    XCTAssertTrue(intent.instantAch)
    XCTAssertTrue(intent.saveForLater)
    XCTAssertFalse(intent.setup)
    XCTAssertFalse(sheetMethods(configFromSubscription(view(instantAch: false)), Charge(amountMinor: 0, currency: "USD", localOffer: nil)).instantAch)
  }

  func testAFirstPaymentKeepsTheCardForRenewalsAOneTimePaymentDoesNot() {
    let config = configFromSubscription(firstPayment)
    let charge = chargeOf(config, payLocal: false)
    let intent = EngineIntent(charge: charge, methods: sheetMethods(config, charge), plan: config.subscription)
    XCTAssertEqual(intent.amount, 999)
    XCTAssertFalse(intent.setup)
    XCTAssertTrue(intent.saveForLater)
    let oneTime = EngineIntent(charge: charge, methods: sheetMethods(config, charge), plan: nil)
    XCTAssertFalse(oneTime.setup)
    XCTAssertFalse(oneTime.saveForLater)
  }

  func testApplePayGetsThePlanAsARecurringPaymentWithTheTrialAndThePageToManageIt() throws {
    let config = configFromSubscription(view())
    let charge = chargeOf(config, payLocal: false)
    let recurring = try XCTUnwrap(ApplePayRecurring(config: config, charge: charge, merchant: "Acme"))
    XCTAssertEqual(recurring.label, "Club")
    XCTAssertEqual(recurring.amount, "9.99")
    XCTAssertEqual(recurring.intervalUnit, "month")
    XCTAssertEqual(recurring.intervalCount, 1)
    XCTAssertEqual(recurring.startDate, isoDate("2026-10-23T12:00:00.000Z"))
    XCTAssertEqual(recurring.trialEndDate, isoDate("2026-10-23T12:00:00.000Z"))
    XCTAssertEqual(recurring.managementURL, URL(string: "https://acme.test/manage/x"))
    XCTAssertEqual(recurring.dueToday, "0.00")
    // Apple requires a page to manage it; a one-time payment has no plan.
    XCTAssertNil(ApplePayRecurring(config: configFromSubscription(view(manageUrl: nil)), charge: charge, merchant: "Acme"))
    XCTAssertNil(ApplePayRecurring(config: makeConfig(), charge: charge, merchant: "Acme"))

    guard #available(iOS 16.0, *) else { return }
    let request = recurring.add(to: PKPaymentRequest())
    let plan = try XCTUnwrap(request.recurringPaymentRequest)
    XCTAssertEqual(plan.regularBilling.amount, NSDecimalNumber(string: "9.99"))
    XCTAssertEqual(plan.regularBilling.intervalUnit, .month)
    XCTAssertNotNil(plan.trialBilling)
    XCTAssertEqual(plan.managementURL, URL(string: "https://acme.test/manage/x"))
    // Apple's last line is the total due today, under the business's name.
    XCTAssertEqual(request.paymentSummaryItems.last?.label, "Acme")
    XCTAssertEqual(request.paymentSummaryItems.last?.amount, NSDecimalNumber(string: "0.00"))
  }

  func testReadsAFreeTrialsSetupIntentForConfirm() {
    XCTAssertEqual(intentIdOf("seti_1AbC_secret_xyz"), "seti_1AbC")
    XCTAssertEqual(intentIdOf("pi_1AbC_secret_xyz"), "pi_1AbC")
  }

  func testDatesInTheBuyersFormat() {
    XCTAssertEqual(dateText("2026-10-23T12:00:00.000Z", locale: usd), "Oct 23, 2026")
    XCTAssertEqual(dateText("2026-10-23T12:00:00Z", locale: usd), "Oct 23, 2026")
    XCTAssertEqual(dateText(nil), "")
    XCTAssertEqual(periodText("WEEK", 2), "2 weeks")
    XCTAssertEqual(periodText("YEAR", 1), "year")
  }
}

@MainActor
final class SubscriptionSessionTests: XCTestCase {
  private var api: FakeAPI!
  private var cardFlow: FakeCardFlow!
  private var session: CheckoutSession!

  private func start(_ v: SubscriptionView = view()) async {
    api = FakeAPI(config: makeConfig())
    api.view = v
    cardFlow = FakeCardFlow()
    session = CheckoutSession(api: api, token: "subtok", returnURL: "acme://vezmo", kind: .subscription)
    session.attachCardFlow(cardFlow)
    await session.load()
  }

  /// The buyer types a card in the card form.
  private func chooseCard() {
    session.changeCard()
    session.setCard(CardChoice(label: "•••• 4242", image: nil))
  }

  func testStartsAFreeTrialOurServerConfirmsItTheResultNamesTheSubscription() async {
    await start()
    XCTAssertEqual(session.snapshot.charge?.amountMinor, 0)
    chooseCard()
    api.subscriptionPayAnswer = {
      SubscriptionPayResponse(
        state: "succeeded",
        subscriptionRef: "SUB-1",
        subscriptionStatus: "trialing",
        paymentId: nil,
        transactionId: nil,
        clientSecret: "seti_1_secret_a",
        method: PaidMethod(type: "card", brand: "visa", last4: "4242", wallet: nil)
      )
    }
    session.pay()
    XCTAssertEqual(cardFlow.confirms, 1)
    await session.onPaymentMethod("pm_1")
    XCTAssertEqual(api.subscriptionPayCalls, [.init(token: "subtok", paymentMethodId: "pm_1", localOffer: nil, returnURL: "acme://vezmo")])
    XCTAssertEqual(cardFlow.resolutions, [["seti_1_secret_a", nil]])
    await session.onConfirmResult(.completed, message: "")
    XCTAssertEqual(
      session.snapshot.phase,
      .done(.succeeded(paymentId: nil, transactionId: nil, subscription: SubscriptionResult(ref: "SUB-1", status: .trialing)))
    )
    XCTAssertTrue(api.payCalls.isEmpty)
  }

  func test3DSecureOnTheFirstPaymentFinishedOnTheDeviceThenRecordedWithConfirm() async {
    await start(firstPayment)
    XCTAssertEqual(session.snapshot.charge?.amountMinor, 999)
    chooseCard()
    api.subscriptionPayAnswer = {
      SubscriptionPayResponse(state: "requires_action", subscriptionRef: "SUB-1", clientSecret: "pi_9_secret_b")
    }
    session.pay()
    await session.onPaymentMethod("pm_1")
    XCTAssertEqual(cardFlow.resolutions, [["pi_9_secret_b", nil]])
    await session.onConfirmResult(.completed, message: "")
    XCTAssertEqual(api.subscriptionConfirmCalls, [["subtok", "pi_9"]])
    XCTAssertEqual(
      session.snapshot.phase,
      .done(.succeeded(paymentId: "pay_9", transactionId: "VT9", subscription: SubscriptionResult(ref: "SUB-1", status: .active)))
    )
  }

  func testDeclinedAfter3DSecureOnTheDeviceTheReasonIsVezmosFromItsConfirmStep() async {
    await start(firstPayment)
    chooseCard()
    api.subscriptionPayAnswer = {
      SubscriptionPayResponse(state: "requires_action", subscriptionRef: "SUB-1", clientSecret: "pi_9_secret_b")
    }
    api.subscriptionConfirmError = VezmoAPIError(.declined, "The payment was not completed.", httpStatus: 400)
    session.pay()
    await session.onPaymentMethod("pm_1")
    await session.onConfirmResult(.failed, message: "Your card was declined.")
    XCTAssertEqual(api.subscriptionConfirmCalls, [["subtok", "pi_9"]])
    XCTAssertEqual(session.snapshot.phase, .ready(error: VezmoError(code: .declined, message: "The payment was not completed.")))
  }

  func testADeclineAtOurConfirmAfter3DSecureLeavesTheSheetReadyInOurWords() async {
    await start(firstPayment)
    chooseCard()
    api.subscriptionPayAnswer = {
      SubscriptionPayResponse(state: "requires_action", subscriptionRef: "SUB-1", clientSecret: "pi_9_secret_b")
    }
    api.subscriptionConfirmError = VezmoAPIError(.declined, "Payment declined by your bank (issuer).", httpStatus: 400)
    session.pay()
    await session.onPaymentMethod("pm_1")
    // Manual confirmation: the engine completes 3D Secure; our confirm step has the bank's answer.
    await session.onConfirmResult(.completed, message: "")
    XCTAssertEqual(api.subscriptionConfirmCalls, [["subtok", "pi_9"]])
    XCTAssertEqual(session.snapshot.phase, .ready(error: VezmoError(code: .declined, message: "Payment declined by your bank (issuer).")))
  }

  func testAUsedOrUnknownSubscriptionLinkClosesTheSheetAsExpired() async {
    api = FakeAPI(config: makeConfig())
    api.subscriptionError = VezmoAPIError(.expired, "This subscription link is no longer valid.", httpStatus: 404)
    session = CheckoutSession(api: api, token: "subtok", returnURL: nil, kind: .subscription)
    await session.load()
    guard case .closed(.failed(let error)) = session.snapshot.phase else { return XCTFail("closed") }
    XCTAssertEqual(error.code, .expired)
  }
}

final class SubscriptionAPITests: XCTestCase {
  private func makeAPI() -> VezmoAPI {
    VezmoAPI(base: URL(string: "https://api.test/v1")!, urlSession: StubProtocol.session())
  }

  func testSubscribesWithOurIntegrationAndTheAppsReturnLink() async throws {
    StubProtocol.answer = { _ in
      (200, ["data": ["state": "processing", "subscriptionRef": "SUB-1", "paymentId": "p", "clientSecret": NSNull()] as [String: Any]])
    }
    let res = try await makeAPI().subscriptionPay(token: "sub", paymentMethodId: "pm_1", localOffer: nil, returnURL: "acme://vezmo")
    XCTAssertEqual(res.state, "processing")
    let sent = try XCTUnwrap(StubProtocol.requests.first)
    XCTAssertEqual(sent.request.url?.absoluteString, "https://api.test/v1/subscription-checkout/sub/pay")
    XCTAssertEqual(sent.body as NSDictionary?, ["paymentMethodId": "pm_1", "integration": "ios", "returnUrl": "acme://vezmo"] as NSDictionary)
  }

  func testAUsedLinkReadsAsExpiredOneAlreadySetUpAsAlreadyPaid() async {
    StubProtocol.answer = { _ in (404, ["message": "Not found"]) }
    do {
      _ = try await makeAPI().subscription(token: "sub")
      XCTFail("expected expired")
    } catch let error as VezmoAPIError {
      XCTAssertEqual(error.code, .expired)
      XCTAssertEqual(error.message, "This subscription link is no longer valid.")
    } catch {
      XCTFail("\(error)")
    }
    StubProtocol.answer = { _ in (400, ["message": "This subscription is already set up."]) }
    do {
      _ = try await makeAPI().subscription(token: "sub")
      XCTFail("expected already paid")
    } catch let error as VezmoAPIError {
      XCTAssertEqual(error.code, .alreadyPaid)
    } catch {
      XCTFail("\(error)")
    }
  }

  func testReadsTheSubscriptionCheckout() async throws {
    StubProtocol.answer = { _ in
      (200, ["success": true, "data": [
        "subscriptionRef": "SUB-1", "status": "TRIALING", "mode": "setup", "publishableKey": "pk_test_x",
        "connectedAccountId": NSNull(), "currency": "USD", "recurringAmount": 9.99, "planName": "Club",
        "interval": "MONTH", "intervalCount": 1, "trialDays": 7, "merchant": ["name": "Acme", "logo": ""],
        "customer": ["email": "ana@example.com", "name": "Ana"], "amount": 0, "consentText": "I authorize…",
        "localOffer": NSNull(), "livemode": false, "nextChargeAt": "2026-10-23T09:33:36.824Z",
        "manageUrl": "https://acme.test/manage/x",
      ] as [String: Any]])
    }
    let v = try await makeAPI().subscription(token: "sub")
    let config = configFromSubscription(v)
    XCTAssertEqual(config.merchantName, "Acme")
    XCTAssertEqual(config.subscription?.trial, true)
    XCTAssertEqual(config.subscription?.manageUrl, "https://acme.test/manage/x")
    XCTAssertNil(config.connectedAccountId)
  }
}
