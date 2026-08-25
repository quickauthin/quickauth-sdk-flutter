import 'dart:async';

import '../attribution/device_info.dart';
import '../core/api_client.dart';
import '../core/config.dart';
import '../core/consent.dart';
import '../core/storage.dart';
import 'auth_event.dart';
import 'sms_retriever.dart';
import 'whatsapp_otp_retriever.dart';

const String _deviceTokenKey = 'device_token';
final RegExp _e164 = RegExp(r'^\+[1-9]\d{6,14}$');
final RegExp _otpCode = RegExp(r'^\d{4,8}$');

/// Internal state machine states.
sealed class _SessionState {
  int? get attemptId;
}

class _Idle extends _SessionState {
  @override
  int? get attemptId => null;
}

class _Sending extends _SessionState {
  _Sending(this._attemptId);
  final int _attemptId;
  @override
  int get attemptId => _attemptId;
}

class _AwaitingOtp extends _SessionState {
  _AwaitingOtp(this._attemptId, this.sessionId);
  final int _attemptId;
  final String sessionId;
  @override
  int get attemptId => _attemptId;
}

class _Verifying extends _SessionState {
  _Verifying(this._attemptId, this.sessionId);
  final int _attemptId;
  final String sessionId;
  @override
  int get attemptId => _attemptId;
}

class _Verified extends _SessionState {
  _Verified(this._attemptId, this.requestId);
  final int _attemptId;
  final String requestId;
  @override
  int get attemptId => _attemptId;
}

class _Failed extends _SessionState {
  _Failed(this._attemptId);
  final int _attemptId;
  @override
  int get attemptId => _attemptId;
}

/// Headless auth state machine. Available as `QuickAuth.auth`.
///
/// Public API:
/// ```dart
/// await QuickAuth.auth.initiate(phone: '+919876543210');
/// await QuickAuth.auth.submitOtp('123456');
/// QuickAuth.auth.reset(forgetDevice: true);
/// ```
///
/// All outcomes flow via [QuickAuthConfig.onAuthEvent]. The async methods
/// resolve once the network call has completed; merchants rely on the event
/// stream as the source of truth for what UI to render.
///
/// State diagram (matches web + iOS + Android + RN):
/// ```
///   idle ──initiate()──► sending ──OTP_SENT───► awaitingOtp ──submitOtp()──► verifying
///                              └──VERIFIED────► verified                              │
///                              └──error───────► failed                                │
///   verifying ──VERIFIED────► verified                                                │
///   verifying ──OTP_FAILED──► awaitingOtp ◄────────────────────────────────────────┘
///   any state ──reset()─────► idle
/// ```
class QuickAuthOtpService {
  /// Creates the service.
  QuickAuthOtpService({
    required QuickAuthApiClient apiClient,
    required SmsRetriever smsRetriever,
    WhatsAppOtpRetriever? whatsAppRetriever,
    required QuickAuthStorage storage,
    required QuickAuthConfig Function() configProvider,
    required QuickAuthConsent consent,
  })  : _api = apiClient,
        _sms = smsRetriever,
        _wa = whatsAppRetriever ?? WhatsAppOtpRetriever(),
        _storage = storage,
        _config = configProvider,
        _consent = consent;

  final QuickAuthApiClient _api;
  final SmsRetriever _sms;
  final WhatsAppOtpRetriever _wa;
  final QuickAuthStorage _storage;
  final QuickAuthConfig Function() _config;
  final QuickAuthConsent _consent;

  /// Mirrors web + iOS: include the opaque `deviceInfo` block (V48 audit
  /// metadata, never used in the OneTap trust decision) only once DPDP/GDPR
  /// consent has been granted. A failure here must never block auth.
  Future<Map<String, dynamic>?> _deviceInfoIfConsented() async {
    if (!_consent.get()) return null;
    try {
      return await QuickAuthDeviceInfo.capture();
    } catch (_) {
      return null;
    }
  }

  _SessionState _state = _Idle();
  int _attemptCounter = 0;
  String? _cachedDeviceToken; // null = explicitly missing; absence = not loaded

  bool _deviceTokenLoaded = false;

  Future<String?> _loadDeviceToken() async {
    if (_deviceTokenLoaded) return _cachedDeviceToken;
    _cachedDeviceToken = await _storage.getString(_deviceTokenKey);
    _deviceTokenLoaded = true;
    return _cachedDeviceToken;
  }

