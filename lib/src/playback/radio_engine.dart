import 'dart:async';

import 'package:audio_service/audio_service.dart';

import '../core/radio_config.dart';
import '../core/radio_failure.dart';
import '../core/radio_station.dart';
import 'radio_audio_handler.dart';
import 'radio_playback.dart';

abstract interface class RadioEngine {
  Stream<RadioPlayback> get playback;

  Future<void> play(RadioStation station);

  Future<void> resume(RadioStation station);

  Future<void> pause();

  Future<void> stop();

  Future<void> holdForReconnect();

  Future<void> dispose();
}

class AudioServiceEngine implements RadioEngine {
  AudioServiceEngine({
    this.config = const RadioConfig(),
    Future<RadioAudioHandler> Function()? start,
  }) : _start = start ?? (() => _service ??= RadioAudioHandler.start(config));

  static Future<RadioAudioHandler>? _service;

  final RadioConfig config;
  final Future<RadioAudioHandler> Function() _start;

  final StreamController<RadioPlayback> _playback =
      StreamController<RadioPlayback>.broadcast();

  Future<RadioAudioHandler>? _handler;
  StreamSubscription<RadioPlayback>? _relay;

  @override
  Stream<RadioPlayback> get playback => _playback.stream;

  @override
  Future<void> play(RadioStation station) async {
    final handler = await _ready();
    await handler.playMediaItem(
      MediaItem(
        id: station.streamUrl.toString(),
        title: station.name,
        artist: station.description,
        artUri: station.artworkUrl,
        isLive: true,
        extras: station.metadata.isEmpty ? null : station.metadata,
      ),
    );
  }

  @override
  Future<void> resume(RadioStation station) async {
    final handler = await _ready();
    if (handler.mediaItem.value == null) return play(station);
    await handler.play();
  }

  @override
  Future<void> pause() => _whenStarted((handler) => handler.pause());

  @override
  Future<void> stop() => _whenStarted((handler) => handler.stop());

  @override
  Future<void> holdForReconnect() =>
      _whenStarted((handler) => handler.holdForReconnect());

  @override
  Future<void> dispose() async {
    await _relay?.cancel();
    _relay = null;
    await _playback.close();
  }

  Future<RadioAudioHandler> _ready() => _handler ??= _connect();

  Future<RadioAudioHandler> _connect() async {
    try {
      final handler = await _start().timeout(config.startTimeout);
      if (!_playback.isClosed) {
        _playback.add(handler.current);
        _relay = handler.playback.listen(_playback.add);
      }
      return handler;
    } on Object catch (error, stackTrace) {
      _handler = null;
      config.logger?.call(
        RadioLogLevel.error,
        'audio service did not start',
        error: error,
        stackTrace: stackTrace,
      );
      throw RadioException(RadioFailure.audioUnavailable, cause: error);
    }
  }

  Future<void> _whenStarted(
    Future<void> Function(RadioAudioHandler handler) action,
  ) async {
    final pending = _handler;
    if (pending == null) return;
    final RadioAudioHandler handler;
    try {
      handler = await pending;
    } on RadioException {
      return;
    }
    await action(handler);
  }
}
