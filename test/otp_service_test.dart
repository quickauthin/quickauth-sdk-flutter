import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:quickauth/quickauth.dart';
import 'package:quickauth/src/auth/otp_service.dart';
import 'package:quickauth/src/auth/sms_retriever.dart';
import 'package:quickauth/src/core/api_client.dart';
import 'package:quickauth/src/core/config.dart';

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

/// Build a JWT with the given `exp` (seconds since epoch). Signature is
/// fake — the SDK only base64-decodes the payload, never verifies the sig.
String _fakeJwt({required int exp, String sub = 'sess_test'}) {
  String b64(Map<String, dynamic> m) {
    final s = base64Url.encode(utf8.encode(jsonEncode(m)));
    return s.replaceAll('=', '');
  }

  final header = b64(<String, dynamic>{'alg': 'HS256', 'typ': 'JWT'});
  final payload = b64(<String, dynamic>{'sub': sub, 'exp': exp});
  return '$header.$payload.sig';
}

QuickAuthConfig _config() => QuickAuthConfig(
      onTokenExpiry: () async => _fakeJwt(
        exp: DateTime.now().add(const Duration(minutes: 10)).millisecondsSinceEpoch ~/
            1000,
      ),
    );

QuickAuthApiClient _client(MockClient mock, {String? seedToken}) {
  final cfg = _config();
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('QuickAuthOtpService.startOTP', () {
    test('posts phone + channel and parses session', () async {
      late http.Request lastRequest;
      final mock = MockClient((req) async {
        lastRequest = req;
        return http.Response(
          jsonEncode(<String, dynamic>{
            'sessionId': 'sess_abc',
            'expiresIn': 300,
            'channelUsed': 'whatsapp',
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final seed = _fakeJwt(
        exp: DateTime.now().add(const Duration(minutes: 9)).millisecondsSinceEpoch ~/
            1000,
        sub: 'sess_seed',
      );
      final service = QuickAuthOtpService(
        apiClient: _client(mock, seedToken: seed),
        smsRetriever: _FakeSmsRetriever(),
      );

      final session = await service.startOTP(
        phone: '+919876543210',
        channel: OtpChannel.whatsapp,
      );

      expect(session.sessionId, 'sess_abc');
      expect(session.expiresIn, 300);
      expect(session.channelUsed, 'whatsapp');
      expect(lastRequest.url.path, '/v1/sdk/auth/initiate');
      // Bearer header is the load-bearing change in this SDK release.
      expect(lastRequest.headers['authorization'], 'Bearer $seed');
      expect(lastRequest.headers['content-type'], contains('application/json'));
      final body = jsonDecode(lastRequest.body) as Map<String, dynamic>;
      expect(body['phone'], '+919876543210');
      expect(body['channel'], 'whatsapp');
    });

    test('verifyOTP posts sessionId + code and returns jwt', () async {
      late http.Request lastReq;
      final mock = MockClient((req) async {
        lastReq = req;
        expect(req.url.path, '/v1/sdk/auth/verify');
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        expect(body['sessionId'], 'sess_abc');
        expect(body['code'], '123456');
        return http.Response(
          jsonEncode(<String, dynamic>{
            'jwt': 'eyJ.signed',
            'expiresIn': 3600,
            'userId': 'usr_1',
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final service = QuickAuthOtpService(
        apiClient: _client(mock),
        smsRetriever: _FakeSmsRetriever(),
      );

      final result = await service.verifyOTP(
        sessionId: 'sess_abc',
        code: '123456',
      );
      expect(result.jwt, 'eyJ.signed');
      expect(result.expiresIn, 3600);
      expect(result.userId, 'usr_1');
      expect(lastReq.headers['authorization'], startsWith('Bearer '));
    });

    test('non-2xx response throws QuickAuthApiException with message', () async {
      final mock = MockClient((_) async => http.Response(
            jsonEncode(<String, dynamic>{
              'message': 'Invalid phone',
              'code': 'invalid_phone',
            }),
            422,
            headers: <String, String>{'content-type': 'application/json'},
          ));
      final service = QuickAuthOtpService(
        apiClient: _client(mock),
        smsRetriever: _FakeSmsRetriever(),
      );

      expect(
        () => service.startOTP(phone: 'bad'),
        throwsA(isA<QuickAuthApiException>()
            .having((e) => e.statusCode, 'statusCode', 422)
            .having((e) => e.code, 'code', 'invalid_phone')
            .having((e) => e.message, 'message', 'Invalid phone')),
      );
    });

    test('verifyOTP without active session throws', () async {
      final service = QuickAuthOtpService(
        apiClient: _client(MockClient((_) async => http.Response('{}', 200))),
        smsRetriever: _FakeSmsRetriever(),
      );
      expect(
        () => service.verifyOTP(code: '111111'),
        throwsA(isA<QuickAuthApiException>()),
      );
    });

    test('on 401 the client invalidates token + retries once', () async {
      // First provider call returns t1 (rejected), second returns t2 (ok).
      final tokens = <String>[
        _fakeJwt(
          exp: DateTime.now()
                  .add(const Duration(minutes: 10))
                  .millisecondsSinceEpoch ~/
              1000,
          sub: 't1',
        ),
        _fakeJwt(
          exp: DateTime.now()
                  .add(const Duration(minutes: 10))
                  .millisecondsSinceEpoch ~/
              1000,
          sub: 't2',
        ),
      ];
      var providerCalls = 0;
      final calls = <String>[];
      final mock = MockClient((req) async {
        calls.add(req.headers['authorization']!);
        if (calls.length == 1) {
          return http.Response('{"message":"unauth"}', 401,
              headers: <String, String>{'content-type': 'application/json'});
        }
        return http.Response(
          jsonEncode(<String, dynamic>{
            'sessionId': 'sess_after_retry',
            'expiresIn': 300,
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final cfg = QuickAuthConfig(onTokenExpiry: () async {
        providerCalls++;
        return tokens.removeAt(0);
      });
      final tm =
          TokenManager(provider: cfg.onTokenExpiry, initialToken: null);
      final api = QuickAuthApiClient(
          config: cfg, tokenManager: tm, httpClient: mock);
      final service = QuickAuthOtpService(
        apiClient: api,
        smsRetriever: _FakeSmsRetriever(),
      );

      final s = await service.startOTP(phone: '+911111111111');
      expect(s.sessionId, 'sess_after_retry');
      expect(calls.length, 2);
      expect(calls[0], startsWith('Bearer '));
      expect(calls[1], startsWith('Bearer '));
      expect(calls[0] != calls[1], true,
          reason: 'token must be refreshed after 401');
      expect(providerCalls, 2);
    });

    test('OtpChannel wire mapping is stable', () {
      expect(OtpChannel.auto.wire, 'auto');
      expect(OtpChannel.sms.wire, 'sms');
      expect(OtpChannel.whatsapp.wire, 'whatsapp');
    });
  });
}
