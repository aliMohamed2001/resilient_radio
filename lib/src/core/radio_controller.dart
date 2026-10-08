import 'dart:async';

import '../diagnostics/failure_mapper.dart';
import '../network/network_monitor.dart';
import '../playback/radio_engine.dart';
import '../playback/radio_playback.dart';
import '../recovery/reconnect_policy.dart';
import '../stream/stream_probe.dart';
import 'radio_config.dart';
import 'radio_event.dart';
import 'radio_failure.dart';
import 'radio_state.dart';
import 'radio_station.dart';

enum _Session { idle, starting, listening, reconnecting, failing }

typedef _Diagnosis = ({RadioFailure failure, int? statusCode});

class RadioController {
  RadioController({
    required RadioStation station,
    required RadioEngine engine,
    required NetworkMonitor network,
    required StreamProbe probe,
    this.config = const RadioConfig(),
  })  : _station = station,
        _engine = engine,
        _network = network,
        _probe = probe,
        _state = RadioState(
          station: station,
          maxAttempts: config.reconnect.maxAttempts,
        ) {
    _playbackSubscription = _engine.playback.listen(_onPlayback);
  }

  final RadioConfig config;
  final RadioEngine _engine;
  final NetworkMonitor _network;
  final StreamProbe _probe;

  final StreamController<RadioState> _states =
      StreamController<RadioState>.broadcast();
  final StreamController<RadioEvent> _events =
      StreamController<RadioEvent>.broadcast();

  late final StreamSubscription<RadioPlayback> _playbackSubscription;
  StreamSubscription<bool>? _networkSubscription;
  Timer? _retryTimer;
  Timer? _bufferingTimer;

  RadioStation _station;
  RadioStation? _loadedStation;
  RadioState _state;
  _Session _session = _Session.idle;
  RadioPlayback _playback = const RadioPlayback();
  Object? _lastError;
  int _generation = 0;
  int _attempt = 0;
  bool _commandInFlight = false;
  bool _attemptRunning = false;
  bool _awaitingNetwork = false;
  bool _disposed = false;

  ReconnectPolicy get _policy => config.reconnect;

  RadioStation get station => _station;

  RadioState get state => _state;

  Stream<RadioState> get states => _states.stream;

  Stream<RadioEvent> get events => _events.stream;

  Future<RadioFailure?> checkConnection() async {
    if (_disposed) return null;
    if (_session != _Session.idle || _state.isCheckingConnection) {
      return _state.isInternetAvailable ? null : _state.failure;
    }
    final generation = _generation;
    _emit(_state.copyWith(isCheckingConnection: true));
    final offline = await _reachability();
    if (_isStale(generation)) return offline;
    final wasOffline = _state.status == RadioStatus.noInternet;
    if (offline != null) {
      _emit(
        _state.copyWith(
          status: RadioStatus.noInternet,
          failure: () => offline,
          isInternetAvailable: false,
          isCheckingConnection: false,
        ),
      );
      return offline;
    }
    _emit(
      _state.copyWith(
        status: wasOffline ? RadioStatus.initial : _state.status,
        failure: wasOffline ? () => null : null,
        isInternetAvailable: true,
        isCheckingConnection: false,
      ),
    );
    return null;
  }

  Future<void> toggle() => _state.isListening ? pause() : play();

  Future<void> retry() async {
    if (_session == _Session.reconnecting && !_attemptRunning) {
      await _attemptReconnect(_generation);
      return;
    }
    await play();
  }

  Future<void> play() async {
    if (_disposed) return;
    final engaged = _session == _Session.starting ||
        _session == _Session.listening ||
        _session == _Session.failing;
    if (engaged && !_state.isInterrupted) return;

    final resume =
        _state.status == RadioStatus.paused && _loadedStation == _station;
    final generation = _beginCommand();
    _session = _Session.starting;
    _report(RadioPlayRequested(_station));
    _emit(
      _state.copyWith(
        status: _state.status == RadioStatus.noInternet
            ? RadioStatus.noInternet
            : RadioStatus.loading,
        attempt: 0,
        isInterrupted: false,
        isCheckingConnection: true,
      ),
    );

    final offline = await _reachability();
    if (_isStale(generation)) return;
    if (offline != null) {
      _session = _Session.idle;
      _emit(
        _state.copyWith(
          status: RadioStatus.noInternet,
          failure: () => offline,
          isInternetAvailable: false,
          isCheckingConnection: false,
        ),
      );
      _report(RadioFailed(offline));
      return;
    }

    _emit(
      _state.copyWith(
        status: RadioStatus.loading,
        failure: () => null,
        isInternetAvailable: true,
        isCheckingConnection: false,
      ),
    );
    _watchNetwork();
    final failure = await _startStream(resume: resume);
    if (_isStale(generation) || failure == null) return;
    await _failStart(failure, generation);
  }

