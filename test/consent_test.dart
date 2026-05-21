import 'package:flutter_test/flutter_test.dart';
import 'package:quickauth/src/core/consent.dart';
import 'package:quickauth/src/core/storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<QuickAuthStorage> _storage() async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final p = await SharedPreferences.getInstance();
  return QuickAuthStorage(overridePrefs: p);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('blocks tracking when consent is off', () async {
    final consent = QuickAuthConsent(storage: await _storage());
    var ran = 0;
    await consent.run(() async => ran++);
    expect(ran, 0);
    expect(consent.pendingCount, 1);
    expect(consent.get(), false);
  });

  test('replays queued events on grant in original order', () async {
    final consent = QuickAuthConsent(storage: await _storage());
    final order = <int>[];
    await consent.run(() async => order.add(1));
    await consent.run(() async => order.add(2));
    await consent.run(() async => order.add(3));
    expect(consent.pendingCount, 3);
    await consent.set(true);
    expect(order, <int>[1, 2, 3]);
    expect(consent.pendingCount, 0);
  });

  test('runs immediately while granted', () async {
    final consent = QuickAuthConsent(storage: await _storage(), initial: true);
    var ran = 0;
    await consent.run(() async => ran++);
    expect(ran, 1);
    expect(consent.pendingCount, 0);
  });

  test('revoke purges queue and clears storage', () async {
    final storage = await _storage();
    final consent = QuickAuthConsent(storage: storage, initial: true);
    await storage.setString('qa_clid', 'abc');
    await consent.set(false);
    expect(await storage.getString('qa_clid'), isNull);
    var ran = 0;
    await consent.run(() async => ran++);
    expect(ran, 0);
  });

  test('hydrate restores prior consent', () async {
    final storage = await _storage();
    await storage.setBool('consent_granted', true);
    final consent = QuickAuthConsent(storage: storage);
    expect(consent.get(), false);
    await consent.hydrate();
    expect(consent.get(), true);
  });

  test('changes stream emits flips', () async {
    final consent = QuickAuthConsent(storage: await _storage());
    final emitted = <bool>[];
    final sub = consent.changes.listen(emitted.add);
    await consent.set(true);
    await consent.set(false);
    await Future<void>.delayed(Duration.zero);
    expect(emitted, <bool>[true, false]);
    await sub.cancel();
    await consent.close();
  });
}
