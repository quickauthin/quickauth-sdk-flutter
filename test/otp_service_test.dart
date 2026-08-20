import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:quickauth_flutter/quickauth_flutter.dart';
import 'package:quickauth_flutter/src/auth/auth_event.dart';
import 'package:quickauth_flutter/src/auth/otp_service.dart';
import 'package:quickauth_flutter/src/auth/sms_retriever.dart';
import 'package:quickauth_flutter/src/core/api_client.dart';
import 'package:quickauth_flutter/src/core/config.dart';
import 'package:quickauth_flutter/src/core/storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeSmsRetriever extends SmsRetriever {
  _FakeSmsRetriever()
      : super(channel: const MethodChannel('io.quickauth/test_noop'));

  int starts = 0;

  @override
  Future<bool> start() async {
    starts++;
    return true;
  }

  @override
  Stream<String> observe() => const Stream<String>.empty();

  @override
  Future<String?> getAppHash() async => null;
}

String _fakeJwt({required int exp, String sub = 'sess_test'}) {
  String b64(Map<String, dynamic> m) {
    final s = base64Url.encode(utf8.encode(jsonEncode(m)));
    return s.replaceAll('=', '');
  }
  final header = b64(<String, dynamic>{'alg': 'HS256', 'typ': 'JWT'});
  final payload = b64(<String, dynamic>{'sub': sub, 'exp': exp});
  return '$header.$payload.sig';
}

QuickAuthConfig _config({AuthEventHandler? onAuthEvent}) => QuickAuthConfig(
      onTokenExpiry: () async => _fakeJwt(
        exp: DateTime.now().add(const Duration(minutes: 10)).millisecondsSinceEpoch ~/
            1000,
      ),
      onAuthEvent: onAuthEvent,
    );

QuickAuthApiClient _client(MockClient mock, QuickAuthConfig cfg, {String? seedToken}) {
  final tm = TokenManager(
    provider: cfg.onTokenExpiry,
    initialToken: seedToken ??
        _fakeJwt(
          exp: DateTime.now()
                  .add(const Duration(minutes: 10))
                  .millisecondsSinceEpoch ~/
              1000,
        ),
  );
  return QuickAuthApiClient(config: cfg, tokenManager: tm, httpClient: mock);
}

