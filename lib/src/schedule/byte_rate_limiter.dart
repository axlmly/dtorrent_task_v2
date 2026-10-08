import 'dart:async';

/// Serializes byte reservations for one direction of a torrent transfer.
///
/// The limiter waits asynchronously, so a capped transfer never blocks the
/// isolate while it waits for the next window.
class ByteRateLimiter {
  int? _bytesPerSecond;
  Future<void> _tail = Future<void>.value();
  DateTime _nextAvailable = DateTime.now();

  int? get bytesPerSecond => _bytesPerSecond;

  set bytesPerSecond(int? value) {
    _bytesPerSecond = value == null || value <= 0 ? null : value;
    if (_bytesPerSecond == null) {
      _nextAvailable = DateTime.now();
    }
  }

  Future<void> acquire(int bytes) {
    if (bytes <= 0 || _bytesPerSecond == null) return Future<void>.value();

    final operation = _tail.then((_) => _reserve(bytes));
    _tail = operation.then<void>((_) {}, onError: (Object _) {});
    return operation;
  }

  Future<void> _reserve(int bytes) async {
    final limit = _bytesPerSecond;
    if (limit == null) return;

    final now = DateTime.now();
    final start = _nextAvailable.isAfter(now) ? _nextAvailable : now;
    final wait = start.difference(now);
    if (wait > Duration.zero) await Future<void>.delayed(wait);

    final durationMicros =
        (bytes * Duration.microsecondsPerSecond / limit).ceil();
    _nextAvailable = start.add(Duration(microseconds: durationMicros));
  }
}
