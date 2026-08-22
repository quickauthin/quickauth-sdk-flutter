import 'package:flutter_test/flutter_test.dart';
import 'package:quickauth_flutter/src/auth/sms_retriever.dart';

/// Pulling the OTP out of an SMS body.
///
/// This was `firstMatch` over a bare `\d{4,8}` — the FIRST digit run in the message. Indian
/// transactional SMS routinely leads with an order id, a reference number or an amount, so the
/// field auto-filled the wrong number and the user watched it happen. There was no test file
/// for this at all, which is how it survived.
void main() {
  String extract(String body) => SmsRetriever.extractCode(body);

  group('keyword-anchored', () {
    test('takes the code after the keyword, not the order number before it', () {
      // The case that started this. "4471029" is nearer the start; "483920" is the code.
      expect(extract('Your OTP for order 4471029 is 483920'), '483920');
    });

    test('plain "your OTP is"', () {
      expect(extract('Your OTP is 483920. Do not share it.'), '483920');
    });

    test('colon separator', () {
      expect(extract('code: 4821'), '4821');
    });

    test('dash separator', () {
      expect(extract('Verification code - 123456'), '123456');
    });

    test('is case-insensitive', () {
      expect(extract('YOUR OTP IS 998877'), '998877');
    });

    test('matches "pin" and "password" too', () {
      expect(extract('Your PIN is 4321'), '4321');
      expect(extract('Password: 87654321'), '87654321');
    });

    test('takes the last keyword match when a body carries two', () {
      // A resend or a quoted earlier message. The newest code is the one that works.
      expect(extract('Old code 111111 expired. Your new code is 222222'), '222222');
    });
  });

  group('fallback when no keyword is present', () {
    test('takes the LAST standalone run, not the first', () {
      // Senders put reference numbers ahead of the code far more often than after it.
      expect(extract('Ref 8899001 — 4455'), '4455');
    });

    test('a bare code still works', () {
      expect(extract('483920'), '483920');
    });
  });

  group('what must not be mistaken for a code', () {
    test('a 10-digit mobile number is skipped, not truncated', () {
      // Without word boundaries this returns "9876543" — a plausible-looking 7-digit code.
      expect(extract('Sent to 9876543210. Your OTP is 483920'), '483920');
    });

    test('a bare 10-digit number yields nothing rather than a slice of it', () {
      expect(extract('Call 9876543210 for help'), '');
    });

    test('the 11-char app hash is stripped before scanning', () {
      // The hash is base64 over [A-Za-z0-9+/], so it can end in a digit run flanked by + or /
      // that reads exactly like a standalone code.
      expect(extract('Your OTP is 483920\nFA+9qCX9VSu'), '483920');
    });

    test('app hash does not win the fallback path either', () {
      expect(extract('Ref 8899001 4455 FA+123456/8'), '4455');
    });

    test('a message with no digits at all returns empty', () {
      expect(extract('Welcome to QuickAuth'), '');
    });

    test('an empty body returns empty', () {
      expect(extract(''), '');
    });
  });
}
