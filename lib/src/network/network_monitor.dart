import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';

import '../core/radio_config.dart';

abstract interface class NetworkMonitor {
  Future<bool> hasNetwork();

  Stream<bool> get changes;

  Future<bool> isInternetReachable();
}

class ConnectivityNetworkMonitor implements NetworkMonitor {
  ConnectivityNetworkMonitor({
    Connectivity? connectivity,
    HttpClient Function()? httpClient,
    List<Uri>? probes,
    this.timeout = const Duration(seconds: 5),
    RadioLogger? logger,
  })  : _connectivity = connectivity ?? Connectivity(),
        _httpClient = httpClient ?? HttpClient.new,
        _probes = probes ?? RadioConfig.defaultInternetProbes,
        _logger = logger;

  final Connectivity _connectivity;
  final HttpClient Function() _httpClient;
  final List<Uri> _probes;
  final Duration timeout;
  final RadioLogger? _logger;

  @override
  Future<bool> hasNetwork() async {
    try {
      return _isConnected(await _connectivity.checkConnectivity());
    } on Object catch (error) {
      _logger?.call(
        RadioLogLevel.warning,
        'connectivity state unavailable',
        error: error,
      );
      return true;
    }
  }

  @override
  Stream<bool> get changes =>
      _connectivity.onConnectivityChanged.map(_isConnected).distinct();

  @override
  Future<bool> isInternetReachable() {
    if (_probes.isEmpty) return Future.value(true);
    final verdict = Completer<bool>();
    var pending = _probes.length;
    for (final probe in _probes) {
      unawaited(
        _reaches(probe).then((reached) {
          pending--;
          if (verdict.isCompleted) return;
          if (reached) {
            verdict.complete(true);
          } else if (pending == 0) {
            verdict.complete(false);
          }
        }),
      );
    }
    return verdict.future;
  }

  Future<bool> _reaches(Uri probe) async {
    final client = _httpClient()..connectionTimeout = timeout;
    try {
      final request = await client.headUrl(probe).timeout(timeout);
      request.followRedirects = false;
      final response = await request.close().timeout(timeout);
      await response.drain<void>().timeout(timeout);
      return response.statusCode >= 200 && response.statusCode < 300;
    } on Object catch (error) {
      _logger?.call(RadioLogLevel.info, 'probe ${probe.host} failed: $error');
      return false;
    } finally {
      client.close(force: true);
    }
  }

  static bool _isConnected(List<ConnectivityResult> results) =>
      results.any((result) => result != ConnectivityResult.none);
}
