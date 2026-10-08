# resilient_radio

A resilient live radio engine for Flutter.

[just_audio](https://pub.dev/packages/just_audio) plays streams and
[audio_service](https://pub.dev/packages/audio_service) keeps them playing in
the background. Live radio brings problems neither of them handles for you:
the stream drops when the phone switches networks, a café Wi-Fi has no
internet behind it, the server answers 503 for a minute, a call interrupts
playback, buffering never ends.

`resilient_radio` sits on top of both and deals with that. It reconnects with
backoff, tells a dead network from a dead stream, and reports what failed in
terms your UI can show.

## Features

- Background playback with a media notification, lock screen and headset
  controls.
- Three checks before blaming the stream: is there a network, does it reach
  the internet, and what does the stream itself answer (HTTP status and
  content type, after redirects).
- Automatic reconnect with configurable exponential backoff. While the device
  is offline it waits for the network instead of burning attempts.
- Buffering that never ends counts as a drop, and a watchdog releases the
  device if audio never comes back.
- Audio interruptions handled explicitly: ducking, calls, other apps,
  headphones unplugged.
- A long pause reconnects to the live edge instead of playing stale audio.
- Stop means stop: pending retries and attempts in flight are cancelled, and
  late async results can't bring playback back.
- Framework-neutral: an immutable state stream and a sealed event stream.
  Works with Bloc, Riverpod, Provider, `ValueNotifier` or plain streams.

## Install

```yaml
dependencies:
  resilient_radio: ^0.1.0
```

## Platform setup

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

If your stream is plain `http`, or redirects to `http` like many radio
hosts do, allow cleartext for that host only. Don't turn it on for the whole
app:

```xml
<!-- android/app/src/main/res/xml/network_security_config.xml -->
<network-security-config>
    <base-config cleartextTrafficPermitted="false" />
    <domain-config cleartextTrafficPermitted="true">
        <domain includeSubdomains="true">radiojar.com</domain>
    </domain-config>
</network-security-config>
```

and reference it from `<application android:networkSecurityConfig="@xml/network_security_config">`.
The same rule applies to the stream probe, which runs on `dart:io`.

On Android 13 and later the media notification shows without the
notification permission.

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
    artworkUrl: Uri.parse('https://example.com/logo.png'),
  ),
);

