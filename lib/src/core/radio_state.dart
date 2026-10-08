import 'package:flutter/foundation.dart';

import 'radio_failure.dart';
import 'radio_station.dart';

/// What the radio is doing.
enum RadioStatus {
  /// Nothing has been played yet.
  initial,

  /// Connecting to the stream, before any audio.
  loading,

  /// Audio was playing and the player is waiting for more data.
  buffering,

  /// Audio is playing.
  playing,

  /// Paused by the user, the system controls or another app's audio.
  paused,

  /// The stream dropped and the radio is reconnecting on its own.
  reconnecting,

  /// The device is offline. See [RadioState.failure] for which layer failed.
  noInternet,

  /// The stream failed. See [RadioState.failure].
  error,

  /// Stopped by the user.
  stopped,
}

/// An immutable snapshot of the radio.
@immutable
class RadioState {
  /// Creates a state for [station].
  const RadioState({
    required this.station,
    this.status = RadioStatus.initial,
    this.failure,
    this.attempt = 0,
    this.maxAttempts = 0,
    this.isInternetAvailable = true,
    this.isInterrupted = false,
    this.isCheckingConnection = false,
  });

  /// The station being played, or the one that will play next.
  final RadioStation station;

  /// What the radio is doing.
  final RadioStatus status;

  /// Why the radio is not playing, when it failed or is reconnecting.
  final RadioFailure? failure;

  /// The current reconnect attempt, from 1, or 0 when not reconnecting.
  final int attempt;

  /// How many reconnect attempts are made before giving up.
  final int maxAttempts;

  /// Whether the last check found the internet reachable.
  final bool isInternetAvailable;

  /// Whether playback is paused by another app's audio and will resume when
  /// it ends.
  final bool isInterrupted;

  /// Whether a connection check is running.
  final bool isCheckingConnection;

  /// Whether audio is playing.
  bool get isPlaying => status == RadioStatus.playing;

  /// Whether the radio is reconnecting on its own.
  bool get isReconnecting => status == RadioStatus.reconnecting;

  /// Whether the user wants audio: starting, playing, buffering or
  /// reconnecting.
  bool get isListening => switch (status) {
        RadioStatus.loading ||
        RadioStatus.buffering ||
        RadioStatus.playing ||
        RadioStatus.reconnecting =>
          true,
        _ => false,
      };

  /// Whether the radio is waiting on the network or the stream.
  bool get isBusy =>
      isCheckingConnection ||
      status == RadioStatus.loading ||
      status == RadioStatus.buffering ||
      status == RadioStatus.reconnecting;

  /// Whether there is anything to stop.
  bool get canStop => isListening || status == RadioStatus.paused;

  /// Returns a copy with the given fields replaced. [failure] is a getter so
  /// that it can be cleared with `failure: () => null`.
  RadioState copyWith({
    RadioStation? station,
    RadioStatus? status,
    ValueGetter<RadioFailure?>? failure,
    int? attempt,
    bool? isInternetAvailable,
    bool? isInterrupted,
    bool? isCheckingConnection,
  }) {
    return RadioState(
      station: station ?? this.station,
      status: status ?? this.status,
      failure: failure == null ? this.failure : failure(),
      attempt: attempt ?? this.attempt,
      maxAttempts: maxAttempts,
      isInternetAvailable: isInternetAvailable ?? this.isInternetAvailable,
      isInterrupted: isInterrupted ?? this.isInterrupted,
      isCheckingConnection: isCheckingConnection ?? this.isCheckingConnection,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is RadioState &&
      other.station == station &&
      other.status == status &&
      other.failure == failure &&
      other.attempt == attempt &&
      other.maxAttempts == maxAttempts &&
      other.isInternetAvailable == isInternetAvailable &&
      other.isInterrupted == isInterrupted &&
      other.isCheckingConnection == isCheckingConnection;

  @override
  int get hashCode => Object.hash(
        station,
        status,
        failure,
        attempt,
        maxAttempts,
        isInternetAvailable,
        isInterrupted,
        isCheckingConnection,
      );

  @override
  String toString() {
    final reason = failure == null ? '' : ', ${failure!.name}';
    final retry = attempt == 0 ? '' : ', attempt $attempt/$maxAttempts';
    return 'RadioState(${status.name}$reason$retry)';
  }
}
