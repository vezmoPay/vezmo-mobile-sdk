# Contributing

Thanks for helping with the Vezmo mobile SDKs. Bug reports and pull requests are welcome.

- **A bug**: [open an issue](https://github.com/vezmoPay/vezmo-mobile-sdk/issues/new/choose) with the
  SDK and its version, the phone and OS version, what you did and what happened. A session's client token is safe to
  share; an API key or secret never is.
- **A security problem**: never in an issue or pull request. Report it privately as [SECURITY.md](SECURITY.md) says.
- **A larger change** (a new feature, a change to the public API): open an issue first, so we can agree on the shape
  before you build it.

## Working on a package

Each package is built and tested on its own. The [repository layout](README.md#repository-layout) shows what lives
where.

### React Native (`packages/react-native`)

```sh
cd packages/react-native
node .yarn/releases/yarn-4.11.0.cjs install
node .yarn/releases/yarn-4.11.0.cjs tsc       # types
node .yarn/releases/yarn-4.11.0.cjs jest      # unit tests
node .yarn/releases/yarn-4.11.0.cjs prepare   # builds lib/
node .yarn/releases/yarn-4.11.0.cjs example expo run:ios       # or run:android
```

The example app pays against Vezmo's dev sandbox. `EXPO_PUBLIC_VEZMO_DEMO_URL` and `EXPO_PUBLIC_VEZMO_API_BASE`
point it at another API.

### iOS (`packages/ios`)

Open the repository root in Xcode (the root `Package.swift` is the iOS SDK) and run the `VezmoCheckout` tests on an
iPhone simulator, or:

```sh
xcodebuild test -scheme VezmoCheckout-Package -destination 'platform=iOS Simulator,name=iPhone 16'
```

The example app: `brew install xcodegen`, then `xcodegen generate` in `packages/ios/Example` and open
`VezmoExample.xcodeproj`.

### Android (`packages/android`)

```sh
cd packages/android
gradle :checkout:testDebugUnitTest :checkout:lintRelease   # unit tests and lint (Gradle 8.14, JDK 17)
gradle :example:installRelease                             # the example app on a connected phone
```

### Flutter (`packages/flutter`)

```sh
cd packages/flutter
flutter analyze && flutter test
cd example && flutter run
```

The plugin runs on the iOS and Android SDKs. Building it against this repository's native code rather than a release
takes a few extra steps; they are in the [Flutter README](packages/flutter#development).

## CI

| Workflow | Runs on | What it checks |
| --- | --- | --- |
| `react-native.yml` | Every pull request and push to `main` | Types, unit tests, the package build, and the example app's iOS and Android builds |
| `react-native-e2e.yml` | Pushes to `main` that change the package | Pays end to end with Maestro on an Android emulator and an iPhone simulator, once per business model, then checks dark mode and the largest text size |
| `ios.yml` | Changes to the iOS SDK | Unit tests, then pays end to end from the example app on an iPhone simulator, once per business model |
| `android.yml` | Changes to the Android SDK | Unit tests, lint, screenshot tests and a Maven local publish, then pays end to end from the minified example app on an Android emulator, once per business model (with one payment through a font size change mid-way); uploads that app as `example-apk` to install on a phone |
| `flutter.yml` | Changes to the Flutter plugin or either native SDK | Analysis and tests (Dart, and the Android plugin's own tests), then pays end to end from the example app on both, once per business model |
| `release-*.yml` | Release tags | Publishing; see [RELEASING.md](RELEASING.md) |
| `testflight-*.yml` | By hand | Sends the example app to TestFlight and reports on its builds |

The end-to-end flows (`packages/*/e2e/maestro`, with the steps they share in `e2e/maestro`) pay against Vezmo's
sandbox on both business models, Connect and merchant of record, each in its own job: cards with 3D Secure, a decline,
a payment and a subscription in the buyer's own currency (AED), and subscriptions with and without a free trial. Once:
cancel, a bad token, a Cash App redirect back into the app, Instant ACH with the sandbox's test bank (merchant of
record), and dark mode. They need no secrets, so they run on pull
requests from forks too (a first-time contributor's runs start once a maintainer approves them).

To run a folder of flows on your own emulator or simulator, name the model:
`.github/scripts/maestro-test.sh connect out packages/ios/e2e/maestro` (or `maestro test -e TRACK=mor …`). A failed
flow is never run again; the only retries are before a payment: making or loading the sandbox session, a tap or
keystroke the device dropped, a browser page that never drew, and Maestro's own driver starting. Before a session and
before Pay, every flow waits until the sandbox is up and, on an iPhone simulator, until HTTPS gets through inside it
(`.github/scripts/sim-tls-gate.py`).

## Pull requests

- Keep a pull request to one change, in one package where you can, and include its tests.
- Title it the way the history reads: `feat(ios): …`, `fix(android): …`, `docs: …`, `test(react-native): …`.
- Add a line to the package's `CHANGELOG.md` under the coming version.
- When the public API or what the buyer sees changes, update the package's README in the same pull request. The four
  SDKs keep the same screens, results and error codes, so a change to one usually belongs in all four; say so in the
  pull request if yours doesn't.
- Buyer-facing text names your business, Vezmo and the payment methods, nothing else.
- Never commit an API key, a secret, a signing key or a real client token. The repository scans every push for them.

Pull requests are squash-merged into `main` after review and a green CI.

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
