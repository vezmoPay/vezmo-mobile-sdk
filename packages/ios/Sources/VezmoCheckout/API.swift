import Foundation

/// A failed call, already in Vezmo's words (the API never names its processor to a buyer).
struct VezmoAPIError: Error, Equatable {
  let code: VezmoError.Code
  let message: String
  let httpStatus: Int?
  /// The API's own error code when it sent one (e.g. `local_price_changed`).
  let reason: String?

  init(_ code: VezmoError.Code, _ message: String, httpStatus: Int? = nil, reason: String? = nil) {
    self.code = code
    self.message = message
    self.httpStatus = httpStatus
    self.reason = reason
  }

  var vezmoError: VezmoError { VezmoError(code: code, message: message) }
}

/// The buyer-side calls of an API checkout session (a protocol so the session's tests can answer them).
protocol CheckoutAPI {
  func checkout(token: String) async throws -> CheckoutConfig
  func pay(token: String, paymentMethodId: String, localOffer: String?, returnURL: String?) async throws -> PayResponse
  func intent(token: String, localOffer: String?) async throws -> SessionIntent
  func startQr(_ method: QrMethod, intent: SessionIntent, returnURL: String, billing: QrBilling) async throws -> QrPayment
  func checkoutPageURL(token: String) -> String
  func confirm(token: String, paymentIntentId: String) async throws
  func status(token: String) async throws -> SessionStatus
  func subscription(token: String) async throws -> SubscriptionView
  func subscriptionPay(token: String, paymentMethodId: String, localOffer: String?, returnURL: String?) async throws -> SubscriptionPayResponse
  func subscriptionConfirm(token: String, intentId: String) async throws -> SubscriptionConfirm
}

/// Everything is scoped by the session's client token; no merchant key ever reaches the app.
struct VezmoAPI: CheckoutAPI {
  static let defaultBase = URL(string: "https://api.vezmo.com/api/v1")!

  let base: String
  let urlSession: URLSession
  /// Sent as `Vezmo-SDK` so a payment records which SDK took it: this one, or a Vezmo wrapper around it.
  let sdk: String

  init(base: URL = VezmoAPI.defaultBase, urlSession: URLSession = .shared, sdk: String? = nil) {
    var s = base.absoluteString
    while s.hasSuffix("/") { s.removeLast() }
    self.base = s
    self.urlSession = urlSession
    self.sdk = sdk ?? "ios/\(VezmoCheckout.version)"
  }

  func checkout(token: String) async throws -> CheckoutConfig {
    try await call("POST", "/secure-payments/\(encode(token))/checkout?redirectMethods=1")
  }

  func pay(token: String, paymentMethodId: String, localOffer: String?, returnURL: String?) async throws -> PayResponse {
    var body: [String: Any] = ["paymentMethodId": paymentMethodId, "integration": "ios"]
    if let localOffer, !localOffer.isEmpty { body["localOffer"] = localOffer }
    if let returnURL, !returnURL.isEmpty { body["returnUrl"] = returnURL }
    return try await call("POST", "/secure-payments/\(encode(token))/pay", body: body)
  }

  func intent(token: String, localOffer: String?) async throws -> SessionIntent {
    var body: [String: Any] = [:]
    if let localOffer, !localOffer.isEmpty { body["localOffer"] = localOffer }
    return try await call("POST", "/secure-payments/\(encode(token))/intent?redirectMethods=1", body: body)
  }

  /// Start UPI or Pix on the intent: the UPI app link, or the Pix code to paste in a bank app.
  func startQr(_ method: QrMethod, intent: SessionIntent, returnURL: String, billing: QrBilling) async throws -> QrPayment {
    var body: [String: Any] = [
      "clientSecret": intent.clientSecret,
      "livemode": intent.livemode,
      "returnUrl": returnURL,
      "billing": billing.json,
    ]
    if let account = intent.connectedAccountId, !account.isEmpty { body["connectedAccountId"] = account }
    return try await call("POST", "/checkout/\(method.rawValue)", body: body)
  }

  /// The session's own checkout page (https): where UPI and Pix send a buyer who comes back by browser.
  func checkoutPageURL(token: String) -> String {
    "\(base)/secure-payments/\(encode(token))"
  }

