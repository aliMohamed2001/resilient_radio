import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:resilient_radio/resilient_radio.dart';
import 'package:resilient_radio/src/playback/radio_audio_handler.dart';
import 'package:resilient_radio/src/playback/radio_playback.dart';

import 'fakes.dart';

const _item = MediaItem(
  id: 'https://example.com/live',
  title: 'Test Radio',
  isLive: true,
);

void main() {
  late FakePlayer player;
  late FakeSession session;
  late DateTime now;

  setUp(() {
    player = FakePlayer();
    session = FakeSession();
    now = DateTime(2026, 10, 8, 12);
  });

  tearDown(() => debugDefaultTargetPlatformOverride = null);

  RadioAudioHandler build([RadioConfig config = const RadioConfig()]) =>
      RadioAudioHandler(
        player: player,
        session: () async => session,
        clock: () => now,
        config: config,
      );

  void run(void Function(FakeAsync async, RadioAudioHandler h) body) {
    fakeAsync((async) {
      final handler = build();
      body(async, handler);
      handler.dispose();
      async.flushMicrotasks();
    });
  }

  void startPlaying(FakeAsync async, RadioAudioHandler handler) {
    handler.playMediaItem(_item);
    async.flushMicrotasks();
    expect(handler.current.phase, RadioPlaybackPhase.playing);
    player.calls.clear();
  }

  void interrupt(FakeAsync async, AudioInterruptionType type, bool begin) {
    session.interruptions.add(AudioInterruptionEvent(begin, type));
    async.flushMicrotasks();
  }

  test('plays the stream and tells the system it is playing', () {
    run((async, handler) {
      handler.playMediaItem(_item);
      async.flushMicrotasks();

      expect(player.calls, ['load', 'play']);
      expect(player.source, Uri.parse(_item.id));
      expect(session.activations, [true]);
      expect(handler.current.phase, RadioPlaybackPhase.playing);
      expect(handler.mediaItem.value, _item);
      expect(handler.playbackState.value.playing, isTrue);
      expect(
        handler.playbackState.value.processingState,
        AudioProcessingState.ready,
      );
      expect(handler.playbackState.value.controls, [
        MediaControl.pause,
        MediaControl.stop,
      ]);
    });
  });

  test('the audio session follows the configured content', () {
    final music = RadioAudioHandler.sessionFor(RadioContent.music);
    final speech = RadioAudioHandler.sessionFor(RadioContent.speech);

    expect(
      music.androidAudioAttributes?.contentType,
      AndroidAudioContentType.music,
    );
    expect(music.avAudioSessionMode, AVAudioSessionMode.defaultMode);
    expect(
      speech.androidAudioAttributes?.contentType,
      AndroidAudioContentType.speech,
    );
    expect(speech.avAudioSessionMode, AVAudioSessionMode.spokenAudio);
    expect(speech.androidWillPauseWhenDucked, isFalse);

    fakeAsync((async) {
      final handler = build(const RadioConfig(content: RadioContent.speech));
      handler.playMediaItem(_item);
      async.flushMicrotasks();
      expect(
        session.configurations.single.avAudioSessionMode,
        AVAudioSessionMode.spokenAudio,
      );
      handler.dispose();
      async.flushMicrotasks();
    });
  });

  test('a transient interruption pauses and resumes when allowed', () {
    run((async, handler) {
      startPlaying(async, handler);

      interrupt(async, AudioInterruptionType.pause, true);
      expect(player.calls, ['pause']);
      expect(handler.current.phase, RadioPlaybackPhase.interrupted);
      expect(handler.playbackState.value.playing, isTrue);

      now = now.add(const Duration(seconds: 10));
      interrupt(async, AudioInterruptionType.pause, false);
      expect(player.calls, ['pause', 'play']);
      expect(handler.current.phase, RadioPlaybackPhase.playing);
    });
  });

  test('a long interruption reconnects to the live edge on resume', () {
    run((async, handler) {
      startPlaying(async, handler);

      interrupt(async, AudioInterruptionType.pause, true);
      now = now.add(const Duration(minutes: 5));
      interrupt(async, AudioInterruptionType.pause, false);

      expect(player.calls, ['pause', 'load', 'play']);
      expect(handler.current.phase, RadioPlaybackPhase.playing);
    });
  });

  test('an iOS interruption that may not resume stays paused', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    run((async, handler) {
      startPlaying(async, handler);

      interrupt(async, AudioInterruptionType.unknown, true);
      expect(handler.current.phase, RadioPlaybackPhase.interrupted);

      interrupt(async, AudioInterruptionType.unknown, false);
      expect(handler.current.phase, RadioPlaybackPhase.paused);
      expect(handler.playbackState.value.playing, isFalse);
      expect(player.calls.where((call) => call == 'play'), isEmpty);
    });
  });

  test('a permanent focus loss on Android pauses for good', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    run((async, handler) {
      startPlaying(async, handler);

      interrupt(async, AudioInterruptionType.unknown, true);
      expect(handler.current.phase, RadioPlaybackPhase.paused);
      expect(handler.playbackState.value.playing, isFalse);

      interrupt(async, AudioInterruptionType.pause, false);
      expect(player.calls, ['pause']);
    });
  });

  test('a user stop during an interruption prevents the resume', () {
    run((async, handler) {
      startPlaying(async, handler);

      interrupt(async, AudioInterruptionType.pause, true);
      handler.stop();
      async.flushMicrotasks();
      interrupt(async, AudioInterruptionType.pause, false);

      expect(player.calls, ['pause', 'stop']);
      expect(handler.current.phase, RadioPlaybackPhase.idle);
      expect(
        handler.playbackState.value.processingState,
        AudioProcessingState.idle,
      );
      expect(session.activations.last, isFalse);
    });
  });

  test('an interruption that starts while paused never resumes', () {
    run((async, handler) {
      startPlaying(async, handler);
      handler.pause();
      async.flushMicrotasks();

      interrupt(async, AudioInterruptionType.pause, true);
      interrupt(async, AudioInterruptionType.pause, false);

      expect(player.calls, ['pause']);
      expect(handler.current.phase, RadioPlaybackPhase.paused);
    });
  });

  test('unplugging headphones pauses immediately', () {
    run((async, handler) {
      startPlaying(async, handler);

      session.noisy.add(null);
      async.flushMicrotasks();

      expect(player.calls, ['pause']);
      expect(handler.current.phase, RadioPlaybackPhase.paused);
      expect(handler.playbackState.value.playing, isFalse);
    });
  });

  test('ducking lowers the volume and restores it', () {
    run((async, handler) {
      startPlaying(async, handler);

      interrupt(async, AudioInterruptionType.duck, true);
      expect(player.level, handler.config.duckVolume);
      expect(handler.current.phase, RadioPlaybackPhase.playing);

      interrupt(async, AudioInterruptionType.duck, false);
      expect(player.level, 1);
    });
  });

  test('a stream error stalls with the mapped failure and keeps going', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    run((async, handler) {
      startPlaying(async, handler);

      player.fail(PlayerException(0, 'Source error', 0));
      async.flushMicrotasks();

      expect(handler.current.phase, RadioPlaybackPhase.stalled);
      expect(handler.current.failure, RadioFailure.connectionLost);
      expect(handler.playbackState.value.playing, isTrue);
      expect(
        handler.playbackState.value.processingState,
        AudioProcessingState.buffering,
      );
    });
  });

  test('a live stream that ends is treated as a lost connection', () {
    run((async, handler) {
      startPlaying(async, handler);

      player.update(processing: ProcessingState.completed);
      async.flushMicrotasks();

      expect(handler.current.phase, RadioPlaybackPhase.stalled);
      expect(handler.current.failure, RadioFailure.connectionLost);
    });
  });

  test('a load failure throws and stalls with the failure', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    fakeAsync((async) {
      final handler = build();
      player.loadError = PlayerException(1, 'Renderer error', 0);
      Object? thrown;
      handler.playMediaItem(_item).catchError((Object error) {
        thrown = error;
      });
      async.flushMicrotasks();

      expect(thrown, isA<RadioException>());
      expect((thrown! as RadioException).failure, RadioFailure.invalidStream);
      expect(handler.current.phase, RadioPlaybackPhase.stalled);
      handler.dispose();
      async.flushMicrotasks();
    });
  });

  test('a slow load times out with its own failure', () {
    fakeAsync((async) {
      final handler = RadioAudioHandler(
        player: _SlowPlayer(),
        session: () async => session,
        clock: () => now,
        config: const RadioConfig(loadTimeout: Duration(seconds: 3)),
      );
      Object? thrown;
      handler.playMediaItem(_item).catchError((Object error) {
        thrown = error;
      });
      async.elapse(const Duration(seconds: 3));

      expect((thrown! as RadioException).failure, RadioFailure.timeout);
      expect(handler.current.phase, RadioPlaybackPhase.stalled);
      expect(handler.current.failure, RadioFailure.timeout);
      handler.dispose();
      async.flushMicrotasks();
    });
  });

  test('buffering after playback is reported as buffering', () {
    run((async, handler) {
      startPlaying(async, handler);

      player.buffer();
      async.flushMicrotasks();

      expect(handler.current.phase, RadioPlaybackPhase.buffering);
      expect(handler.current.failure, isNull);
    });
  });

  test('holding for a reconnect keeps the system in a playing state', () {
    run((async, handler) {
      startPlaying(async, handler);

      handler.holdForReconnect();
      async.flushMicrotasks();

      expect(player.calls, ['stop']);
      expect(handler.current.phase, RadioPlaybackPhase.stalled);
      expect(handler.current.failure, isNull);
      expect(handler.playbackState.value.playing, isTrue);
    });
  });

  test('the watchdog pauses a stall that lasts too long', () {
    run((async, handler) {
      startPlaying(async, handler);

      handler.holdForReconnect();
      async.elapse(handler.config.stallWatchdog - const Duration(seconds: 1));
      expect(handler.current.phase, RadioPlaybackPhase.stalled);

      async.elapse(const Duration(seconds: 1));
      expect(handler.current.phase, RadioPlaybackPhase.paused);
      expect(handler.playbackState.value.playing, isFalse);
    });
  });

  test('play from the notification after a pause resumes in place', () {
    run((async, handler) {
      startPlaying(async, handler);
      handler.pause();
      async.flushMicrotasks();

      now = now.add(const Duration(seconds: 5));
      handler.play();
      async.flushMicrotasks();

      expect(player.calls, ['pause', 'play']);
      expect(handler.current.phase, RadioPlaybackPhase.playing);
    });
  });

  test('audio focus refused at start leaves the radio paused', () {
    run((async, handler) {
      session.grantsFocus = false;
      handler.playMediaItem(_item);
      async.flushMicrotasks();

      expect(player.calls.where((call) => call == 'load'), isEmpty);
      expect(handler.current.phase, RadioPlaybackPhase.paused);
      expect(handler.playbackState.value.playing, isFalse);
    });
  });

  test('swiping the app away while paused stops the service', () {
    run((async, handler) {
      startPlaying(async, handler);
      handler.pause();
      async.flushMicrotasks();

      handler.onTaskRemoved();
      async.flushMicrotasks();

      expect(handler.current.phase, RadioPlaybackPhase.idle);
    });
  });

  test('swiping the app away while playing keeps playing', () {
    run((async, handler) {
      startPlaying(async, handler);

      handler.onTaskRemoved();
      async.flushMicrotasks();

      expect(handler.current.phase, RadioPlaybackPhase.playing);
    });
  });
}

class _SlowPlayer extends FakePlayer {
  @override
  Future<Duration?> setAudioSource(
    AudioSource audioSource, {
    bool preload = true,
    int? initialIndex,
    Duration? initialPosition,
  }) {
    calls.add('load');
    update(processing: ProcessingState.loading);
    return Completer<Duration?>().future;
  }
}
