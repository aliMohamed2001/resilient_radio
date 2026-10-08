# resilient_radio

[![pub package](https://img.shields.io/pub/v/resilient_radio.svg)](https://pub.dev/packages/resilient_radio)
[![CI](https://github.com/aliMohamed2001/resilient_radio/actions/workflows/ci.yml/badge.svg)](https://github.com/aliMohamed2001/resilient_radio/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

A resilient live radio engine for Flutter.

[just_audio](https://pub.dev/packages/just_audio) plays streams and
[audio_service](https://pub.dev/packages/audio_service) keeps them playing in
the background. `resilient_radio` sits on top of both and handles what goes
wrong with live streams: it reconnects with backoff, tells a dead network from
a dead stream, and reports each failure as a type your UI can act on.

## Demo

<p>
  <img src="https://raw.githubusercontent.com/aliMohamed2001/resilient_radio/main/doc/demo.gif" width="260" alt="The example app connecting, losing the network, reconnecting and playing again">
</p>

The example app on an Android 14 emulator: play, the network is switched off,
the radio waits for it, and playback resumes on its own when it comes back.
Recorded from the emulator screen at 1.5× speed.

<p>
  <img src="https://raw.githubusercontent.com/aliMohamed2001/resilient_radio/main/doc/playing.png" width="240" alt="Playing after a reconnect, with the event log">
  <img src="https://raw.githubusercontent.com/aliMohamed2001/resilient_radio/main/doc/reconnecting.png" width="240" alt="Reconnecting while the device has no network">
  <img src="https://raw.githubusercontent.com/aliMohamed2001/resilient_radio/main/doc/probe.png" width="240" alt="StreamProbe reporting HTTP 404 for a URL that is not a stream">
</p>

Playing after a reconnect · waiting for the network · `StreamProbe` reporting a
404 for a URL that is not a stream.

## Features

- Background playback with a media notification, lock screen and headset
  controls.
- Three checks before blaming the stream: is there a network, does it reach
  the internet, and what does the stream answer (HTTP status and content
  type, after redirects).
- Automatic reconnect with configurable exponential backoff. While the device
  has no network, it waits for it instead of spending attempts.
- Buffering that never ends counts as a drop, and a watchdog releases the
  device if audio never comes back.
- Interruptions handled explicitly: ducking, calls, other apps, headphones
  unplugged.
- A long pause reconnects to the live edge instead of playing stale audio.
- `stop()` cancels pending retries and attempts in flight; late async results
  can't restart playback.
- An immutable state stream and a sealed event stream, usable from Bloc,
  Riverpod, Provider, `ValueNotifier` or plain streams.

## Platform and testing status

| Platform | Status |
|---|---|
| Android | Tested on an Android 14 emulator, in the example app and in an app built on the package: playback, background audio, media buttons, network loss and recovery, stop. Not yet tested on a physical device. |
| iOS | The CI workflow builds the example app for the iOS simulator on every push (`flutter build ios --simulator` on macOS); the CI badge shows the latest result. Not yet run on a simulator or a physical iPhone. |
| Web, desktop | Not supported. |

The package's own tests (`flutter test`) run on every push with the minimum
supported Flutter version (3.27.0) and the latest stable.

## Install

```yaml
dependencies:
  resilient_radio: ^0.1.0
```

### Android

Make `MainActivity` extend `AudioServiceActivity`:

```kotlin
import com.ryanheise.audioservice.AudioServiceActivity

class MainActivity : AudioServiceActivity()
```

Add the permissions, the audio service and the media button receiver to
`android/app/src/main/AndroidManifest.xml`:

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    xmlns:tools="http://schemas.android.com/tools">

    <uses-permission android:name="android.permission.INTERNET"/>
    <uses-permission android:name="android.permission.WAKE_LOCK"/>
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK"/>

    <application ...>
        <activity android:name=".MainActivity" ...>
            ...
        </activity>

        <service
            android:name="com.ryanheise.audioservice.AudioService"
            android:exported="true"
            android:foregroundServiceType="mediaPlayback"
            tools:ignore="Exported">
            <intent-filter>
                <action android:name="android.media.browse.MediaBrowserService"/>
            </intent-filter>
        </service>

        <receiver
            android:name="com.ryanheise.audioservice.MediaButtonReceiver"
            android:exported="true"
            tools:ignore="Instantiatable">
            <intent-filter>
                <action android:name="android.intent.action.MEDIA_BUTTON"/>
            </intent-filter>
        </receiver>
    </application>
</manifest>
```

`exported="true"` lets Android's media resumption controls and Android Auto
connect to the service after the app has closed. If you don't want that, set
`exported="false"` on both: the notification, lock screen and headset buttons
keep working.

If a stream is plain `http`, or redirects to `http` as many radio hosts do,
allow cleartext for that host only, not for the whole app:

```xml
<!-- android/app/src/main/res/xml/network_security_config.xml -->
<network-security-config>
    <base-config cleartextTrafficPermitted="false" />
    <domain-config cleartextTrafficPermitted="true">
        <domain includeSubdomains="true">radiojar.com</domain>
    </domain-config>
</network-security-config>
```

and reference it with `android:networkSecurityConfig="@xml/network_security_config"`
on `<application>`. The stream probe runs on `dart:io` and follows the same
rule.

### iOS

Enable background audio in `ios/Runner/Info.plist`:

```xml
<key>UIBackgroundModes</key>
<array>
    <string>audio</string>
</array>
```

For an `http` stream, add an App Transport Security exception for its domain:

```xml
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSExceptionDomains</key>
    <dict>
        <key>radiojar.com</key>
        <dict>
            <key>NSIncludesSubdomains</key>
            <true/>
            <key>NSExceptionAllowsInsecureHTTPLoads</key>
            <true/>
        </dict>
    </dict>
</dict>
```

## Usage

Create one radio for the lifetime of the app:

```dart
import 'package:resilient_radio/resilient_radio.dart';

final radio = ResilientRadio(
  station: RadioStation(
    id: 'my_station',
    name: 'My Radio',
    description: 'Live',
    streamUrl: Uri.parse('https://example.com/live'),
  ),
);

await radio.play();
await radio.pause();
await radio.stop();
await radio.retry();
```

Creating a radio starts nothing: the audio service starts on the first
`play()`. `play()` doesn't throw; a failure ends up in the state and the
events.

### State

```dart
StreamBuilder<RadioState>(
  stream: radio.stateStream,
  initialData: radio.state,
  builder: (context, snapshot) {
    final state = snapshot.data!;
    return switch (state.status) {
      RadioStatus.playing => const Text('Live'),
      RadioStatus.reconnecting =>
        Text('Reconnecting (${state.attempt}/${state.maxAttempts})'),
      RadioStatus.noInternet => const Text('You are offline'),
      RadioStatus.error => Text('Could not play: ${state.failure?.name}'),
      _ => const SizedBox.shrink(),
    };
  },
);
```

`stateStream` emits changes only; read `radio.state` for the current value.

### Events

Events are for things that happen once: a dialog, a snackbar, analytics.

```dart
radio.eventStream.listen((event) {
  switch (event) {
    case RadioFailed(:final failure, gaveUp: false) when failure.isOffline:
      showOfflineDialog();
    case RadioReconnected(:final attempts):
      analytics.log('radio_reconnected', {'attempts': attempts});
    default:
      break;
  }
});
```

| Event | When |
|---|---|
| `RadioPlayRequested` | `play()` was called, or play was pressed in the notification |
| `RadioPlaying` | audio started |
| `RadioBuffering` | audio is waiting for data |
| `RadioPaused` | paused; `interrupted` is true when another app's audio caused it |
| `RadioStopped` | stopped |
| `RadioReconnecting` | an attempt is scheduled; `delay` is null while waiting for the network |
| `RadioReconnected` | audio is back after a drop |
| `RadioNetworkLost` / `RadioNetworkRestored` | the network changed while the radio was in use |
| `RadioFailed` | a play request failed (`gaveUp: false`) or reconnecting gave up (`gaveUp: true`) |

`failureStream` carries only the `RadioFailed` events.

### More

```dart
final RadioFailure? offline = await radio.checkConnection();
await radio.setStation(otherStation);

final result = await StreamProbe().check(Uri.parse(userEnteredUrl));
print('${result.statusCode} ${result.failure?.name}');
```

`checkConnection()` returns why the device is offline, or null, so a screen
can say so before the user presses play.
`setStation()` starts the new station right away if the radio is in use.
`StreamProbe` requests a URL the way the player will, which is useful for
user-entered streams.

## How it recovers

On `play()`, the radio checks for a network, then for the internet (requests
to Google's and Cloudflare's `generate_204` endpoints, in parallel). If the
player fails without saying why, the stream URL itself is requested to get its
HTTP status and content type; after a transport error, the internet is checked
again in case it just dropped.

While playing, a player error, a live stream that "ends", buffering longer
than `bufferingTimeout` (20 s) or a lost network starts a reconnect. The audio
service stays in the foreground meanwhile, because Android 12 and later won't
let an app bring it back from the background. With the default policy the
attempts come after 1, 2, 4, 8, 16, 30, 30 and 30 seconds; with no network at
all it waits up to `offlineWait` (3 min) and tries as soon as the network
returns.

A failed `play()` is not retried: the state shows the failure and the app
decides, for example with `retry()`. After a drop, the radio reconnects on its
own unless the failure rules it out:

| `RadioFailure` | Meaning | Reconnects |
|---|---|---|
| `noNetwork` | no Wi-Fi or mobile network | waits for the network |
| `internetUnavailable` | a network without internet | yes |
| `streamUnreachable` | DNS failure, refused connection, TLS error | yes |
| `timeout` | the stream didn't answer or start in time | yes |
| `streamNotFound` | HTTP 404 or 410 | yes |
| `accessDenied` | HTTP 401, 403 or 451 | no |
| `serverError` | HTTP 429 or 5xx | yes |
| `streamRejected` | any other HTTP error | no |
| `invalidStream` | the answer isn't audio the player can decode | no |
| `connectionLost` | the stream dropped while playing | yes |
| `playbackFailed` | the player failed for an unknown reason | yes |
| `audioUnavailable` | the audio service couldn't start | no |

Platform player codes (ExoPlayer error types, `NSURLError` codes) are mapped to
these categories and never reported as HTTP status codes.

## Configuration

```dart
final radio = ResilientRadio(
  station: station,
  config: RadioConfig(
    content: RadioContent.speech,
    reconnect: const ReconnectPolicy(
      maxAttempts: 5,
      initialDelay: Duration(seconds: 2),
      maxDelay: Duration(seconds: 20),
    ),
    notification: const RadioNotificationConfig(
      channelName: 'Live radio',
      icon: 'drawable/ic_radio',
    ),
    logger: (level, message, {error, stackTrace}) {
      if (level == RadioLogLevel.error) {
        crashReporter.record(error, stackTrace, reason: message);
      }
    },
  ),
);
```

| `RadioConfig` | Default | |
|---|---|---|
| `reconnect` | `ReconnectPolicy()` | backoff, attempts, `offlineWait`, `bufferingTimeout` |
| `notification` | channel `resilient_radio.playback` | Android channel, icon and color |
| `content` | `RadioContent.music` | `speech` for talk or recitation |
| `internetProbes` | Google and Cloudflare `generate_204` | your own endpoints, or `[]` to skip the check |
| `internetProbeTimeout` | 5 s | per internet probe |
| `streamProbeTimeout` | 8 s | for the request to the stream when diagnosing a failure |
| `loadTimeout` | 20 s | how long the player may take to open the stream |
| `liveResumeWindow` | 30 s | shorter pauses resume in place, longer ones reconnect |
| `stallWatchdog` | 6 min | how long it may go without audio before pausing to release the device |
| `duckVolume` | 0.3 | the volume while another app ducks the radio |
| `startTimeout` | 10 s | how long the audio service may take to start |
| `logger` | none | receives info, warning and error messages |

For another backoff curve, extend `ReconnectPolicy` and override `delayFor`.

## Limitations

- One radio per app: audio_service starts once per process, so the first
  radio's notification settings are the ones used.
- An app that already uses audio_service for other audio can't add this
  radio's handler next to its own.
- Apps that open a second Flutter engine in its own Activity (a full-screen
  alarm, for example) can hit an audio_service 0.18 issue where that Activity
  creates a hidden engine and the next launch shows a black screen. Check
  audio_service's issue tracker before shipping such an app.
- HLS is detected by `.m3u8` in the URL, as in just_audio.
- No ICY "now playing" metadata and no custom HTTP headers yet.
- The internet check contacts Google and Cloudflare. Point `internetProbes`
  at your own endpoint if that matters to your users.

## Example

[`example/`](example) has the app shown above: a station picker, a custom URL
field checked with `StreamProbe`, the live state and an event log. Its default
station, Quran Radio Cairo, is a stream hosted by a third party (RadioJar);
check a stream's terms before you ship it in an app.

## License

MIT, see [LICENSE](LICENSE).
