import 'dart:async';

import 'storage.dart';

/// A queued event waiting for consent before it can be flushed to the API.
typedef ConsentQueuedRunner = Future<void> Function();

/// Tracks DPDP / GDPR analytics consent.
///
/// While consent is `false`, [run] queues every analytics-style call. The
/// moment [set] flips to `true`, queued runners replay in the order they were
/// captured. A revoke (`false` after a `true`) drains the queue and wipes
/// SDK-owned storage.
class QuickAuthConsent {
  /// Creates a consent gate.
  QuickAuthConsent({
    required QuickAuthStorage storage,
    bool initial = false,
  })  : _storage = storage,
        _granted = initial;

  static const String _storageKey = 'consent_granted';

  final QuickAuthStorage _storage;
  bool _granted;
  final List<ConsentQueuedRunner> _queue = <ConsentQueuedRunner>[];
  final StreamController<bool> _controller = StreamController<bool>.broadcast();

  /// Stream of consent flips (`true` = granted).
  Stream<bool> get changes => _controller.stream;

  /// Current consent value (synchronous).
  bool get() => _granted;

  /// Hydrate from persistent storage. Safe to call multiple times.
  Future<void> hydrate() async {
    final stored = await _storage.getBool(_storageKey);
    if (stored != null) {
      _granted = stored;
    }
  }

  /// Update the consent value. Returns the resolved value (after queue replay).
  Future<bool> set(bool granted) async {
    final previous = _granted;
    _granted = granted;
    await _storage.setBool(_storageKey, granted);

    if (granted && !previous) {
      // Replay everything queued while denied. Clone first so any new
      // enqueues during replay land on the next cycle.
      final replay = List<ConsentQueuedRunner>.from(_queue);
      _queue.clear();
      for (final runner in replay) {
        try {
          await runner();
        } catch (_) {
          // Swallow — analytics must never crash the host.
        }
      }
    } else if (!granted && previous) {
      _queue.clear();
      await _storage.clearAll();
    }

    if (!_controller.isClosed) {
      _controller.add(granted);
    }
    return granted;
  }

  /// Run a tracking call now, or queue it if consent has not been granted.
  Future<void> run(ConsentQueuedRunner runner) async {
    if (_granted) {
      await runner();
    } else {
      _queue.add(runner);
    }
  }

  /// Number of items currently waiting on consent. Visible for tests.
  int get pendingCount => _queue.length;

  /// Release the broadcast controller. Call from `dispose` paths.
  Future<void> close() async {
    if (!_controller.isClosed) await _controller.close();
  }
}
