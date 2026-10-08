import 'package:flutter_test/flutter_test.dart';
import 'package:resilient_radio/resilient_radio.dart';

import 'fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a new radio waits for play before touching anything', () async {
    final radio = ResilientRadio(
      station: station,
      config: const RadioConfig(
        content: RadioContent.speech,
        reconnect: ReconnectPolicy(maxAttempts: 3),
        notification: RadioNotificationConfig(channelName: 'Live radio'),
      ),
    );

    expect(radio.station, station);
    expect(radio.state.station, station);
    expect(radio.state.status, RadioStatus.initial);
    expect(radio.state.maxAttempts, 3);
    expect(radio.config.content, RadioContent.speech);

    await radio.dispose();
  });

  test('the default policy waits 1, 2, 4, 8, 16 and then 30 seconds', () {
    const policy = ReconnectPolicy();
    expect(
      [for (var attempt = 0; attempt < 8; attempt++) policy.delayFor(attempt)],
      [1, 2, 4, 8, 16, 30, 30, 30].map((seconds) => Duration(seconds: seconds)),
    );
    expect(policy.delayFor(100), const Duration(seconds: 30));
  });
}
