/// Why the radio could not play, as precisely as it can be told.
///
/// Failures are classified from the network state, the HTTP response of the
/// stream and the platform player error. Platform error codes are never
/// passed off as HTTP status codes.
enum RadioFailure {
  /// The device is not connected to any network.
  noNetwork,

  /// The device has a network, but the internet is not reachable from it.
  internetUnavailable,

  /// The stream host could not be reached (DNS, refused connection, TLS).
  streamUnreachable,

  /// The stream took too long to answer or to start.
  timeout,

  /// The stream answered 404 or 410.
  streamNotFound,

  /// The stream answered 401, 403 or 451.
  accessDenied,

  /// The stream answered 429 or 5xx.
  serverError,

  /// The stream answered with another error, or refused the request.
  streamRejected,

  /// The stream answered, but not with audio the player can decode.
  invalidStream,

  /// The connection dropped while the stream was playing.
  connectionLost,

  /// The player failed for a reason that could not be classified.
  playbackFailed,

  /// The background audio service could not be started.
  audioUnavailable;

  /// Whether the failure is about the device being offline rather than about
  /// the stream.
  bool get isOffline => this == noNetwork || this == internetUnavailable;

  /// Whether reconnecting can fix this failure.
  bool get isRetryable => switch (this) {
        accessDenied ||
        streamRejected ||
        invalidStream ||
        audioUnavailable =>
          false,
        _ => true,
      };
}
