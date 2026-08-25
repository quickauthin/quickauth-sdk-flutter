import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:flutter/services.dart';

/// Receives a WhatsApp zero-tap or one-tap authentication code.
///
/// WhatsApp does not send these over SMS. It broadcasts the code to the app named in the
/// template's `supported_apps`, matched on package name and the 11-character signing hash, so
/// [SmsRetriever] never sees it — the two are different delivery channels that happen to share
/// the same app hash.
///
/// Android only. Zero-tap and one-tap are Android features; on every other platform this is an
/// empty stream, so callers can listen unconditionally rather than branching on the platform.
///
/// The code can arrive before Flutter is running — that is the point of zero-tap — so the
/// native receiver holds it and delivers it the moment [observe] is listened to.
class WhatsAppOtpRetriever {
  /// [channel] is injectable so tests can drive the platform side.
  ///
  /// [supportedOverride] exists because the platform gate below reads dart:io, which reports
  /// the host in a test run — every stream assertion would otherwise exercise the empty-stream
  /// branch and prove nothing. Test-only; production always takes the real check.
  WhatsAppOtpRetriever({MethodChannel? channel, @visibleForTesting bool? supportedOverride})
      : _channel = channel ?? const MethodChannel(SmsChannel.method),
        _supportedOverride = supportedOverride;

  final MethodChannel _channel;
  final bool? _supportedOverride;
  final EventChannel _eventChannel = const EventChannel(SmsChannel.whatsappEvents);
  Stream<String>? _stream;

  /// Android only. False on web without touching [Platform], which throws there.
  bool get isSupported => _supportedOverride ?? (!kIsWeb && Platform.isAndroid);

  /// Codes as WhatsApp delivers them — already the code, not a message to parse.
  ///
  /// Broadcast, so a widget and a service can both listen; the underlying channel is created
  /// once and shared.
  Stream<String> observe() {
    if (!isSupported) return const Stream<String>.empty();
    return _stream ??= _eventChannel
        .receiveBroadcastStream()
        .map(normalise)
        .where((code) => code.isNotEmpty)
        .asBroadcastStream();
  }

  /// What arrives from the platform, cleaned up.
  ///
  /// A padded code fails verification for no reason the user can see, and an empty broadcast
  /// would otherwise clear the OTP field or submit nothing.
  @visibleForTesting
  static String normalise(Object? event) => event is String ? event.trim() : '';

  /// Tell WhatsApp a code is about to be requested, and that this app may receive it.
  ///
  /// Zero-tap does not work without this. Meta requires the handshake to be broadcast BEFORE
  /// the authentication template is sent — without it WhatsApp shows the message and simply
  /// never broadcasts the code, with every other check passing and nothing to explain it.
  ///
  /// The handshake expires after ten minutes, so it is sent per request rather than once at
  /// startup. Returns the request id WhatsApp will echo back with the code, or null where
  /// this is not supported or the broadcast failed.
  ///
  /// Never throws: a missing handshake costs auto-read, not the login.
  Future<String?> sendHandshake() async {
    if (!isSupported) return null;
    try {
      return await _channel.invokeMethod<String>('sendWhatsAppOtpHandshake');
    } on PlatformException {
      return null;
    }
  }

  /// Discard any code held natively from an earlier attempt.
  ///
  /// Call when requesting a fresh OTP. Without it, a code that arrived after the user gave up
  /// on a previous attempt would be delivered against the new request and fail verification
  /// for reasons the user cannot see.
  Future<void> clearPending() async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<bool>('clearWhatsAppOtp');
    } on PlatformException {
      // Older embedding without the method. Nothing is held on those builds either, so
      // failing here would break a call that has nothing to do.
    }
  }
}

/// Channel names, in one place so Dart and Kotlin cannot drift apart.
class SmsChannel {
  const SmsChannel._();
  /// Method channel shared by the SMS and WhatsApp paths.
  static const String method = 'io.quickauth/sms_retriever';

  /// WhatsApp zero-tap / one-tap codes, already extracted.
  static const String whatsappEvents = 'io.quickauth/whatsapp_otp/events';
}
