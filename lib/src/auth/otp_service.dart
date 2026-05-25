import 'dart:async';

import '../core/api_client.dart';
import '../core/config.dart';
import '../core/storage.dart';
import 'auth_event.dart';
import 'sms_retriever.dart';

const String _deviceTokenKey = 'device_token';
final RegExp _e164 = RegExp(r'^\+[1-9]\d{6,14}$');
final RegExp _otpCode = RegExp(r'^\d{4,8}$');

/// Internal state machine states.
sealed class _SessionState {
  int? get attemptId;
}

class _Idle extends _SessionState {
  @override
  int? get attemptId => null;
}

class _Sending extends _SessionState {
  _Sending(this._attemptId);
  final int _attemptId;
  @override
  int get attemptId => _attemptId;
}

class _AwaitingOtp extends _SessionState {
  _AwaitingOtp(this._attemptId, this.sessionId);
  final int _attemptId;
  final String sessionId;
  @override
  int get attemptId => _attemptId;
}

class _Verifying extends _SessionState {
  _Verifying(this._attemptId, this.sessionId);
  final int _attemptId;
  final String sessionId;
  @override
  int get attemptId => _attemptId;
}

class _Verified extends _SessionState {
  _Verified(this._attemptId, this.requestId);
  final int _attemptId;
  final String requestId;
  @override
  int get attemptId => _attemptId;
}

class _Failed extends _SessionState {
  _Failed(this._attemptId);
  final int _attemptId;
  @override
  int get attemptId => _attemptId;
}

/// Headless auth state machine. Available as `QuickAuth.auth`.
///
/// Public API:
/// ```dart
/// await QuickAuth.auth.initiate(phone: '+919876543210');
/// await QuickAuth.auth.submitOtp('123456');
/// QuickAuth.auth.reset(forgetDevice: true);
/// ```
///
/// All outcomes flow via [QuickAuthConfig.onAuthEvent]. The async methods
/// resolve once the network call has completed; merchants rely on the event
/// stream as the source of truth for what UI to render.
///
/// State diagram (matches web + iOS + Android + RN):
/// ```
///   idle ──initiate()──► sending ──OTP_SENT───► awaitingOtp ──submitOtp()──► verifying
///                              └──VERIFIED────► verified                              │
///                              └──error───────► failed                                │
///   verifying ──VERIFIED────► verified                                                │
///   verifying ──OTP_FAILED──► awaitingOtp ◄────────────────────────────────────────┘
///   any state ──reset()─────► idle
/// ```
class QuickAuthOtpService {
  /// Creates the service.
  QuickAuthOtpService({
    required QuickAuthApiClient apiClient,
    required SmsRetriever smsRetriever,
    required QuickAuthStorage storage,
    required QuickAuthConfig Function() configProvider,
  })  : _api = apiClient,
        _sms = smsRetriever,
        _storage = storage,
        _config = configProvider;

  final QuickAuthApiClient _api;
  final SmsRetriever _sms;
  final QuickAuthStorage _storage;
  final QuickAuthConfig Function() _config;

  _SessionState _state = _Idle();
  int _attemptCounter = 0;
  String? _cachedDeviceToken; // null = explicitly missing; absence = not loaded

  bool _deviceTokenLoaded = false;

  Future<String?> _loadDeviceToken() async {
    if (_deviceTokenLoaded) return _cachedDeviceToken;
    _cachedDeviceToken = await _storage.getString(_deviceTokenKey);
    _deviceTokenLoaded = true;
    return _cachedDeviceToken;
  }

  Future<void> _saveDeviceToken(String token) async {
    _cachedDeviceToken = token;
    _deviceTokenLoaded = true;
    await _storage.setString(_deviceTokenKey, token);
  }

  Future<void> _clearDeviceToken() async {
    _cachedDeviceToken = null;
    _deviceTokenLoaded = true;
    await _storage.remove(_deviceTokenKey);
  }

  /// Begin an auth attempt. Emits [OtpSentEvent] (OTP delivered) or
  /// [VerifiedEvent] (OneTap fired) via [QuickAuthConfig.onAuthEvent]. Throws
  /// only on validation / transport failure.
  Future<void> initiate({
    required String phone,
    OtpChannel channel = OtpChannel.auto,
  }) async {
    if (!_e164.hasMatch(phone)) {
      throw ArgumentError.value(
        phone,
        'phone',
        'must be E.164 formatted (e.g. +919876543210)',
      );
    }

    final attemptId = ++_attemptCounter;
    _state = _Sending(attemptId);

    // Fire-and-forget SMS Retriever — failure must not block OTP delivery.
    unawaited(_sms.start());

    final deviceToken = await _loadDeviceToken();
    final body = <String, dynamic>{
      'phone': phone,
      'channel': channel.wire,
    };
    if (deviceToken != null && deviceToken.isNotEmpty) {
      body['deviceToken'] = deviceToken;
    }

    Map<String, dynamic> json;
    try {
      json = await _api.post('/v1/sdk/auth/initiate', body);
    } catch (e) {
      if (_state.attemptId == attemptId) {
        _state = _Failed(attemptId);
        _emit(AuthErrorEvent(code: _classify(e), message: _message(e)));
      }
      rethrow;
    }

    if (_state.attemptId != attemptId) return;

    final state = json['state'] as String?;
    final sessionId = json['sessionId'] as String;
    final expiresIn = (json['expiresIn'] as num?)?.toInt() ?? 300;
    final newToken = json['deviceToken'] as String?;
    if (newToken != null && newToken.isNotEmpty) {
      await _saveDeviceToken(newToken);
    }

    if (state == 'VERIFIED') {
      _state = _Verified(attemptId, sessionId);
      _emit(VerifiedEvent(requestId: sessionId));
      return;
    }

    _state = _AwaitingOtp(attemptId, sessionId);
    _emit(OtpSentEvent(
      sessionId: sessionId,
      channel: channel,
      expiresIn: expiresIn,
    ));
  }