  Future<void> pause() async {
    if (_disposed) return;
    final interrupted =
        _state.status == RadioStatus.paused && _state.isInterrupted;
    if (!_state.isListening && !interrupted) return;
    _beginCommand();
    _session = _Session.idle;
    _stopWatchingNetwork();
    _emit(
      _state.copyWith(
        status: RadioStatus.paused,
        failure: () => null,
        attempt: 0,
        isInterrupted: false,
        isCheckingConnection: false,
      ),
    );
    if (!interrupted) _report(const RadioPaused());
    await _engine.pause();
  }

  Future<void> stop() async {
    if (_disposed) return;
    _beginCommand();
    _session = _Session.idle;
    _stopWatchingNetwork();
    final wasStopped = _state.status == RadioStatus.stopped;
    _emit(
      _state.copyWith(
        status: RadioStatus.stopped,
        failure: () => null,
        attempt: 0,
        isInterrupted: false,
        isCheckingConnection: false,
      ),
    );
    if (!wasStopped) _report(const RadioStopped());
    await _engine.stop();
  }

  Future<void> setStation(RadioStation station) async {
    if (_disposed || station == _station) return;
    final engaged = _session != _Session.idle;
    _station = station;
    _emit(_state.copyWith(station: station));
    if (!engaged) return;
    _beginCommand();
    _session = _Session.idle;
    _stopWatchingNetwork();
    await play();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _generation++;
    _cancelTimers();
    _stopWatchingNetwork();
    _session = _Session.idle;
    _disposed = true;
    unawaited(_playbackSubscription.cancel());
    await _engine.stop();
    await _engine.dispose();
    await _states.close();
    await _events.close();
  }

  int _beginCommand() {
    _cancelTimers();
    _attempt = 0;
    _awaitingNetwork = false;
    return ++_generation;
  }

  bool _isStale(int generation) => _disposed || generation != _generation;

  Future<RadioFailure?> _reachability() async {
    if (!await _network.hasNetwork()) return RadioFailure.noNetwork;
    if (!await _network.isInternetReachable()) {
      return RadioFailure.internetUnavailable;
    }
    return null;
  }

  Future<RadioFailure?> _startStream({required bool resume}) async {
    _commandInFlight = true;
    _lastError = null;
    try {
      if (resume) {
        await _engine.resume(_station);
      } else {
        _loadedStation = _station;
        await _engine.play(_station);
      }
      return _playback.phase == RadioPlaybackPhase.stalled
          ? _playback.failure
          : null;
    } on RadioException catch (error) {
      _lastError = error.cause;
      return error.failure;
    } on Object catch (error, stackTrace) {
      _lastError = error;
      _log(
          RadioLogLevel.error, 'could not start the stream', error, stackTrace);
      return RadioFailure.playbackFailed;
    } finally {
      _commandInFlight = false;
    }
  }

  Future<_Diagnosis> _classify(RadioFailure failure) async {
    if (failure.isOffline) return (failure: failure, statusCode: null);
    var diagnosed = failure;
    int? statusCode;
    if (!failure.isConclusive) {
      final result = await _probe.check(_station.streamUrl);
      _log(RadioLogLevel.info, 'probed ${_station.streamUrl}: $result');
      statusCode = result.statusCode;
      diagnosed = result.failure ?? failure;
    }
    if (diagnosed.isTransport) {
      diagnosed = await _reachability() ?? diagnosed;
    }
    return (failure: diagnosed, statusCode: statusCode);
  }

  Future<void> _failStart(RadioFailure failure, int generation) async {
    _session = _Session.failing;
    _bufferingTimer?.cancel();
    final error = _lastError;
    final diagnosis = await _classify(failure);
    if (_isStale(generation) || _session != _Session.failing) return;
    _beginCommand();
    _session = _Session.idle;
    _stopWatchingNetwork();
    final diagnosed = diagnosis.failure;
    _log(RadioLogLevel.warning, 'stream did not start: ${diagnosed.name}');
    _emit(
      _state.copyWith(
        status:
            diagnosed.isOffline ? RadioStatus.noInternet : RadioStatus.error,
        failure: () => diagnosed,
        attempt: 0,
        isInternetAvailable: !diagnosed.isOffline,
        isCheckingConnection: false,
      ),
    );
    _report(
      RadioFailed(diagnosed, statusCode: diagnosis.statusCode, error: error),
    );
    await _engine.stop();
  }

