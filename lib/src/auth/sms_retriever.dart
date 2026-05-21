import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Bridge to the native Android SMS Retriever API.
///
/// On iOS the platform handles `oneTimeCode` autofill via TextField props, so
/// every method here returns `null` / a no-op stream.
class SmsRetriever {
  /// Creates a retriever. Inject [channel] in tests.
  SmsRetriever({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(channelName);

  /// Method-channel name shared with the Android plugin.
  static const String channelName = 'io.quickauth/sms_retriever';

  /// Event-channel name for parsed SMS payloads.
  static const String eventChannelName = 'io.quickauth/sms_retriever/events';

  final MethodChannel _channel;
  final EventChannel _eventChannel = const EventChannel(eventChannelName);

  Stream<String>? _stream;

  /// Whether SMS Retriever is supported on the current platform.
  bool get isSupported => !kIsWeb && Platform.isAndroid;

  /// Start a retrieval session. Resolves once the native side has registered
  /// the broadcast receiver. No-op + `false` on iOS.
  Future<bool> start() async {
    if (!isSupported) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('start');
      return ok ?? false;
    } on PlatformException catch (e) {
      debugPrint('[QuickAuth] SmsRetriever.start failed: ${e.message}');
      return false;
    }
  }

  /// Fetch the app-signing hash that must appear at the end of every OTP SMS
  /// body for SMS Retriever to deliver the message.
  ///
  /// Returns `null` on iOS / web.
  Future<String?> getAppHash() async {
    if (!isSupported) return null;
    try {
      return await _channel.invokeMethod<String>('getAppHash');
    } on PlatformException {
      return null;
    }
  }

  /// Stream of OTP codes parsed from inbound SMS. Empty stream on iOS.
  Stream<String> observe() {
    if (!isSupported) return const Stream<String>.empty();
    return _stream ??= _eventChannel
        .receiveBroadcastStream()
        .map((dynamic e) => e?.toString() ?? '')
        .where((String s) => s.isNotEmpty)
        .map(_extractCode)
        .where((String s) => s.isNotEmpty);
  }

  static final RegExp _digits = RegExp(r'\d{4,8}');

  static String _extractCode(String body) {
    final m = _digits.firstMatch(body);
    return m?.group(0) ?? '';
  }
}
