# Changelog

All notable changes to the QuickAuth Flutter SDK are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

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
