# Changelog

All notable changes to the QuickAuth Flutter SDK are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [1.2.1] — 2026-08-27

### Fixed

- **iOS integration now works at all.** `pod install` failed in every consuming app with
  `No podspec found for 'quickauth_flutter' in .symlinks/plugins/quickauth_flutter/ios`.
  Flutter resolves a plugin's podspec purely by convention — `<package name>.podspec` inside
  the plugin's `ios/` — but the file was named `quickauth_sdk_flutter.podspec` and declared
  `s.name = 'quickauth_sdk_flutter'`, while the package is `quickauth_flutter`. Both now match
  the package name, and `s.version` tracks the package version instead of sitting at `0.1.0`.
  Android was never affected: Gradle resolves through the `package`/`pluginClass` declared in
  `pubspec.yaml` and has no filename convention, which is why this went unnoticed from v0.1.0
  through v1.2.0 — every one of those releases is broken on iOS. Upgrading is the only fix;
  there is no workaround inside a consuming app short of a dependency override.

### Changed

- **The publish workflow now verifies the podspec name before shipping.** Nothing in the repo
  could previously see this class of fault: the workflow runs on `ubuntu-latest` and never
  invokes CocoaPods, and `example/` has no `ios/` runner, so a broken podspec published green
  and failed only on the integrator's Mac. The check needs no macOS runner and fails on either
  half of the mismatch — wrong filename, or a mismatched `s.name`.

## [1.2.0] — 2026-08-25

### Added

- **WhatsApp zero-tap and one-tap auto-read (Android).** WhatsApp does not deliver these over
  SMS — it broadcasts the code to the app named in the template's `supported_apps` — so
  `SmsRetriever` never saw them and the code was dropped. Four things had to be right together
  and each one missing looked identical: message arrives, code does not fill in, nothing errors.
  The receiver is manifest-declared so it works while the app is backgrounded, the handshake
  Meta requires is sent before each request, and `<queries>` is declared so Android 11+ actually
  delivers that handshake.
- **`resendOtp()`.** Resends to the number the current attempt is already for. Takes no
  arguments deliberately: passing a differently formatted number starts a second transaction
  with a second code and leaves the user holding two, only one of which works. Carries the
  original channel and `autoSubmit`, and re-sends the WhatsApp handshake, which Meta expires
  after ten minutes.
- **`initiate(autoSubmit: true)`.** An auto-read code verifies itself, so the integration is
  initiate-and-listen. Off by default: an app already submitting from its own `observeOTP`
  callback would otherwise submit twice, and the second fails against a code the server has
  consumed — an error after a success.

### Changed

- **`observeOTP()` now covers both channels.** SMS and WhatsApp are two delivery mechanisms for
  one thing; listening to only one meant a merchant on `auto` got auto-read for some users and
  not others, with nothing to explain the difference.
- **`initiate()` subscribes for auto-read itself.** Auto-read previously only worked for a
  caller who happened to call `observeOTP()` — the native receiver holds a code until something
  listens, so with nobody subscribed it was received, held, and never delivered.
- **`OtpAutoReadEvent` fires once per code.** It was emitted by both the internal subscription
  and the caller's, so a merchant driving their UI from it saw the field fill, clear and fill
  again.

### Removed

- **`RECEIVE_SMS` and `INTERNET` from the SDK manifest.** Neither was ever used: auto-read goes
  through `SmsRetriever`, which reads exactly one message — the one ending in the app's own hash
  — and needs no permission, and Flutter's own manifest provides `INTERNET`.

  This matters beyond tidiness. A plugin's manifest merges into every app that depends on it, so
  every merchant was shipping an SMS permission they did not use, and `RECEIVE_SMS` is in Google
  Play's restricted set: an app declaring it must justify the use in a Play Console declaration
  or be removed from the store. **If you added that declaration because of this SDK, you can
  drop it.**

### Upgrading

Nothing is required. `initiate`, `submitOtp`, `observeOTP` and `reset` are unchanged.

For WhatsApp auto-read, the template must carry your app's package name and its 11-character
app hash in `supported_apps` — and the hash of the build you are testing, which for a debug
build is not your release hash.

## [1.1.2] — 2026-08-22

### Fixed

- **OTP auto-fill took the first number in the message, not the code.** A body like
  `"Your OTP for order 4471029 is 483920"` filled in `4471029`. Extraction now anchors on the
  keyword (`otp`, `code`, `pin`, `password`) and otherwise takes the *last* standalone 4–8
  digit run — senders put reference numbers ahead of the code far more often than after it.
  The 11-character SMS Retriever app hash is stripped before scanning, and word boundaries
  keep a 10-digit mobile number from being truncated into a plausible code.
- **A 401 retry could surface the wrong exception.** The retry's future was returned from
  inside a `try` without being awaited, so its own timeout or network failure escaped the
  handler and reached callers as a raw `TimeoutException` instead of `QuickAuthApiException`.

### Changed

