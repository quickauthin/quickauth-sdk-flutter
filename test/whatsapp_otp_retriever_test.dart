import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quickauth_flutter/quickauth_flutter.dart';
import 'package:quickauth_flutter/src/auth/sms_retriever.dart';

/// WhatsApp's zero-tap / one-tap code path.
///
/// WhatsApp broadcasts the code to the app rather than sending an SMS, so SmsRetriever never
/// sees it and it was previously dropped. These pin the contract the native side delivers on.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const eventChannel = MethodChannel(SmsChannel.whatsappEvents);
  final binding = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  /// Push codes through the platform side of the event channel, as the receiver would.
  void emit(List<String> codes) {
    binding.setMockMethodCallHandler(eventChannel, (call) async {
      if (call.method == 'listen') {
        for (final c in codes) {
          await binding.handlePlatformMessage(
            SmsChannel.whatsappEvents,
            const StandardMethodCodec().encodeSuccessEnvelope(c),
            (_) {},
          );
        }
      }
      return null;
    });
  }

  tearDown(() => binding.setMockMethodCallHandler(eventChannel, null));

  test('delivers the code WhatsApp broadcast', () async {
    emit(['483920']);
    final codes = await WhatsAppOtpRetriever(supportedOverride: true).observe().take(1).toList();
    expect(codes, ['483920']);
  });

  test('ignores empty broadcasts rather than surfacing a blank code', () async {
    // A malformed broadcast should not clear the user's OTP field or submit nothing.
    emit(['', '   ', '112233']);
    final codes = await WhatsAppOtpRetriever(supportedOverride: true).observe().take(1).toList();
    expect(codes, ['112233']);
  });

  test('trims, because a padded code fails verification for no visible reason', () async {
    emit([' 998877 ']);
    final codes = await WhatsAppOtpRetriever(supportedOverride: true).observe().take(1).toList();
    expect(codes, ['998877']);
  });

  test('is a broadcast stream, so a field and a service can both listen', () async {
    emit(['246810']);
    final r = WhatsAppOtpRetriever(supportedOverride: true);
    final stream = r.observe();
    final a = stream.take(1).toList();
    final b = stream.take(1).toList();
    expect(await a, ['246810']);
    expect(await b, ['246810']);
  });

  test('normalise trims and rejects anything that is not a code', () {
    expect(WhatsAppOtpRetriever.normalise(' 483920 '), '483920');
    expect(WhatsAppOtpRetriever.normalise(''), '');
    expect(WhatsAppOtpRetriever.normalise(null), '');
    expect(WhatsAppOtpRetriever.normalise(42), '');
  });

  test('is an empty stream off Android, so callers need not branch', () {
    expect(WhatsAppOtpRetriever(supportedOverride: false).isSupported, isFalse);
  });

  test('the SMS and WhatsApp channels stay separate', () {
    // They carry different things — a whole message body versus an extracted code — and
    // merging them would hand every existing SMS listener a shape it was never written for.
    expect(SmsRetriever.eventChannelName, isNot(SmsChannel.whatsappEvents));
  });
}