  /// Records a payment that finished on the device (after 3D Secure or a redirect).
  func confirm(token: String, paymentIntentId: String) async throws {
    let _: Ignored = try await call(
      "POST",
      "/secure-payments/\(encode(token))/confirm",
      body: ["paymentIntentId": paymentIntentId, "integration": "ios"]
    )
  }

  func status(token: String) async throws -> SessionStatus {
    try await call("GET", "/secure-payments/\(encode(token))/status")
  }

  // MARK: Subscriptions (a subscription checkout's token)

  /// The subscription checkout: plan, first charge or free trial, keys. A used or unknown link reads as expired.
  func subscription(token: String) async throws -> SubscriptionView {
    do {
      return try await call("GET", "/subscription-checkout/\(encode(token))")
    } catch let error as VezmoAPIError where error.httpStatus == 404 {
      throw VezmoAPIError(.expired, "This subscription link is no longer valid.", httpStatus: 404)
    } catch let error as VezmoAPIError
      where error.httpStatus == 400 && error.message.range(of: "already set up", options: .caseInsensitive) != nil {
      throw VezmoAPIError(.alreadyPaid, "This subscription is already set up.", httpStatus: 400)
    }
  }

  /// Subscribe: our server confirms the first payment, or a free trial's card, with the payment method (`pm_…`).
  func subscriptionPay(token: String, paymentMethodId: String, localOffer: String?, returnURL: String?) async throws -> SubscriptionPayResponse {
    var body: [String: Any] = ["paymentMethodId": paymentMethodId, "integration": "ios"]
    if let localOffer, !localOffer.isEmpty { body["localOffer"] = localOffer }
    if let returnURL, !returnURL.isEmpty { body["returnUrl"] = returnURL }
    return try await call("POST", "/subscription-checkout/\(encode(token))/pay", body: body)
  }

  /// Records a subscription start finished on the device (after 3D Secure): `pi_…`, or a free trial's `seti_…`.
  func subscriptionConfirm(token: String, intentId: String) async throws -> SubscriptionConfirm {
    try await call("POST", "/subscription-checkout/\(encode(token))/confirm", body: ["paymentIntentId": intentId])
  }

  // MARK: Transport

  private struct Ignored: Decodable {}

  private func call<T: Decodable>(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> T {
    guard let url = URL(string: base + path) else { throw VezmoAPIError(.config, "The Vezmo API address is not valid.") }
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue(sdk, forHTTPHeaderField: "Vezmo-SDK")
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try? JSONSerialization.data(withJSONObject: body)
    }

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await urlSession.data(for: request)
    } catch {
      throw VezmoAPIError(.network, "Check your connection and try again.")
    }
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]

    if (200..<300).contains(status), json?["success"] as? Bool != false {
      // `{ success, data }`, or the object itself.
      let payload: [String: Any] = (json?["data"] as? [String: Any]) ?? json ?? [:]
      if let raw = try? JSONSerialization.data(withJSONObject: payload),
         let decoded = try? JSONDecoder().decode(T.self, from: raw) {
        return decoded
      }
      throw VezmoAPIError(.unknown, Self.fallbackMessage, httpStatus: status)
    }

    let firstError = (json?["errors"] as? [Any])?.first as? [String: Any]
    let message = (json?["message"] as? String).flatMap { $0.isEmpty ? nil : $0 }
      ?? (firstError?["message"] as? String).flatMap { $0.isEmpty ? nil : $0 }
      ?? Self.fallbackMessage
    let reason = firstError?["code"] as? String
    throw VezmoAPIError(Self.code(status: status, reason: reason), message, httpStatus: status, reason: reason)
  }

  static let fallbackMessage = "Something went wrong. Please try again."

  static func code(status: Int, reason: String?) -> VezmoError.Code {
    // The app's return link isn't registered for this business, or this way to pay is off for it.
    if reason == "return_url_not_registered" { return .config }
    if reason == "method_unavailable" { return .notAvailable }
    switch status {
    case 410: return .expired
    case 409: return reason == "local_price_changed" ? .unknown : .alreadyPaid
    case 400, 402: return .declined
    case 401, 403, 404: return .config
    default: return .unknown
    }
  }

  /// As JavaScript's `encodeURIComponent`.
  private func encode(_ s: String) -> String {
    s.addingPercentEncoding(withAllowedCharacters: Self.unreserved) ?? s
  }

  private static let unreserved = CharacterSet(
    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()"
  )
}
