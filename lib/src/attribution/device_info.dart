import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Captures lightweight device + app metadata for attribution requests.
///
/// We deliberately avoid `device_info_plus` to keep the dependency surface
/// minimal. Everything here is non-PII.
class QuickAuthDeviceInfo {
  /// Build a fresh snapshot.
  static Future<Map<String, dynamic>> capture() async {
    final dispatcher = PlatformDispatcher.instance;
    final locale = dispatcher.locale;

    String platform;
    if (kIsWeb) {
      platform = 'web';
    } else if (Platform.isAndroid) {
      platform = 'android';
    } else if (Platform.isIOS) {
      platform = 'ios';
    } else if (Platform.isMacOS) {
      platform = 'macos';
    } else if (Platform.isWindows) {
      platform = 'windows';
    } else if (Platform.isLinux) {
      platform = 'linux';
    } else {
      platform = 'unknown';
    }

    String? appVersion;
    String? appBuild;
    String? appId;
    try {
      final info = await PackageInfo.fromPlatform();
      appVersion = info.version;
      appBuild = info.buildNumber;
      appId = info.packageName;
    } catch (_) {
      // PackageInfo is unavailable in some test contexts; ignore.
    }

    return <String, dynamic>{
      'platform': platform,
      'osVersion': kIsWeb ? null : Platform.operatingSystemVersion,
      'locale': locale.toLanguageTag(),
      'timeZoneOffsetMinutes': DateTime.now().timeZoneOffset.inMinutes,
      if (appVersion != null) 'appVersion': appVersion,
      if (appBuild != null) 'appBuild': appBuild,
      if (appId != null) 'appId': appId,
      'sdk': 'flutter/0.1.0',
    };
  }
}
