import 'dart:async';

import 'package:flutter/foundation.dart';

import 'attribution/attribution_service.dart';
import 'auth/otp_service.dart';
import 'auth/sms_retriever.dart';
import 'auth/whatsapp_login.dart';
import 'core/api_client.dart';
import 'core/config.dart';
import 'core/consent.dart';
import 'core/storage.dart';

/// Top-level access point for the QuickAuth SDK.
///
/// Call [QuickAuth.init] once on app startup, then use:
/// - `QuickAuth.auth` for OTP & WhatsApp login
/// - `QuickAuth.attribution` for click attribution & conversions
/// - `QuickAuth.consent` for DPDP / GDPR consent gating
class QuickAuth {
  QuickAuth._();

  static QuickAuth? _instance;

  /// Whether [init] has resolved.
  static bool get isInitialized => _instance != null;

  /// Singleton accessor — throws if [init] has not been called.
  static QuickAuth get _i {
    final i = _instance;
    if (i == null) {
      throw StateError('QuickAuth.init() must be called before use.');
    }
    return i;
  }

  late QuickAuthConfig _config;
  late QuickAuthApiClient _api;
  late QuickAuthStorage _storage;
  late QuickAuthConsent _consent;
  late QuickAuthOtpService _auth;
  late QuickAuthAttributionService _attribution;
  late WhatsAppLogin _whatsapp;
  late TokenManager _tokens;

  /// Active configuration.
  static QuickAuthConfig get config => _i._config;

  /// Token manager — exposed for tests / advanced flows.
  static TokenManager get tokenManager => _i._tokens;

  /// Consent gate.
  static QuickAuthConsent get consent => _i._consent;

  /// OTP / WhatsApp login service.
  static QuickAuthOtpService get auth => _i._auth;

  /// Attribution service.
  static QuickAuthAttributionService get attribution => _i._attribution;

  /// Direct WhatsApp deep-link helper. Most apps should prefer
  /// [QuickAuthOtpService.startWhatsAppLogin] which wires consent.
  static WhatsAppLogin get whatsapp => _i._whatsapp;

  /// Initialise the SDK. Idempotent — repeated calls update the cached config.
  ///
  /// [onTokenExpiry] — required callback that returns a fresh QuickAuth
  ///   session JWT. The customer's backend must mint this JWT via a
  ///   server-to-server `POST /v1/sdk/session` call (using the customer's
  ///   QuickAuth client secret). The SDK will invoke this callback whenever
  ///   the cached token has fewer than 30 seconds of life left, and will
  ///   single-flight concurrent requests so the callback is never racing
  ///   with itself.
  ///
  /// [apiBaseUrl] — override the API host (defaults to the production URL).
  ///
  /// [initialToken] — optional pre-fetched JWT to seed the [TokenManager].
  ///
  /// [unsafeDirectClientId] / [unsafeDirectClientSecret] — **DO NOT USE**
  ///   in normal apps. When both are provided, the SDK will mint session
  ///   JWTs directly by calling `/v1/sdk/session` with the client secret
  ///   embedded in the binary. Trusted-enterprise / first-party builds
  ///   only. A warning is printed to the console on init.
  ///
  /// [consent] — initial consent state. Persisted afterwards.
  ///
  /// [debug] — enable verbose `debugPrint` output.
  static Future<QuickAuth> init({
    required TokenProvider onTokenExpiry,
    String apiBaseUrl = QuickAuthConfig.defaultApiBaseUrl,
    String? initialToken,
    String? unsafeDirectClientId,
    String? unsafeDirectClientSecret,
    bool consent = false,
    bool debug = false,
  }) async {
    final cfg = QuickAuthConfig(
      apiBaseUrl: apiBaseUrl,
      onTokenExpiry: onTokenExpiry,
      initialToken: initialToken,
      unsafeDirectClientId: unsafeDirectClientId,
      unsafeDirectClientSecret: unsafeDirectClientSecret,
      debug: debug,
    );

    final inst = _instance ??= QuickAuth._();
    inst._config = cfg;

    // Resolve the effective TokenProvider. In unsafe-direct mode we replace
    // the customer-supplied callback with one that calls /v1/sdk/session
    // directly using X-Client-Id / X-Client-Secret headers.
    final TokenProvider effectiveProvider;
    if (cfg.isUnsafeDirect) {
      // ignore: avoid_print
      print(
          '[QuickAuth] ⚠️ UNSAFE mode: client_secret embedded; for trusted-enterprise only');
      effectiveProvider = () => _mintTokenUnsafe(inst);
    } else {
      effectiveProvider = onTokenExpiry;
    }

    inst._tokens = TokenManager(
      provider: effectiveProvider,
      initialToken: initialToken,
    );
    inst._api = QuickAuthApiClient(
      config: cfg,
      tokenManager: inst._tokens,
    );
    inst._storage = QuickAuthStorage();
    inst._consent = QuickAuthConsent(storage: inst._storage, initial: consent);
    await inst._consent.hydrate();

    final smsRetriever = SmsRetriever();
    inst._auth = QuickAuthOtpService(
      apiClient: inst._api,
      smsRetriever: smsRetriever,
    );
    inst._whatsapp = WhatsAppLogin();
    inst._attribution = QuickAuthAttributionService(
      apiClient: inst._api,
      storage: inst._storage,
      consent: inst._consent,
    );

    if (debug) {
      debugPrint('[QuickAuth] init ok — base=$apiBaseUrl consent=$consent');
    }
    return inst;
  }

  /// Mint a session JWT using the unsafe direct-mode client credentials.
  /// Only invoked when the customer opts in via
  /// `unsafeDirectClientId` + `unsafeDirectClientSecret`.
  static Future<String> _mintTokenUnsafe(QuickAuth inst) async {
    final cfg = inst._config;
    final json = await inst._api.postUnauthenticated(
      '/v1/sdk/session',
      <String, dynamic>{},
      extraHeaders: <String, String>{
        'x-client-id': cfg.unsafeDirectClientId!,
        'x-client-secret': cfg.unsafeDirectClientSecret!,
      },
    );
    final token = json['sessionToken'];
    if (token is! String || token.isEmpty) {
      throw QuickAuthApiException(
        message: 'POST /v1/sdk/session did not return a sessionToken',
      );
    }
    return token;
  }

  /// Reset the SDK — primarily for tests.
  @visibleForTesting
  static Future<void> reset() async {
    final i = _instance;
    if (i == null) return;
    await i._consent.close();
    i._api.close();
    _instance = null;
  }
}

/// Convenience extension so existing callers can write
/// `QuickAuth.auth.startWhatsAppLogin(...)`.
extension QuickAuthAuthWhatsApp on QuickAuthOtpService {
  /// Open WhatsApp at [businessNumber] for the click-to-WhatsApp login flow.
  Future<bool> startWhatsAppLogin({
    required String businessNumber,
    String prefilledMessage = 'Hi, I want to log in.',
  }) {
    return QuickAuth.whatsapp.open(
      businessNumber: businessNumber,
      prefilledMessage: prefilledMessage,
    );
  }
}
