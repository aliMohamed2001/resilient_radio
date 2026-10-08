import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resilient_radio/resilient_radio.dart';
import 'package:resilient_radio/src/playback/radio_audio_handler.dart';
import 'package:resilient_radio/src/playback/radio_engine.dart';
import 'package:resilient_radio/src/playback/radio_playback.dart';

import 'fakes.dart';

void main() {
  late FakePlayer player;
  late FakeSession session;
  late int starts;
  late Object? startError;
  late RadioAudioHandler handler;

  setUp(() {
    player = FakePlayer();
    session = FakeSession();
    starts = 0;
    startError = null;
  });

  AudioServiceEngine build() {
    handler = RadioAudioHandler(player: player, session: () async => session);
    return AudioServiceEngine(
      start: () async {
        starts++;
        final error = startError;
        if (error != null) throw error;
        return handler;
      },
    );
  }

  test('nothing starts before the first play', () {
    fakeAsync((async) {
      final engine = build();
      engine.pause();
      engine.stop();
      engine.holdForReconnect();
      async.flushMicrotasks();

      expect(starts, 0);
      expect(player.calls, isEmpty);
      engine.dispose();
      async.flushMicrotasks();
    });
  });

  test('play shows the station in the media notification', () {
    fakeAsync((async) {
      final engine = build();
      final phases = <RadioPlaybackPhase>[];
      engine.playback.listen((playback) => phases.add(playback.phase));

      engine.play(station);
      async.flushMicrotasks();

      final item = handler.mediaItem.value!;
      expect(item.id, station.streamUrl.toString());
      expect(item.title, station.name);
      expect(item.artist, station.description);
      expect(item.isLive, isTrue);
      expect(phases.last, RadioPlaybackPhase.playing);
      expect(starts, 1);

      engine.play(otherStation);
      async.flushMicrotasks();
      expect(handler.mediaItem.value!.title, otherStation.name);
      expect(starts, 1);

      engine.dispose();
      async.flushMicrotasks();
    });
  });

  test('a service that fails to start is reported and retried later', () {
    fakeAsync((async) {
      final engine = build();
      startError = StateError('no AudioServiceActivity');
      Object? thrown;
      engine.play(station).catchError((Object error) {
        thrown = error;
      });
      async.flushMicrotasks();

      expect(thrown, isA<RadioException>());
      expect(
        (thrown! as RadioException).failure,
        RadioFailure.audioUnavailable,
      );

      startError = null;
      engine.play(station);
      async.flushMicrotasks();
      expect(starts, 2);
      expect(handler.current.phase, RadioPlaybackPhase.playing);

      engine.dispose();
      async.flushMicrotasks();
    });
  });

  test('resume after a pause continues the same stream', () {
    fakeAsync((async) {
      final engine = build();
      engine.play(station);
      async.flushMicrotasks();
      engine.pause();
      async.flushMicrotasks();
      player.calls.clear();

      engine.resume(station);
      async.flushMicrotasks();

      expect(player.calls, ['play']);
      expect(handler.current.phase, RadioPlaybackPhase.playing);
      engine.dispose();
      async.flushMicrotasks();
    });
  });
}
