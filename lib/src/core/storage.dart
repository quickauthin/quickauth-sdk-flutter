import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

/// Thin async wrapper around [SharedPreferences] with a per-app prefix so the
/// SDK never collides with host-app keys.
class QuickAuthStorage {
  /// Creates a storage helper. Pass [overridePrefs] in tests.
  QuickAuthStorage({SharedPreferences? overridePrefs}) : _override = overridePrefs;

  static const String _prefix = 'io.quickauth.sdk.';

  final SharedPreferences? _override;
  SharedPreferences? _cached;

  Future<SharedPreferences> _prefs() async {
    final override = _override;
    if (override != null) return override;
    return _cached ??= await SharedPreferences.getInstance();
  }

  String _k(String key) => '$_prefix$key';

  /// Persist a string value.
  Future<void> setString(String key, String value) async {
    final p = await _prefs();
    await p.setString(_k(key), value);
  }

  /// Read a string value, or `null` if missing.
  Future<String?> getString(String key) async {
    final p = await _prefs();
    return p.getString(_k(key));
  }

  /// Persist a boolean value.
  Future<void> setBool(String key, bool value) async {
    final p = await _prefs();
    await p.setBool(_k(key), value);
  }

  /// Read a boolean value, or `null` if missing.
  Future<bool?> getBool(String key) async {
    final p = await _prefs();
    return p.getBool(_k(key));
  }

  /// Remove a single key.
  Future<void> remove(String key) async {
    final p = await _prefs();
    await p.remove(_k(key));
  }

  /// Wipe every QuickAuth-namespaced key (e.g. on consent revoke).
  Future<void> clearAll() async {
    final p = await _prefs();
    final keys = p.getKeys().where((k) => k.startsWith(_prefix)).toList();
    for (final k in keys) {
      await p.remove(k);
    }
  }
}