await radio.play();
await radio.pause();
await radio.stop();
await radio.retry();
```

Nothing touches the network or starts the audio service until `play()`.
None of the methods throw: what happened ends up in the state and the events.

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

`stateStream` emits changes only. Read `radio.state` for the current value.

### Events

Events are for things that happen once: a dialog, a snackbar, analytics.

```dart
radio.eventStream.listen((event) {
  switch (event) {
    case RadioFailed(:final failure, gaveUp: false) when failure.isOffline:
      showOfflineDialog();
    case RadioReconnected(:final attempts):
      analytics.log('radio_reconnected', {'attempts': attempts});
    case RadioFailed(:final failure, :final statusCode):
      analytics.log('radio_failed', {'failure': failure.name, 'http': statusCode});
    default:
      break;
  }
});
```

`failureStream` carries only the `RadioFailed` events.

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

### Before playing

Check the connection when a screen opens, to tell the user before they press
play:

```dart
final offline = await radio.checkConnection();
if (offline != null) showOfflineBanner(offline);
```

### Several stations

```dart
await radio.setStation(otherStation);
```

If the radio is playing, the new station starts right away. Otherwise it
plays on the next `play()`.

### Checking a URL

`StreamProbe` requests a URL the way the player will, which is handy for
user-entered streams:

```dart
final result = await StreamProbe().check(Uri.parse(url));
if (result.isPlayable) {
  await radio.setStation(RadioStation(id: 'custom', name: 'Custom', streamUrl: Uri.parse(url)));
} else {
  print('${result.failure?.name}, HTTP ${result.statusCode}');
}
```

## How it recovers

**On play.** The radio checks that the device has a network, then that the
internet answers (a request to Google's and Cloudflare's `generate_204`
endpoints, in parallel). If either fails it reports `noNetwork` or
`internetUnavailable` without touching the stream. If the player then fails
and the error doesn't say why, the stream URL itself is requested to get its
HTTP status and content type. When the failure looks like a transport error,
the internet is checked again, because it may have just dropped.

**While playing.** A player error, a live stream that "ends", buffering longer
than `bufferingTimeout` (20 s) or a lost network starts a reconnect. The
audio service stays in the foreground while it does, because Android 12 and
later won't let an app bring it back from the background.

With the default policy, the attempts come after these waits:

| Attempt | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 |
|---|---|---|---|---|---|---|---|---|
| Wait | 1 s | 2 s | 4 s | 8 s | 16 s | 30 s | 30 s | 30 s |

Each attempt re-checks the network first. While the device has no network at
all, no attempts are made: the radio waits up to `offlineWait` (3 min) and
tries the moment the network returns. After the last attempt the status
becomes `error` or `noInternet` and a `RadioFailed(gaveUp: true)` event is
sent. `accessDenied`, `streamRejected`, `invalidStream` and
`audioUnavailable` are not retried.

**Interruptions.**

| What happens | Result |
|---|---|
| Another app ducks the audio | volume drops to `duckVolume` (0.3) and comes back |
| A call or a short sound (transient focus loss) | pauses, resumes when it ends |
| Another app starts playing (permanent focus loss) | pauses for good |
| Headphones or Bluetooth disconnect | pauses at once |
| The user pauses or stops during an interruption | no automatic resume |

**Pause and resume.** A pause shorter than `liveResumeWindow` (30 s) resumes
where it stopped. A longer one reconnects to the live edge.

**Watchdog.** If the radio wants to play but has no audio for `stallWatchdog`
(6 min), it pauses to release the wake lock and the foreground service.

**Stop.** `stop()` cancels the pending retry and any attempt in flight. Every
async step checks a generation token before it changes anything, so a slow
response that arrives after a stop can't restart playback.

## Failures

| `RadioFailure` | Meaning | Retried |
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

`failure.isOffline` is true for the first two, which is usually where a UI
shows "you're offline" instead of an error. Platform player codes (ExoPlayer
error types, `NSURLError` codes) are mapped to these categories and never
reported as HTTP status codes.

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
| `content` | `RadioContent.music` | `speech` for talk or recitation: other spoken audio pauses it instead of ducking |
| `internetProbes` | Google and Cloudflare `generate_204` | your own endpoints, or `[]` to skip the internet check |
| `internetProbeTimeout` | 5 s | |
| `streamProbeTimeout` | 8 s | |
| `loadTimeout` | 20 s | how long the player may take to open the stream |
| `liveResumeWindow` | 30 s | |
| `stallWatchdog` | 6 min | |
| `duckVolume` | 0.3 | |
| `startTimeout` | 10 s | how long the audio service may take to start |
| `logger` | none | |

For another backoff curve, extend `ReconnectPolicy` and override `delayFor`.

## With your state management

The radio is a plain object with streams, so adapters stay small.

```dart
class RadioCubit extends Cubit<RadioState> {
  RadioCubit(this.radio) : super(radio.state) {
    _subscription = radio.stateStream.listen(emit);
  }

  final ResilientRadio radio;
  late final StreamSubscription<RadioState> _subscription;

  @override
  Future<void> close() async {
    await _subscription.cancel();
    return super.close();
  }
}
```

```dart
final radioStateProvider = StreamProvider<RadioState>(
  (ref) => ref.watch(radioProvider).stateStream,
);
```

## Built-in stations

There are none in the package itself. The example app plays Quran Radio
Cairo, a stream hosted by a third party (RadioJar); check a stream's terms
before you ship it in an app.

## Limitations

- One radio per app. audio_service starts once per process, so the first
  radio's notification settings are the ones used.
- An app that already uses audio_service for other audio can't add this
  radio's handler next to its own.
- Apps that open a second Flutter engine in its own Activity (a full-screen
  alarm, for example) can hit an audio_service 0.18 issue where that
  Activity creates a hidden engine and the next launch shows a black screen.
  If you do this, check audio_service's issue tracker before shipping.
- HLS is detected by `.m3u8` in the URL, as in just_audio.
- No ICY "now playing" metadata and no custom HTTP headers yet.
- Android and iOS only.
- The internet check contacts Google and Cloudflare. Point
  `internetProbes` at your own endpoint if that matters to your users.

## Example

[`example/`](example) has a small app with a station picker, a custom URL
field, the live state and an event log.

## License

MIT, see [LICENSE](LICENSE).