  Future<void> _saveDeviceToken(String token) async {
    _cachedDeviceToken = token;
    _deviceTokenLoaded = true;
    await _storage.setString(_deviceTokenKey, token);
  }

  Future<void> _clearDeviceToken() async {
    _cachedDeviceToken = null;
    _deviceTokenLoaded = true;
    await _storage.remove(_deviceTokenKey);
  }

  /// Begin an auth attempt. Emits [OtpSentEvent] (OTP delivered) or
  /// [VerifiedEvent] (OneTap fired) via [QuickAuthConfig.onAuthEvent]. Throws
  /// only on validation / transport failure.
  Future<void> initiate({
    required String phone,
    OtpChannel channel = OtpChannel.auto,
    bool autoSubmit = false,
  }) async {
    if (!_e164.hasMatch(phone)) {
      throw ArgumentError.value(
        phone,
        'phone',
        'must be E.164 formatted (e.g. +919876543210)',
      );
    }

    final attemptId = ++_attemptCounter;
    _state = _Sending(attemptId);

    // Fire-and-forget SMS Retriever — failure must not block OTP delivery.
    unawaited(_sms.start());
    // Drop any WhatsApp code held from an earlier attempt. The native receiver keeps one so a
    // zero-tap code arriving before the app was running is not lost, but delivering that
    // against a request the user has since restarted fails verification for reasons they
    // cannot see.
    unawaited(_wa.clearPending());
    // Before the OTP is requested, not after: WhatsApp checks for a live handshake when it
    // receives the template, and one sent afterwards is too late for the message already in
    // flight. Awaited for the same reason — firing it unawaited would race the send.
    await _wa.sendHandshake();
    _activePhone = phone;
    _activeChannel = channel;
    _autoSubmit = autoSubmit;
    _autoSubmitted = false;
    _listenForAutoRead();

    final deviceToken = await _loadDeviceToken();
    final body = <String, dynamic>{
      'phone': phone,
      'channel': channel.wire,
    };
    if (deviceToken != null && deviceToken.isNotEmpty) {
      body['deviceToken'] = deviceToken;
    }
    final deviceInfo = await _deviceInfoIfConsented();
    if (deviceInfo != null) body['deviceInfo'] = deviceInfo;

    Map<String, dynamic> json;
    try {
      json = await _api.post('/v1/sdk/auth/initiate', body);
    } catch (e) {
      if (_state.attemptId == attemptId) {
        _state = _Failed(attemptId);
        _emit(AuthErrorEvent(code: _classify(e), message: _message(e)));
      }
      rethrow;
    }

    if (_state.attemptId != attemptId) return;

    final state = json['state'] as String?;
    final sessionId = json['sessionId'] as String;
    final expiresIn = (json['expiresIn'] as num?)?.toInt() ?? 300;
    final newToken = json['deviceToken'] as String?;
    if (newToken != null && newToken.isNotEmpty) {
      await _saveDeviceToken(newToken);
    }

    if (state == 'VERIFIED') {
      _state = _Verified(attemptId, sessionId);
      _emit(VerifiedEvent(requestId: sessionId));
      return;
    }

    _state = _AwaitingOtp(attemptId, sessionId);
    _emit(OtpSentEvent(
      sessionId: sessionId,
      channel: channel,
      expiresIn: expiresIn,
    ));
  }

  /// Submit the user-entered OTP. Valid only after [OtpSentEvent]. Emits
  /// [VerifiedEvent] on success or [OtpFailedEvent] on wrong code (state
  /// stays in awaiting-OTP for retry).
  Future<void> submitOtp(String code) async {
    if (!_otpCode.hasMatch(code)) {
      throw ArgumentError.value(code, 'code', 'must be 4–8 digits');
    }
    final current = _state;
    if (current is! _AwaitingOtp) {
      throw StateError(
        'submitOtp called in state ${current.runtimeType} — must follow an OtpSentEvent',
      );
    }
    final attemptId = current._attemptId;
    final sessionId = current.sessionId;
    _state = _Verifying(attemptId, sessionId);

    final deviceToken = await _loadDeviceToken();
    final body = <String, dynamic>{
      'sessionId': sessionId,
      'code': code,
    };
    if (deviceToken != null && deviceToken.isNotEmpty) {
      body['deviceToken'] = deviceToken;
    }
    final deviceInfo = await _deviceInfoIfConsented();
    if (deviceInfo != null) body['deviceInfo'] = deviceInfo;

    Map<String, dynamic> json;
    try {
      json = await _api.post('/v1/sdk/auth/verify', body);
    } catch (e) {
      if (_state.attemptId == attemptId) {
        _state = _Failed(attemptId);
        _emit(AuthErrorEvent(code: _classify(e), message: _message(e)));
      }
      rethrow;
    }

    if (_state.attemptId != attemptId) return;

    final state = json['state'] as String?;
    final verified = json['verified'] as bool? ?? false;
    final requestId = json['requestId'] as String? ?? '';
    final message = json['message'] as String? ?? '';

    final isVerified = state == 'VERIFIED' || (state == null && verified);
    if (isVerified) {
      _state = _Verified(attemptId, requestId);
      _emit(VerifiedEvent(requestId: requestId, message: message));
      return;
    }

    _state = _AwaitingOtp(attemptId, sessionId);
    _emit(OtpFailedEvent(message));
  }

