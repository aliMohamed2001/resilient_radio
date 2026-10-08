import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// When to reconnect after the stream drops, and when to give up.
///
/// The default waits 1, 2, 4, 8, 16, 30, 30 and 30 seconds before its eight
/// attempts. Override [delayFor] for another curve.
@immutable
class ReconnectPolicy {
  const ReconnectPolicy({
    this.initialDelay = const Duration(seconds: 1),
    this.maxDelay = const Duration(seconds: 30),
    this.maxAttempts = 8,
    this.offlineWait = const Duration(minutes: 3),
    this.bufferingTimeout = const Duration(seconds: 20),
  }) : assert(maxAttempts >= 0);

  /// The wait before the first attempt. Each later wait doubles.
  final Duration initialDelay;

  /// The longest wait between attempts.
  final Duration maxDelay;

  /// How many attempts to make before giving up. 0 disables reconnecting.
  final int maxAttempts;

  /// How long to wait for the network to come back before giving up. No
  /// attempts are made while the device has no network.
  final Duration offlineWait;

  /// How long buffering may last before it counts as a dropped connection.
  final Duration bufferingTimeout;

  /// The wait before attempt number `attempt + 1`.
  Duration delayFor(int attempt) {
    final factor = math.pow(2, math.min(attempt, 30)).toInt();
    final delay = initialDelay * factor;
    return delay > maxDelay ? maxDelay : delay;
  }
}
