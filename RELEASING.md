# Releasing

For maintainers. Release the four SDKs in this order (each tag runs its own workflow):

> **Repository moved (24 Oct 2026):** this repo now lives at `github.com/vezmoPay/vezmo-mobile-sdk` (it was
> `ACCEPT-GLOBAL-LIMITED/vezmo-mobile-sdk`; GitHub redirects the old address). npm trusted publishing and pub.dev
> automated publishing name the repository, so both must say `vezmoPay/vezmo-mobile-sdk` before the next React Native
> or Flutter release (npm: package settings → Trusted publisher; pub.dev: package Admin → Automated publishing).

1. **Android**: push `android-v<version>`. `release-android.yml` signs and uploads to Maven Central (needs
   `MAVEN_CENTRAL_USERNAME`, `MAVEN_CENTRAL_PASSWORD`, `SIGNING_KEY` and `SIGNING_KEY_PASSWORD`: a Central Portal
   account with the `com.vezmo` namespace verified); then release the validated upload in the Central Portal.
2. **iOS**: push the plain semver tag `<version>` (for example `0.1.0`) at the repository root; Swift Package Manager
   reads it directly. `release-ios.yml` checks that it equals `VezmoCheckout.version`.
3. **React Native**: push `react-native-v<version>`. `release-react-native.yml` publishes to npm with provenance, signed
   in by npm trusted publishing (no token: the package's npm settings trust this repository's
   `release-react-native.yml`).
4. **Flutter**, last: push `flutter-v<version>`. The plugin runs on the native SDKs, so it needs 1 and 2 out first;
   `release-flutter.yml` checks both, then publishes to pub.dev with GitHub's login (the one-time pub.dev setup is in
   that file's header). **0.1.0 only**: pub.dev automates only a package that already exists, so publish 0.1.0 by
   hand with `flutter pub publish` from `packages/flutter` and push no `flutter-v0.1.0` tag (the workflow would fail
   on the version that is already there); the tags take over from 0.1.1.

Bump every place a version lives (and each package's `CHANGELOG.md`) before tagging:

| Package | Version |
| --- | --- |
| React Native | `packages/react-native/package.json` and `packages/react-native/src/version.ts` |
| iOS | `VezmoCheckout.version` in `packages/ios/Sources/VezmoCheckout/VezmoCheckout.swift` |
| Android | `VERSION_NAME` in `packages/android/gradle.properties` |
| Flutter | `packages/flutter/pubspec.yaml`, `VezmoCheckout.version` in `packages/flutter/lib/vezmo_checkout.dart`, `version` and the `com.vezmo:vezmo-checkout` pin in `packages/flutter/android/build.gradle.kts`, and the iOS SDK pin in `packages/flutter/ios/vezmo_checkout/Package.swift` |

The READMEs link to the guides on user.vezmo.com: make sure those docs are live before publishing.

