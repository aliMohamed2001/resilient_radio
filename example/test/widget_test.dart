import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resilient_radio/resilient_radio.dart';
import 'package:resilient_radio_example/main.dart';

void main() {
  testWidgets('shows the station ready to play', (tester) async {
    final radio = ResilientRadio(station: quranCairo);

    await tester.pumpWidget(RadioExampleApp(radio: radio));

    expect(find.text(quranCairo.name), findsOneWidget);
    expect(find.textContaining('Ready'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Play'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Stop'), findsOneWidget);
  });
}
