require "json"

package = JSON.parse(File.read(File.join(__dir__, "package.json")))
# The native payment engine the element runs on, pinned exactly; bumped on purpose, release by release.
payment_engine_version = "26.14.0"

if ENV["RCT_NEW_ARCH_ENABLED"] == "0"
  raise "@vezmopay/react-native needs the React Native New Architecture (RCT_NEW_ARCH_ENABLED=1)."
end

Pod::Spec.new do |s|
  s.name         = "VezmoReactNative"
  s.version      = package["version"]
  s.summary      = package["description"]
  s.homepage     = package["homepage"]
  s.license      = package["license"]
  s.authors      = package["author"]

  s.platforms    = { :ios => "15.1" }
  s.source       = { :git => "https://github.com/vezmoPay/vezmo-mobile-sdk.git", :tag => "react-native-v#{s.version}" }
  s.swift_version = "5.9"

  s.source_files = "ios/**/*.{h,m,mm,swift}"
  s.private_header_files = "ios/**/*.h"
  # Apple's privacy manifest, in its own bundle (beside the app's own manifest): no tracking; what the sheet sends
  # Vezmo to take the payment, as the native iOS SDK declares. The payment engine's pod brings its own.
  s.resource_bundles = { "VezmoReactNativePrivacy" => ["ios/PrivacyInfo.xcprivacy"] }

  s.pod_target_xcconfig = {
    "DEFINES_MODULE" => "YES",
    "CLANG_CXX_LANGUAGE_STANDARD" => "c++20",
  }

  s.dependency "StripePaymentSheet", payment_engine_version
  # Instant ACH's bank step, drawn natively (without it the engine falls back to a web page).
  s.dependency "StripeFinancialConnections", payment_engine_version

  install_modules_dependencies(s)
end
