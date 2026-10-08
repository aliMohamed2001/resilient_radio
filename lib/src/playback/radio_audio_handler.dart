import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../core/radio_config.dart';
import '../core/radio_failure.dart';
import '../diagnostics/failure_mapper.dart';
import 'radio_playback.dart';

class RadioAudioHandler extends BaseAudioHandler {
  RadioAudioHandler({
    AudioPlayer? player,
    Future<AudioSession> Function()? session,
    DateTime Function() clock = DateTime.now,
    this.config = const RadioConfig(),
  })  : _player = player ??
            AudioPlayer(
              handleInterruptions: false,
              handleAudioSessionActivation: false,
            ),
        _openSession = session ?? (() => AudioSession.instance),
        _clock = clock,
        _sessionConfiguration = sessionFor(config.content) {
    _subscriptions
      ..add(_player.playerStateStream.listen(_onPlayerState))
      ..add(_player.errorStream.listen(_onPlayerError));
    _publish();
  }

  static Future<RadioAudioHandler> start(RadioConfig config) {
    final notification = config.notification;
    return AudioService.init(
      builder: () => RadioAudioHandler(config: config),
      config: AudioServiceConfig(
        androidNotificationChannelId: notification.channelId,
        androidNotificationChannelName: notification.channelName,
        androidNotificationChannelDescription: notification.channelDescription,
        androidNotificationIcon: notification.icon,
        notificationColor: notification.color,
      ),
    );
  }

  static AudioSessionConfiguration sessionFor(RadioContent content) {
    final speech = content == RadioContent.speech;
    return AudioSessionConfiguration(
      avAudioSessionCategory: AVAudioSessionCategory.playback,
      avAudioSessionMode: speech
          ? AVAudioSessionMode.spokenAudio
          : AVAudioSessionMode.defaultMode,
      avAudioSessionSetActiveOptions:
          AVAudioSessionSetActiveOptions.notifyOthersOnDeactivation,
      androidAudioAttributes: AndroidAudioAttributes(
        contentType: speech
            ? AndroidAudioContentType.speech
            : AndroidAudioContentType.music,
        usage: AndroidAudioUsage.media,
      ),
      androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
      androidWillPauseWhenDucked: false,
    );
  }

  final RadioConfig config;
  final AudioPlayer _player;
  final Future<AudioSession> Function() _openSession;
  final DateTime Function() _clock;
  final AudioSessionConfiguration _sessionConfiguration;

  final StreamController<RadioPlayback> _playback =
      StreamController<RadioPlayback>.broadcast();
  final List<StreamSubscription<Object?>> _subscriptions = [];

  Future<AudioSession>? _session;
  RadioPlayback _current = const RadioPlayback();
  bool _wantsToPlay = false;
  bool _stopped = true;
  bool _interrupted = false;
  bool _stalled = false;
  bool _ducked = false;
  bool _hasPlayed = false;
  RadioFailure? _failure;
  DateTime? _pausedAt;
  int _loadToken = 0;
  Timer? _stallWatchdog;

  Stream<RadioPlayback> get playback => _playback.stream;

  RadioPlayback get current => _current;

  bool get _isAndroid => defaultTargetPlatform == TargetPlatform.android;

  @override
  Future<void> playMediaItem(MediaItem mediaItem) async {
    this.mediaItem.add(mediaItem);
    await _load();
  }

  @override
  Future<void> play() async {
    if (mediaItem.value == null) return;
    if (_canResumeInPlace) {
      await _resumeInPlace();
      return;
    }
    try {
      await _load();
    } on RadioException catch (error) {
      _log(RadioLogLevel.info, 'resume failed: $error');
    }
  }

  @override
  Future<void> pause() async {
    _loadToken++;
    _wantsToPlay = false;
    _interrupted = false;
    _clearStall();
    _pausedAt = _clock();
    _publish();
    await _player.pause();
  }

  @override
  Future<void> stop() async {
    _loadToken++;
    _wantsToPlay = false;
    _stopped = true;
    _interrupted = false;
    _pausedAt = null;
    _clearStall();
    _publish();
    await _restoreVolume();
    await _player.stop();
    await _deactivateSession();
  }

  @override
  Future<void> onTaskRemoved() async {
    if (!_wantsToPlay) await stop();
  }

