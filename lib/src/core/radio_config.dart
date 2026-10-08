import 'dart:ui';

import 'package:flutter/foundation.dart';

import '../recovery/reconnect_policy.dart';

/// What the station broadcasts. It sets how the platform treats the audio
/// when other apps play sounds.
enum RadioContent {
  /// Music and mixed programming.
  music,

  /// Talk, recitation and other spoken audio. Other spoken audio pauses it
  /// instead of ducking it.
  speech,
}

/// Severity of a [RadioLogger] message.
enum RadioLogLevel { info, warning, error }

/// Receives the radio's log messages. Errors are unexpected failures worth
/// reporting to a crash service.
typedef RadioLogger = void Function(
  RadioLogLevel level,
  String message, {
  Object? error,
  StackTrace? stackTrace,
});

/// The Android media notification channel and look.
@immutable
class RadioNotificationConfig {
  const RadioNotificationConfig({
    this.channelId = 'resilient_radio.playback',
    this.channelName = 'Radio',
    this.channelDescription,
    this.icon = 'mipmap/ic_launcher',
    this.color,
  });

  /// The Android notification channel id.
  final String channelId;

  /// The channel name users see in the system notification settings.
  final String channelName;

  /// The channel description users see in the system notification settings.
  final String? channelDescription;

  /// A drawable resource in `type/name` form, such as `drawable/ic_radio`.
  final String icon;

  /// The notification accent color.
  final Color? color;
}

/// Radio settings. The defaults suit most live streams.
@immutable
class RadioConfig {
  const RadioConfig({
    this.reconnect = const ReconnectPolicy(),
    this.notification = const RadioNotificationConfig(),
    this.content = RadioContent.music,
    this.internetProbes,
    this.internetProbeTimeout = const Duration(seconds: 5),
    this.streamProbeTimeout = const Duration(seconds: 8),
    this.loadTimeout = const Duration(seconds: 20),
    this.liveResumeWindow = const Duration(seconds: 30),
    this.stallWatchdog = const Duration(minutes: 6),
    this.duckVolume = 0.3,
    this.startTimeout = const Duration(seconds: 10),
    this.logger,
  });

  /// URLs that answer 2xx when the internet is reachable, used when
  /// [internetProbes] is null. They are requested in parallel and the first
  /// answer wins.
  static final List<Uri> defaultInternetProbes = List.unmodifiable([
    Uri.https('www.gstatic.com', '/generate_204'),
    Uri.https('cp.cloudflare.com', '/generate_204'),
  ]);

  /// When and how often to reconnect after the stream drops.
  final ReconnectPolicy reconnect;

  /// The Android media notification. It is read once, by the first radio
  /// that plays, because the audio service starts once per app.
  final RadioNotificationConfig notification;

  /// What the stations broadcast.
  final RadioContent content;

  /// URLs used to tell a network without internet from a working one.
  /// Defaults to [defaultInternetProbes]. An empty list skips the check.
  final List<Uri>? internetProbes;

  /// How long each internet probe may take.
  final Duration internetProbeTimeout;

  /// How long the request to the stream may take when diagnosing a failure.
  final Duration streamProbeTimeout;

  /// How long the player may take to open the stream.
  final Duration loadTimeout;

  /// A pause shorter than this resumes where it stopped. A longer one
  /// reconnects to the live edge instead of playing old audio.
  final Duration liveResumeWindow;

  /// How long the radio may wait without audio, while it wants to play,
  /// before it pauses to release the device.
  final Duration stallWatchdog;

  /// The volume while another app ducks the radio.
  final double duckVolume;

  /// How long the background audio service may take to start.
  final Duration startTimeout;

  /// Receives log messages. Nothing is logged when null.
  final RadioLogger? logger;
}
