import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:resilient_radio/resilient_radio.dart';
import 'package:resilient_radio/src/diagnostics/failure_mapper.dart';

void main() {
  group('HTTP status', () {
    test('a playable 2xx is not a failure', () {
      expect(FailureMapper.fromHttpStatus(200, mimeType: 'audio/mpeg'), isNull);
      expect(FailureMapper.fromHttpStatus(200), isNull);
      expect(
        FailureMapper.fromHttpStatus(
          200,
          mimeType: 'application/vnd.apple.mpegurl',
        ),
        isNull,
      );
    });

    test('a 2xx page that is not audio is an invalid stream', () {
      expect(
        FailureMapper.fromHttpStatus(200, mimeType: 'text/html'),
        RadioFailure.invalidStream,
      );
    });

    test('each status maps to its own failure', () {
      const expected = {
        401: RadioFailure.accessDenied,
        403: RadioFailure.accessDenied,
        451: RadioFailure.accessDenied,
        404: RadioFailure.streamNotFound,
        410: RadioFailure.streamNotFound,
        408: RadioFailure.timeout,
        429: RadioFailure.serverError,
        500: RadioFailure.serverError,
        502: RadioFailure.serverError,
        503: RadioFailure.serverError,
        504: RadioFailure.serverError,
        400: RadioFailure.streamRejected,
        418: RadioFailure.streamRejected,
      };
      expected.forEach((status, failure) {
        expect(
          FailureMapper.fromHttpStatus(status),
          failure,
          reason: 'HTTP $status',
        );
      });
    });
  });

  group('I/O errors', () {
    test('transport errors are told apart', () {
      expect(
        FailureMapper.fromIoError(TimeoutException('slow')),
        RadioFailure.timeout,
      );
      expect(
        FailureMapper.fromIoError(
          const SocketException('Connection reset by peer'),
        ),
        RadioFailure.streamUnreachable,
      );
      expect(
        FailureMapper.fromIoError(const HandshakeException('bad cert')),
        RadioFailure.streamUnreachable,
      );
      expect(
        FailureMapper.fromIoError(StateError('Insecure HTTP blocked')),
        RadioFailure.streamRejected,
      );
    });

    test('an unparseable response stays inconclusive', () {
      expect(
        FailureMapper.fromIoError(const HttpException('Invalid line')),
        isNull,
      );
    });
  });

  group('player errors', () {
    RadioFailure android(int code) => FailureMapper.fromPlayerException(
          PlayerException(code, 'error', 0),
          android: true,
        );

    RadioFailure apple(int code) => FailureMapper.fromPlayerException(
          PlayerException(code, 'error', 0),
          android: false,
        );

    test('ExoPlayer error types do not pretend to be HTTP codes', () {
      expect(android(0), RadioFailure.connectionLost);
      expect(android(1), RadioFailure.invalidStream);
      expect(android(2), RadioFailure.playbackFailed);
      expect(android(2002), RadioFailure.timeout);
      expect(android(2005), RadioFailure.streamNotFound);
      expect(android(2003), RadioFailure.streamRejected);
      expect(android(2001), RadioFailure.connectionLost);
      expect(android(3001), RadioFailure.invalidStream);
      expect(android(4003), RadioFailure.invalidStream);
    });

    test('AVFoundation and NSURL errors are mapped', () {
      expect(apple(-1009), RadioFailure.noNetwork);
      expect(apple(-1001), RadioFailure.timeout);
      expect(apple(-1004), RadioFailure.streamUnreachable);
      expect(apple(-1005), RadioFailure.connectionLost);
      expect(apple(-1011), RadioFailure.streamRejected);
      expect(apple(-1100), RadioFailure.streamNotFound);
      expect(apple(-11828), RadioFailure.invalidStream);
      expect(apple(-11800), RadioFailure.playbackFailed);
    });
  });

  group('failure policy', () {
    test('only failures worth retrying are retried', () {
      final notRetried =
          RadioFailure.values.where((failure) => !failure.isRetryable).toSet();
      expect(notRetried, {
        RadioFailure.accessDenied,
        RadioFailure.streamRejected,
        RadioFailure.invalidStream,
        RadioFailure.audioUnavailable,
      });
    });

    test('only network failures count as offline', () {
      final offline =
          RadioFailure.values.where((failure) => failure.isOffline).toSet();
      expect(offline, {
        RadioFailure.noNetwork,
        RadioFailure.internetUnavailable,
      });
    });

    test('transport failures are the ones worth a second look', () {
      final transport =
          RadioFailure.values.where((failure) => failure.isTransport).toSet();
      expect(transport, {
        RadioFailure.streamUnreachable,
        RadioFailure.timeout,
        RadioFailure.connectionLost,
      });
      expect(
        transport.where((failure) => failure.isConclusive),
        isEmpty,
      );
    });
  });
}
