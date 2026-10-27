import Combine
import UIKit

/// What the engine's element (pay-later rows, Cash App…) can be asked to do.
@MainActor
protocol ElementPort: AnyObject {
  func confirm()
  func resolveConfirmation(clientSecret: String?, errorMessage: String?)
  func clearSelection()
}

/// What the card flow can be asked to do: the card form, the bank step (Instant ACH), paying with what they chose,
/// answering its confirmation.
@MainActor
protocol CardFlowPort: AnyObject {
  func presentCard()
  func confirmCard()
  func presentBank()
  func confirmBank()
  func resolveConfirmation(clientSecret: String?, errorMessage: String?)
}

/// The card from the native card form, for the sheet's own Card row (or the bank account linked for Instant ACH).
struct CardChoice: Equatable {
  /// "•••• 4242".
  var label: String
  /// The network's logo when the engine gives one.
  var image: UIImage?
}

enum ConfirmStatus {
  case completed, canceled, failed
}

enum SessionPhase: Equatable {
  case loading
  case ready(error: VezmoError?)
  case paying
  /// UPI or Pix started: the buyer finishes in their bank app; we watch the session.
  case waiting(method: QrMethod, qr: QrPayment)
  case done(CheckoutResult)
  /// The session can't be paid (expired, already paid, the business can't take payments).
  case closed(CheckoutResult)

  var isReady: Bool { if case .ready = self { return true } else { return false } }
  var isWaiting: Bool { if case .waiting = self { return true } else { return false } }
  var isClosed: Bool { if case .closed = self { return true } else { return false } }
}

/// The selected way to pay: the sheet's Card row, one of the element's rows (pay-later), our UPI or Pix row, or our
/// Instant ACH row.
enum PayMethod: Equatable {
  case card, element, upi, pix, instantAch

  var qr: QrMethod? { self == .upi ? .upi : self == .pix ? .pix : nil }
}

struct SessionSnapshot: Equatable {
  var phase: SessionPhase = .loading
  var config: CheckoutConfig?
  /// The buyer chose to pay in their own currency.
  var payLocal = false
  var charge: Charge?
  var methods: SheetMethods?
  /// The element has a method selected and can be paid.
  var canPay = false
  /// The selected method as the element names it ("Klarna").
  var option: String?
  /// The method the buyer paid with, kept for the receipt (the element clears its selection after paying).
  var paidWith: String?
  /// The same as Vezmo's server read it from the payment (the card's network for its logo).
  var paidMethod: PaidMethod?
  /// The engine couldn't load (shown in the sheet with Try again).
  var elementError: String?
  /// Bumped by Try again: rebuilds the engine.
  var elementAttempt = 0
  var method: PayMethod = .element
  /// The card typed in the card form, kept when the buyer looks at another method and comes back.
  var card: CardChoice?
  /// The bank account linked in the engine's bank step for Instant ACH, kept the same way.
  var bank: CardChoice?
}

private let priceChanged = "The price in your currency just changed. Check the new amount and pay again."
/// The engine isn't set up for this payment (it is loading, or loading again after a currency switch).
let engineLoading = "The card form is still loading. Try again in a moment."
let walletLoading = "Apple Pay is still loading. Try again in a moment."
let bankLoading = "Instant ACH is still loading. Try again in a moment."
/// The engine failed before Vezmo was asked to take the payment: never its own words.
let notCompleted = "Your payment couldn’t be completed. Please try again."
/// What the receipt calls an Instant ACH payment.
let instantAchName = "Instant ACH"

/// What the token is: an API checkout session's (a one-time payment) or a subscription checkout's (cards and Apple Pay;
/// a first payment or a free trial).
enum CheckoutKind {
  case payment, subscription
}

/// One checkout, from the session's client token (or a subscription checkout's token) to a result. The money
/// decisions are the server's: this only moves the buyer's payment method to Vezmo and the answer back to the
/// engine.
@MainActor
final class CheckoutSession: ObservableObject {
  @Published private(set) var snapshot = SessionSnapshot()