QuickAuthOtpService _service(MockClient mock, {
  AuthEventHandler? onAuthEvent,
  String? seedToken,
  QuickAuthConsent? consent,
}) {
  late QuickAuthConfig cfg;
  cfg = _config(onAuthEvent: onAuthEvent);
  return QuickAuthOtpService(
    apiClient: _client(mock, cfg, seedToken: seedToken),
    smsRetriever: _FakeSmsRetriever(),
    storage: QuickAuthStorage(),
    configProvider: () => cfg,
    consent: consent ?? QuickAuthConsent(storage: QuickAuthStorage(), initial: false),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('QuickAuthOtpService.initiate', () {
    test('posts phone + channel and emits OtpSent on OTP_SENT state', () async {
      late http.Request lastRequest;
      final mock = MockClient((req) async {
        lastRequest = req;
        return http.Response(
          jsonEncode(<String, dynamic>{
            'state': 'OTP_SENT',
            'sessionId': 'sess_abc',
            'expiresIn': 300,
            'deviceToken': 'dtok_new',
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });

      final events = <AuthEvent>[];
      final service = _service(mock, onAuthEvent: events.add);
      await service.initiate(phone: '+919876543210', channel: OtpChannel.whatsapp);
      // Drain microtasks so the queued event fires.
      await Future<void>.delayed(Duration.zero);

      expect(lastRequest.url.path, '/v1/sdk/auth/initiate');
      final body = jsonDecode(lastRequest.body) as Map<String, dynamic>;
      expect(body['phone'], '+919876543210');
      expect(body['channel'], 'whatsapp');

      expect(events, hasLength(1));
      final ev = events[0] as OtpSentEvent;
      expect(ev.sessionId, 'sess_abc');
      expect(ev.channel, OtpChannel.whatsapp);
      expect(ev.expiresIn, 300);
    });

    test('omits deviceInfo when consent has not been granted', () async {
      late http.Request lastRequest;
      final mock = MockClient((req) async {
        lastRequest = req;
        return http.Response(
          jsonEncode(<String, dynamic>{
            'state': 'OTP_SENT',
            'sessionId': 'sess_nc',
            'expiresIn': 300,
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final service = _service(mock);
      await service.initiate(phone: '+919876543210');

      final body = jsonDecode(lastRequest.body) as Map<String, dynamic>;
      expect(body.containsKey('deviceInfo'), isFalse);
    });

    test('attaches deviceInfo once consent is granted', () async {
      late http.Request lastRequest;
      final mock = MockClient((req) async {
        lastRequest = req;
        return http.Response(
          jsonEncode(<String, dynamic>{
            'state': 'OTP_SENT',
            'sessionId': 'sess_c',
            'expiresIn': 300,
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final consent = QuickAuthConsent(storage: QuickAuthStorage(), initial: true);
      final service = _service(mock, consent: consent);
      await service.initiate(phone: '+919876543210');

      final body = jsonDecode(lastRequest.body) as Map<String, dynamic>;
      expect(body['deviceInfo'], isA<Map<String, dynamic>>());
      expect((body['deviceInfo'] as Map<String, dynamic>)['platform'], isNotNull);
    });

    test('emits Verified directly when backend reports OneTap', () async {
      final mock = MockClient((req) async => http.Response(
            jsonEncode(<String, dynamic>{
              'state': 'VERIFIED',
              'sessionId': 'req_verified',
              'expiresIn': 300,
              'deviceToken': 'dtok_v',
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          ));
      final events = <AuthEvent>[];
      final service = _service(mock, onAuthEvent: events.add);

      await service.initiate(phone: '+919876543210');
      await Future<void>.delayed(Duration.zero);

      expect(events, hasLength(1));
      expect(events[0], isA<VerifiedEvent>());
      expect((events[0] as VerifiedEvent).requestId, 'req_verified');
    });

    test('replays stored deviceToken on subsequent initiate', () async {
      var callCount = 0;
      final bodies = <Map<String, dynamic>>[];
      final mock = MockClient((req) async {
        callCount++;
        bodies.add(jsonDecode(req.body) as Map<String, dynamic>);
        return http.Response(
          jsonEncode(<String, dynamic>{
            'state': 'OTP_SENT',
            'sessionId': 'sess_$callCount',
            'expiresIn': 300,
            'deviceToken': 'dtok_abc',
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final service = _service(mock);

      await service.initiate(phone: '+919876543210');
      await service.initiate(phone: '+919876543210');

      expect(bodies[0]['deviceToken'], isNull);
      expect(bodies[1]['deviceToken'], 'dtok_abc');
    });

    test('rejects non-E.164 phones', () async {
      final service = _service(MockClient((_) async => http.Response('{}', 200)));
      expect(
        () => service.initiate(phone: 'bad'),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('QuickAuthOtpService.submitOtp', () {
    test('emits Verified on success and forwards deviceToken', () async {
      var callIndex = 0;
      final bodies = <Map<String, dynamic>>[];
      final mock = MockClient((req) async {
        bodies.add(jsonDecode(req.body) as Map<String, dynamic>);
        callIndex++;
        if (callIndex == 1) {
          return http.Response(
            jsonEncode(<String, dynamic>{
              'state': 'OTP_SENT',
              'sessionId': 'sess_1',
              'expiresIn': 300,
              'deviceToken': 'dtok_v',
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }
        return http.Response(
          jsonEncode(<String, dynamic>{
            'state': 'VERIFIED',
            'verified': true,
            'requestId': 'req_abc',
            'message': 'Verified successfully',
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final events = <AuthEvent>[];
      final service = _service(mock, onAuthEvent: events.add);

      await service.initiate(phone: '+919876543210');
      await service.submitOtp('123456');
      await Future<void>.delayed(Duration.zero);

      expect(events.map((e) => e.runtimeType.toString()),
          equals(['OtpSentEvent', 'VerifiedEvent']));
      expect(bodies[1]['sessionId'], 'sess_1');
      expect(bodies[1]['code'], '123456');
      expect(bodies[1]['deviceToken'], 'dtok_v');
    });

    test('emits OtpFailed on wrong code, retry-able', () async {
      var callIndex = 0;
      final mock = MockClient((req) async {
        callIndex++;
        if (callIndex == 1) {
          return http.Response(
            jsonEncode(<String, dynamic>{
              'state': 'OTP_SENT',
              'sessionId': 'sess_1',
              'expiresIn': 300,
              'deviceToken': 'dtok_v',
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }
        if (callIndex == 2) {
          return http.Response(
            jsonEncode(<String, dynamic>{
              'state': 'OTP_FAILED',
              'verified': false,
              'requestId': 'sess_1',
              'message': 'Invalid OTP. 2 attempt(s) remaining.',
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }
        return http.Response(
          jsonEncode(<String, dynamic>{
            'state': 'VERIFIED',
            'verified': true,
            'requestId': 'req_abc',
            'message': 'Verified successfully',
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final events = <AuthEvent>[];
      final service = _service(mock, onAuthEvent: events.add);

      await service.initiate(phone: '+919876543210');
      await service.submitOtp('000000');
      await service.submitOtp('123456');
      await Future<void>.delayed(Duration.zero);

      expect(events.map((e) => e.runtimeType.toString()),
          equals(['OtpSentEvent', 'OtpFailedEvent', 'VerifiedEvent']));
    });

    test('submitOtp before initiate throws StateError', () async {
      final service = _service(MockClient((_) async => http.Response('{}', 200)));
      expect(
        () => service.submitOtp('123456'),
        throwsA(isA<StateError>()),
      );
    });

    test('submitOtp rejects malformed code', () async {
      final service = _service(MockClient((_) async => http.Response('{}', 200)));
      expect(
        () => service.submitOtp('abc'),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('QuickAuthOtpService.reset', () {
    test('with forgetDevice clears stored deviceToken', () async {
      final bodies = <Map<String, dynamic>>[];
      final mock = MockClient((req) async {
        bodies.add(jsonDecode(req.body) as Map<String, dynamic>);
        return http.Response(
          jsonEncode(<String, dynamic>{
            'state': 'OTP_SENT',
            'sessionId': 'sess_x',
            'expiresIn': 300,
            'deviceToken': 'dtok_x',
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final service = _service(mock);

      await service.initiate(phone: '+919876543210');
      await service.reset(forgetDevice: true);
      await service.initiate(phone: '+919876543210');

      expect(bodies[0]['deviceToken'], isNull);
      expect(bodies[1]['deviceToken'], isNull,
          reason: 'forgetDevice should drop the token');
    });
  });

  group('QuickAuthOtpService.error path', () {
    test('emits AuthError on transport failure', () async {
      final mock = MockClient((_) async => http.Response(
            jsonEncode(<String, dynamic>{'message': 'boom'}),
            500,
            headers: <String, String>{'content-type': 'application/json'},
          ));
      final events = <AuthEvent>[];
      final service = _service(mock, onAuthEvent: events.add);

      await expectLater(
        () => service.initiate(phone: '+919876543210'),
        throwsA(isA<QuickAuthApiException>()),
      );
      await Future<void>.delayed(Duration.zero);

      expect(events, hasLength(1));
      final ev = events[0] as AuthErrorEvent;
      expect(ev.code, 'SERVER_ERROR');
    });
  });

  group('OtpChannel wire mapping', () {
    test('stable strings', () {
      expect(OtpChannel.auto.wire, 'auto');
      expect(OtpChannel.sms.wire, 'sms');
      expect(OtpChannel.whatsapp.wire, 'whatsapp');
    });
  });
}
