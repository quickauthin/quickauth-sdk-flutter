import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:quickauth/src/attribution/attribution_service.dart';
import 'package:quickauth/src/core/api_client.dart';
import 'package:quickauth/src/core/config.dart';
import 'package:quickauth/src/core/consent.dart';
import 'package:quickauth/src/core/storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<QuickAuthStorage> _storage() async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  return QuickAuthStorage(overridePrefs: await SharedPreferences.getInstance());
}

String _fakeJwt() {
  String b64(Map<String, dynamic> m) =>
      base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  final exp =
      DateTime.now().add(const Duration(minutes: 10)).millisecondsSinceEpoch ~/
          1000;
  return '${b64(<String, dynamic>{'alg': 'HS256'})}.'
      '${b64(<String, dynamic>{'sub': 'sess_attr', 'exp': exp})}.sig';
}

QuickAuthApiClient _client(MockClient mock) {
  final cfg = QuickAuthConfig(onTokenExpiry: () async => _fakeJwt());
  final tm = TokenManager(
    provider: cfg.onTokenExpiry,
    initialToken: _fakeJwt(),
  );
  return QuickAuthApiClient(
    config: cfg,
    tokenManager: tm,
    httpClient: mock,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('captureLaunch parses qa_clid from query string', () async {
    var captured = <String, dynamic>{};
    final mock = MockClient((req) async {
      captured = jsonDecode(req.body) as Map<String, dynamic>;
      return http.Response(
        jsonEncode(<String, dynamic>{
          'matched': true,
          'qa_clid': 'cl_abc',
          'campaignId': 'cmp_1',
          'templateId': 'tpl_1',
          'variantId': 'v_a',
        }),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );
    });
    final storage = await _storage();
    final consent = QuickAuthConsent(storage: storage, initial: true);
    final service = QuickAuthAttributionService(
      apiClient: _client(mock),
      storage: storage,
      consent: consent,
    );

    final result = await service.captureLaunch(
      launchUri: Uri.parse('myapp://open?qa_clid=cl_abc&utm_source=wa'),
    );

    expect(result.matched, true);
    expect(result.campaignId, 'cmp_1');
    expect(result.templateId, 'tpl_1');
    expect(result.variantId, 'v_a');
    expect(captured['qa_clid'], 'cl_abc');
    expect(captured['fingerprint'], isA<Map<String, dynamic>>());
    expect(captured['deviceInfo'], isA<Map<String, dynamic>>());
    // qa_clid persisted for later conversions.
    expect(await service.qaClid(), 'cl_abc');
  });

  test('trackConversion is queued when consent denied, replayed on grant',
      () async {
    var calls = 0;
    final mock = MockClient((req) async {
      calls++;
      expect(req.url.path, '/v1/sdk/attribution/conversion');
      return http.Response('{}', 200);
    });
    final storage = await _storage();
    await storage.setString('qa_clid', 'cl_xyz');
    final consent = QuickAuthConsent(storage: storage);
    final service = QuickAuthAttributionService(
      apiClient: _client(mock),
      storage: storage,
      consent: consent,
    );

    await service.trackConversion(event: 'signup', value: 1, currency: 'INR');
    expect(calls, 0, reason: 'must not network without consent');
    expect(consent.pendingCount, 1);

    await consent.set(true);
    expect(calls, 1, reason: 'replay on grant');
  });

  test('trackConversion runs immediately when consent granted', () async {
    Map<String, dynamic>? body;
    final mock = MockClient((req) async {
      body = jsonDecode(req.body) as Map<String, dynamic>;
      return http.Response('{}', 200);
    });
    final storage = await _storage();
    await storage.setString('qa_clid', 'cl_xyz');
    final consent = QuickAuthConsent(storage: storage, initial: true);
    final service = QuickAuthAttributionService(
      apiClient: _client(mock),
      storage: storage,
      consent: consent,
    );
    await service.trackConversion(
      event: 'purchase',
      value: 199,
      currency: 'INR',
      metadata: <String, dynamic>{'plan': 'pro'},
    );
    expect(body, isNotNull);
    expect(body!['event'], 'purchase');
    expect(body!['value'], 199);
    expect(body!['currency'], 'INR');
    expect(body!['qa_clid'], 'cl_xyz');
    expect((body!['metadata'] as Map<String, dynamic>)['plan'], 'pro');
  });

  test('captureLaunch returns unmatched without network when consent denied',
      () async {
    var calls = 0;
    final mock = MockClient((_) async {
      calls++;
      return http.Response('{}', 200);
    });
    final storage = await _storage();
    final consent = QuickAuthConsent(storage: storage);
    final service = QuickAuthAttributionService(
      apiClient: _client(mock),
      storage: storage,
      consent: consent,
    );
    final r = await service.captureLaunch(
      launchUri: Uri.parse('myapp://open?qa_clid=cl_q'),
    );
    expect(r.matched, false);
    expect(calls, 0);
    // qa_clid should still be persisted for replay.
    expect(await storage.getString('qa_clid'), 'cl_q');
  });
}
