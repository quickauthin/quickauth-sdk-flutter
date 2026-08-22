import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

import 'config.dart';

/// Raised by [QuickAuthApiClient] when the backend returns a non-2xx status or
/// a transport-level error occurs.
class QuickAuthApiException implements Exception {
  /// Creates an API exception.
  QuickAuthApiException({
    required this.message,
    this.statusCode,
    this.code,
    this.body,
  });

  /// Human-readable message — pulled from the JSON `message` field when
  /// available.
  final String message;

  /// HTTP status code, or `null` for transport errors.
  final int? statusCode;

  /// Backend error code (`invalid_phone`, `rate_limited`, ...).
  final String? code;

  /// Raw decoded body, if any.
  final Map<String, dynamic>? body;

  @override
  String toString() =>
      'QuickAuthApiException($statusCode${code == null ? '' : ' / $code'}): $message';
}

/// Refresh window: when the cached JWT has fewer than this many seconds left
/// it is considered expired and a fresh one is fetched up-front.
const Duration _kRefreshWindow = Duration(seconds: 30);

/// Manages the ephemeral session JWT used for `Authorization: Bearer ...`.
///
/// Responsibilities:
/// - Cache the current token in memory.
/// - Decode the JWT `exp` claim and refresh ~30s before expiry.
/// - Coalesce concurrent refresh requests via single-flight.
/// - Allow forced invalidation (e.g. on a 401 response).
///
/// The actual token-minting is delegated to a [TokenProvider] supplied by the
/// host app (see [QuickAuthConfig.onTokenExpiry]).
class TokenManager {
  /// Creates a token manager.
  TokenManager({
    required TokenProvider provider,
    String? initialToken,
    DateTime Function()? clock,
  })  : _provider = provider,
        _token = initialToken,
        _clock = clock ?? DateTime.now {
    if (initialToken != null) {
      _expiresAt = _decodeExpiry(initialToken);
    }
  }

  final TokenProvider _provider;
  final DateTime Function() _clock;

  String? _token;
  DateTime? _expiresAt;
  Future<String>? _inflight;

  /// Number of times [getToken] has triggered a fresh provider call. Test
  /// hook — counts the *underlying* invocations, not the number of awaiters.
  int providerCalls = 0;

  /// Returns a fresh JWT, refreshing if the cached token is missing or has
  /// fewer than 30 seconds of life left.
  ///
  /// Concurrent callers share a single in-flight refresh.
  Future<String> getToken() {
    if (_isFresh()) {
      return Future<String>.value(_token!);
    }
    final pending = _inflight;
    if (pending != null) return pending;
    final fut = _refresh();
    _inflight = fut;
    return fut;
  }

  /// Drop the cached token. Forces the next [getToken] to call [_provider].
  void invalidate() {
    _token = null;
    _expiresAt = null;
  }

  /// Whether a non-expired token is currently cached.
  @visibleForTesting
  bool get hasFreshToken => _isFresh();

  bool _isFresh() {
    final t = _token;
    final exp = _expiresAt;
    if (t == null) return false;
    if (exp == null) return true; // can't decode — assume valid
    return exp.isAfter(_clock().add(_kRefreshWindow));
  }

  Future<String> _refresh() async {
    try {
      providerCalls++;
      final fresh = await _provider();
      if (fresh.isEmpty) {
        throw QuickAuthApiException(
          message: 'TokenProvider returned an empty session token',
        );
      }
      _token = fresh;
      _expiresAt = _decodeExpiry(fresh);
      return fresh;
    } finally {
      _inflight = null;
    }
  }

