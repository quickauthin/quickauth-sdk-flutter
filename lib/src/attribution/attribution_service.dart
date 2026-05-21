import 'dart:async';

import '../core/api_client.dart';
import '../core/consent.dart';
import '../core/storage.dart';
import 'device_info.dart';
import 'fingerprint.dart';

/// Result of `POST /v1/sdk/attribution/launch`.
class AttributionResult {
  /// Creates a result snapshot.
  const AttributionResult({
    required this.matched,
    this.qaClid,
    this.campaignId,
    this.templateId,
    this.variantId,
  });

  /// Decode from API JSON.
  factory AttributionResult.fromJson(Map<String, dynamic> json) =>
      AttributionResult(
        matched: json['matched'] == true,
        qaClid: json['qa_clid'] as String?,
        campaignId: json['campaignId'] as String?,
        templateId: json['templateId'] as String?,
        variantId: json['variantId'] as String?,
      );

  /// Whether a campaign click was successfully attributed to this launch.
  final bool matched;

  /// QuickAuth click identifier echoed back. Persisted so future conversions
  /// can be tied to the same click.
  final String? qaClid;

  /// Resolved campaign id.
  final String? campaignId;

  /// Resolved template id.
  final String? templateId;

  /// Resolved A/B variant id.
  final String? variantId;
}

/// Headless attribution API. Available as `QuickAuth.attribution`.
class QuickAuthAttributionService {
  /// Creates the service.
  QuickAuthAttributionService({
    required QuickAuthApiClient apiClient,
    required QuickAuthStorage storage,
    required QuickAuthConsent consent,
  })  : _api = apiClient,
        _storage = storage,
        _consent = consent,
        _fp = QuickAuthFingerprint(storage: storage);

  static const String _qaClidKey = 'qa_clid';
  static const String _resolvedCampaignKey = 'qa_campaign_id';

  final QuickAuthApiClient _api;
  final QuickAuthStorage _storage;
  final QuickAuthConsent _consent;
  final QuickAuthFingerprint _fp;

  /// Most recent attribution result.
  AttributionResult? lastResult;

  /// Capture the current launch.
  ///
  /// [launchUri] — the URL the app was opened with (deep-link / universal
  /// link). Pass `null` if the launch had no URL; the SDK will still attempt
  /// fingerprint-only matching.
  ///
  /// Returns an [AttributionResult]. When consent is denied, returns an
  /// `unmatched` result without making any network call.
  Future<AttributionResult> captureLaunch({Uri? launchUri}) async {
    final qaClid = _readQaClid(launchUri);
    if (qaClid != null) {
      await _storage.setString(_qaClidKey, qaClid);
    }

    if (!_consent.get()) {
      // Tracking not yet allowed — queue the actual call so it replays on
      // grant. Return an empty result for now.
      unawaited(
        _consent.run(() async {
          await _doCapture(qaClid: qaClid);
        }),
      );
      return const AttributionResult(matched: false);
    }
    return _doCapture(qaClid: qaClid);
  }

  Future<AttributionResult> _doCapture({String? qaClid}) async {
    final fingerprint = await _fp.compose();
    final deviceInfo = await QuickAuthDeviceInfo.capture();
    final body = <String, dynamic>{
      if (qaClid != null) 'qa_clid': qaClid,
      'fingerprint': fingerprint,
      'deviceInfo': deviceInfo,
    };
    final json = await _api.post('/v1/sdk/attribution/launch', body);
    final result = AttributionResult.fromJson(json);
    lastResult = result;
    if (result.qaClid != null) {
      await _storage.setString(_qaClidKey, result.qaClid!);
    }
    if (result.campaignId != null) {
      await _storage.setString(_resolvedCampaignKey, result.campaignId!);
    }
    return result;
  }

  /// Track a conversion event tied to the most recent click.
  Future<void> trackConversion({
    required String event,
    num value = 0,
    String currency = 'INR',
    Map<String, dynamic>? metadata,
  }) async {
    Future<void> runner() async {
      final qaClid = await _storage.getString(_qaClidKey);
      await _api.post('/v1/sdk/attribution/conversion', <String, dynamic>{
        'event': event,
        'value': value,
        'currency': currency,
        if (qaClid != null) 'qa_clid': qaClid,
        if (metadata != null) 'metadata': metadata,
      });
    }

    await _consent.run(runner);
  }

  /// Read the persisted `qa_clid`, if any.
  Future<String?> qaClid() => _storage.getString(_qaClidKey);

  String? _readQaClid(Uri? uri) {
    if (uri == null) return null;
    final fromQuery = uri.queryParameters['qa_clid'];
    if (fromQuery != null && fromQuery.isNotEmpty) return fromQuery;
    // Some platforms route the click id through the fragment.
    final fragment = uri.fragment;
    if (fragment.isEmpty) return null;
    final parsed = Uri.tryParse('?$fragment');
    return parsed?.queryParameters['qa_clid'];
  }
}
