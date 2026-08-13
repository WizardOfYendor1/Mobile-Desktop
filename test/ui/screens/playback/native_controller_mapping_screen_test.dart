import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/ui/screens/playback/native_controller_mapping_screen.dart';
import 'package:moonfin/util/native_controller_mapping.dart';

void main() {
  const deviceA = NativeControllerDevice(id: 'a', name: 'Pad A');
  const deviceB = NativeControllerDevice(id: 'b', name: 'Pad B');
  const deviceC = NativeControllerDevice(id: 'c', name: 'Pad C');

  test('creates a native device from Android connection metadata', () {
    final device = NativeControllerDevice.fromMap({
      'id': 'profile-a',
      'connectionId': 'connection-a',
      'name': 'Pad A',
      'port': 1,
      'supported': true,
    });

    expect(device.id, 'profile-a');
    expect(device.connectionId, 'connection-a');
    expect(device.port, 1);
    expect(device.supported, isTrue);
  });

  Widget harness(
    List<NativeControllerDevice> devices,
    GlobalKey<NativeControllerMappingScreenState> key,
  ) {
    return MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            NativeControllerMappingScreen(
              key: key,
              devices: devices,
              mappings: const {},
              onMappingChanged: (_, _) async {},
              onClose: () {},
            ),
          ],
        ),
      ),
    );
  }

  testWidgets(
    'rebuild with a shorter device list clamps selection instead of throwing',
    (tester) async {
      final key = GlobalKey<NativeControllerMappingScreenState>();
      await tester.pumpWidget(harness([deviceA, deviceB, deviceC], key));
      key.currentState!.handleButton(7, true); // -> b
      await tester.pump();
      key.currentState!.handleButton(7, true); // -> c
      await tester.pump();
      expect(find.text('Unassigned — ${deviceC.name}'), findsOneWidget);

      // deviceC (currently selected) is gone; list is now shorter than the
      // stored index. Must not throw RangeError.
      await tester.pumpWidget(harness([deviceA], key));
      await tester.pump();

      expect(find.text('Unassigned — ${deviceA.name}'), findsOneWidget);
    },
  );

  testWidgets(
    'rebuild with an empty device list renders the empty-state message',
    (tester) async {
      final key = GlobalKey<NativeControllerMappingScreenState>();
      await tester.pumpWidget(harness([deviceA, deviceB], key));
      await tester.pumpWidget(harness(const [], key));
      await tester.pump();

      expect(
        find.text('Connect a physical controller to change its mapping.'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'rebuild preserves the selected device when it moves to a different index',
    (tester) async {
      final key = GlobalKey<NativeControllerMappingScreenState>();
      await tester.pumpWidget(harness([deviceA, deviceB, deviceC], key));
      key.currentState!.handleButton(7, true); // -> b
      await tester.pump();
      expect(find.text('Unassigned — ${deviceB.name}'), findsOneWidget);

      // Same device, new position in the list.
      await tester.pumpWidget(harness([deviceC, deviceA, deviceB], key));
      await tester.pump();

      expect(find.text('Unassigned — ${deviceB.name}'), findsOneWidget);
    },
  );

  testWidgets('copy asks for confirmation and invokes the source callback', (
    tester,
  ) async {
    final key = GlobalKey<NativeControllerMappingScreenState>();
    String? copied;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              NativeControllerMappingScreen(
                key: key,
                devices: const [
                  NativeControllerDevice(
                    id: 'a',
                    connectionId: 'a-connection',
                    name: 'Pad A',
                    port: 0,
                  ),
                  NativeControllerDevice(
                    id: 'b',
                    connectionId: 'b-connection',
                    name: 'Pad B',
                    port: 1,
                  ),
                ],
                mappings: const {
                  'a': NativeControllerMapping({96: RetroPadButton.a}),
                },
                onMappingChanged: (_, _) async {},
                onCopyMapping: (id) async => copied = id,
                onClose: () {},
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    for (var i = 0; i < 17; i++) {
      key.currentState!.handleButton(5, true);
    }
    key.currentState!.handleButton(0, true);
    await tester.pump();
    expect(
      find.textContaining('copies Android button keycodes'),
      findsOneWidget,
    );
    expect(copied, isNull);

    key.currentState!.handleButton(0, true);
    await tester.pump();
    expect(copied, 'a');
  });

  testWidgets('shows and applies the supported core controller type selector', (
    tester,
  ) async {
    final key = GlobalKey<NativeControllerMappingScreenState>();
    int? selectedType;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              NativeControllerMappingScreen(
                key: key,
                devices: const [
                  NativeControllerDevice(id: 'a', name: 'Pad A', port: 0),
                ],
                mappings: const {
                  'a': NativeControllerMapping(
                    {},
                    controllerTypesByCore: {'fbneo': 517},
                  ),
                },
                coreId: 'fbneo',
                controllerTypesByPort: const {
                  0: [
                    CoreControllerType(port: 0, id: 5, label: 'Classic'),
                    CoreControllerType(port: 0, id: 517, label: 'Modern'),
                    CoreControllerType(
                      port: 0,
                      id: 261,
                      label: '6-Button Panel',
                    ),
                  ],
                },
                onMappingChanged: (_, _) async {},
                onControllerTypeChanged: (_, type) async => selectedType = type,
                onClose: () {},
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Core controller type'), findsOneWidget);
    expect(find.text('Modern'), findsOneWidget);

    key.currentState!.handleButton(5, true);
    key.currentState!.handleButton(0, true);
    await tester.pump();
    expect(find.text('Auto (Core default)'), findsOneWidget);

    key.currentState!.handleButton(4, true);
    key.currentState!.handleButton(0, true);
    await tester.pump();
    expect(selectedType, 5);
  });

  testWidgets('shows Auto when one alternate layout is supported', (
    tester,
  ) async {
    final key = GlobalKey<NativeControllerMappingScreenState>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              NativeControllerMappingScreen(
                key: key,
                devices: const [
                  NativeControllerDevice(id: 'a', name: 'Pad A', port: 0),
                ],
                mappings: const {},
                coreId: 'fbneo',
                controllerTypesByPort: const {
                  0: [CoreControllerType(port: 0, id: 5, label: 'Classic')],
                },
                onMappingChanged: (_, _) async {},
                onClose: () {},
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Core controller type'), findsOneWidget);
  });
}
