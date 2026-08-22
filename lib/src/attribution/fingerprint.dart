import 'dart:convert';
import 'dart:math';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/widgets.dart' show WidgetsBinding;

import '../core/storage.dart';

/// Deterministic-ish device fingerprint used by the attribution endpoint to
/// match a launch back to a campaign click.
///
/// The fingerprint is intentionally low-resolution: we pair stable device
/// attributes (locale, screen, timezone) with a SDK-generated random anchor
/// persisted in [QuickAuthStorage]. The anchor lets us tie repeat launches to
/// the same install without ever reading IMEI / IDFA / advertising id.
class QuickAuthFingerprint {
  /// Build a fingerprinter.
  QuickAuthFingerprint({required QuickAuthStorage storage})
      : _storage = storage;

  static const String _anchorKey = 'fingerprint_anchor';

  final QuickAuthStorage _storage;

  /// Lazily generates an opaque, locally-stored install anchor (UUID-ish
  /// 32-hex string).
  Future<String> anchor() async {
    final existing = await _storage.getString(_anchorKey);
    if (existing != null) return existing;
    final fresh = _randomHex(32);
    await _storage.setString(_anchorKey, fresh);
    return fresh;
  }

  /// Compose the fingerprint payload sent to the backend.
  Future<Map<String, dynamic>> compose() async {
    final dispatcher = PlatformDispatcher.instance;
    final locale = dispatcher.locale;

    double? width;
    double? height;
    double? dpr;
    final view = WidgetsBinding.instance.platformDispatcher.views.isNotEmpty
        ? WidgetsBinding.instance.platformDispatcher.views.first
        : null;
    if (view != null) {
      width = view.physicalSize.width;
      height = view.physicalSize.height;
      dpr = view.devicePixelRatio;
    }

    final raw = <String, dynamic>{
      'anchor': await anchor(),
      'locale': locale.toLanguageTag(),
      'tz': DateTime.now().timeZoneOffset.inMinutes,
      'screenW': width,
      'screenH': height,
      'dpr': dpr,
    };

    final canonical = jsonEncode(raw);
    raw['hash'] = _stableHash(canonical);
    return raw;
  }

  String _randomHex(int length) {
    final r = Random.secure();
    const hex = '0123456789abcdef';
    return List<String>.generate(length, (_) => hex[r.nextInt(16)]).join();
  }

  /// Tiny, dependency-free FNV-1a 64-bit hash — good enough to bucketise.
  String _stableHash(String input) {
    final bytes = utf8.encode(input);
    BigInt hash = BigInt.parse('14695981039346656037');
    final mod = BigInt.from(2).pow(64);
    final prime = BigInt.parse('1099511628211');
    for (final b in bytes) {
      hash = (hash ^ BigInt.from(b)) % mod;
      hash = (hash * prime) % mod;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }
}
