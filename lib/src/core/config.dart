import '../auth/auth_event.dart';

/// Signature for the customer-supplied callback that mints a fresh QuickAuth
/// session JWT. The SDK invokes this whenever the cached token is missing,
/// expired, or about to expire (~30s before `exp`). The callback is expected
/// to call the customer's own backend (which holds the QuickAuth client
/// secret) and return the `sessionToken` from `POST /v1/sdk/session`.
typedef TokenProvider = Future<String> Function();

/// Immutable runtime configuration for the QuickAuth SDK.
///
/// Created by [QuickAuth.init] and read by every internal service. The
/// instance is cached on the [QuickAuth] facade after `init`.
///
/// ## Auth model
/// QuickAuth uses **ephemeral session tokens** (Twilio-Verify pattern):
///
/// 1. The customer's backend mints a 10-min JWT via server-to-server
///    `POST /v1/sdk/session` (using the QuickAuth client secret).
/// 2. The SDK uses that JWT as `Authorization: Bearer ...` for every API call.
/// 3. ~30s before expiry, the SDK calls [onTokenExpiry] to fetch a fresh JWT.
///
/// The client secret never lives on-device.
class QuickAuthConfig {
  /// Default base URL for the QuickAuth public API.
  static const String defaultApiBaseUrl = 'https://api.quickauth.in';

  /// Default OTP code length (matches backend default template length).
  static const int defaultOtpLength = 6;

  /// Default OTP request timeout.
  static const Duration defaultRequestTimeout = Duration(seconds: 15);

  /// Creates a config snapshot.
  QuickAuthConfig({
    this.apiBaseUrl = defaultApiBaseUrl,
    this.onTokenExpiry,
    this.publishableKey,
    this.initialToken,
    this.unsafeDirectClientId,
    this.unsafeDirectClientSecret,
    this.otpLength = defaultOtpLength,
    this.requestTimeout = defaultRequestTimeout,
    this.debug = false,
    this.onAuthEvent,
  });

  /// Override the API base URL (e.g. for staging). Defaults to
  /// [defaultApiBaseUrl].
  final String apiBaseUrl;

  /// Callback the SDK invokes to fetch a fresh session JWT from the customer's
  /// backend (the hardened "session-token" auth mode).
  ///
  /// In production the customer hosts a tiny endpoint (e.g.
  /// `GET /api/quickauth-token`) that proxies to QuickAuth's
  /// `POST /v1/sdk/session` server-to-server. The callback must return the
  /// `sessionToken` string from that response.
  ///
  /// Exactly one of [onTokenExpiry] or [publishableKey] must be supplied. Use
  /// [publishableKey] for the zero-backend quick-start; use [onTokenExpiry]
  /// when you want the extra-hardened server-minted-token flow.
  final TokenProvider? onTokenExpiry;

  /// Publishable key (`pk_live_…` / `pk_test_…`) — the in-app-safe credential
  /// for the zero-backend auth mode.
  ///
  /// Unlike the client **secret**, a publishable key is *designed* to ship
  /// inside the app: on the backend it is scoped to OTP initiate/verify only,
  /// locked to your registered app identity (Android package / iOS bundle /
  /// web origin), and rate-limited. When set, the SDK sends it as
  /// `X-QuickAuth-Key` on `/v1/sdk/auth/*` and no session token is needed.
  final String? publishableKey;

  /// Optional pre-fetched JWT to seed the [TokenManager]. Useful when the
  /// host app already holds a freshly-minted token at boot and wants to skip
  /// the first round-trip.
  final String? initialToken;

  /// **UNSAFE** — when both this and [unsafeDirectClientSecret] are provided,
  /// the SDK calls `POST /v1/sdk/session` directly with the client secret
  /// embedded in the app. Trusted-enterprise / first-party builds only.
  final String? unsafeDirectClientId;

  /// **UNSAFE** — see [unsafeDirectClientId].
  final String? unsafeDirectClientSecret;

  /// Expected OTP digit count.
  final int otpLength;

  /// HTTP request timeout for every API call made by the SDK.
  final Duration requestTimeout;

  /// When `true`, internal services emit `debugPrint` lines.
  final bool debug;

  /// Headless auth event handler. The SDK invokes this with a typed
  /// [AuthEvent] as the auth lifecycle progresses (OTP sent, verified,
  /// failed, error). Pass at [QuickAuth.init]; one handler per config.
  ///
  /// Events are delivered via a microtask so callers can rely on the
  /// pattern `await initiate(); /* handler fires next tick */` without
  /// racing themselves.
  final AuthEventHandler? onAuthEvent;

  /// Whether the SDK was configured with the unsafe-direct escape hatch.
  bool get isUnsafeDirect =>
      (unsafeDirectClientId != null && unsafeDirectClientId!.isNotEmpty) &&
      (unsafeDirectClientSecret != null &&
          unsafeDirectClientSecret!.isNotEmpty);

  /// Whether the SDK is using the publishable-key (zero-backend) auth mode.
  bool get isPublishableKeyMode =>
      publishableKey != null && publishableKey!.isNotEmpty;
}

/// OTP delivery channel sent to `/v1/sdk/auth/initiate`.
enum OtpChannel {
  /// Backend picks the best available channel (typically WhatsApp first, then
  /// SMS fallback).
  auto,

  /// Force delivery via SMS.
  sms,

  /// Force delivery via WhatsApp.
  whatsapp,
}

/// Wire-format mapper for [OtpChannel].
extension OtpChannelWire on OtpChannel {
  /// Lowercase string the backend accepts.
  String get wire {
    switch (this) {
      case OtpChannel.auto:
        return 'auto';
      case OtpChannel.sms:
        return 'sms';
      case OtpChannel.whatsapp:
        return 'whatsapp';
    }
  }
}