  Future<void> holdForReconnect() async {
    if (!_wantsToPlay) return;
    _loadToken++;
    _interrupted = false;
    _stall(null);
    await _player.stop();
  }

  Future<void> dispose() async {
    _stallWatchdog?.cancel();
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    await _player.dispose();
    await _playback.close();
  }

  Future<void> _load() async {
    final item = mediaItem.value;
    if (item == null) return;
    final token = ++_loadToken;
    _wantsToPlay = true;
    _stopped = false;
    _interrupted = false;
    _hasPlayed = false;
    _pausedAt = null;
    _clearStall();
    _publish();
    try {
      if (!await _activateSession()) {
        if (token == _loadToken) await _yieldFocus();
        return;
      }
      if (token != _loadToken) return;
      await _player
          .setAudioSource(AudioSource.uri(Uri.parse(item.id), tag: item))
          .timeout(config.loadTimeout);
      if (token != _loadToken || !_wantsToPlay || _interrupted) return;
      _startPlayer();
    } on PlayerInterruptedException {
      return;
    } on TimeoutException catch (error) {
      if (token != _loadToken) return;
      await _player.stop();
      _fail(RadioFailure.timeout);
      throw RadioException(RadioFailure.timeout, cause: error);
    } on PlayerException catch (error) {
      if (token != _loadToken) return;
      final failure = FailureMapper.fromPlayerException(
        error,
        android: _isAndroid,
      );
      _fail(failure);
      throw RadioException(failure, cause: error);
    } on Object catch (error, stackTrace) {
      if (token != _loadToken) return;
      _log(RadioLogLevel.error, 'load failed', error, stackTrace);
      _fail(RadioFailure.playbackFailed);
      throw RadioException(RadioFailure.playbackFailed, cause: error);
    }
  }

  Future<void> _resumeInPlace() async {
    final token = ++_loadToken;
    _wantsToPlay = true;
    _stopped = false;
    _interrupted = false;
    _clearStall();
    _publish();
    if (!await _activateSession()) {
      if (token == _loadToken) await _yieldFocus();
      return;
    }
    if (token != _loadToken || !_wantsToPlay) return;
    _startPlayer();
  }

  bool get _canResumeInPlace {
    final pausedAt = _pausedAt;
    return pausedAt != null &&
        !_stalled &&
        _player.processingState == ProcessingState.ready &&
        _clock().difference(pausedAt) < config.liveResumeWindow;
  }

  void _startPlayer() {
    unawaited(
      _player.play().catchError((Object error) {
        if (error is PlayerException) {
          _onPlayerError(error);
        } else if (error is! PlayerInterruptedException) {
          _log(RadioLogLevel.warning, 'player refused to start', error);
          _fail(RadioFailure.playbackFailed);
        }
      }),
    );
  }

  void _onPlayerState(PlayerState state) {
    if (_wantsToPlay &&
        state.playing &&
        state.processingState == ProcessingState.ready) {
      _hasPlayed = true;
    }
    if (_wantsToPlay &&
        !_stalled &&
        !_interrupted &&
        state.processingState == ProcessingState.completed) {
      _fail(RadioFailure.connectionLost);
      return;
    }
    _publish();
  }

  void _onPlayerError(PlayerException error) {
    if (!_wantsToPlay || _stalled) return;
    _log(RadioLogLevel.warning, 'stream error ${error.code}: ${error.message}');
    _fail(FailureMapper.fromPlayerException(error, android: _isAndroid));
  }

  void _onInterruption(AudioInterruptionEvent event) {
    if (event.begin) {
      switch (event.type) {
        case AudioInterruptionType.duck:
          unawaited(_duck());
        case AudioInterruptionType.pause:
          unawaited(_interrupt());
        case AudioInterruptionType.unknown:
          unawaited(_isAndroid ? _yieldFocus() : _interrupt());
      }
      return;
    }
    switch (event.type) {
      case AudioInterruptionType.duck:
        unawaited(_restoreVolume());
      case AudioInterruptionType.pause:
        if (_interrupted) unawaited(play());
      case AudioInterruptionType.unknown:
        if (_interrupted) unawaited(pause());
    }
  }

  void _onBecomingNoisy() {
    if (_wantsToPlay || _interrupted) unawaited(pause());
  }

