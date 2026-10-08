import 'radio_failure.dart';
import 'radio_station.dart';

/// Something that happened to the radio, for analytics, logs or one-off UI
/// such as a dialog. Use the state stream for what the radio is doing now.
sealed class RadioEvent {
  const RadioEvent();
}

/// Playback was requested, from the app or from the system media controls.
final class RadioPlayRequested extends RadioEvent {
  const RadioPlayRequested(this.station);

  final RadioStation station;

  @override
  String toString() => 'RadioPlayRequested(${station.id})';
}

/// Audio started playing.
final class RadioPlaying extends RadioEvent {
  const RadioPlaying();

  @override
  String toString() => 'RadioPlaying()';
}

/// Audio stopped to wait for more data.
final class RadioBuffering extends RadioEvent {
  const RadioBuffering();

  @override
  String toString() => 'RadioBuffering()';
}

/// Playback paused. [interrupted] is true when another app's audio paused it
/// and it will resume on its own.
final class RadioPaused extends RadioEvent {
  const RadioPaused({this.interrupted = false});

  final bool interrupted;

  @override
  String toString() => 'RadioPaused(interrupted: $interrupted)';
}

/// Playback stopped.
final class RadioStopped extends RadioEvent {
  const RadioStopped();

  @override
  String toString() => 'RadioStopped()';
}

/// A reconnect attempt is scheduled after the stream dropped because of
/// [reason]. [delay] is null while the radio waits for the network to return.
final class RadioReconnecting extends RadioEvent {
  const RadioReconnecting({
    required this.reason,
    required this.attempt,
    this.delay,
  });

  final RadioFailure reason;
  final int attempt;
  final Duration? delay;

  @override
  String toString() =>
      'RadioReconnecting(${reason.name}, attempt $attempt, delay: $delay)';
}

/// Audio is back after a drop. [attempts] is how many attempts it took.
final class RadioReconnected extends RadioEvent {
  const RadioReconnected({required this.attempts});

  final int attempts;

  @override
  String toString() => 'RadioReconnected(attempts: $attempts)';
}

/// The device lost its network while the radio was in use.
final class RadioNetworkLost extends RadioEvent {
  const RadioNetworkLost();

  @override
  String toString() => 'RadioNetworkLost()';
}

/// The device got its network back while the radio was in use.
final class RadioNetworkRestored extends RadioEvent {
  const RadioNetworkRestored();

  @override
  String toString() => 'RadioNetworkRestored()';
}

/// Playback failed.
///
/// [gaveUp] is false when a play request failed, and true when the radio
/// stopped reconnecting after a drop. [statusCode] is the HTTP status of the
/// stream when the failure was diagnosed with a request to it.
final class RadioFailed extends RadioEvent {
  const RadioFailed(
    this.failure, {
    this.statusCode,
    this.error,
    this.gaveUp = false,
  });

  final RadioFailure failure;
  final int? statusCode;
  final Object? error;
  final bool gaveUp;

  @override
  String toString() {
    final status = statusCode == null ? '' : ', HTTP $statusCode';
    return 'RadioFailed(${failure.name}$status, gaveUp: $gaveUp)';
  }
}