  private let api: CheckoutAPI
  private let token: String
  private let returnURL: String?
  private let kind: CheckoutKind
  private weak var element: ElementPort?
  private weak var cardFlow: CardFlowPort?
  /// Which engine view started the payment in progress (its confirmation is answered there).
  private var confirmViaCard = false
  private var lastPay: PayResponse?
  private var lastError: VezmoError?
  private var watching: Task<Void, Never>?
  private var qrIntentId: String?
  /// The card form was opened by the buyer: the card it returns becomes the selection.
  private var awaitingCard = false
  /// The bank step was opened by the buyer: the account it links becomes the selection.
  private var awaitingBank = false
  /// Vezmo's answer when /pay itself got none (a timeout, a dropped connection) but the payment went through.
  private var recovered: CheckoutResult?
  /// The buyer asked to close and Vezmo is being asked whether a UPI or Pix payment went through.
  private var closing = false

  init(api: CheckoutAPI, token: String, returnURL: String?, kind: CheckoutKind = .payment) {
    self.api = api
    self.token = token
    self.returnURL = returnURL
    self.kind = kind
  }

  /// The buyer's currency offer no longer holds: fetch the new one; the buyer sees the new amount before paying again.
  private func refreshOffer() async {
    if let config = try? await fetchConfig() { apply(config, payLocal: snapshot.payLocal) }
  }

  private func fetchConfig() async throws -> CheckoutConfig {
    if kind == .subscription {
      let view = try await api.subscription(token: token)
      return configFromSubscription(view)
    }
    return try await api.checkout(token: token)
  }

  private func set(_ change: (inout SessionSnapshot) -> Void) {
    var next = snapshot
    change(&next)
    if next != snapshot { snapshot = next }
  }

  func attachElement(_ element: ElementPort?) { self.element = element }
  func attachCardFlow(_ cardFlow: CardFlowPort?) { self.cardFlow = cardFlow }

  // MARK: Loading and currency

  func load() async {
    do {
      let config = try await fetchConfig()
      // The buyer's own currency is offered first when there is an offer (as on the web checkout).
      apply(config, payLocal: config.localOffer != nil)
      set { $0.phase = .ready(error: nil) }
    } catch {
      close(error)
    }
  }

  /// The buyer switched between their own currency and the price's.
  func choosePayLocal(_ payLocal: Bool) {
    guard let config = snapshot.config, snapshot.phase != .paying else { return }
    apply(config, payLocal: payLocal)
  }

  /// The element's selected method changed (nil: nothing selected). Choosing one leaves the card, UPI or Pix.
  func setOption(_ label: String?) {
    let leave = label != nil && snapshot.method != .element && snapshot.phase.isReady
    set {
      $0.canPay = label != nil
      $0.option = label.flatMap { $0.isEmpty ? nil : $0 }
      if leave { $0.method = .element }
    }
  }

  /// The buyer tapped the Card row: the card already typed, or the card form to type one.
  func chooseCard() {
    guard snapshot.phase.isReady else { return }
    if snapshot.card != nil {
      element?.clearSelection()
      set {
        $0.method = .card
        $0.phase = .ready(error: nil)
      }
    } else {
      changeCard()
    }
  }

  /// Change (or first type) the card.
  func changeCard() {
    guard snapshot.phase.isReady else { return }
    awaitingCard = true
    cardFlow?.presentCard()
  }

  /// The card form reported its card (or none). One the buyer just typed becomes the selection.
  func setCard(_ card: CardChoice?) {
    let chosen = card != nil && awaitingCard && snapshot.phase.isReady
    if card != nil { awaitingCard = false }
    if chosen { element?.clearSelection() }
    set {
      $0.card = card
      if chosen {
        $0.method = .card
        $0.phase = .ready(error: nil)
      }
    }
  }

  /// The buyer tapped the Instant ACH row: the bank account already linked, or the bank step to link one.
  func chooseBank() {
    guard snapshot.phase.isReady else { return }
    if snapshot.bank != nil {
      element?.clearSelection()
      set {
        $0.method = .instantAch
        $0.phase = .ready(error: nil)
      }
    } else {
      changeBank()
    }
  }

  /// Change (or first link) the bank account.
  func changeBank() {
    guard snapshot.phase.isReady else { return }
    awaitingBank = true
    cardFlow?.presentBank()
  }

