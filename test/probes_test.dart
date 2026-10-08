import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resilient_radio/resilient_radio.dart';
import 'package:resilient_radio/src/network/network_monitor.dart';

class _FakeConnectivity extends Fake implements Connectivity {
  _FakeConnectivity(this.current);

  List<ConnectivityResult> current;
  final StreamController<List<ConnectivityResult>> changes =
      StreamController<List<ConnectivityResult>>.broadcast();

  @override
  Future<List<ConnectivityResult>> checkConnectivity() async => current;

  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged => changes.stream;
}

void main() {
  late HttpServer server;
  late Uri base;
  final hanging = <HttpResponse>[];

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = Uri.parse('http://${server.address.host}:${server.port}');
    server.listen((request) async {
      final response = request.response;
      switch (request.uri.path) {
        case '/204':
          response.statusCode = HttpStatus.noContent;
          await response.close();
        case '/live':
          response.headers.contentType = ContentType('audio', 'mpeg');
          response.add(List<int>.filled(4096, 0));
          await response.flush();
          hanging.add(response);
        case '/redirect':
          await response.redirect(base.replace(path: '/live'));
        case '/html':
          response.headers.contentType = ContentType.html;
          response.write('<html>portal</html>');
          await response.close();
        case '/hang':
          hanging.add(response);
        default:
          response.statusCode = int.parse(request.uri.path.substring(1));
          await response.close();
      }
    });
  });

  tearDown(() async {
    hanging.clear();
    await server.close(force: true);
  });

  Uri at(String path) => base.replace(path: path);

  Future<Uri> closedPort() async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    return Uri.parse('http://127.0.0.1:$port/live');
  }

  group('stream probe', () {
    final probe = StreamProbe(timeout: const Duration(seconds: 2));

    test('a live audio stream is playable and the probe returns at once',
        () async {
      final result =
          await probe.check(at('/live')).timeout(const Duration(seconds: 3));
      expect(result.isPlayable, isTrue);
      expect(result.failure, isNull);
      expect(result.statusCode, 200);
      expect(result.contentType, 'audio/mpeg');
    });

    test('redirects are followed to the stream', () async {
      final result = await probe.check(at('/redirect'));
      expect(result.isPlayable, isTrue);
      expect(result.statusCode, 200);
    });

    test('HTTP failures are reported with real status codes', () async {
      const expected = {
        404: RadioFailure.streamNotFound,
        403: RadioFailure.accessDenied,
        500: RadioFailure.serverError,
        502: RadioFailure.serverError,
        503: RadioFailure.serverError,
        504: RadioFailure.serverError,
      };
      for (final MapEntry(key: status, value: failure) in expected.entries) {
        final result = await probe.check(at('/$status'));
        expect(result.failure, failure, reason: 'HTTP $status');
        expect(result.statusCode, status);
        expect(result.isPlayable, isFalse);
      }
    });

    test('a web page instead of audio is an invalid stream', () async {
      final result = await probe.check(at('/html'));
      expect(result.failure, RadioFailure.invalidStream);
      expect(result.contentType, 'text/html');
    });

    test('a refused connection means the stream is unreachable', () async {
      final patient = StreamProbe(timeout: const Duration(seconds: 8));
      final result = await patient.check(await closedPort());
      expect(result.failure, RadioFailure.streamUnreachable);
      expect(result.statusCode, isNull);
      expect(result.error, isA<SocketException>());
    });

    test('a server that never answers times out', () async {
      final quick = StreamProbe(timeout: const Duration(milliseconds: 300));
      final result = await quick.check(at('/hang'));
      expect(result.failure, RadioFailure.timeout);
    });
  });

  group('network monitor', () {
    test('no connectivity result means no network', () async {
      final monitor = ConnectivityNetworkMonitor(
        connectivity: _FakeConnectivity([ConnectivityResult.none]),
      );
      expect(await monitor.hasNetwork(), isFalse);
    });

    test('any connected transport counts as a network', () async {
      final monitor = ConnectivityNetworkMonitor(
        connectivity: _FakeConnectivity([
          ConnectivityResult.vpn,
          ConnectivityResult.wifi,
        ]),
      );
      expect(await monitor.hasNetwork(), isTrue);
    });

    test('changes are reported once per transition', () async {
      final connectivity = _FakeConnectivity([ConnectivityResult.wifi]);
      final monitor = ConnectivityNetworkMonitor(connectivity: connectivity);
      final seen = <bool>[];
      final subscription = monitor.changes.listen(seen.add);

      connectivity.changes
        ..add([ConnectivityResult.wifi])
        ..add([ConnectivityResult.mobile])
        ..add([ConnectivityResult.none])
        ..add([ConnectivityResult.none])
        ..add([ConnectivityResult.wifi]);
      await pumpEventQueue();
      await subscription.cancel();

      expect(seen, [true, false, true]);
    });

    test('internet is reachable when any probe answers', () async {
      final monitor = ConnectivityNetworkMonitor(
        connectivity: _FakeConnectivity([ConnectivityResult.wifi]),
        probes: [await closedPort(), at('/204')],
        timeout: const Duration(seconds: 2),
      );
      expect(await monitor.isInternetReachable(), isTrue);
    });

    test('internet is unreachable when every probe fails', () async {
      final monitor = ConnectivityNetworkMonitor(
        connectivity: _FakeConnectivity([ConnectivityResult.wifi]),
        probes: [await closedPort(), at('/500'), at('/hang')],
        timeout: const Duration(milliseconds: 300),
      );
      expect(await monitor.isInternetReachable(), isFalse);
    });

    test('an empty probe list skips the internet check', () async {
      final monitor = ConnectivityNetworkMonitor(
        connectivity: _FakeConnectivity([ConnectivityResult.wifi]),
        probes: const [],
      );
      expect(await monitor.isInternetReachable(), isTrue);
    });
  });
}
