import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:resilient_radio/resilient_radio.dart';
import 'package:resilient_radio/src/network/network_monitor.dart';
import 'package:resilient_radio/src/playback/radio_engine.dart';
import 'package:resilient_radio/src/playback/radio_playback.dart';

final station = RadioStation(
  id: 'test',
  name: 'Test Radio',
  description: 'Live',
  streamUrl: Uri.parse('https://example.com/live'),
);

final otherStation = RadioStation(
  id: 'other',
  name: 'Other Radio',
  streamUrl: Uri.parse('https://example.com/other'),
);

class FakeNetworkMonitor implements NetworkMonitor {
  bool network = true;
  bool internet = true;
  final List<bool> internetSequence = [];
  Completer<void>? gate;
  int reachabilityChecks = 0;

  final StreamController<bool> _changes = StreamController<bool>.broadcast();

  bool get isWatched => _changes.hasListener;

  void change({required bool connected}) {
    network = connected;
    _changes.add(connected);
  }

  @override
  Future<bool> hasNetwork() async => network;

  @override
  Future<bool> isInternetReachable() async {
    reachabilityChecks++;
    final pending = gate;
    if (pending != null) await pending.future;
    if (internetSequence.isNotEmpty) return internetSequence.removeAt(0);
    return internet;
  }

  @override
  Stream<bool> get changes => _changes.stream;
}

class FakeEngine implements RadioEngine {
  final StreamController<RadioPlayback> _playback =
      StreamController<RadioPlayback>.broadcast();
  final List<String> calls = [];
  final List<RadioStation> played = [];

  RadioFailure? playFailure;
  Object? playError;
  bool startsAudibly = true;

  int count(String call) => calls.where((entry) => entry == call).length;

  void emit(RadioPlaybackPhase phase, [RadioFailure? failure]) =>
      _playback.add(RadioPlayback(phase: phase, failure: failure));

  @override
  Stream<RadioPlayback> get playback => _playback.stream;

  @override
  Future<void> play(RadioStation station) async {
    calls.add('play');
    played.add(station);
    emit(RadioPlaybackPhase.loading);
    final failure = playFailure;
    if (failure != null) {
      emit(RadioPlaybackPhase.stalled, failure);
      throw RadioException(failure, cause: playError);
    }
    if (startsAudibly) emit(RadioPlaybackPhase.playing);
  }

  @override
  Future<void> resume(RadioStation station) async {
    calls.add('resume');
    if (startsAudibly) emit(RadioPlaybackPhase.playing);
  }

  @override
  Future<void> pause() async {
    calls.add('pause');
    emit(RadioPlaybackPhase.paused);
  }

  @override
  Future<void> stop() async {
    calls.add('stop');
    emit(RadioPlaybackPhase.idle);
  }

  @override
  Future<void> holdForReconnect() async {
    calls.add('hold');
    emit(RadioPlaybackPhase.stalled);
  }

  @override
  Future<void> dispose() async {
    calls.add('dispose');
    await _playback.close();
  }
}

class FakeStreamProbe implements StreamProbe {
  StreamProbeResult result = const StreamProbeResult();
  int checks = 0;

  @override
  Duration get timeout => Duration.zero;

  @override
  Future<StreamProbeResult> check(Uri stream) async {
    checks++;
    return result;
  }
}

class FakePlayer extends Fake implements AudioPlayer {
  final StreamController<PlayerState> _states =
      StreamController<PlayerState>.broadcast();
  final StreamController<PlayerException> _errors =
      StreamController<PlayerException>.broadcast();
  final List<String> calls = [];

  ProcessingState _processing = ProcessingState.idle;
  bool _playing = false;
  double level = 1;
  Object? loadError;
  Uri? source;

  void update({ProcessingState? processing, bool? playing}) {
    _processing = processing ?? _processing;
    _playing = playing ?? _playing;
    _states.add(PlayerState(_playing, _processing));
  }

  void fail(PlayerException error) => _errors.add(error);

  void buffer() => update(processing: ProcessingState.buffering);

  @override
  Stream<PlayerState> get playerStateStream => _states.stream;

  @override
  Stream<PlayerException> get errorStream => _errors.stream;

  @override
  ProcessingState get processingState => _processing;

  @override
  bool get playing => _playing;

  @override
  Duration get position => Duration.zero;

  @override
  Duration get bufferedPosition => Duration.zero;

  @override
  Future<Duration?> setAudioSource(
    AudioSource audioSource, {
    bool preload = true,
    int? initialIndex,
    Duration? initialPosition,
  }) async {
    calls.add('load');
    if (audioSource is UriAudioSource) source = audioSource.uri;
    update(processing: ProcessingState.loading);
    final error = loadError;
    if (error != null) {
      update(processing: ProcessingState.idle);
      throw error;
    }
    update(processing: ProcessingState.ready);
    return null;
  }

  @override
  Future<void> play() async {
    calls.add('play');
    update(playing: true);
  }

  @override
  Future<void> pause() async {
    calls.add('pause');
    update(playing: false);
  }

  @override
  Future<void> stop() async {
    calls.add('stop');
    update(playing: false, processing: ProcessingState.idle);
  }

  @override
  Future<void> setVolume(double volume) async => level = volume;

  @override
  Future<void> dispose() async {
    await _states.close();
    await _errors.close();
  }
}

class FakeSession extends Fake implements AudioSession {
  final StreamController<AudioInterruptionEvent> interruptions =
      StreamController<AudioInterruptionEvent>.broadcast();
  final StreamController<void> noisy = StreamController<void>.broadcast();
  final List<bool> activations = [];
  final List<AudioSessionConfiguration> configurations = [];
  bool grantsFocus = true;

  @override
  Stream<AudioInterruptionEvent> get interruptionEventStream =>
      interruptions.stream;

  @override
  Stream<void> get becomingNoisyEventStream => noisy.stream;

  @override
  Future<void> configure(AudioSessionConfiguration configuration) async {
    configurations.add(configuration);
  }

  @override
  Future<bool> setActive(
    bool active, {
    AVAudioSessionSetActiveOptions? avAudioSessionSetActiveOptions,
    AndroidAudioFocusGainType? androidAudioFocusGainType,
    AndroidAudioAttributes? androidAudioAttributes,
    bool? androidWillPauseWhenDucked,
    AudioSessionConfiguration fallbackConfiguration =
        const AudioSessionConfiguration.music(),
  }) async {
    activations.add(active);
    return !active || grantsFocus;
  }
}
