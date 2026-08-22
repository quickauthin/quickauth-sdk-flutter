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
        .map(extractCode)
        .where((String s) => s.isNotEmpty);
  }

  /// Keyword-anchored code, e.g. "your OTP is 483920" or "code: 4821".
  ///
  /// Only punctuation, whitespace and a short "is"/"are" may sit between the keyword and the
  /// digits. A looser gap swallows the wrong number in bodies like
  /// "Your OTP for order 4471029 is 483920", where an unrelated reference number is the nearer
  /// match — there the gap fails and we fall through to [_fallbackCode].
  static final RegExp _keywordCode = RegExp(
    r'(?:otp|code|pin|password)[\s:=.,\-\u2013\u2014]{0,6}(?:is|are)?'
    r'[\s:=.,\-\u2013\u2014]{0,6}\b(\d{4,8})\b',
    caseSensitive: false,
  );

  /// Any standalone 4-8 digit run. The word boundaries keep this off part of a longer run, so
  /// 10-digit mobile numbers and 12-digit E.164 numbers are skipped rather than truncated into
  /// something that looks like a plausible code.
  static final RegExp _fallbackCode = RegExp(r'\b(\d{4,8})\b');

  /// The 11-char app hash that terminates every SMS Retriever body. It is base64 over
  /// [A-Za-z0-9+/], so it can contain a digit run flanked by `+` or `/` that reads exactly like
  /// a standalone code. Strip it before scanning.
  static final RegExp _appHashSuffix = RegExp(r'\s+[A-Za-z0-9+/]{11}\s*$');

  /// Pull the OTP out of an SMS body.
  ///
  /// Was `firstMatch` over a bare `\d{4,8}`, which returned the first digit run in the
  /// message — so "Your OTP for order 4471029 is 483920" auto-filled the order number and the
  /// user watched the wrong code appear in the field.
  ///
  /// Prefers a keyword-anchored match; otherwise takes the **last** standalone run. Last, not
  /// first: senders put reference numbers, order ids and amounts ahead of the code far more
  /// often than after it.
  @visibleForTesting
  static String extractCode(String body) {
    final stripped = body.replaceAll(_appHashSuffix, '');
    final keyed = _keywordCode.allMatches(stripped);
    if (keyed.isNotEmpty) return keyed.last.group(1) ?? '';
    final runs = _fallbackCode.allMatches(stripped);
    return runs.isEmpty ? '' : (runs.last.group(1) ?? '');
  }
}