  /// The bank step reported its account (or none). One the buyer just linked becomes the selection.
  func setBank(_ bank: CardChoice?) {
    let chosen = bank != nil && awaitingBank && snapshot.phase.isReady
    if bank != nil { awaitingBank = false }
    if chosen { element?.clearSelection() }
    set {
      $0.bank = bank
      if chosen {
        $0.method = .instantAch
        $0.phase = .ready(error: nil)
      } else if bank == nil && $0.method == .instantAch && $0.phase.isReady {
        // The bank step went away (the sheet's look changed): pick again.
        $0.method = .element
      }
    }
  }

  /// The Pay button can be pressed: a typed card on the Card row, a linked bank on the Instant ACH row, or a method
  /// chosen in the element.
  static func canPay(_ s: SessionSnapshot) -> Bool {
    switch s.method {
    case .card: return s.card != nil
    case .instantAch: return s.bank != nil
    case .element: return s.canPay
    case .upi, .pix: return false
    }
  }

  /// The engine refused (it isn't set up yet): back to the sheet, in our words.
  func engineNotReady(_ message: String = engineLoading) {
    guard snapshot.phase.isReady || snapshot.phase == .paying else { return }
    set { $0.phase = .ready(error: VezmoError(code: .unknown, message: message)) }
  }

  func setElementError(_ message: String?) {
    set {
      $0.elementError = message
      if message != nil { $0.canPay = false }
    }
  }

  func retryElement() {
    set {
      $0.elementError = nil
      $0.elementAttempt += 1
    }
  }

  private func apply(_ config: CheckoutConfig, payLocal: Bool) {
    let charge = chargeOf(config, payLocal: payLocal && config.localOffer != nil)
    let methods = sheetMethods(config, charge)
    set {
      // A method that this currency doesn't offer falls back to the element.
      if ($0.method == .upi && !methods.upi) || ($0.method == .pix && !methods.pix)
        || ($0.method == .instantAch && !methods.instantAch) { $0.method = .element }
      $0.config = config
      $0.payLocal = charge.localOffer != nil
      $0.charge = charge
      $0.methods = methods
    }
  }

  /// UPI or Pix (the sheet's own rows) or back to the element; one method is selected at a time.
  func chooseMethod(_ method: PayMethod) {
    guard snapshot.phase.isReady else { return }
    if method != .element { element?.clearSelection() }
    set {
      $0.method = method
      $0.phase = .ready(error: nil)
    }
  }

  // MARK: UPI and Pix

  /// Start UPI or Pix: the UPI app link or the Pix code comes back; then we watch the session until it is paid.
  func payWithQr(_ method: QrMethod, billing: QrBilling) async {
    guard snapshot.phase.isReady else { return }
    set {
      $0.phase = .paying
      $0.paidWith = method == .upi ? "UPI" : "Pix"
    }
    do {
      let intent = try await api.intent(token: token, localOffer: snapshot.charge?.localOffer)
      qrIntentId = intent.id
      let qr = try await api.startQr(method, intent: intent, returnURL: api.checkoutPageURL(token: token), billing: billing)
      set { $0.phase = .waiting(method: method, qr: qr) }
      watch()
    } catch {
      let apiError = error as? VezmoAPIError
      if apiError?.code == .expired || apiError?.code == .alreadyPaid { return close(error) }
      // UPI and Pix are always in the buyer's currency: an offer that ran out is fetched again, not resent.
      if apiError?.reason == "local_price_changed" {
        set { $0.phase = .ready(error: VezmoError(code: .unknown, message: priceChanged)) }
        return await refreshOffer()
      }
      set { $0.phase = .ready(error: apiError?.vezmoError ?? VezmoError(code: .unknown, message: declinedError.message)) }
    }
  }

  /// The buyer gave up waiting: back to the sheet (a payment made meanwhile still settles).
  func stopWaiting() {
    unwatch()
    if snapshot.phase.isWaiting { set { $0.phase = .ready(error: nil) } }
  }