  /// Decode the `exp` claim from a JWT (returns `null` if malformed).
  static DateTime? _decodeExpiry(String jwt) {
    try {
      final parts = jwt.split('.');
      if (parts.length < 2) return null;
      final payloadStr = _b64UrlDecode(parts[1]);
      final payload = jsonDecode(payloadStr);
      if (payload is! Map) return null;
      final exp = payload['exp'];
      if (exp is num) {
        return DateTime.fromMillisecondsSinceEpoch(exp.toInt() * 1000,
            isUtc: true);
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  static String _b64UrlDecode(String input) {
    var s = input.replaceAll('-', '+').replaceAll('_', '/');
    switch (s.length % 4) {
      case 0:
        break;
      case 2:
        s += '==';
        break;
      case 3:
        s += '=';
        break;
      default:
        throw const FormatException('invalid base64url payload');
    }
    return utf8.decode(base64.decode(s));
  }
}

/// JSON HTTP client for the QuickAuth public API.
///
/// Every request carries `Authorization: Bearer <sessionToken>` where the
/// token is fetched from a [TokenManager]. On a 401 the client invalidates
/// the cached token and retries the request once.
class QuickAuthApiClient {
  /// Creates an API client. Inject [httpClient] in tests.
  ///
  /// [tokenManager] is the source of truth for the bearer token. The unsafe
  /// direct-mode bootstrap (which calls `/v1/sdk/session` directly with the
  /// client secret) is wired up by the facade by passing a [TokenProvider]
  /// that hits this same client with `_authedHeaders` skipped.
  QuickAuthApiClient({
    required this.config,
    required TokenManager tokenManager,
    http.Client? httpClient,
  })  : _tokens = tokenManager,
        _http = httpClient ?? http.Client();

  /// Active configuration.
  final QuickAuthConfig config;

  /// Token manager — exposed mainly so tests can inspect provider call counts.
  final TokenManager _tokens;

  /// Token manager — exposed for tests / advanced uses.
  TokenManager get tokenManager => _tokens;

  final http.Client _http;

  /// SDK version reported in the `x-quickauth-sdk` header.
  static const String sdkVersion = '0.2.0';

  /// Cached app-identity headers (Android package / iOS bundle) — captured
  /// once and reused for every publishable-key request.
  Future<Map<String, String>>? _appIdentity;

  /// Headers used for every authenticated request.
  ///
  /// In **publishable-key mode** this sends `X-QuickAuth-Key` plus the app's
  /// identity (Android package / iOS bundle; web relies on the browser-set
  /// `Origin`) — no bearer token. Otherwise it resolves and attaches the
  /// session JWT as `Authorization: Bearer …`.
  Future<Map<String, String>> _authedHeaders() async {
    final base = <String, String>{
      'content-type': 'application/json',
      'accept': 'application/json',
      'x-quickauth-sdk': 'flutter/${QuickAuthApiClient.sdkVersion}',
    };
    if (config.isPublishableKeyMode) {
      base['x-quickauth-key'] = config.publishableKey!;
      base.addAll(await (_appIdentity ??= _captureAppIdentity()));
      return base;
    }
    final token = await _tokens.getToken();
    base['authorization'] = 'Bearer $token';
    return base;
  }

  /// Best-effort capture of the host app's identity for publishable-key
  /// app-locking. Never throws — a missing identity just omits the header and
  /// the backend falls back to its configured policy.
  static Future<Map<String, String>> _captureAppIdentity() async {
    if (kIsWeb) return const <String, String>{}; // Origin is set by the browser
    try {
      final info = await PackageInfo.fromPlatform();
      final id = info.packageName;
      if (id.isEmpty) return const <String, String>{};
      switch (defaultTargetPlatform) {
        case TargetPlatform.android:
          return <String, String>{'x-quickauth-package': id};
        case TargetPlatform.iOS:
          return <String, String>{'x-quickauth-bundle': id};
        default:
          return const <String, String>{};
      }
    } catch (_) {
      return const <String, String>{};
    }
  }

  /// POST [path] with a JSON [body] and decode the JSON response.
  ///
  /// On a 401 Unauthorized the bearer token is invalidated and the request
  /// is retried exactly once.
  Future<Map<String, dynamic>> post(
    String path,
    Map<String, dynamic> body,
  ) async {
    return _postOnce(path, body, retryOn401: true);
  }

  /// Variant that **must not** add a bearer header. Used by the unsafe-direct
  /// bootstrap when calling `/v1/sdk/session` with `X-Client-Id` /
  /// `X-Client-Secret` to mint the very first JWT.
  Future<Map<String, dynamic>> postUnauthenticated(
    String path,
    Map<String, dynamic> body, {
    required Map<String, String> extraHeaders,
  }) async {
    final uri = Uri.parse('${config.apiBaseUrl}$path');
    final headers = <String, String>{
      'content-type': 'application/json',
      'accept': 'application/json',
      'x-quickauth-sdk': 'flutter/${QuickAuthApiClient.sdkVersion}',
      ...extraHeaders,
    };
    if (config.debug) {
      debugPrint('[QuickAuth] POST(unauth) $uri body=$body');
    }
    try {
      final res = await _http
          .post(uri, headers: headers, body: jsonEncode(body))
          .timeout(config.requestTimeout);
      return _handle(res);
    } on TimeoutException {
      throw QuickAuthApiException(
        message: 'Request timed out after ${config.requestTimeout.inSeconds}s',
      );
    } catch (e) {
      if (e is QuickAuthApiException) rethrow;
      throw QuickAuthApiException(message: 'Network error: $e');
    }
  }

  Future<Map<String, dynamic>> _postOnce(
    String path,
    Map<String, dynamic> body, {
    required bool retryOn401,
  }) async {
    final uri = Uri.parse('${config.apiBaseUrl}$path');
    if (config.debug) {
      debugPrint('[QuickAuth] POST $uri body=$body');
    }
    try {
      final headers = await _authedHeaders();
      final res = await _http
          .post(uri, headers: headers, body: jsonEncode(body))
          .timeout(config.requestTimeout);
      if (res.statusCode == 401 && retryOn401) {
        _tokens.invalidate();
        // Awaited, not returned bare. Returning the future hands it to the caller
        // unawaited, so the retry's own timeout or network failure escapes the catch
        // blocks below and surfaces as a raw TimeoutException instead of the
        // QuickAuthApiException every caller is written against.
        return await _postOnce(path, body, retryOn401: false);
      }
      return _handle(res);
    } on TimeoutException {
      throw QuickAuthApiException(
        message: 'Request timed out after ${config.requestTimeout.inSeconds}s',
      );
    } catch (e) {
      if (e is QuickAuthApiException) rethrow;
      throw QuickAuthApiException(message: 'Network error: $e');
    }
  }

  Map<String, dynamic> _handle(http.Response res) {
    Map<String, dynamic>? decoded;
    if (res.body.isNotEmpty) {
      try {
        final raw = jsonDecode(res.body);
        if (raw is Map<String, dynamic>) decoded = raw;
      } catch (_) {
        // fall through
      }
    }
    if (res.statusCode >= 200 && res.statusCode < 300) {
      return decoded ?? <String, dynamic>{};
    }
    throw QuickAuthApiException(
      statusCode: res.statusCode,
      message: (decoded?['message'] as String?) ?? 'HTTP ${res.statusCode}',
      code: decoded?['code'] as String?,
      body: decoded,
    );
  }

  /// Free the underlying HTTP client.
  void close() => _http.close();
}
