import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/radio_failure.dart';
import '../diagnostics/failure_mapper.dart';

/// The outcome of a [StreamProbe.check].
@immutable
class StreamProbeResult {
  const StreamProbeResult({
    this.failure,
    this.statusCode,
    this.contentType,
    this.error,
  });

  /// What is wrong with the stream, or null when it looks playable or the
  /// probe could not tell.
  final RadioFailure? failure;

  /// The HTTP status of the final response, after redirects.
  final int? statusCode;

  /// The MIME type of the final response.
  final String? contentType;

  /// The error that ended the request, if any.
  final Object? error;

  /// Whether the stream answered with audio.
  bool get isPlayable => statusCode != null && failure == null;

  @override
  String toString() {
    final status = statusCode == null ? '' : 'HTTP $statusCode, ';
    return 'StreamProbeResult($status${failure?.name ?? 'ok'})';
  }
}

/// Checks a stream URL the way the player will open it, and reports what is
/// wrong with it in terms of HTTP status and content type.
///
/// Only the response headers are read; the connection is closed right after.
class StreamProbe {
  StreamProbe({
    this.timeout = const Duration(seconds: 8),
    HttpClient Function()? httpClient,
  }) : _httpClient = httpClient ?? HttpClient.new;

  /// How long connecting and each response step may take.
  final Duration timeout;

  final HttpClient Function() _httpClient;

  /// Requests [stream], following up to five redirects.
  Future<StreamProbeResult> check(Uri stream) async {
    final client = _httpClient()..connectionTimeout = timeout;
    try {
      final request = await client.getUrl(stream).timeout(timeout);
      request
        ..followRedirects = true
        ..maxRedirects = 5
        ..headers.set(HttpHeaders.acceptHeader, 'audio/*, */*;q=0.5');
      final response = await request.close().timeout(timeout);
      final contentType = response.headers.contentType?.mimeType;
      return StreamProbeResult(
        failure: FailureMapper.fromHttpStatus(
          response.statusCode,
          mimeType: contentType,
        ),
        statusCode: response.statusCode,
        contentType: contentType,
      );
    } on Object catch (error) {
      return StreamProbeResult(
        failure: FailureMapper.fromIoError(error),
        error: error,
      );
    } finally {
      client.close(force: true);
    }
  }
}
