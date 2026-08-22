import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:quickauth_flutter/src/core/api_client.dart';
import 'package:quickauth_flutter/src/core/config.dart';

String _b64(Map<String, dynamic> m) =>
    base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');

String _jwtWithExp(int expSeconds, {String sub = 's'}) {
  final h = _b64(<String, dynamic>{'alg': 'HS256', 'typ': 'JWT'});
  final p = _b64(<String, dynamic>{'sub': sub, 'exp': expSeconds});
  return '$h.$p.sig';
}

int _nowSec([Duration offset = Duration.zero]) =>
    (DateTime.now().add(offset).millisecondsSinceEpoch / 1000).round();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TokenManager', () {
    test('seeded fresh token is returned without invoking provider', () async {
      final seed =
          _jwtWithExp(_nowSec(const Duration(minutes: 9)), sub: 'seed');
      var calls = 0;
      final tm = TokenManager(
        provider: () async {
          calls++;
          return _jwtWithExp(_nowSec(const Duration(minutes: 10)));
        },
        initialToken: seed,
      );
      expect(await tm.getToken(), seed);
      expect(calls, 0);
    });

    test('refreshes when expiring within 30s window', () async {
      final almostDead = _jwtWithExp(_nowSec(const Duration(seconds: 10)));
      final fresh = _jwtWithExp(_nowSec(const Duration(minutes: 10)));
      var calls = 0;
      final tm = TokenManager(
        provider: () async {
          calls++;
          return fresh;
        },
        initialToken: almostDead,
      );
      final t = await tm.getToken();
      expect(t, fresh);
      expect(calls, 1);
    });

    test('single-flight: concurrent getToken() calls trigger provider once',
        () async {
      var calls = 0;
      final completer = Completer<String>();
      final tm = TokenManager(
        provider: () async {
          calls++;
          return completer.future;
        },
      );
      final futures = Future.wait<String>(<Future<String>>[
        tm.getToken(),
        tm.getToken(),
        tm.getToken(),
      ]);
      // Resolve the underlying provider exactly once.
      completer.complete(_jwtWithExp(_nowSec(const Duration(minutes: 10))));
      final results = await futures;
      expect(results.length, 3);
      expect(results.toSet().length, 1, reason: 'all callers see same token');
      expect(calls, 1);
    });

    test('invalidate() drops cached token, next getToken refreshes', () async {
      final t1 = _jwtWithExp(_nowSec(const Duration(minutes: 10)), sub: 't1');
      final t2 = _jwtWithExp(_nowSec(const Duration(minutes: 10)), sub: 't2');
      var calls = 0;
      final tm = TokenManager(
        provider: () async {
          calls++;
          return calls == 1 ? t1 : t2;
        },
      );
      expect(await tm.getToken(), t1);
      expect(calls, 1);
      // Cached — no new call.
      expect(await tm.getToken(), t1);
      expect(calls, 1);
      tm.invalidate();
      expect(await tm.getToken(), t2);
      expect(calls, 2);
    });

    test('malformed JWT is treated as never-expiring (best-effort)', () async {
      var calls = 0;
      final tm = TokenManager(
        provider: () async {
          calls++;
          return 'not-a-jwt';
        },
      );
      final a = await tm.getToken();
      final b = await tm.getToken();
      expect(a, 'not-a-jwt');
      expect(b, 'not-a-jwt');
      expect(calls, 1, reason: 'undecodable exp -> assume valid, no refresh');
    });

    test('empty token from provider raises', () async {
      final tm = TokenManager(provider: () async => '');
      expect(tm.getToken, throwsA(isA<QuickAuthApiException>()));
    });
  });

  group('QuickAuthApiClient bearer + 401 retry', () {
    test('attaches Authorization: Bearer on every POST', () async {
      final seed = _jwtWithExp(_nowSec(const Duration(minutes: 10)));
      late http.Request req1;
      late http.Request req2;
      var n = 0;
      final mock = MockClient((req) async {
        n++;
        if (n == 1) {
          req1 = req;
        } else {
          req2 = req;
        }
        return http.Response('{}', 200);
      });
      final cfg = QuickAuthConfig(
        onTokenExpiry: () async => seed,
        initialToken: seed,
      );
      final tm = TokenManager(provider: cfg.onTokenExpiry!, initialToken: seed);
      final client =
          QuickAuthApiClient(config: cfg, tokenManager: tm, httpClient: mock);
      await client.post('/v1/sdk/auth/initiate', <String, dynamic>{'a': 1});
      await client.post('/v1/sdk/auth/verify', <String, dynamic>{'b': 2});
      expect(req1.headers['authorization'], 'Bearer $seed');
      expect(req2.headers['authorization'], 'Bearer $seed');
    });

    test('on 401 invalidates and retries once with fresh token', () async {
      final t1 = _jwtWithExp(_nowSec(const Duration(minutes: 10)), sub: 'old');
      final t2 = _jwtWithExp(_nowSec(const Duration(minutes: 10)), sub: 'new');
      var providerCalls = 0;
      final cfg = QuickAuthConfig(onTokenExpiry: () async {
        providerCalls++;
        return providerCalls == 1 ? t1 : t2;
      });
      final tm = TokenManager(provider: cfg.onTokenExpiry!, initialToken: null);
      final headers = <String>[];
      final mock = MockClient((req) async {
        headers.add(req.headers['authorization']!);
        if (headers.length == 1) {
          return http.Response('{"message":"unauth"}', 401);
        }
        return http.Response('{"ok":true}', 200);
      });
      final client =
          QuickAuthApiClient(config: cfg, tokenManager: tm, httpClient: mock);
      final res = await client.post('/v1/test', <String, dynamic>{});
      expect(res['ok'], true);
      expect(headers, <String>['Bearer $t1', 'Bearer $t2']);
      expect(providerCalls, 2);
    });

    test('does not retry beyond once on consecutive 401s', () async {
      final t1 = _jwtWithExp(_nowSec(const Duration(minutes: 10)));
      final cfg = QuickAuthConfig(onTokenExpiry: () async => t1);
      final tm = TokenManager(provider: cfg.onTokenExpiry!);
      var calls = 0;
      final mock = MockClient((req) async {
        calls++;
        return http.Response('{"message":"still unauth"}', 401);
      });
      final client =
          QuickAuthApiClient(config: cfg, tokenManager: tm, httpClient: mock);
      await expectLater(
        client.post('/v1/test', <String, dynamic>{}),
        throwsA(isA<QuickAuthApiException>()
            .having((e) => e.statusCode, 'statusCode', 401)),
      );
      expect(calls, 2, reason: 'initial + one retry');
    });
  });
}
