import StripePaymentSheet
import SwiftUI
import UIKit

/// The Vezmo payment sheet. Create one with your settings, `prepare` it with a session's client token from your
/// server, then `present` it. Neither throws.
///
///     let vezmo = VezmoCheckout(configuration: .init(returnURL: URL(string: "acme://vezmo")))
///     if let error = await vezmo.prepare(clientToken: token) { show(error.message); return }
///     switch await vezmo.present(from: viewController) { … }
///
/// A subscription is the same with `prepare(subscriptionToken:)`.
///
/// It lives on the main actor, like the screens it presents over: create and use it from your views and view
/// controllers (Swift 6 apps need no `Sendable` workarounds).
@MainActor
public final class VezmoCheckout {
  /// This SDK's version (sent to Vezmo with each call, for support).
  nonisolated public static let version = "0.2.0"

  public let configuration: Configuration
  private var prepared: (session: CheckoutSession, merchantDisplayName: String?)?
  /// A sheet is open (read by the SwiftUI modifier).
  private(set) var presenting = false

  public init(configuration: Configuration = Configuration()) {
    self.configuration = configuration
  }

  /// Loads a one-time payment: call it as soon as you have the client token. Returns an error (for example an expired
  /// session) or nil when the sheet is ready to present.
  /// - Parameters:
  ///   - clientToken: From your server: the API checkout session's `clientToken`.
  ///   - merchantDisplayName: Shown at the top of the sheet. Defaults to the business name on the session.
  public func prepare(clientToken: String, merchantDisplayName: String? = nil) async -> VezmoError? {
    await load(clientToken, kind: .payment, merchantDisplayName: merchantDisplayName, missing: "clientToken is required.")
  }

  /// Loads a subscription to start in the app: the first payment, or a free trial with the card saved for the
  /// renewals. Returns an error (for example a used subscription link) or nil when the sheet is ready to present.
  /// - Parameters:
  ///   - subscriptionToken: From your server: the subscription's `checkoutToken` (`POST /merchant/subscription`).
  ///   - merchantDisplayName: Shown at the top of the sheet. Defaults to the business name.
  public func prepare(subscriptionToken: String, merchantDisplayName: String? = nil) async -> VezmoError? {
    await load(subscriptionToken, kind: .subscription, merchantDisplayName: merchantDisplayName, missing: "subscriptionToken is required.")
  }

  private func load(_ rawToken: String, kind: CheckoutKind, merchantDisplayName: String?, missing: String) async -> VezmoError? {
    let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !token.isEmpty else { return VezmoError(code: .config, message: missing) }
    let api = VezmoAPI(base: configuration.apiBase, sdk: configuration.sdk)
    let session = CheckoutSession(api: api, token: token, returnURL: configuration.returnURL?.absoluteString, kind: kind)
    await session.load()
    if case .closed(.failed(let error)) = session.snapshot.phase {
      prepared = nil
      return error
    }
    prepared = (session, merchantDisplayName)
    return nil
  }

  /// Opens the sheet over `viewController` (or whatever it presents) and returns when the buyer is done.
  public func present(from viewController: UIViewController) async -> CheckoutResult {
    guard !presenting else {
      return .failed(VezmoError(code: .config, message: "The checkout is already open."))
    }
    guard let next = prepared else {
      return .failed(VezmoError(code: .config, message: "Call prepare(clientToken:) before present(from:)."))
    }
    var top = viewController
    while let presented = top.presentedViewController, !presented.isBeingDismissed { top = presented }
    // UIKit ignores a present from a screen that isn't showing: the sheet would never open, nor this return.
    guard top.viewIfLoaded?.window != nil else {
      return .failed(VezmoError(code: .config, message: "Present the checkout from a view controller on screen."))
    }
    // Each prepared session is presented once; a prepare meanwhile is for the next present.
    prepared = nil
    presenting = true
    let result = await withCheckedContinuation { (done: CheckedContinuation<CheckoutResult, Never>) in
      let sheet = SheetController(
        session: next.session,
        merchantDisplayName: next.merchantDisplayName,
        configuration: configuration,
        dark: top.traitCollection.userInterfaceStyle == .dark
      ) { result in done.resume(returning: result) }
      top.present(sheet, animated: false)
    }
    presenting = false
    return result
  }

  /// Hands the app a link back from 3D Secure, a bank app or a pay-later provider. Call it from `onOpenURL` or your
  /// scene delegate's `scene(_:openURLContexts:)` (no `await` needed); returns true when the link was Vezmo's.
  @discardableResult
  nonisolated public static func handleURL(_ url: URL) -> Bool {
    StripeAPI.handleURLCallback(with: url)
  }
}

