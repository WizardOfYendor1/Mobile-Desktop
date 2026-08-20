import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/ui/screens/playback/controller_test_panel.dart';
import 'package:moonfin/util/focus/gamepad/controller_diagnostics.dart';

void main() {
  Widget harness(ControllerDiagnosticsSnapshot? snapshot, {int? port}) {
    return MaterialApp(
      home: Scaffold(
        body: ControllerTestPanel(
          snapshot: snapshot,
          deviceName: 'F710',
          port: port,
        ),
      ),
    );
  }

  testWidgets('an analog left stick renders its numbers and verdict', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(
        const ControllerDiagnosticsSnapshot(
          connectionId: 'a',
          port: 0,
          channels: [
            StickChannel(
              id: 'left',
              x: -0.42,
              y: 0.13,
              verdict: DiagnosticVerdict.analog,
            ),
          ],
        ),
        port: 0,
      ),
    );

    expect(find.text('-0.42/0.13'), findsOneWidget);
    expect(find.text('ANALOG'), findsOneWidget);
    expect(find.text('[F710 - P1]'), findsOneWidget);
  });

  testWidgets('an unknown verdict renders the placeholder, not a verdict word', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(
        const ControllerDiagnosticsSnapshot(
          connectionId: 'a',
          port: null,
          channels: [
            StickChannel(
              id: 'left',
              x: 0,
              y: 0,
              verdict: DiagnosticVerdict.unknown,
            ),
          ],
        ),
      ),
    );

    expect(find.text('--'), findsWidgets);
    expect(find.text('ANALOG'), findsNothing);
    expect(find.text('DIGITAL'), findsNothing);
    expect(find.text('[F710 - Unassigned]'), findsOneWidget);
  });

  testWidgets('a button with the full naming chain renders every link', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(
        const ControllerDiagnosticsSnapshot(
          connectionId: 'a',
          port: 0,
          channels: [
            ButtonChannel(
              rawCode: 96,
              rawName: 'BUTTON_A',
              retroPad: 'A',
              label: 'Fire',
              pressed: true,
            ),
          ],
        ),
      ),
    );

    expect(find.text('key 96 (BUTTON_A)'), findsOneWidget);
    expect(find.text('-> RetroPad A'), findsOneWidget);
    expect(find.text('-> "Fire"'), findsOneWidget);
  });

  testWidgets(
    'a button with only rawCode/rawName renders just that link, no "null"',
    (tester) async {
      await tester.pumpWidget(
        harness(
          const ControllerDiagnosticsSnapshot(
            connectionId: 'a',
            port: 0,
            channels: [
              ButtonChannel(rawCode: 96, rawName: 'BUTTON_A', pressed: true),
            ],
          ),
        ),
      );

      expect(find.text('key 96 (BUTTON_A)'), findsOneWidget);
      expect(find.textContaining('RetroPad'), findsNothing);
      expect(find.textContaining('->'), findsNothing);
      expect(find.textContaining('null'), findsNothing);
    },
  );

  testWidgets('no hat channel shows the "reported as buttons" line', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(
        const ControllerDiagnosticsSnapshot(
          connectionId: 'a',
          port: 0,
          channels: [],
        ),
      ),
    );

    expect(find.text('reported as buttons'), findsOneWidget);
  });

  testWidgets('a hat channel present shows the d-pad row instead', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(
        const ControllerDiagnosticsSnapshot(
          connectionId: 'a',
          port: 0,
          channels: [
            StickChannel(
              id: 'hat',
              x: -1,
              y: -1,
              verdict: DiagnosticVerdict.digital,
            ),
          ],
        ),
      ),
    );

    expect(find.text('reported as buttons'), findsNothing);
    expect(find.text('< ^ - -'), findsOneWidget);
  });
}