  Future<void> _interrupt() async {
    if (!_wantsToPlay || _interrupted) return;
    _interrupted = true;
    _pausedAt = _clock();
    _publish();
    await _player.pause();
  }

  Future<void> _yieldFocus() async {
    if (_wantsToPlay || _interrupted) await pause();
  }

  Future<void> _duck() async {
    if (!_wantsToPlay || _ducked) return;
    _ducked = true;
    await _player.setVolume(config.duckVolume);
  }

  Future<void> _restoreVolume() async {
    if (!_ducked) return;
    _ducked = false;
    await _player.setVolume(1);
  }

  void _fail(RadioFailure failure) {
    if (_stalled && _failure == failure) return;
    _stall(failure);
  }

  void _stall(RadioFailure? failure) {
    _stalled = true;
    _failure = failure;
    _stallWatchdog?.cancel();
    _stallWatchdog = Timer(config.stallWatchdog, _onStallWatchdog);
    _publish();
  }

  void _clearStall() {
    _stalled = false;
    _failure = null;
    _stallWatchdog?.cancel();
    _stallWatchdog = null;
  }

  void _onStallWatchdog() {
    if (!_wantsToPlay || !_stalled) return;
    _log(
        RadioLogLevel.warning, 'no audio for ${config.stallWatchdog}, pausing');
    unawaited(pause());
  }

  Future<AudioSession> _prepareSession() async {
    final session = await _openSession();
    _subscriptions
      ..add(session.interruptionEventStream.listen(_onInterruption))
      ..add(session.becomingNoisyEventStream.listen((_) => _onBecomingNoisy()));
    return session;
  }

  Future<bool> _activateSession() async {
    try {
      final session = await (_session ??= _prepareSession());
      await session.configure(_sessionConfiguration);
      return await session.setActive(true);
    } on Object catch (error, stackTrace) {
      _log(RadioLogLevel.error, 'audio session failed', error, stackTrace);
      return true;
    }
  }

  Future<void> _deactivateSession() async {
    final pending = _session;
    if (pending == null) return;
    try {
      await (await pending).setActive(false);
    } on Object catch (error) {
      _log(RadioLogLevel.warning, 'could not release the audio session', error);
    }
  }

  RadioPlaybackPhase _phase() {
    if (!_wantsToPlay) {
      return _stopped ? RadioPlaybackPhase.idle : RadioPlaybackPhase.paused;
    }
    if (_interrupted) return RadioPlaybackPhase.interrupted;
    if (_stalled) return RadioPlaybackPhase.stalled;
    return switch (_player.processingState) {
      ProcessingState.idle ||
      ProcessingState.loading =>
        RadioPlaybackPhase.loading,
      ProcessingState.buffering =>
        _hasPlayed ? RadioPlaybackPhase.buffering : RadioPlaybackPhase.loading,
      ProcessingState.ready => _player.playing
          ? RadioPlaybackPhase.playing
          : RadioPlaybackPhase.loading,
      ProcessingState.completed => RadioPlaybackPhase.stalled,
    };
  }

  void _publish() {
    final phase = _phase();
    final snapshot = RadioPlayback(
      phase: phase,
      failure: phase == RadioPlaybackPhase.stalled ? _failure : null,
    );
    if (snapshot != _current) {
      _current = snapshot;
      if (!_playback.isClosed) _playback.add(snapshot);
    }
    playbackState.add(
      PlaybackState(
        controls: [
          _wantsToPlay ? MediaControl.pause : MediaControl.play,
          MediaControl.stop,
        ],
        androidCompactActionIndices: const [0, 1],
        processingState: switch (phase) {
          RadioPlaybackPhase.idle => AudioProcessingState.idle,
          RadioPlaybackPhase.loading => AudioProcessingState.loading,
          RadioPlaybackPhase.buffering ||
          RadioPlaybackPhase.stalled =>
            AudioProcessingState.buffering,
          RadioPlaybackPhase.playing ||
          RadioPlaybackPhase.paused ||
          RadioPlaybackPhase.interrupted =>
            AudioProcessingState.ready,
        },
        playing: _wantsToPlay,
        updatePosition: _player.position,
        bufferedPosition: _player.bufferedPosition,
      ),
    );
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
