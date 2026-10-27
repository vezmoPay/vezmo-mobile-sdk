// swift-tools-version: 5.9
// The plugin's iOS side, on Vezmo's native iOS SDK: the `VezmoCheckout` Swift package at the root of the
// vezmo-mobile-sdk repository. VEZMO_IOS_SDK_REVISION (a commit of that repository) builds against that commit
// instead of a release: the repository's own CI uses it to test the plugin with the SDK next to it.

import PackageDescription

let repository = "https://github.com/vezmoPay/vezmo-mobile-sdk"
let sdk: Package.Dependency = Context.environment["VEZMO_IOS_SDK_REVISION"].map { .package(url: repository, revision: $0) }
    ?? .package(url: repository, from: "0.2.0")

let package = Package(
    name: "vezmo_checkout",
    platforms: [
        .iOS("15.1")
    ],
    products: [
        .library(name: "vezmo-checkout", targets: ["vezmo_checkout"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework"),
        sdk,
    ],
    targets: [
        .target(
            name: "vezmo_checkout",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework"),
                .product(name: "VezmoCheckout", package: "vezmo-mobile-sdk"),
            ],
            resources: [
                .process("PrivacyInfo.xcprivacy")
            ]
        )
    ]
)