  /// Check now (the buyer came back from their bank app).
  func checkNow() async {
    guard snapshot.phase.isWaiting else { return }
    guard let status = try? await api.status(token: token),
          let result = resultFromStatus(status),
          snapshot.phase.isWaiting else { return }
    // The watcher stops, but only once this check is over: it may be the watcher's own, and cancelling it now would
    // cancel the confirm call below with it.
    let watcher = watching
    watching = nil
    defer { watcher?.cancel() }
    if case .failed = result {
      set { $0.phase = .ready(error: VezmoError(code: .declined, message: "The payment didn’t go through. Try again.")) }
      return
    }
    // Recorded now rather than when the webhook arrives (as the web checkout does).
    if let qrIntentId { try? await api.confirm(token: token, paymentIntentId: qrIntentId) }
    set { $0.phase = .done(result) }
  }

  private func watch() {
    unwatch()
    let started = Date()
    watching = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        guard let self, !Task.isCancelled else { return }
        // A code lasts 10 minutes; stop watching a little after.
        if Date().timeIntervalSince(started) > 11 * 60 { return self.stopWaiting() }
        await self.checkNow()
      }
    }
  }

  private func unwatch() {
    watching?.cancel()
    watching = nil
  }

  /// The sheet is going away.
  func dispose() {
    unwatch()
  }

  // MARK: Paying

  func pay() {
    guard snapshot.phase.isReady, Self.canPay(snapshot) else { return }
    let method = snapshot.method
    // Cards and Instant ACH are the card flow's; the rest the element's.
    let viaCard = method == .card || method == .instantAch
    guard viaCard ? cardFlow != nil : element != nil else { return }
    lastPay = nil
    lastError = nil
    recovered = nil
    confirmViaCard = viaCard
    set {
      $0.phase = .paying
      $0.paidWith = method == .card ? $0.card?.label : method == .instantAch ? instantAchName : $0.option
    }
    switch method {
    case .card: cardFlow?.confirmCard()
    case .instantAch: cardFlow?.confirmBank()
    default: element?.confirm()
    }
  }

  /// An express wallet button was tapped (Apple Pay): its payment has started in the card flow.
  func walletStarted(_ wallet: String) {
    guard snapshot.phase.isReady else { return }
    lastPay = nil
    lastError = nil
    recovered = nil
    confirmViaCard = true
    set {
      $0.phase = .paying
      $0.paidWith = wallet == "apple_pay" ? "Apple Pay" : wallet == "google_pay" ? "Google Pay" : wallet
    }
  }

  /// The engine view that started the payment in progress answers its own confirmation.
  private func resolve(_ clientSecret: String?, _ errorMessage: String?) {
    if confirmViaCard {
      cardFlow?.resolveConfirmation(clientSecret: clientSecret, errorMessage: errorMessage)
    } else {
      element?.resolveConfirmation(clientSecret: clientSecret, errorMessage: errorMessage)
    }
  }

  /// The engine made a payment method (`pm_…`): Vezmo prices and confirms the payment with it.
  func onPaymentMethod(_ id: String) async {
    do {
      let localOffer = snapshot.charge?.localOffer
      let res: PayResponse
      if kind == .subscription {
        let answer = try await api.subscriptionPay(token: token, paymentMethodId: id, localOffer: localOffer, returnURL: returnURL)
        res = payFromSubscription(answer)
      } else {
        res = try await api.pay(token: token, paymentMethodId: id, localOffer: localOffer, returnURL: returnURL)
      }
      lastPay = res
      if let method = res.method { set { $0.paidMethod = method } }
      resolve(res.clientSecret, res.clientSecret == nil ? declinedError.message : nil)
    } catch {
      let apiError = error as? VezmoAPIError
      // No answer (a timeout, a dropped connection): the payment may have gone through all the same. Vezmo says.
      if apiError?.code == .network, let landed = await paidAfterNoAnswer() {
        recovered = landed
        resolve(nil, "")
        return
      }
      if apiError?.reason == "local_price_changed" {
        let message = VezmoError(code: .unknown, message: priceChanged)
        lastError = message
        resolve(nil, message.message)
        await refreshOffer()
        return
      }
      let message = apiError?.vezmoError ?? VezmoError(code: .unknown, message: declinedError.message)
      lastError = message
      resolve(nil, message.message)
      if apiError?.code == .expired || apiError?.code == .alreadyPaid { close(error) }
    }
  }

  /// The engine finished: completed (maybe after 3D Secure), canceled, or failed.
  func onConfirmResult(_ status: ConfirmStatus, message: String) async {
    if snapshot.phase.isClosed { return }
    switch status {
    case .canceled:
      set { $0.phase = .ready(error: nil) }
      return
    case .failed:
      // The engine gave up for want of Vezmo's answer, but the payment went through; or it failed after Vezmo had
      // already taken the payment. Either way the payment is the result, never the engine's words.
      if let paid = recovered ?? lastPay.flatMap(resultFromPay) {
        set { $0.phase = .done(paid) }
        return
      }
      var error = lastError
      if error == nil {
        switch await deviceFailure() {
        case .failed(let verdict)?: error = verdict
        case let paid?:
          set { $0.phase = .done(paid) }
          return
        case nil: break
        }
      }
      // Without Vezmo's answer, the engine's own words only for a payment Vezmo handed it: a failure before any (the
      // engine not set up, a wallet that couldn't start) is never shown in its words.
      let fallback = lastPay == nil
        ? VezmoError(code: .unknown, message: notCompleted)
        : VezmoError(code: .declined, message: message.isEmpty ? declinedError.message : message)
      let shown = error ?? fallback
      set { $0.phase = .ready(error: shown) }
      return
    case .completed:
      break
    }
    // A payment our server already recorded is done; one finished on the device (3D Secure, a redirect) is recorded
    // now, then read back.
    if let lastPay, let result = resultFromPay(lastPay) {
      set { $0.phase = .done(result) }
      return
    }
    let intentId = intentIdOf(lastPay?.clientSecret)
    do {
      if kind == .subscription {
        var confirmed: SubscriptionConfirm?
        if let intentId {
          confirmed = try await declineOnly { try await api.subscriptionConfirm(token: token, intentId: intentId) }
        }
        let result = startedSubscription(confirmed)
        set { $0.phase = .done(result) }
        return
      }
      if let intentId {
        // The webhook records it either way; the status below is the answer.
        _ = try await declineOnly { try await api.confirm(token: token, paymentIntentId: intentId) }
      }
    } catch {
      // Our server confirmed the card after 3D Secure and the bank said no: its reason in Vezmo's words, and the sheet
      // stays open for another card.
      set { $0.phase = .ready(error: (error as? VezmoAPIError)?.vezmoError ?? declinedError) }
      return
    }
    let result = await settledResult()
    set { $0.phase = .done(result) }
  }

  /// Our server's confirm after the buyer's step (3D Secure, a redirect). It confirms a card that waits for it after 3D
  /// Secure (manual confirmation), so the bank's decline comes back here: rethrown. Anything else (offline, a step
  /// still running) is nil: the webhook records the payment and the status says how it stands.
  private func declineOnly<T>(_ call: () async throws -> T) async throws -> T? {
    do {
      return try await call()
    } catch let error as VezmoAPIError where error.code == .declined && error.reason != "requires_action" {
      throw error
    } catch {
      return nil
    }
  }

  /// A payment Vezmo handed to the device (3D Secure, a redirect) that failed or was lost there: Vezmo's verdict.
  /// Paid after all; or why not, in Vezmo's words (the same on every phone, where the engine words a decline
  /// differently), its confirm step recording the decline at once. Nil when Vezmo has no answer.
  private func deviceFailure() async -> CheckoutResult? {
    guard lastPay?.state == "requires_action", let intentId = intentIdOf(lastPay?.clientSecret) else { return nil }
    do {
      if kind == .subscription {
        return resultFromSubscriptionConfirm(try await api.subscriptionConfirm(token: token, intentId: intentId))
      }
      // The session's state first: a step only lost (the payment still waiting on it) has no verdict to confirm.
      guard let status = try? await api.status(token: token) else { return nil }
      if let result = resultFromStatus(status) {
        if case .failed = result {} else { return result }
      }
      guard status.state == "failed" else { return nil }
      try await api.confirm(token: token, paymentIntentId: intentId)
      return nil
    } catch let error as VezmoAPIError where error.code == .declined {
      return .failed(error.vezmoError)
    } catch {
      return nil
    }
  }

  /// A subscription started on the device (after 3D Secure), as Vezmo's confirm recorded it.
  private func startedSubscription(_ confirmed: SubscriptionConfirm?) -> CheckoutResult {
    if let confirmed { return resultFromSubscriptionConfirm(confirmed) }
    // Recorded from the processor's notice instead; the merchant's webhook tells them.
    let ref = snapshot.config?.subscription?.ref ?? ""
    return .processing(paymentId: nil, subscription: SubscriptionResult(ref: ref, status: .incomplete))
  }

  /// /pay got no answer: whether the payment went through anyway, from the session's status (a subscription: whether
  /// it is set up). A few tries while the connection comes back; nil when Vezmo says it didn't, or can't be reached
  /// (the buyer sees the network error and can pay again: Vezmo never charges a session twice).
  private func paidAfterNoAnswer() async -> CheckoutResult? {
    for attempt in 0..<3 {
      if attempt > 0 { try? await Task.sleep(nanoseconds: 1_500_000_000) }
      if kind == .subscription {
        do {
          _ = try await api.subscription(token: token)
          return nil // still open: not started
        } catch let error as VezmoAPIError where error.code == .alreadyPaid {
          // Started; the webhook says how (trialing or active).
          let ref = snapshot.config?.subscription?.ref ?? ""
          return .processing(paymentId: nil, subscription: SubscriptionResult(ref: ref, status: .incomplete))
        } catch let error as VezmoAPIError where error.code == .network {
          continue
        } catch {
          return nil
        }
      }
      do {
        let status = try await api.status(token: token)
        guard let paid = resultFromStatus(status), paid.isPaid else { return nil }
        return paid
      } catch {
        continue
      }
    }
    return nil
  }

  /// The session's state, polled briefly while the server catches up with a payment just made.
  private func settledResult() async -> CheckoutResult {
    for _ in 0..<5 {
      if let status = try? await api.status(token: token), let result = resultFromStatus(status) { return result }
      try? await Task.sleep(nanoseconds: 1_500_000_000)
    }
    // Paid on the device and not yet visible: the webhook will tell the merchant's server.
    return .processing(paymentId: snapshot.config?.paymentId ?? "", subscription: nil)
  }

  // MARK: Closing

  /// The buyer closed the sheet. A UPI or Pix payment started here may still go through in their bank app, so Vezmo is
  /// asked first. Paid: the sheet shows the receipt and stays open (nil). Still waiting on the bank app: `processing`
  /// (the webhook says how it ends). Otherwise `canceled`.
  func closeRequested() async -> CheckoutResult? {
    guard qrIntentId != nil, snapshot.phase.isReady || snapshot.phase.isWaiting else { return .canceled }
    // A second tap while Vezmo is asked waits for the first.
    guard !closing else { return nil }
    closing = true
    defer { closing = false }
    let waiting = snapshot.phase.isWaiting
    unwatch()
    if let status = await statusSoon(), let result = resultFromStatus(status) {
      guard result.isPaid else { return .canceled }
      if let qrIntentId { try? await api.confirm(token: token, paymentIntentId: qrIntentId) }
      set { $0.phase = .done(result) }
      return nil
    }
    // No verdict yet: the buyer can still pay in their bank app (or Vezmo couldn't be reached).
    return waiting ? .processing(paymentId: snapshot.config?.paymentId, subscription: nil) : .canceled
  }

  /// The session's status, or nil when it takes more than a few seconds (the buyer is waiting for the sheet to close).
  private func statusSoon() async -> SessionStatus? {
    let api = self.api
    let token = self.token
    return await withTaskGroup(of: SessionStatus?.self) { group in
      group.addTask { try? await api.status(token: token) }
      group.addTask {
        try? await Task.sleep(nanoseconds: 5_000_000_000)
        return nil
      }
      let first = await group.next() ?? nil
      group.cancelAll()
      return first
    }
  }

  private func close(_ error: Error) {
    let err = (error as? VezmoAPIError)?.vezmoError ?? networkError
    set { $0.phase = .closed(.failed(err.code == .expired ? expiredError : err)) }
  }
}
