import 'dart:async';

import '../core/api_client.dart';
import '../core/config.dart';
import 'sms_retriever.dart';

/// Result of `POST /v1/sdk/auth/initiate`.
class OtpSession {
  /// Creates a session record.
  const OtpSession({
    required this.sessionId,
    required this.expiresIn,
    this.channelUsed,
  });

  /// Decode from API JSON.
  factory OtpSession.fromJson(Map<String, dynamic> json) => OtpSession(
        sessionId: json['sessionId'] as String,
        expiresIn: (json['expiresIn'] as num?)?.toInt() ?? 300,
        channelUsed: json['channelUsed'] as String?,
      );

  /// Server-issued session id passed back to `verifyOTP`.
  final String sessionId;

  /// Seconds until the OTP expires.
  final int expiresIn;

  /// Channel the backend actually used (`sms` / `whatsapp`).
  final String? channelUsed;
}

/// Result of `POST /v1/sdk/auth/verify`.
class OtpResult {
  /// Creates a verify result.
  const OtpResult({
    required this.jwt,
    required this.expiresIn,
    this.userId,
  });

  /// Decode from API JSON.
  factory OtpResult.fromJson(Map<String, dynamic> json) => OtpResult(
        jwt: json['jwt'] as String,
        expiresIn: (json['expiresIn'] as num?)?.toInt() ?? 3600,
        userId: json['userId'] as String?,
      );

  /// Signed user JWT — pass this to your app backend.
  final String jwt;

  /// Seconds until the JWT expires.
  final int expiresIn;

  /// Optional resolved user id.
  final String? userId;
}

/// Headless OTP API. Available as `QuickAuth.auth`.
class QuickAuthOtpService {
  /// Creates the service.
  QuickAuthOtpService({
    required QuickAuthApiClient apiClient,
    required SmsRetriever smsRetriever,
  })  : _api = apiClient,
        _sms = smsRetriever;

  final QuickAuthApiClient _api;
  final SmsRetriever _sms;

  /// Last session — handy when the host doesn't want to thread state.
  OtpSession? lastSession;

  /// Issue an OTP via [channel]. On Android, kicks off SMS Retriever in
  /// parallel so [observeOTP] starts emitting as soon as the SMS arrives.
  Future<OtpSession> startOTP({
    required String phone,
    OtpChannel channel = OtpChannel.auto,
  }) async {
    // Fire-and-forget — failure here must not block OTP delivery.
    unawaited(_sms.start());

    final json = await _api.post('/v1/sdk/auth/initiate', <String, dynamic>{
      'phone': phone,
      'channel': channel.wire,
    });
    final session = OtpSession.fromJson(json);
    lastSession = session;
    return session;
  }

  /// Verify a code. Pass `sessionId` from [startOTP], or omit it to use the
  /// last session.
  Future<OtpResult> verifyOTP({
    required String code,
    String? sessionId,
  }) async {
    final sid = sessionId ?? lastSession?.sessionId;
    if (sid == null) {
      throw QuickAuthApiException(
        message: 'No active session. Call startOTP first.',
      );
    }
    final json = await _api.post('/v1/sdk/auth/verify', <String, dynamic>{
      'sessionId': sid,
      'code': code,
    });
    return OtpResult.fromJson(json);
  }

  /// Stream of OTPs auto-read from inbound SMS (Android-only).
  Stream<String> observeOTP() => _sms.observe();

  /// Get the Android app-signing hash that must terminate every OTP SMS.
  Future<String?> getAppHash() => _sms.getAppHash();
}
