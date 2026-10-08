import 'package:flutter/foundation.dart';

/// A live stream and the details shown for it on the lock screen and in the
/// media notification.
@immutable
class RadioStation {
  /// Creates a station for [streamUrl].
  ///
  /// [artworkUrl] must be an `http`, `https` or `file` URI: the media
  /// notification cannot read Flutter assets.
  const RadioStation({
    required this.id,
    required this.name,
    required this.streamUrl,
    this.description,
    this.artworkUrl,
    this.metadata = const {},
  });

  /// A stable identifier for the station.
  final String id;

  /// The title shown in the media notification.
  final String name;

  /// The live stream. Redirects are followed.
  final Uri streamUrl;

  /// The line shown under [name] in the media notification.
  final String? description;

  /// The artwork shown in the media notification and on the lock screen.
  final Uri? artworkUrl;

  /// Extra values passed to the media session.
  final Map<String, dynamic> metadata;

  @override
  bool operator ==(Object other) =>
      other is RadioStation &&
      other.id == id &&
      other.name == name &&
      other.streamUrl == streamUrl &&
      other.description == description &&
      other.artworkUrl == artworkUrl &&
      mapEquals(other.metadata, metadata);

  @override
  int get hashCode => Object.hash(id, name, streamUrl, description, artworkUrl);

  @override
  String toString() => 'RadioStation($id, $streamUrl)';
}