  void _beginReconnect(RadioFailure failure) {
    if (_session == _Session.reconnecting) return;
    _session = _Session.reconnecting;
    _attempt = 0;
    _bufferingTimer?.cancel();
    _log(RadioLogLevel.info, 'stream lost (${failure.name}), reconnecting');
    unawaited(_engine.holdForReconnect());
    _scheduleAttempt(failure);
  }

  void _scheduleAttempt(RadioFailure failure, {int? statusCode}) {
    _retryTimer?.cancel();
    if (!failure.isRetryable || _attempt >= _policy.maxAttempts) {
      unawaited(_giveUp(failure, statusCode: statusCode));
      return;
    }
    if (failure == RadioFailure.noNetwork) {
      _awaitingNetwork = true;
      _retryTimer = Timer(
        _policy.offlineWait,
        () => unawaited(_giveUp(RadioFailure.noNetwork)),
      );
      _emit(
        _state.copyWith(
          status: RadioStatus.reconnecting,
          failure: () => failure,
          attempt: _attempt,
          isInternetAvailable: false,
          isInterrupted: false,
        ),
      );
      _report(RadioReconnecting(reason: failure, attempt: _attempt + 1));
      return;
    }
    _awaitingNetwork = false;
    final generation = _generation;
    final delay = _policy.delayFor(_attempt);
    _retryTimer = Timer(
      delay,
      () => unawaited(_attemptReconnect(generation)),
    );
    _emit(
      _state.copyWith(
        status: RadioStatus.reconnecting,
        failure: () => failure,
        attempt: _attempt + 1,
        isInternetAvailable: failure != RadioFailure.internetUnavailable,
        isInterrupted: false,
      ),
    );
    _report(
      RadioReconnecting(reason: failure, attempt: _attempt + 1, delay: delay),
    );
  }

  Future<void> _attemptReconnect(int generation) async {
    if (_isStale(generation) ||
        _session != _Session.reconnecting ||
        _attemptRunning) {
      return;
    }
    _attemptRunning = true;
    _retryTimer?.cancel();
    _awaitingNetwork = false;
    _attempt++;
    try {
      _emit(_state.copyWith(attempt: _attempt));
      final offline = await _reachability();
      if (_isStale(generation) || _session != _Session.reconnecting) return;
      if (offline != null) {
        _scheduleAttempt(offline);
        return;
      }
      final failure = await _startStream(resume: false);
      if (_isStale(generation) || _session != _Session.reconnecting) return;
      if (failure == null) return;
      final diagnosis = await _classify(failure);
      if (_isStale(generation) || _session != _Session.reconnecting) return;
      _scheduleAttempt(diagnosis.failure, statusCode: diagnosis.statusCode);
    } finally {
      _attemptRunning = false;
    }
  }

  Future<void> _giveUp(RadioFailure failure, {int? statusCode}) async {
    _beginCommand();
    _session = _Session.idle;
    _stopWatchingNetwork();
    _log(RadioLogLevel.warning, 'reconnect abandoned: ${failure.name}');
    _emit(
      _state.copyWith(
        status: failure.isOffline ? RadioStatus.noInternet : RadioStatus.error,
        failure: () => failure,
        attempt: 0,
        isInternetAvailable: !failure.isOffline,
        isInterrupted: false,
        isCheckingConnection: false,
      ),
    );
    _report(RadioFailed(failure, statusCode: statusCode, gaveUp: true));
    await _engine.pause();
  }

  void _onPlayback(RadioPlayback playback) {
    _playback = playback;
    switch (playback.phase) {
      case RadioPlaybackPhase.playing:
        _onAudible();
      case RadioPlaybackPhase.loading:
        _onLoading();
      case RadioPlaybackPhase.buffering:
        _onBuffering();
      case RadioPlaybackPhase.stalled:
        final failure = playback.failure;
        if (failure != null) _onStreamFailure(failure);
      case RadioPlaybackPhase.interrupted:
        _onInterrupted();
      case RadioPlaybackPhase.paused:
        _onEndedElsewhere(RadioStatus.paused);
      case RadioPlaybackPhase.idle:
        _onEndedElsewhere(RadioStatus.stopped);
    }
  }