- Cleared every analyzer lint and formatted the package. pub.dev static analysis 30/50 → 50/50
  (overall 130 → 150).

### Note

`QuickAuth.init(publishableKey: …)` shipped in 1.1.1, but the backend did not recognise the
`X-QuickAuth-Key` header until 22 August. Zero-backend initialisation returned 401 before that
date and works from it — no SDK change was involved, so 1.1.1 users need only the server side.

## [1.1.1] — 2026-08-20

### Changed
- **Package renamed** `quickauth` → `quickauth_flutter`. Import
  `package:quickauth_flutter/quickauth_flutter.dart` and depend on
  `quickauth_flutter:` in your `pubspec.yaml`. The public API is unchanged.

### Added
- **Publishable-key auth mode (preview)** — `QuickAuth.init(publishableKey: 'pk_live_…')`
  for a zero-backend quick start. The SDK sends the key as `X-QuickAuth-Key`
  (plus Android package / iOS bundle for app-locking) instead of a
  server-minted session token. `onTokenExpiry` is now optional; exactly one of
  `publishableKey` or `onTokenExpiry` must be supplied. The session-token flow
  is unchanged. Note: requires backend publishable-key support to be enabled —
  inert until you're issued a `pk_` key.
- Consent-gated `deviceInfo` capture on `initiate` and `submitOtp`. When
  DPDP/GDPR consent has been granted via `QuickAuth.consent`, the SDK now
  attaches an opaque `deviceInfo` block (platform, OS version, locale,
  timezone, app version/build/id) to the auth request — matching the web
  and iOS SDKs' V48 audit metadata. Consent off → nothing is sent. Capture
  failures are swallowed and never block authentication.

### Fixed
- Widened the `package_info_plus` constraint from `^5.0.0` to
  `>=5.0.0 <11.0.0`. The old upper bound (`<6.0.0`) forced a version
  conflict for host apps already on `package_info_plus` 6.x–10.x,
  blocking `flutter pub get`. The SDK only reads `PackageInfo.version`,
  `.buildNumber`, and `.packageName`, which are unchanged across all
  supported majors, so no code changes were needed. Verified against
  `package_info_plus` 10.x (full test suite green).

## [1.0.0] — 2026-05-23

### Changed
- **BREAKING**: `OtpResult` returned by `verifyOTP` no longer contains
  `jwt` / `expiresIn` / `userId`. QuickAuth is a verification provider,
  not an identity provider — we tell you whether the phone was verified
  and return a `requestId`. Forward `requestId` to your own backend,
  which confirms server-to-server via `GET /v1/auth/status?requestId=...`
  and mints its own session JWT against its own user table.
  See https://quickauth.in/docs/backend
  ```diff
  - class OtpResult { String jwt; int expiresIn; String? userId; }
  + class OtpResult { bool verified; String requestId; String message; }
  ```
- **BREAKING**: `QuickAuthLoginButton.onSuccess` signature changed from
  `void Function(String jwt)` to `void Function(String requestId)`.
  The widget now gates on `result.verified` internally and surfaces
  `result.message` through `onError` on failure.

## [0.2.0] — 2026-04-28

### Changed
- **BREAKING**: `QuickAuth.init` now takes a `TokenProvider onTokenExpiry`
  callback instead of `publicKey`. The customer's backend mints 10-minute
  ephemeral session JWTs via server-to-server `POST /v1/sdk/session` and
  the SDK uses them as `Authorization: Bearer <sessionToken>`. Twilio-Verify
  pattern — the client secret never lives on-device.
- `x-quickauth-key` header replaced with standard `Authorization: Bearer`.

### Added
- `TokenManager` with JWT `exp` parsing, 30s pre-expiry refresh window,
  single-flight refresh coalescing, and 401 → invalidate+retry handling.
- Optional `initialToken`, `unsafeDirectClientId`, `unsafeDirectClientSecret`
  init parameters. The unsafe-direct escape hatch prints a console warning
  and is documented as trusted-enterprise only.
- New `test/token_manager_test.dart` covering refresh, single-flight,
  invalidation, malformed JWT, and 401 retry.

## [0.1.0] — 2026-04-28

### Added
- Initial public release.
- `QuickAuth.init` for one-time configuration.
- Headless API: `QuickAuth.auth.startOTP`, `verifyOTP`, `observeOTP`,
  `startWhatsAppLogin`.
- Component API: `QuickAuthLoginButton`, `QuickAuthOtpField`.
- Attribution: `captureLaunch`, `trackConversion`, browser-cookie / launch-URL
  qa_clid resolution.
- Consent gate (`QuickAuth.consent.set/get`) — DPDP / GDPR friendly.
- Android plugin: `SmsRetriever` integration via MethodChannel
  `io.quickauth/sms_retriever`; `getAppHash` helper.
- iOS plugin: no-op shim — autofill driven by `TextField.textContentType =
  .oneTimeCode` on the Dart side.
