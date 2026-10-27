import XCTest
@testable import VezmoCheckout

/// Answers every request of a URLSession from the test, and keeps what was asked.
final class StubProtocol: URLProtocol {
  static var answer: (URLRequest) throws -> (Int, [String: Any]) = { _ in (200, [:]) }
  static var requests: [(request: URLRequest, body: [String: Any]?)] = []

  static func session() -> URLSession {
    requests = []
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubProtocol.self]
    return URLSession(configuration: configuration)
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func stopLoading() {}

  override func startLoading() {
    Self.requests.append((request, Self.body(of: request)))
    do {
      let (status, json) = try Self.answer(request)
      let data = try JSONSerialization.data(withJSONObject: json)
      let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  /// URLSession hands the body over as a stream.
  private static func body(of request: URLRequest) -> [String: Any]? {
    var data = request.httpBody ?? Data()
    if let stream = request.httpBodyStream {
      stream.open()
      defer { stream.close() }
      var buffer = [UInt8](repeating: 0, count: 4096)
      while stream.hasBytesAvailable {
        let n = stream.read(&buffer, maxLength: buffer.count)
        if n <= 0 { break }
        data.append(buffer, count: n)
      }
    }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
  }
}

final class APITests: XCTestCase {
  private func makeAPI() -> VezmoAPI {
    VezmoAPI(base: URL(string: "https://api.test/v1")!, urlSession: StubProtocol.session())
  }

  func testAVezmoWrapperNamesItselfInTheSDKHeader() async throws {
    StubProtocol.answer = { _ in (200, ["success": true, "data": ["state": "processing", "paymentId": "p", "clientSecret": NSNull()] as [String: Any]]) }
    let api = VezmoAPI(base: URL(string: "https://api.test/v1")!, urlSession: StubProtocol.session(), sdk: "flutter/0.1.0")
    _ = try await api.pay(token: "t", paymentMethodId: "c", localOffer: nil, returnURL: nil)
    let sent = try XCTUnwrap(StubProtocol.requests.first)
    XCTAssertEqual(sent.request.value(forHTTPHeaderField: "Vezmo-SDK"), "flutter/0.1.0")
  }

  func testPaysWithThePaymentMethodOurIntegrationAndSDKHeaderAndUnwrapsTheData() async throws {
    StubProtocol.answer = { _ in (200, ["success": true, "data": ["state": "processing", "paymentId": "p", "clientSecret": NSNull()] as [String: Any]]) }
    let api = makeAPI()
    let res = try await api.pay(token: "tok/1", paymentMethodId: "pm_1", localOffer: "o", returnURL: "acme://vezmo")
    XCTAssertEqual(res.state, "processing")
    XCTAssertNil(res.clientSecret)
    let sent = try XCTUnwrap(StubProtocol.requests.first)
    XCTAssertEqual(sent.request.url?.absoluteString, "https://api.test/v1/secure-payments/tok%2F1/pay")
    XCTAssertEqual(sent.request.httpMethod, "POST")
    let sdk = try XCTUnwrap(sent.request.value(forHTTPHeaderField: "Vezmo-SDK"))
    XCTAssertNotNil(sdk.range(of: #"^ios/\d+\.\d+\.\d+"#, options: .regularExpression), sdk)
    XCTAssertEqual(sent.body as NSDictionary?, [
      "paymentMethodId": "pm_1",
      "integration": "ios",
      "localOffer": "o",
      "returnUrl": "acme://vezmo",
    ] as NSDictionary)
  }

  func testTurnsFailuresIntoVezmosOwnCodesAndWords() async throws {
    StubProtocol.answer = { _ in (410, ["message": "Secure-payments token has expired"]) }
    await assertThrows(code: .expired) { try await self.makeAPI().status(token: "t") }

    StubProtocol.answer = { _ in (400, ["message": "Your bank declined this card."]) }
    let declined = await assertThrows(code: .declined) {
      try await self.makeAPI().pay(token: "t", paymentMethodId: "c", localOffer: nil, returnURL: nil)
    }
    XCTAssertEqual(declined?.message, "Your bank declined this card.")

    StubProtocol.answer = { _ in (409, ["message": "Price changed", "errors": [["code": "local_price_changed", "message": "x"]]] as [String: Any]) }
    let priceChanged = await assertThrows(code: .unknown) {
      try await self.makeAPI().pay(token: "t", paymentMethodId: "c", localOffer: nil, returnURL: nil)
    }
    XCTAssertEqual(priceChanged?.reason, "local_price_changed")

    StubProtocol.answer = { _ in (400, ["message": "Register acme://vezmo for this business.", "errors": [["code": "return_url_not_registered", "message": "Register acme://vezmo for this business."]]] as [String: Any]) }
    let unregistered = await assertThrows(code: .config) {
      try await self.makeAPI().pay(token: "t", paymentMethodId: "c", localOffer: nil, returnURL: "acme://vezmo")
    }
    XCTAssertEqual(unregistered?.message, "Register acme://vezmo for this business.")

    StubProtocol.answer = { _ in (400, ["errors": [["code": "method_unavailable", "message": "This way to pay is not available."]]] as [String: Any]) }
    await assertThrows(code: .notAvailable) {
      try await self.makeAPI().subscriptionPay(token: "t", paymentMethodId: "c", localOffer: nil, returnURL: nil)
    }

    StubProtocol.answer = { _ in (409, ["message": "This checkout was already paid."]) }
    await assertThrows(code: .alreadyPaid) { try await self.makeAPI().status(token: "t") }

    StubProtocol.answer = { _ in throw URLError(.notConnectedToInternet) }
    await assertThrows(code: .network) { try await self.makeAPI().status(token: "t") }
  }

  func testSendsTheReturnLinkOnlyWhenThereIsOne() async throws {
    StubProtocol.answer = { _ in (200, ["data": ["state": "succeeded", "paymentId": "p", "transactionId": "VT1"]]) }
    let api = makeAPI()
    _ = try await api.pay(token: "t", paymentMethodId: "c", localOffer: nil, returnURL: nil)
    XCTAssertEqual(StubProtocol.requests.first?.body as NSDictionary?, ["paymentMethodId": "c", "integration": "ios"] as NSDictionary)
  }

  func testStartsUPIOnTheSessionIntent() async throws {
    StubProtocol.answer = { _ in (200, ["data": ["status": "requires_action", "qr": NSNull(), "link": "upi://pay?pa=x", "code": NSNull()] as [String: Any]]) }
    let api = makeAPI()
    let qr = try await api.startQr(
      .upi,
      intent: SessionIntent(id: "pi_7", clientSecret: "pi_7_secret_q", connectedAccountId: nil, livemode: false),
      returnURL: api.checkoutPageURL(token: "tok"),
      billing: QrBilling(name: "Asha Rao", line1: "12 MG Road", country: "IN")
    )
    XCTAssertEqual(qr.link, "upi://pay?pa=x")
    let sent = try XCTUnwrap(StubProtocol.requests.first)
    XCTAssertEqual(sent.request.url?.absoluteString, "https://api.test/v1/checkout/upi")
    XCTAssertEqual(sent.body as NSDictionary?, [
      "clientSecret": "pi_7_secret_q",
      "livemode": false,
      "returnUrl": "https://api.test/v1/secure-payments/tok",
      "billing": ["name": "Asha Rao", "line1": "12 MG Road", "country": "IN"],
    ] as NSDictionary)
  }

  @discardableResult
  private func assertThrows(
    code: VezmoError.Code,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ call: () async throws -> Any
  ) async -> VezmoAPIError? {
    do {
      _ = try await call()
      XCTFail("expected \(code)", file: file, line: line)
      return nil
    } catch let error as VezmoAPIError {
      XCTAssertEqual(error.code, code, file: file, line: line)
      return error
    } catch {
      XCTFail("unexpected \(error)", file: file, line: line)
      return nil
    }
  }
}