  /// Send the code again, to the number the current attempt is already for.
  ///
  /// Within the merchant's expiry window the server returns the SAME code and pushes the
  /// expiry forward, so a user who missed the first message gets that message again rather
  /// than a second code to choose between. Past the window it issues a fresh one, which is
  /// what an expired code deserves.
  ///
  /// Takes no phone number deliberately. The merchant already gave us one, and asking again is
  /// an opportunity to pass a different number by accident — which would start a separate
  /// transaction and leave the user holding two codes, only one of which works.
  ///
  /// Carries the original attempt's channel and [initiate]'s `autoSubmit` setting, so a resend
  /// behaves like the request it repeats rather than silently reverting to defaults.
  ///
  /// It also re-sends the WhatsApp handshake. Meta expires that after ten minutes, so a user
  /// who waits before tapping resend would otherwise get a message their app can no longer
  /// auto-read — the failure being invisible, as ever.
  ///
  /// Throws [StateError] if there is no attempt to resend. That is a programming error rather
  /// than a runtime condition: a resend button should only exist once a code has been sent.
  Future<void> resendOtp() async {
    final phone = _activePhone;
    if (phone == null) {
      throw StateError(
        'resendOtp: nothing to resend — call initiate() first.',
      );
    }
    await initiate(
      phone: phone,
      channel: _activeChannel,
      autoSubmit: _autoSubmit,
    );
  }

  /// Stop listening for auto-read codes. Called on reset, and safe to call twice.
  Future<void> _stopAutoRead() async {
    await _autoReadSub?.cancel();
    _autoReadSub = null;
    _autoSubmit = false;
    // Nothing left to resend to: a reset ends the attempt, and resending afterwards would
    // message someone who is no longer mid-login.
    _activePhone = null;
  }

  /// Reset the state machine. Pass [forgetDevice] = `true` on user-initiated
  /// sign-out to also drop the persistent device token, making the next
  /// [initiate] act like a brand-new install (no OneTap).
  Future<void> reset({bool forgetDevice = false}) async {
    await _stopAutoRead();
    _state = _Idle();
    _attemptCounter++; // invalidate any in-flight attempt
    if (forgetDevice) {
      await _clearDeviceToken();
    }
  }

  /// Manually publish an auto-read OTP code into the event stream.
  /// Useful when integrating with an external SMS observer.
  void publishAutoReadCode(String code) {
    _emit(OtpAutoReadEvent(code));
    _maybeAutoSubmit(code);
  }

  /// The phone and options of the live attempt, so [resendOtp] needs no arguments.
  ///
  /// A merchant should not have to hold the number themselves to resend to it — they already
  /// gave it to us, and asking again is an opportunity to pass a different one, which would
  /// start a second transaction and leave the user holding two codes.
  String? _activePhone;
  OtpChannel _activeChannel = OtpChannel.auto;

  /// Whether the current attempt should verify an auto-read code by itself.
  bool _autoSubmit = false;

  /// The service's own subscription to the auto-read sources.
  ///
  /// Without this, auto-read only worked for a caller who happened to listen to
  /// [observeOTP]. The native side attaches to the WhatsApp receiver on the event channel's
  /// onListen, so with nobody subscribed the code was received, held, and never delivered —
  /// autoSubmit did nothing at all, which is precisely the case where the caller was told
  /// they need not listen.
  StreamSubscription<String>? _autoReadSub;

