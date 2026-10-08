# resilient_radio example

A small app that plays a live stream with `resilient_radio`: pick the built-in
Quran Radio Cairo stream or paste your own URL, then watch the state and the
event log while you toggle airplane mode or switch networks.

```sh
cd example
flutter run
```

The Quran Radio Cairo stream is hosted by RadioJar, a third party. It
redirects from `https` to `http`, so the app allows cleartext traffic for
`radiojar.com` only, in `android/app/src/main/res/xml/network_security_config.xml`
and in `NSAppTransportSecurity` in `ios/Runner/Info.plist`. Custom `http`
streams need the same kind of exception for their own domain.