extension VezmoCheckout {
  public struct Configuration: Sendable {
    /// The link that opens your app after a bank app, a pay-later provider or 3D Secure, registered under
    /// Developers → Mobile apps (for example `acme://vezmo`). Required for redirect-based methods.
    public var returnURL: URL?
    /// Apple Pay with your Apple Merchant ID. Without it the sheet shows no Apple Pay.
    public var applePay: ApplePay?
    /// Light, dark, or follow the phone (default).
    public var style: Style
    public var appearance: Appearance?
    /// Vezmo's API. Leave as is; for Vezmo's own testing only.
    public var apiBase: URL
    /// For Vezmo's own wrappers (the Flutter plugin), not for apps: the wrapper's `<name>/<version>` (for example
    /// `flutter/0.1.0`), sent in place of `ios/<version>` so a payment records which SDK took it.
    public var sdk: String?

    public init(
      returnURL: URL? = nil,
      applePay: ApplePay? = nil,
      style: Style = .automatic,
      appearance: Appearance? = nil,
      apiBase: URL = URL(string: "https://api.vezmo.com/api/v1")!
    ) {
      self.returnURL = returnURL
      self.applePay = applePay
      self.style = style
      self.appearance = appearance
      self.apiBase = apiBase
    }
  }

  public struct ApplePay: Equatable, Sendable {
    /// Your Apple Merchant ID (Apple Developer → Identifiers → Merchant IDs).
    public var merchantId: String
    /// The country of the account that processes the payment, as two letters. Leave it nil: Vezmo's session says
    /// (your business's own country on Connect, Vezmo's on merchant of record).
    public var merchantCountryCode: String?

    public init(merchantId: String, merchantCountryCode: String? = nil) {
      self.merchantId = merchantId
      self.merchantCountryCode = merchantCountryCode
    }
  }

  public enum Style: Sendable {
    case automatic, light, dark
  }

  /// What you may change in the sheet's look. (Sendable: `UIColor` is immutable.)
  public struct Appearance: @unchecked Sendable {
    /// The sheet's colour tokens.
    public enum ColorKey: String, CaseIterable, Sendable {
      case page, surface, surface2, raised, fill, disabled, onDisabled, field, fieldLine, line
      case ink, ink2, ink3, accent, onAccent, accentSoft, good, bad, badSoft, warn, warnInk, warnSoft, logoTile, scrim
    }

    /// Colours by token. A dynamic `UIColor` (or one from an asset catalog) can differ between light and dark.
    /// Setting your own `.accent` replaces the Vezmo gradient on the Pay button.
    public var colors: [ColorKey: UIColor]
    /// Corner radius of fields and payment method rows, in points. Default 14.
    public var cornerRadius: CGFloat?
    /// A font already in your app: its PostScript or family name.
    public var fontFamily: String?

    public init(colors: [ColorKey: UIColor] = [:], cornerRadius: CGFloat? = nil, fontFamily: String? = nil) {
      self.colors = colors
      self.cornerRadius = cornerRadius
      self.fontFamily = fontFamily
    }
  }
}

// MARK: - SwiftUI

extension View {
  /// Presents the prepared Vezmo sheet while `isPresented` is true; `onCompletion` gets the result (on the main actor)
  /// and `isPresented` goes back to false.
  @MainActor
  public func vezmoCheckout(
    _ checkout: VezmoCheckout,
    isPresented: Binding<Bool>,
    onCompletion: @escaping @MainActor (CheckoutResult) -> Void
  ) -> some View {
    modifier(VezmoCheckoutPresenter(checkout: checkout, isPresented: isPresented, onCompletion: onCompletion))
  }
}

@MainActor
private struct VezmoCheckoutPresenter: ViewModifier {
  let checkout: VezmoCheckout
  @Binding var isPresented: Bool
  let onCompletion: @MainActor (CheckoutResult) -> Void

  func body(content: Content) -> some View {
    content
      .onAppear { if isPresented { open() } }
      .onChange(of: isPresented) { shown in if shown { open() } }
  }

  private func open() {
    Task { @MainActor in
      // Already open (this view appeared again meanwhile): that sheet's result is on its way.
      guard !checkout.presenting else { return }
      guard let root = UIApplication.shared.connectedScenes
        .compactMap({ ($0 as? UIWindowScene)?.windows.first(where: \.isKeyWindow) })
        .first?.rootViewController else {
        isPresented = false
        onCompletion(.failed(VezmoError(code: .config, message: "No window to present the checkout from.")))
        return
      }
      let result = await checkout.present(from: root)
      isPresented = false
      onCompletion(result)
    }
  }
}