  /// One auto-submit per attempt. Both sources can deliver — a merchant sending on `auto`
  /// may get the SMS and the WhatsApp copy — and submitting the second would verify a code
  /// the server has already consumed, surfacing as a spurious failure after a success.
  bool _autoSubmitted = false;

  /// Subscribe on the caller's behalf, so a code is delivered whether or not they listen.
  ///
  /// Idempotent across attempts: a resend must not stack subscriptions, and the old one is
  /// dropped first so a code from a previous attempt cannot arrive on it.
  void _listenForAutoRead() {
    unawaited(_autoReadSub?.cancel());
    _autoReadSub = null;
    // No platform guard. Both sources return an empty stream where they are unsupported, so
    // subscribing off Android costs one immediately-closing stream — and a guard reading the
    // platform here would be a second place for "is auto-read available" to be decided, which
    // is how the two ended up disagreeing before.
    _autoReadSub = _merge(_sms.observe(), _wa.observe()).listen(
      (code) {
        _emit(OtpAutoReadEvent(code));
        _maybeAutoSubmit(code);
      },
      // A platform-side failure must not take down the OTP flow; the user can still type it.
      onError: (Object _) {},
    );
  }

  void _maybeAutoSubmit(String code) {
    if (!_autoSubmit || _autoSubmitted) return;
    _autoSubmitted = true;
    unawaited(submitOtp(code));
  }

  /// Codes read automatically, from whichever channel delivered them (Android only).
  ///
  /// Merges the two, because they are two delivery mechanisms for one thing and a caller
  /// should not have to know which arrived. An OTP sent over SMS is parsed out of the message
  /// body by SmsRetriever; a WhatsApp one-tap or zero-tap code is broadcast to the app by
  /// WhatsApp and arrives already extracted. Listening to only one — which is all that was
  /// possible before — means a merchant on `auto` gets auto-read for some users and not
  /// others, with nothing to explain the difference.
  ///
  /// Codes also surface as [OtpAutoReadEvent] on the event stream, so callers already
  /// listening there get WhatsApp codes without changing anything.
  Stream<String> observeOTP() {
    // No _emit here. initiate() already subscribes on the caller's behalf and emits from
    // there; doing it again would fire OtpAutoReadEvent twice for one code, and a merchant
    // driving their UI from that event would see the field filled, cleared and filled again.
    return _merge(_sms.observe(), _wa.observe());
  }

  /// Merge two code sources into one.
  ///
  /// Hand-rolled rather than pulling in package:async for a two-stream merge. Both are
  /// broadcast streams and either may be empty (neither fires off Android), so the merged
  /// stream closes only once both have, and cancelling it cancels both — a listener that
  /// walks away must not leave a native receiver attached.
  static Stream<String> _merge(Stream<String> a, Stream<String> b) {
    late StreamController<String> controller;
    final subs = <StreamSubscription<String>>[];
    var open = 2;

    void onDone() {
      if (--open == 0) controller.close();
    }

    controller = StreamController<String>.broadcast(
      onListen: () {
        for (final source in [a, b]) {
          subs.add(source.listen(controller.add,
              onError: controller.addError, onDone: onDone));
        }
      },
      onCancel: () async {
        for (final sub in subs) {
          await sub.cancel();
        }
        subs.clear();
      },
    );
    return controller.stream;
  }

  /// Get the Android app-signing hash that must terminate every OTP SMS.
  Future<String?> getAppHash() => _sms.getAppHash();

  // -- Internals ----------------------------------------------------------

  void _emit(AuthEvent event) {
    final handler = _config().onAuthEvent;
    if (handler == null) return;
    // Microtask defer so events fire after the awaited future resumes,
    // matching the contract of every other QuickAuth SDK.
    scheduleMicrotask(() {
      try {
        handler(event);
      } catch (err, stack) {
        // Don't let merchant handler bugs crash the SDK.
        // ignore: avoid_print
        print('[QuickAuth] onAuthEvent handler threw: $err\n$stack');
      }
    });
  }

  String _classify(Object e) {
    if (e is QuickAuthApiException) {
      final code = e.statusCode;
      if (code == 429) return 'RATE_LIMITED';
      if (code != null && code >= 500) return 'SERVER_ERROR';
      if (code != null && code >= 400) return 'CLIENT_ERROR';
      return 'HTTP_ERROR';
    }
    return 'UNKNOWN_ERROR';
  }

  String _message(Object e) {
    if (e is QuickAuthApiException) return e.message;
    return e.toString();
  }
}
