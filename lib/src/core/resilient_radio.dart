import '../network/network_monitor.dart';
import '../playback/radio_engine.dart';
import '../stream/stream_probe.dart';
import 'radio_config.dart';
import 'radio_controller.dart';
import 'radio_event.dart';
import 'radio_failure.dart';
import 'radio_state.dart';
import 'radio_station.dart';

/// Plays a live stream in the background and keeps it playing.
///
/// Create one for the lifetime of the app: the background audio service it
/// runs on can only be started once per app. Nothing touches the network or
/// the audio service until [play] is called.
///
/// ```dart
/// final radio = ResilientRadio(
///   station: RadioStation(
///     id: 'my_station',
///     name: 'My Radio',
///     streamUrl: Uri.parse('https://example.com/live'),
///   ),
/// );
///
/// radio.stateStream.listen((state) => print(state.status));
/// await radio.play();
/// ```
class ResilientRadio {
  ResilientRadio({
    required RadioStation station,
    RadioConfig config = const RadioConfig(),
  }) : _controller = RadioController(
          station: station,
          config: config,
          engine: AudioServiceEngine(config: config),
          network: ConnectivityNetworkMonitor(
            probes: config.internetProbes,
            timeout: config.internetProbeTimeout,
            logger: config.logger,
          ),
          probe: StreamProbe(timeout: config.streamProbeTimeout),
        );

  final RadioController _controller;

  /// The settings this radio was created with.
  RadioConfig get config => _controller.config;

  /// The station that is playing, or that plays next.
  RadioStation get station => _controller.station;

  /// The current state.
  RadioState get state => _controller.state;

  /// Every change of [state]. It does not replay the current state to new
  /// listeners; read [state] first.
  Stream<RadioState> get stateStream => _controller.states;

  /// What happens to the radio, as it happens.
  Stream<RadioEvent> get eventStream => _controller.events;

  /// The [RadioFailed] events of [eventStream].
  Stream<RadioFailed> get failureStream => _controller.events
      .where((event) => event is RadioFailed)
      .cast<RadioFailed>();

  /// Checks the network and the internet, then plays [station].
  ///
  /// It does not throw: failures end up in [state] and [eventStream]. A pause
  /// shorter than [RadioConfig.liveResumeWindow] resumes in place.
  Future<void> play() => _controller.play();

  /// Pauses playback and any reconnecting.
  Future<void> pause() => _controller.pause();

  /// Stops playback and cancels any reconnect attempt, including one in
  /// flight.
  Future<void> stop() => _controller.stop();

  /// Plays again after a failure. While reconnecting, it skips the remaining
  /// wait and tries right away.
  Future<void> retry() => _controller.retry();

  /// Pauses when listening, plays otherwise.
  Future<void> toggle() => _controller.toggle();

  /// Checks the network and the internet without playing, and returns why
  /// the radio is offline, or null when it is online.
  ///
  /// Useful when a screen opens, to tell the user before they press play.
  Future<RadioFailure?> checkConnection() => _controller.checkConnection();

  /// Switches to [station]. If the radio is in use, the new station plays
  /// right away.
  Future<void> setStation(RadioStation station) =>
      _controller.setStation(station);

  /// Stops playback and closes the streams.
  Future<void> dispose() => _controller.dispose();
}
