import 'dart:async';

import 'package:flutter/services.dart';

/// Launches the system WhatsApp deep-link for a "Login with WhatsApp" flow.
///
/// Implemented through the same MethodChannel as the SMS retriever to keep the
/// dependency tree small (no `url_launcher` requirement).
class WhatsAppLogin {
  /// Creates the helper. Inject [channel] in tests.
  WhatsAppLogin({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(channelName);

  /// Method-channel name shared with the native plugins.
  static const String channelName = 'io.quickauth/sms_retriever';

  final MethodChannel _channel;

  /// Open WhatsApp pointing at [businessNumber] with [prefilledMessage].
  ///
  /// `businessNumber` may be supplied with or without a leading `+`.
  /// [prefilledMessage] defaults to the magic string the QuickAuth backend
  /// recognises for click-to-WhatsApp login.
  Future<bool> open({
    required String businessNumber,
    String prefilledMessage = 'Hi, I want to log in.',
  }) async {
    final normalized = businessNumber.replaceAll(RegExp(r'[^0-9]'), '');
    final url =
        'https://wa.me/$normalized?text=${Uri.encodeComponent(prefilledMessage)}';
    try {
      final ok = await _channel.invokeMethod<bool>(
        'launchUrl',
        <String, dynamic>{'url': url},
      );
      return ok ?? false;
    } on PlatformException {
      return false;
    }
  }
}
