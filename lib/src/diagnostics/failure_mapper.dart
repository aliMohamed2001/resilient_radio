import 'dart:async';
import 'dart:io';

import 'package:just_audio/just_audio.dart';

import '../core/radio_failure.dart';

extension RadioFailureDiagnosis on RadioFailure {
  bool get isConclusive => switch (this) {
        RadioFailure.noNetwork ||
        RadioFailure.internetUnavailable ||
        RadioFailure.streamNotFound ||
        RadioFailure.accessDenied ||
        RadioFailure.serverError ||
        RadioFailure.invalidStream ||
        RadioFailure.audioUnavailable =>
          true,
        _ => false,
      };

  bool get isTransport =>
      this == RadioFailure.streamUnreachable ||
      this == RadioFailure.timeout ||
      this == RadioFailure.connectionLost;
}

abstract final class FailureMapper {
  static const int _exoSource = 0;
  static const int _exoRenderer = 1;

  static const int _urlTimedOut = -1001;
  static const int _urlCannotFindHost = -1003;
  static const int _urlCannotConnectToHost = -1004;
  static const int _urlConnectionLost = -1005;
  static const int _urlDnsLookupFailed = -1006;
  static const int _urlNotConnectedToInternet = -1009;
  static const int _urlBadServerResponse = -1011;
  static const int _urlDataNotAllowed = -1020;
  static const int _urlFileDoesNotExist = -1100;
  static const int _avFileFormatNotRecognized = -11828;
  static const int _avServerIncorrectlyConfigured = -11850;
  static const int _avFailedToParse = -11853;

  static RadioFailure? fromHttpStatus(int status, {String? mimeType}) {
    if (status >= 200 && status < 300) {
      return _isPlayable(mimeType) ? null : RadioFailure.invalidStream;
    }
    return switch (status) {
      401 || 403 || 451 => RadioFailure.accessDenied,
      404 || 410 => RadioFailure.streamNotFound,
      408 => RadioFailure.timeout,
      429 => RadioFailure.serverError,
      >= 500 && < 600 => RadioFailure.serverError,
      _ => RadioFailure.streamRejected,
    };
  }

  static RadioFailure? fromIoError(Object error) => switch (error) {
        TimeoutException() => RadioFailure.timeout,
        SocketException() || TlsException() => RadioFailure.streamUnreachable,
        StateError() => RadioFailure.streamRejected,
        _ => null,
      };

  static RadioFailure fromPlayerException(
    PlayerException error, {
    required bool android,
  }) {
    return android ? _fromExoPlayer(error.code) : _fromAvFoundation(error.code);
  }

  static RadioFailure _fromExoPlayer(int code) {
    if (code == _exoSource) return RadioFailure.connectionLost;
    if (code == _exoRenderer) return RadioFailure.invalidStream;
    if (code == 2002) return RadioFailure.timeout;
    if (code == 2005) return RadioFailure.streamNotFound;
    if (code == 2003 || code == 2007) return RadioFailure.streamRejected;
    if (code >= 2000 && code < 3000) return RadioFailure.connectionLost;
    if (code >= 3000 && code < 5000) return RadioFailure.invalidStream;
    return RadioFailure.playbackFailed;
  }

  static RadioFailure _fromAvFoundation(int code) => switch (code) {
        _urlTimedOut => RadioFailure.timeout,
        _urlNotConnectedToInternet ||
        _urlDataNotAllowed =>
          RadioFailure.noNetwork,
        _urlCannotFindHost ||
        _urlCannotConnectToHost ||
        _urlDnsLookupFailed =>
          RadioFailure.streamUnreachable,
        _urlConnectionLost => RadioFailure.connectionLost,
        _urlBadServerResponse ||
        _avServerIncorrectlyConfigured =>
          RadioFailure.streamRejected,
        _urlFileDoesNotExist => RadioFailure.streamNotFound,
        _avFileFormatNotRecognized ||
        _avFailedToParse =>
          RadioFailure.invalidStream,
        _ => RadioFailure.playbackFailed,
      };

  static bool _isPlayable(String? mimeType) {
    if (mimeType == null || mimeType.isEmpty) return true;
    final type = mimeType.toLowerCase();
    return type.startsWith('audio/') ||
        type.contains('mpegurl') ||
        type == 'application/ogg' ||
        type == 'application/octet-stream' ||
        type == 'video/mp2t';
  }
}
