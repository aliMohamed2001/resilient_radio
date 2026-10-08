import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resilient_radio/resilient_radio.dart';
import 'package:resilient_radio/src/core/radio_controller.dart';
import 'package:resilient_radio/src/playback/radio_playback.dart';

import 'fakes.dart';

void main() {
  late FakeEngine engine;
  late FakeNetworkMonitor network;
  late FakeStreamProbe probe;
  late List<RadioEvent> events;

  const policy = ReconnectPolicy();

  setUp(() {
    engine = FakeEngine();
    network = FakeNetworkMonitor();
    probe = FakeStreamProbe();
    events = [];
  });

  RadioController build([ReconnectPolicy reconnect = policy]) {
    final radio = RadioController(
      station: station,
      engine: engine,
      network: network,
      probe: probe,
      config: RadioConfig(reconnect: reconnect),
    );
    radio.events.listen(events.add);
    return radio;
  }

  void run(
    void Function(FakeAsync async, RadioController radio) body, {
    ReconnectPolicy reconnect = policy,
  }) {
    fakeAsync((async) {
      final radio = build(reconnect);
      body(async, radio);
      radio.dispose();
      async.flushMicrotasks();
    });
  }

  void startListening(FakeAsync async, RadioController radio) {
    radio.play();
    async.flushMicrotasks();
    expect(radio.state.status, RadioStatus.playing);
    engine.calls.clear();
    events.clear();
  }

  void drop(FakeAsync async,
      [RadioFailure failure = RadioFailure.connectionLost]) {
    engine.emit(RadioPlaybackPhase.stalled, failure);
    async.flushMicrotasks();
  }

  group('connectivity', () {
    test('no network shows noInternet and never touches the stream', () {
      run((async, radio) {
        network.network = false;
        radio.play();
        async.flushMicrotasks();

        expect(radio.state.status, RadioStatus.noInternet);
        expect(radio.state.failure, RadioFailure.noNetwork);
        expect(radio.state.isInternetAvailable, isFalse);
        expect(engine.calls, isEmpty);
        expect(
          events.last,
          isA<RadioFailed>()
              .having((e) => e.failure, 'failure', RadioFailure.noNetwork)
              .having((e) => e.gaveUp, 'gaveUp', isFalse),
        );
      });
    });

    test('a network without internet is reported separately', () {
      run((async, radio) {
        network.internet = false;
        radio.play();
        async.flushMicrotasks();

        expect(radio.state.status, RadioStatus.noInternet);
        expect(radio.state.failure, RadioFailure.internetUnavailable);
        expect(engine.calls, isEmpty);
      });
    });

    test('retry starts the stream once internet is back', () {
      run((async, radio) {
        network.network = false;
        radio.play();
        async.flushMicrotasks();

        network.network = true;
        radio.retry();
        async.flushMicrotasks();

        expect(radio.state.status, RadioStatus.playing);
        expect(engine.count('play'), 1);
      });
    });

    test('retry while still offline keeps the same state', () {
      run((async, radio) {
        network.network = false;
        radio.play();
        async.flushMicrotasks();

        radio.retry();
        async.flushMicrotasks();

        expect(radio.state.status, RadioStatus.noInternet);
        expect(radio.state.isCheckingConnection, isFalse);
        expect(engine.calls, isEmpty);
      });
    });

    test('checking the connection reports the offline layer without playing',
        () {
      run((async, radio) {
        RadioFailure? checked;
        network.internet = false;
        radio.checkConnection().then((value) => checked = value);
        async.flushMicrotasks();

        expect(checked, RadioFailure.internetUnavailable);
        expect(radio.state.status, RadioStatus.noInternet);

        network.internet = true;
        radio.checkConnection().then((value) => checked = value);
        async.flushMicrotasks();

        expect(checked, isNull);
        expect(radio.state.status, RadioStatus.initial);
        expect(radio.state.failure, isNull);
        expect(engine.calls, isEmpty);
      });
    });

    test('play during a connection check takes over', () {
      run((async, radio) {
        final gate = network.gate = Completer<void>();
        radio.checkConnection();
        async.flushMicrotasks();
        expect(radio.state.isCheckingConnection, isTrue);

        radio.play();
        async.flushMicrotasks();
        network.gate = null;
        gate.complete();
        async.flushMicrotasks();

        expect(radio.state.status, RadioStatus.playing);
        expect(radio.state.isCheckingConnection, isFalse);
        expect(engine.count('play'), 1);
      });
    });

    test('internet returning does not start a radio that never played', () {
      run((async, radio) {
        network.network = false;
        radio.checkConnection();
        async.flushMicrotasks();

        network.change(connected: true);
        async.elapse(const Duration(minutes: 5));

        expect(network.isWatched, isFalse);
        expect(engine.calls, isEmpty);
      });
    });

    test('an unavailable stream reports the diagnosed HTTP failure', () {
      run((async, radio) {
        engine
          ..playFailure = RadioFailure.connectionLost
          ..playError = 'Source error';
        probe.result = const StreamProbeResult(
          failure: RadioFailure.streamNotFound,
          statusCode: 404,
        );
        radio.play();
        async.flushMicrotasks();

        expect(radio.state.status, RadioStatus.error);
        expect(radio.state.failure, RadioFailure.streamNotFound);
        expect(engine.calls, ['play', 'stop']);
        expect(probe.checks, 1);
        expect(network.isWatched, isFalse);
        expect(
          events.last,
          isA<RadioFailed>()
              .having((e) => e.failure, 'failure', RadioFailure.streamNotFound)
              .having((e) => e.statusCode, 'statusCode', 404)
              .having((e) => e.error, 'error', 'Source error')
              .having((e) => e.gaveUp, 'gaveUp', isFalse),
        );
      });
    });

    test('a conclusive failure is not probed again', () {
      run((async, radio) {
        engine.playFailure = RadioFailure.invalidStream;
        radio.play();
        async.flushMicrotasks();

        expect(radio.state.status, RadioStatus.error);
        expect(radio.state.failure, RadioFailure.invalidStream);
        expect(probe.checks, 0);
      });
    });

    test('a transport failure with internet gone becomes noInternet', () {
      run((async, radio) {
        engine.playFailure = RadioFailure.streamUnreachable;
        network.internetSequence.addAll([true, false]);
        radio.play();
        async.flushMicrotasks();

        expect(radio.state.status, RadioStatus.noInternet);
        expect(radio.state.failure, RadioFailure.internetUnavailable);
        expect(probe.checks, 1);
      });
    });
  });

  group('playback', () {
    test('play reaches playing and watches the network', () {
      run((async, radio) {
        radio.play();
        async.flushMicrotasks();

        expect(radio.state.status, RadioStatus.playing);
        expect(engine.calls, ['play']);
        expect(engine.played.single, station);
        expect(network.isWatched, isTrue);
        expect(events, [
          isA<RadioPlayRequested>(),
          isA<RadioPlaying>(),
        ]);
      });
    });

    test('pause then play resumes the same session', () {
      run((async, radio) {
        startListening(async, radio);

        radio.pause();
        async.flushMicrotasks();
        expect(radio.state.status, RadioStatus.paused);
        expect(network.isWatched, isFalse);

        radio.play();
        async.flushMicrotasks();
        expect(radio.state.status, RadioStatus.playing);
        expect(engine.calls, ['pause', 'resume']);
      });
    });

    test('pause before anything played does nothing', () {
      run((async, radio) {
        radio.pause();
        async.flushMicrotasks();

        expect(radio.state.status, RadioStatus.initial);
        expect(engine.calls, isEmpty);
        expect(events, isEmpty);
      });
    });

    test('stop ends the session', () {
      run((async, radio) {
        startListening(async, radio);

        radio.stop();
        async.flushMicrotasks();

        expect(radio.state.status, RadioStatus.stopped);
        expect(engine.calls, ['stop']);
        expect(network.isWatched, isFalse);
        expect(events, [isA<RadioStopped>()]);
      });
    });

    test('buffering is shown without an error and recovers', () {
      run((async, radio) {
        startListening(async, radio);

        engine.emit(RadioPlaybackPhase.buffering);
        async.flushMicrotasks();
        expect(radio.state.status, RadioStatus.buffering);
        expect(radio.state.failure, isNull);

        async.elapse(const Duration(seconds: 10));
        engine.emit(RadioPlaybackPhase.playing);
        async.flushMicrotasks();
        async.elapse(const Duration(minutes: 1));

        expect(radio.state.status, RadioStatus.playing);
        expect(engine.calls, isEmpty);
        expect(events, [isA<RadioBuffering>(), isA<RadioPlaying>()]);
      });
    });

    test('buffering past the timeout starts a reconnect', () {
      run((async, radio) {
        startListening(async, radio);

        engine.emit(RadioPlaybackPhase.buffering);
        async.elapse(policy.bufferingTimeout);

        expect(radio.state.status, RadioStatus.reconnecting);
        expect(radio.state.failure, RadioFailure.connectionLost);
        expect(engine.calls.first, 'hold');
      });
    });

    test('a player error while playing starts a reconnect', () {
      run((async, radio) {
        startListening(async, radio);

        drop(async);

        expect(radio.state.status, RadioStatus.reconnecting);
        expect(radio.state.isReconnecting, isTrue);
        expect(radio.state.attempt, 1);
        expect(radio.state.failure, RadioFailure.connectionLost);
        expect(
          events.single,
          isA<RadioReconnecting>()
              .having((e) => e.attempt, 'attempt', 1)
              .having((e) => e.delay, 'delay', const Duration(seconds: 1)),
        );
      });
    });

    test('tapping play repeatedly starts the stream once', () {
      run((async, radio) {
        radio
          ..play()
          ..play()
          ..play();
        async.flushMicrotasks();
        radio.play();
        async.flushMicrotasks();

        expect(engine.count('play'), 1);
        expect(radio.state.status, RadioStatus.playing);
      });
    });

    test('play, pause, play, stop in quick succession ends stopped', () {
      run((async, radio) {
        radio
          ..play()
          ..pause()
          ..play()
          ..stop();
        async.flushMicrotasks();
        async.elapse(const Duration(minutes: 10));

        expect(radio.state.status, RadioStatus.stopped);
        expect(engine.calls.last, 'stop');
        expect(engine.count('play'), 0);
      });
    });

    test('an interruption pauses without ending the session', () {
      run((async, radio) {
        startListening(async, radio);

        engine.emit(RadioPlaybackPhase.interrupted);
        async.flushMicrotasks();
        expect(radio.state.status, RadioStatus.paused);
        expect(radio.state.isInterrupted, isTrue);
        expect(network.isWatched, isTrue);

        engine.emit(RadioPlaybackPhase.playing);
        async.flushMicrotasks();
        expect(radio.state.status, RadioStatus.playing);
        expect(radio.state.isInterrupted, isFalse);
        expect(events, [
          isA<RadioPaused>().having((e) => e.interrupted, 'interrupted', true),
          isA<RadioPlaying>(),
        ]);
      });
    });

    test('pausing during an interruption cancels the automatic resume', () {
      run((async, radio) {
        startListening(async, radio);
        engine.emit(RadioPlaybackPhase.interrupted);
        async.flushMicrotasks();

        radio.pause();
        async.flushMicrotasks();

        expect(radio.state.status, RadioStatus.paused);
        expect(radio.state.isInterrupted, isFalse);
        expect(engine.calls, ['pause']);
        expect(network.isWatched, isFalse);
      });
    });

    test('playback started from the system controls is followed', () {
      run((async, radio) {
        engine.emit(RadioPlaybackPhase.loading);
        async.flushMicrotasks();
        expect(radio.state.status, RadioStatus.loading);

        engine.emit(RadioPlaybackPhase.playing);
        async.flushMicrotasks();
        expect(radio.state.status, RadioStatus.playing);
        expect(network.isWatched, isTrue);
        expect(events, [isA<RadioPlayRequested>(), isA<RadioPlaying>()]);
      });
    });
  });

  group('reconnection', () {
    test('network loss holds the stream and retries when it returns', () {
      run((async, radio) {
        startListening(async, radio);

        network.change(connected: false);
        async.flushMicrotasks();
        expect(radio.state.status, RadioStatus.reconnecting);
        expect(radio.state.failure, RadioFailure.noNetwork);
        expect(radio.state.isInternetAvailable, isFalse);
        expect(engine.calls, ['hold']);

        async.elapse(const Duration(minutes: 1));
        expect(engine.count('play'), 0);

        network.change(connected: true);
        async.flushMicrotasks();
        expect(engine.count('play'), 1);
        expect(radio.state.status, RadioStatus.playing);
        expect(radio.state.attempt, 0);
        expect(events, [
          isA<RadioNetworkLost>(),
          isA<RadioReconnecting>()
              .having((e) => e.reason, 'reason', RadioFailure.noNetwork)
              .having((e) => e.delay, 'delay', isNull),
          isA<RadioNetworkRestored>(),
          isA<RadioReconnected>().having((e) => e.attempts, 'attempts', 1),
          isA<RadioPlaying>(),
        ]);
      });
    });

    test('retries back off exponentially up to the cap', () {
      run((async, radio) {
        startListening(async, radio);
        engine.playFailure = RadioFailure.serverError;

        drop(async);

        const expected = [1, 2, 4, 8, 16, 30, 30, 30];
        for (var index = 0; index < expected.length; index++) {
          final delay = Duration(seconds: expected[index]);
          async.elapse(delay - const Duration(milliseconds: 1));
          expect(engine.count('play'), index, reason: 'before $delay');
          async.elapse(const Duration(milliseconds: 1));
          expect(engine.count('play'), index + 1, reason: 'at $delay');
        }
      });
    });

    test('a custom policy sets the waits and the number of attempts', () {
      run(
        reconnect: const ReconnectPolicy(
          initialDelay: Duration(seconds: 2),
          maxDelay: Duration(seconds: 5),
          maxAttempts: 3,
        ),
        (async, radio) {
          startListening(async, radio);
          engine.playFailure = RadioFailure.serverError;

          drop(async);

          for (final (index, seconds) in [2, 4, 5].indexed) {
            async.elapse(Duration(seconds: seconds));
            expect(engine.count('play'), index + 1, reason: 'after $seconds s');
          }
          expect(radio.state.status, RadioStatus.error);
          expect(radio.state.failure, RadioFailure.serverError);
        },
      );
    });

    test('a policy without attempts gives up at the first drop', () {
      run(
        reconnect: const ReconnectPolicy(maxAttempts: 0),
        (async, radio) {
          startListening(async, radio);

          drop(async);

          expect(radio.state.status, RadioStatus.error);
          expect(radio.state.failure, RadioFailure.connectionLost);
          expect(engine.count('play'), 0);
          expect(
            events.last,
            isA<RadioFailed>().having((e) => e.gaveUp, 'gaveUp', isTrue),
          );
        },
      );
    });

    test('gives up after the last attempt and pauses', () {
      run((async, radio) {
        startListening(async, radio);
        engine.playFailure = RadioFailure.serverError;

        drop(async);
        async.elapse(const Duration(minutes: 10));

        expect(engine.count('play'), policy.maxAttempts);
        expect(radio.state.status, RadioStatus.error);
        expect(radio.state.failure, RadioFailure.serverError);
        expect(engine.calls.last, 'pause');
        expect(network.isWatched, isFalse);
        expect(
          events.last,
          isA<RadioFailed>()
              .having((e) => e.failure, 'failure', RadioFailure.serverError)
              .having((e) => e.gaveUp, 'gaveUp', isTrue),
        );
      });
    });

    test('a non retryable failure stops reconnecting at once', () {
      run((async, radio) {
        startListening(async, radio);
        engine.playFailure = RadioFailure.connectionLost;
        probe.result = const StreamProbeResult(
          failure: RadioFailure.accessDenied,
          statusCode: 403,
        );

        drop(async);
        async.elapse(const Duration(seconds: 1));
        async.elapse(const Duration(minutes: 5));

        expect(engine.count('play'), 1);
        expect(radio.state.status, RadioStatus.error);
        expect(radio.state.failure, RadioFailure.accessDenied);
        expect(
          events.last,
          isA<RadioFailed>()
              .having((e) => e.statusCode, 'statusCode', 403)
              .having((e) => e.gaveUp, 'gaveUp', isTrue),
        );
      });
    });

    test('retry while reconnecting tries right away', () {
      run((async, radio) {
        startListening(async, radio);
        drop(async);
        expect(radio.state.status, RadioStatus.reconnecting);

        radio.retry();
        async.flushMicrotasks();

        expect(engine.count('play'), 1);
        expect(radio.state.status, RadioStatus.playing);
      });
    });

    test('stop during backoff cancels the retry loop immediately', () {
      run((async, radio) {
        startListening(async, radio);
        drop(async);
        expect(radio.state.status, RadioStatus.reconnecting);

        radio.stop();
        async.elapse(const Duration(minutes: 10));

        expect(radio.state.status, RadioStatus.stopped);
        expect(engine.count('play'), 0);
      });
    });

    test('stop while an attempt is in flight discards that attempt', () {
      run((async, radio) {
        startListening(async, radio);
        drop(async);

        async.elapse(const Duration(seconds: 1));
        radio.stop();
        async.elapse(const Duration(minutes: 10));

        expect(radio.state.status, RadioStatus.stopped);
        expect(engine.calls.last, 'stop');
      });
    });

    test('network loss, user stop, network restored stays stopped', () {
      run((async, radio) {
        startListening(async, radio);

        network.change(connected: false);
        async.flushMicrotasks();
        radio.stop();
        async.flushMicrotasks();
        network.change(connected: true);
        async.elapse(const Duration(minutes: 10));

        expect(radio.state.status, RadioStatus.stopped);
        expect(engine.count('play'), 0);
        expect(network.isWatched, isFalse);
      });
    });

    test('racing connectivity, timers and player errors run one loop', () {
      run((async, radio) {
        startListening(async, radio);
        engine.startsAudibly = false;

        drop(async);
        network.change(connected: false);
        async.flushMicrotasks();
        network
          ..change(connected: true)
          ..change(connected: true);
        drop(async);

        expect(engine.count('play'), 1);

        engine.startsAudibly = true;
        engine.emit(RadioPlaybackPhase.playing);
        async.flushMicrotasks();
        async.elapse(const Duration(minutes: 10));

        expect(radio.state.status, RadioStatus.playing);
        expect(engine.count('play'), 1);
      });
    });

    test('staying offline past the wait gives up as noInternet', () {
      run((async, radio) {
        startListening(async, radio);

        network.change(connected: false);
        async.elapse(policy.offlineWait);

        expect(radio.state.status, RadioStatus.noInternet);
        expect(radio.state.failure, RadioFailure.noNetwork);
        expect(engine.calls.last, 'pause');
      });
    });

    test('a pause from the system controls ends the reconnect loop', () {
      run((async, radio) {
        startListening(async, radio);
        drop(async);

        engine.emit(RadioPlaybackPhase.paused);
        async.elapse(const Duration(minutes: 10));

        expect(radio.state.status, RadioStatus.paused);
        expect(engine.count('play'), 0);
      });
    });
  });

  group('stations', () {
    test('switching station while playing plays the new stream', () {
      run((async, radio) {
        startListening(async, radio);

        radio.setStation(otherStation);
        async.flushMicrotasks();

        expect(radio.station, otherStation);
        expect(radio.state.station, otherStation);
        expect(radio.state.status, RadioStatus.playing);
        expect(engine.calls, ['play']);
        expect(engine.played.last, otherStation);
        expect(events.first, isA<RadioPlayRequested>());
      });
    });

    test('switching station while paused plays it on the next play', () {
      run((async, radio) {
        startListening(async, radio);
        radio.pause();
        async.flushMicrotasks();

        radio.setStation(otherStation);
        async.flushMicrotasks();
        expect(engine.calls, ['pause']);
        expect(radio.state.status, RadioStatus.paused);

        radio.play();
        async.flushMicrotasks();
        expect(engine.calls, ['pause', 'play']);
        expect(engine.played.last, otherStation);
      });
    });

    test('switching to the same station does nothing', () {
      run((async, radio) {
        startListening(async, radio);

        radio.setStation(station);
        async.flushMicrotasks();

        expect(engine.calls, isEmpty);
        expect(events, isEmpty);
      });
    });
  });

  group('lifecycle', () {
    test('dispose stops playback and closes the streams', () {
      fakeAsync((async) {
        final radio = build();
        var closed = false;
        radio.states.listen(null, onDone: () => closed = true);
        radio.play();
        async.flushMicrotasks();
        engine.calls.clear();

        radio.dispose();
        async.flushMicrotasks();

        expect(engine.calls, ['stop', 'dispose']);
        expect(closed, isTrue);
      });
    });

    test('dispose cancels pending retries', () {
      fakeAsync((async) {
        final radio = build();
        radio.play();
        async.flushMicrotasks();
        drop(async);
        engine.calls.clear();

        radio.dispose();
        async.elapse(const Duration(minutes: 10));

        expect(engine.count('play'), 0);
        expect(network.isWatched, isFalse);
      });
    });
  });
}
