import 'dart:async';

import '../models/transfer.dart';

typedef ProgressSink = void Function(String event);
typedef DoneSink = void Function();

/// Tracks in-flight and recently-finished transfers and fans progress out to:
///  * Server-Sent Events subscribers (the browser's `/api/progress/:id`), and
///  * a single `onChanged` callback (throttled) used to notify the UI isolate.
class TransferManager {
  final Map<String, Transfer> _transfers = {};
  final Map<String, _Subscriber> _subscribers = {};
  final Map<String, _SpeedSample> _samples = {};
  final void Function() _onChanged;

  /// Speed sampling window (rolling).
  final Duration _speedWindow = const Duration(seconds: 2);

  TransferManager({required void Function() onChanged}) : _onChanged = onChanged;

  List<Transfer> snapshot() {
    final list = _transfers.values.toList();
    list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  Transfer? get(String id) => _transfers[id];

  Transfer create(
    String id,
    String fileName,
    TransferDirection direction, {
    int? totalBytes,
  }) {
    _transfers[id] = Transfer(
      id: id,
      fileName: fileName,
      direction: direction,
      totalBytes: totalBytes,
    );
    _emit(id);
    _notify();
    return _transfers[id]!;
  }

  /// Records bytes transferred for [id] and recomputes a rolling speed.
  void addBytes(String id, int delta) {
    final t = _transfers[id];
    if (t == null) return;
    t.transferredBytes += delta;
    final now = DateTime.now();
    final sample = _samples[id] ??= _SpeedSample();
    sample.accumBytes += delta;
    sample.windowStart ??= now;
    final elapsed = now.difference(sample.windowStart!);
    if (elapsed >= _speedWindow) {
      t.speedBytesPerSec = sample.accumBytes / elapsed.inMilliseconds * 1000;
      sample.accumBytes = 0;
      sample.windowStart = now;
    }
    _emit(id);
    _notify();
  }

  void complete(String id) {
    final t = _transfers[id];
    if (t == null) return;
    t.done = true;
    t.speedBytesPerSec = 0;
    _samples.remove(id);
    _emit(id);
    _closeSubscriber(id);
    _notify();
    _scheduleCleanup(id);
  }

  void fail(String id, String error) {
    final t = _transfers[id];
    if (t == null) return;
    t.failed = true;
    t.error = error;
    t.speedBytesPerSec = 0;
    _samples.remove(id);
    _emit(id);
    _closeSubscriber(id);
    _notify();
    _scheduleCleanup(id);
  }

  /// Subscribe a Server-Sent Events sink to a transfer's progress.
  void subscribe(String id, ProgressSink emit, DoneSink onDone) {
    _subscribers[id] = _Subscriber(emit, onDone);
    // Replay a current snapshot so a late subscriber sees immediate state.
    final t = _transfers[id];
    if (t != null) emit(_sse(t));
  }

  void _emit(String id) {
    final t = _transfers[id];
    if (t == null) return;
    final event = _sse(t);
    _subscribers[id]?.emit(event);
  }

  void _closeSubscriber(String id) {
    final sub = _subscribers.remove(id);
    sub?.onDone();
  }

  String _sse(Transfer t) => 'data: ${t.toJson()}\n\n';

  void _scheduleCleanup(String id) {
    Timer(const Duration(seconds: 8), () {
      _transfers.remove(id);
      _subscribers.remove(id);
    });
  }

  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);
  void _notify() {
    final now = DateTime.now();
    // Throttle UI updates to ~4 Hz so we don't flood the isolate channel.
    if (now.difference(_lastNotify).inMilliseconds < 250) return;
    _lastNotify = now;
    _onChanged();
  }

  void dispose() {
    for (final sub in _subscribers.values) {
      sub.onDone();
    }
    _subscribers.clear();
    _transfers.clear();
  }
}

class _Subscriber {
  final ProgressSink emit;
  final DoneSink onDone;
  _Subscriber(this.emit, this.onDone);
}

class _SpeedSample {
  int accumBytes = 0;
  DateTime? windowStart;
}