  void _onAudible() {
    if (_session == _Session.failing) return;
    final recovered = _session == _Session.reconnecting;
    final attempts = _attempt;
    final wasPlaying = _state.status == RadioStatus.playing;
    _cancelTimers();
    _attempt = 0;
    _awaitingNetwork = false;
    _session = _Session.listening;
    _watchNetwork();
    _emit(
      _state.copyWith(
        status: RadioStatus.playing,
        failure: () => null,
        attempt: 0,
        isInternetAvailable: true,
        isInterrupted: false,
        isCheckingConnection: false,
      ),
    );
    if (recovered) _report(RadioReconnected(attempts: attempts));
    if (!wasPlaying) _report(const RadioPlaying());
  }

  void _onLoading() {
    switch (_session) {
      case _Session.idle:
        _beginCommand();
        _session = _Session.starting;
        _watchNetwork();
        _report(RadioPlayRequested(_station));
      case _Session.reconnecting || _Session.failing:
        return;
      case _Session.starting || _Session.listening:
        break;
    }
    _emit(
      _state.copyWith(
        status: RadioStatus.loading,
        failure: () => null,
        isInterrupted: false,
        isCheckingConnection: false,
      ),
    );
  }

  void _onBuffering() {
    if (_session != _Session.listening) return;
    final wasBuffering = _state.status == RadioStatus.buffering;
    _emit(
      _state.copyWith(status: RadioStatus.buffering, isInterrupted: false),
    );
    if (!wasBuffering) _report(const RadioBuffering());
    _bufferingTimer?.cancel();
    _bufferingTimer = Timer(_policy.bufferingTimeout, () {
      if (_session == _Session.listening &&
          _playback.phase == RadioPlaybackPhase.buffering) {
        _beginReconnect(RadioFailure.connectionLost);
      }
    });
  }

  void _onStreamFailure(RadioFailure failure) {
    if (_commandInFlight) return;
    switch (_session) {
      case _Session.starting:
        unawaited(_failStart(failure, _generation));
      case _Session.listening:
        _beginReconnect(failure);
      case _Session.reconnecting:
        if (!_attemptRunning) _scheduleAttempt(failure);
      case _Session.idle || _Session.failing:
        break;
    }
  }

  void _onInterrupted() {
    if (_session == _Session.idle || _session == _Session.failing) return;
    _cancelTimers();
    _awaitingNetwork = false;
    if (_session == _Session.reconnecting) _session = _Session.listening;
    final wasInterrupted = _state.isInterrupted;
    _emit(
      _state.copyWith(
        status: RadioStatus.paused,
        attempt: 0,
        isInterrupted: true,
      ),
    );
    if (!wasInterrupted) _report(const RadioPaused(interrupted: true));
  }

  void _onEndedElsewhere(RadioStatus status) {
    if (_session == _Session.idle || _session == _Session.failing) return;
    _beginCommand();
    _session = _Session.idle;
    _stopWatchingNetwork();
    _emit(
      _state.copyWith(
        status: status,
        failure: () => null,
        attempt: 0,
        isInterrupted: false,
        isCheckingConnection: false,
      ),
    );
    _report(
      status == RadioStatus.paused ? const RadioPaused() : const RadioStopped(),
    );
  }

  void _watchNetwork() {
    _networkSubscription ??= _network.changes.listen(_onNetworkChanged);
  }

  void _stopWatchingNetwork() {
    final subscription = _networkSubscription;
    _networkSubscription = null;
    if (subscription != null) unawaited(subscription.cancel());
  }

  void _onNetworkChanged(bool connected) {
    if (_session == _Session.idle) return;
    if (_state.isInternetAvailable != connected) {
      _emit(_state.copyWith(isInternetAvailable: connected));
      _report(
        connected ? const RadioNetworkRestored() : const RadioNetworkLost(),
      );
    }
    switch (_session) {
      case _Session.listening:
        if (!connected && !_state.isInterrupted) {
          _beginReconnect(RadioFailure.noNetwork);
        }
      case _Session.reconnecting:
        if (_attemptRunning) return;
        if (connected) {
          unawaited(_attemptReconnect(_generation));
        } else if (!_awaitingNetwork) {
          _scheduleAttempt(RadioFailure.noNetwork);
        }
      case _Session.idle || _Session.starting || _Session.failing:
        break;
    }
  }

  void _cancelTimers() {
    _retryTimer?.cancel();
    _retryTimer = null;
    _bufferingTimer?.cancel();
    _bufferingTimer = null;
  }

  void _emit(RadioState next) {
    if (_disposed || next == _state) return;
    _state = next;
    _states.add(next);
  }

  void _report(RadioEvent event) {
    if (!_disposed) _events.add(event);
  }

  void _log(
    RadioLogLevel level,
    String message, [
    Object? error,
    StackTrace? stackTrace,
  ]) {
    config.logger?.call(level, message, error: error, stackTrace: stackTrace);
  }
}
