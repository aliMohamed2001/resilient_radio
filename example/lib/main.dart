import 'dart:async';

import 'package:flutter/material.dart';
import 'package:resilient_radio/resilient_radio.dart';

final quranCairo = RadioStation(
  id: 'quran_cairo',
  name: 'إذاعة القرآن الكريم من القاهرة',
  description: 'Quran Radio Cairo',
  streamUrl: Uri.parse('https://stream.radiojar.com/8s5u5tpdtwzuv'),
);

void main() {
  final radio = ResilientRadio(
    station: quranCairo,
    config: RadioConfig(
      content: RadioContent.speech,
      logger: (level, message, {error, stackTrace}) {
        final cause = error == null ? '' : ' ($error)';
        debugPrint('radio ${level.name}: $message$cause');
      },
    ),
  );
  runApp(RadioExampleApp(radio: radio));
}

class RadioExampleApp extends StatelessWidget {
  const RadioExampleApp({super.key, required this.radio});

  final ResilientRadio radio;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'resilient_radio',
      theme: ThemeData(colorSchemeSeed: Colors.teal),
      home: RadioPage(radio: radio),
    );
  }
}

enum _Source { quranCairo, custom }

class RadioPage extends StatefulWidget {
  const RadioPage({super.key, required this.radio});

  final ResilientRadio radio;

  @override
  State<RadioPage> createState() => _RadioPageState();
}

class _RadioPageState extends State<RadioPage> {
  final _url = TextEditingController();
  final _events = <String>[];
  late final StreamSubscription<RadioEvent> _subscription;
  _Source _source = _Source.quranCairo;

  ResilientRadio get radio => widget.radio;

  @override
  void initState() {
    super.initState();
    _subscription = radio.eventStream.listen((event) {
      final time = DateTime.now().toIso8601String().substring(11, 19);
      setState(() {
        _events.insert(0, '$time  $event');
        if (_events.length > 30) _events.removeLast();
      });
    });
  }

  @override
  void dispose() {
    _subscription.cancel();
    _url.dispose();
    super.dispose();
  }

  Future<void> _select(_Source source) async {
    setState(() => _source = source);
    if (source == _Source.quranCairo) await radio.setStation(quranCairo);
  }

  Future<void> _useCustomUrl() async {
    final url = Uri.tryParse(_url.text.trim());
    if (url == null ||
        url.host.isEmpty ||
        !(url.isScheme('http') || url.isScheme('https'))) {
      _show('Enter an http or https stream URL.');
      return;
    }
    final result = await StreamProbe().check(url);
    if (!mounted) return;
    final failure = result.failure;
    if (failure != null) {
      final status =
          result.statusCode == null ? '' : ' (HTTP ${result.statusCode})';
      _show('${describeFailure(failure)}$status');
      return;
    }
    await radio.setStation(
      RadioStation(
        id: 'custom',
        name: url.host,
        description: 'Custom stream',
        streamUrl: url,
      ),
    );
  }

  Future<void> _checkConnection() async {
    final failure = await radio.checkConnection();
    if (!mounted) return;
    _show(failure == null ? 'Online' : describeFailure(failure));
  }

  void _show(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('resilient_radio')),
      body: StreamBuilder<RadioState>(
        stream: radio.stateStream,
        initialData: radio.state,
        builder: (context, snapshot) {
          final state = snapshot.data!;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              SegmentedButton<_Source>(
                segments: const [
                  ButtonSegment(
                    value: _Source.quranCairo,
                    label: Text('Quran Radio Cairo'),
                  ),
                  ButtonSegment(
                      value: _Source.custom, label: Text('Custom URL')),
                ],
                selected: {_source},
                onSelectionChanged: (selection) => _select(selection.single),
              ),
              if (_source == _Source.custom) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: _url,
                  keyboardType: TextInputType.url,
                  decoration: InputDecoration(
                    labelText: 'Stream URL',
                    hintText: 'https://example.com/live',
                    suffixIcon: IconButton(
                      tooltip: 'Use this stream',
                      icon: const Icon(Icons.check),
                      onPressed: _useCustomUrl,
                    ),
                  ),
                  onSubmitted: (_) => _useCustomUrl(),
                ),
              ],
              const SizedBox(height: 16),
              _StatusCard(state: state),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: radio.toggle,
                    icon: Icon(
                        state.isListening ? Icons.pause : Icons.play_arrow),
                    label: Text(state.isListening ? 'Pause' : 'Play'),
                  ),
                  OutlinedButton.icon(
                    onPressed: state.canStop ? radio.stop : null,
                    icon: const Icon(Icons.stop),
                    label: const Text('Stop'),
                  ),
                  TextButton(
                    onPressed: _canRetry(state) ? radio.retry : null,
                    child: const Text('Retry'),
                  ),
                  TextButton(
                    onPressed: _checkConnection,
                    child: const Text('Check connection'),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              Text('Events', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              for (final line in _events)
                Text(
                  line,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
            ],
          );
        },
      ),
    );
  }

  bool _canRetry(RadioState state) =>
      state.status == RadioStatus.error ||
      state.status == RadioStatus.noInternet ||
      state.status == RadioStatus.reconnecting;
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.state});

  final RadioState state;

  @override
  Widget build(BuildContext context) {
    final failure = state.failure;
    final detail = switch (state.status) {
      RadioStatus.reconnecting =>
        'Attempt ${state.attempt} of ${state.maxAttempts}'
            '${failure == null ? '' : ': ${describeFailure(failure)}'}',
      RadioStatus.paused when state.isInterrupted =>
        'Paused for another app, resumes on its own',
      _ when failure != null => describeFailure(failure),
      _ => state.station.description ?? state.station.streamUrl.host,
    };

    return Card(
      child: ListTile(
        title: Text(state.station.name),
        subtitle: Text('${statusLabel(state.status)}\n$detail'),
        isThreeLine: true,
        trailing: state.isBusy
            ? const SizedBox.square(
                dimension: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : null,
      ),
    );
  }
}

String statusLabel(RadioStatus status) => switch (status) {
      RadioStatus.initial => 'Ready',
      RadioStatus.loading => 'Connecting…',
      RadioStatus.buffering => 'Buffering…',
      RadioStatus.playing => 'Playing',
      RadioStatus.paused => 'Paused',
      RadioStatus.reconnecting => 'Reconnecting…',
      RadioStatus.noInternet => 'Offline',
      RadioStatus.error => 'Error',
      RadioStatus.stopped => 'Stopped',
    };

String describeFailure(RadioFailure failure) => switch (failure) {
      RadioFailure.noNetwork => 'No network connection',
      RadioFailure.internetUnavailable =>
        'Connected, but the internet is not reachable',
      RadioFailure.streamUnreachable => 'The stream server cannot be reached',
      RadioFailure.timeout => 'The stream took too long to answer',
      RadioFailure.streamNotFound => 'The stream was not found',
      RadioFailure.accessDenied => 'The stream refused access',
      RadioFailure.serverError => 'The stream server is having problems',
      RadioFailure.streamRejected => 'The stream rejected the request',
      RadioFailure.invalidStream => 'The URL did not return playable audio',
      RadioFailure.connectionLost => 'The connection dropped',
      RadioFailure.playbackFailed => 'Playback failed',
      RadioFailure.audioUnavailable => 'The audio service could not start',
    };
