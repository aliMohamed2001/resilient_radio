import 'package:flutter/foundation.dart';

import '../core/radio_failure.dart';

enum RadioPlaybackPhase {
  idle,
  loading,
  buffering,
  playing,
  paused,
  interrupted,
  stalled,
}

@immutable
class RadioPlayback {
  const RadioPlayback({this.phase = RadioPlaybackPhase.idle, this.failure});

  final RadioPlaybackPhase phase;
  final RadioFailure? failure;

  @override
  bool operator ==(Object other) =>
      other is RadioPlayback &&
      other.phase == phase &&
      other.failure == failure;

  @override
  int get hashCode => Object.hash(phase, failure);

  @override
  String toString() => 'RadioPlayback(${phase.name}, ${failure?.name})';
}

final class RadioException implements Exception {
  const RadioException(this.failure, {this.cause});

  final RadioFailure failure;
  final Object? cause;

  @override
  String toString() {
    final reason = cause == null ? '' : ': $cause';
    return 'RadioException(${failure.name})$reason';
  }
}
