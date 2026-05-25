import '../core/config.dart';

/// Typed lifecycle events emitted by the headless auth state machine.
///
/// Subscribe once via [QuickAuthConfig.onAuthEvent] and switch on the
/// subtype to drive your UI:
///
/// ```dart
/// QuickAuth.init(
///   onTokenExpiry: fetchToken,
///   onAuthEvent: (event) => switch (event) {
///     OtpSentEvent()     => showOtpInput(),
///     OtpAutoReadEvent() => prefillInput(event.code),
///     VerifiedEvent()    => finishLogin(event.requestId),
///     OtpFailedEvent()   => showError(event.message),
///     AuthErrorEvent()   => showError(event.message),
///   },
/// );
/// ```
///
/// Each `initiate()` call produces at most one terminal event
/// ([VerifiedEvent] / [OtpFailedEvent] / [AuthErrorEvent]). Calling
/// `initiate()` again resets the state machine.
sealed class AuthEvent {
  const AuthEvent();
}

/// Backend dispatched an OTP. Render the input UI.
class OtpSentEvent extends AuthEvent {
  /// Creates an OTP-sent event.
  const OtpSentEvent({
    required this.sessionId,
    required this.channel,
    required this.expiresIn,
  });

  /// Opaque session id (forwarded as `sessionId` on the verify call).
  final String sessionId;

  /// Delivery channel requested.
  final OtpChannel channel;

  /// Seconds the OTP entry session stays open.
  final int expiresIn;
}

/// Inbound SMS auto-read (Android SMS Retriever). The SDK does NOT
/// auto-submit — the merchant decides whether to forward to `submitOtp`.
class OtpAutoReadEvent extends AuthEvent {
  /// Creates an auto-read event.
  const OtpAutoReadEvent(this.code);

  /// The OTP code extracted from the SMS.
  final String code;
}

/// User is authenticated. Covers fresh OTP success AND silent device-trust
/// re-auth. Forward [requestId] to the merchant backend for server-to-
/// server confirmation.
class VerifiedEvent extends AuthEvent {
  /// Creates a verified event.
  const VerifiedEvent({required this.requestId, this.message});

  /// Opaque id the merchant backend confirms server-to-server.
  final String requestId;

  /// Human-readable status. Optional — present on /verify path; absent
  /// when OneTap fires on /initiate.
  final String? message;
}

/// Submitted code was rejected. SDK stays in awaiting-OTP state so the
/// user can retry.
class OtpFailedEvent extends AuthEvent {
  /// Creates an OTP-failed event.
  const OtpFailedEvent(this.message);

  /// Human-readable failure reason ("Invalid OTP. 2 attempt(s) remaining.").
  final String message;
}

/// Transport / rate-limit / unexpected failure. Final for this attempt.
class AuthErrorEvent extends AuthEvent {
  /// Creates an error event.
  const AuthErrorEvent({required this.code, required this.message});

  /// Short machine-readable code (`RATE_LIMITED`, `SERVER_ERROR`,
  /// `NETWORK_ERROR`, `CLIENT_ERROR`, `UNKNOWN_ERROR`).
  final String code;

  /// Human-readable error description.
  final String message;
}

/// Signature for the merchant-supplied auth event handler.
typedef AuthEventHandler = void Function(AuthEvent event);