  /// Submit the user-entered OTP. Valid only after [OtpSentEvent]. Emits
  /// [VerifiedEvent] on success or [OtpFailedEvent] on wrong code (state
  /// stays in awaiting-OTP for retry).
  Future<void> submitOtp(String code) async {
    if (!_otpCode.hasMatch(code)) {
      throw ArgumentError.value(code, 'code', 'must be 4–8 digits');
    }
    final current = _state;
    if (current is! _AwaitingOtp) {
      throw StateError(
        'submitOtp called in state ${current.runtimeType} — must follow an OtpSentEvent',
      );
    }
    final attemptId = current._attemptId;
    final sessionId = current.sessionId;
    _state = _Verifying(attemptId, sessionId);

    final deviceToken = await _loadDeviceToken();
    final body = <String, dynamic>{
      'sessionId': sessionId,
      'code': code,
    };
    if (deviceToken != null && deviceToken.isNotEmpty) {
      body['deviceToken'] = deviceToken;
    }

    Map<String, dynamic> json;
    try {
      json = await _api.post('/v1/sdk/auth/verify', body);
    } catch (e) {
      if (_state.attemptId == attemptId) {
        _state = _Failed(attemptId);
        _emit(AuthErrorEvent(code: _classify(e), message: _message(e)));
      }
      rethrow;
    }

    if (_state.attemptId != attemptId) return;

    final state = json['state'] as String?;
    final verified = json['verified'] as bool? ?? false;
    final requestId = json['requestId'] as String? ?? '';
    final message = json['message'] as String? ?? '';

    final isVerified = state == 'VERIFIED' || (state == null && verified);
    if (isVerified) {
      _state = _Verified(attemptId, requestId);
      _emit(VerifiedEvent(requestId: requestId, message: message));
      return;
    }

    _state = _AwaitingOtp(attemptId, sessionId);
    _emit(OtpFailedEvent(message));
  }

  /// Reset the state machine. Pass [forgetDevice] = `true` on user-initiated
  /// sign-out to also drop the persistent device token, making the next
  /// [initiate] act like a brand-new install (no OneTap).
  Future<void> reset({bool forgetDevice = false}) async {
    _state = _Idle();
    _attemptCounter++; // invalidate any in-flight attempt
    if (forgetDevice) {
      await _clearDeviceToken();
    }
  }

  /// Manually publish an auto-read OTP code into the event stream.
  /// Useful when integrating with an external SMS observer.
  void publishAutoReadCode(String code) {
    _emit(OtpAutoReadEvent(code));
  }

  /// Stream of OTPs auto-read from inbound SMS (Android-only). Codes
  /// collected here are also surfaced as [OtpAutoReadEvent] events.
  Stream<String> observeOTP() {
    return _sms.observe().map((code) {
      _emit(OtpAutoReadEvent(code));
      return code;
    });
  }

  /// Get the Android app-signing hash that must terminate every OTP SMS.
  Future<String?> getAppHash() => _sms.getAppHash();

  // -- Internals ----------------------------------------------------------

  void _emit(AuthEvent event) {
    final handler = _config().onAuthEvent;
    if (handler == null) return;
    // Microtask defer so events fire after the awaited future resumes,
    // matching the contract of every other QuickAuth SDK.
    scheduleMicrotask(() {
      try {
        handler(event);
      } catch (err, stack) {
        // Don't let merchant handler bugs crash the SDK.
        // ignore: avoid_print
        print('[QuickAuth] onAuthEvent handler threw: $err\n$stack');
      }
    });
  }

  String _classify(Object e) {
    if (e is QuickAuthApiException) {
      final code = e.statusCode;
      if (code == 429) return 'RATE_LIMITED';
      if (code != null && code >= 500) return 'SERVER_ERROR';
      if (code != null && code >= 400) return 'CLIENT_ERROR';
      return 'HTTP_ERROR';
    }
    return 'UNKNOWN_ERROR';
  }

  String _message(Object e) {
    if (e is QuickAuthApiException) return e.message;
    return e.toString();
  }
}
