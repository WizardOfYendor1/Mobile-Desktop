import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/ui/screens/playback/native_controller_mapping_screen.dart';
import 'package:moonfin/util/native_controller_mapping.dart';
import 'package:moonfin/util/native_controller_player_assignments.dart';
import 'package:moonfin/util/core_input_descriptors.dart';

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

  test('reads the device class and assignment metadata', () {
    final remote = NativeControllerDevice.fromMap({
      'id': 'remote',
      'name': 'onn TV Remote',
      'deviceClass': 'remote',
      'assignable': false,
      'supported': false,
    });

    expect(remote.deviceClass, NativeControllerDeviceClass.remote);
    expect(remote.assignable, isFalse);
    expect(remote.playerLabel, 'Menu & navigation');
  });

  test('a native build without the new keys keeps the old behaviour', () {
    final device = NativeControllerDevice.fromMap({
      'id': 'a',
      'name': 'Pad A',
      'port': 0,
    });

    expect(device.deviceClass, NativeControllerDeviceClass.gamepad);
    expect(device.assignable, isTrue);
    expect(device.pinned, isFalse);
  });

  test('a borrowed player slot is not labelled as pinned', () {
    const borrowed = NativeControllerDevice(id: 'a', name: 'Pad A', port: 0);
    const pinned = NativeControllerDevice(
      id: 'b',
      name: 'Pad B',
      port: 1,
      pinned: true,
    );

    expect(borrowed.playerLabel, 'Player 1');
    expect(pinned.playerLabel, 'Player 2 · pinned');
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

  testWidgets('Back steps out of an armed capture instead of leaving', (
    tester,
  ) async {
    final key = GlobalKey<NativeControllerMappingScreenState>();
    await tester.pumpWidget(harness([deviceA], key));

    // Row 1 is the first button; activating it arms capture.
    key.currentState!.handleButton(5, true);
    key.currentState!.handleButton(0, true);
    await tester.pump();
    expect(find.textContaining('Press the physical button'), findsOneWidget);

    expect(key.currentState!.handleBack(), isTrue);
    await tester.pump();

    // Back to the button list, and the host is told not to close the screen.
    expect(find.textContaining('Press the physical button'), findsNothing);
    expect(find.text('Unassigned — ${deviceA.name}'), findsOneWidget);
  });

  testWidgets('Back at the top level defers to the host overlay', (
    tester,
  ) async {
    final key = GlobalKey<NativeControllerMappingScreenState>();
    await tester.pumpWidget(harness([deviceA], key));
    await tester.pump();

    expect(key.currentState!.handleBack(), isFalse);
  });

  Widget assignmentHarness({
    required List<NativeControllerDevice> devices,
    required NativeControllerPlayerAssignments assignments,
    required Future<void> Function(NativeControllerPlayerAssignments) onChanged,
  }) => MaterialApp(
    home: Scaffold(
      body: Column(
        children: [
          NativeControllerMappingScreen(
            devices: devices,
            mappings: const {},
            assignments: assignments,
            onAssignmentChanged: onChanged,
            onMappingChanged: (_, _) async {},
            onClose: () {},
          ),
        ],
      ),
    ),
  );

  testWidgets('assigning a player swaps with the device already holding it', (
    tester,
  ) async {
    NativeControllerPlayerAssignments? applied;
    await tester.pumpWidget(
      assignmentHarness(
        devices: const [
          NativeControllerDevice(id: 'a', name: 'Pad A', port: 0, pinned: true),
          NativeControllerDevice(id: 'b', name: 'Pad B', port: 1, pinned: true),
        ],
        assignments: const NativeControllerPlayerAssignments({1: 'a', 2: 'b'}),
        onChanged: (next) async => applied = next,
      ),
    );
    await tester.pump();

    expect(find.text('Player assignment'), findsOneWidget);
    expect(find.text('Player 1 · pinned'), findsOneWidget);

    await tester.tap(find.text('Player assignment'));
    await tester.pump();
    // Pad A is selected; taking Player 2 must hand Player 1 to Pad B rather
    // than leaving it unassigned.
    expect(find.textContaining('Currently Pad B'), findsOneWidget);
    await tester.tap(find.text('Player 2'));
    await tester.pump();

    expect(applied?.profileIdByPlayer, {2: 'a', 1: 'b'});
  });

  testWidgets('core input descriptors annotate the button rows', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              NativeControllerMappingScreen(
                devices: const [
                  NativeControllerDevice(id: 'a', name: 'Pad A', port: 0),
                ],
                mappings: const {},
                inputDescriptors: CoreInputDescriptors.fromChannelPayload(
                  const [
                    // libretro calls id 0 "B" and id 1 "Y"; this screen shows
                    // them as "A" and "X". The ids are what match.
                    {
                      'port': 0,
                      'device': 1,
                      'index': 0,
                      'id': 0,
                      'description': 'Fire',
                    },
                    {
                      'port': 0,
                      'device': 1,
                      'index': 0,
                      'id': 1,
                      'description': 'Insert Coin',
                    },
                    // A core that just restates the button name adds nothing.
                    {
                      'port': 0,
                      'device': 1,
                      'index': 0,
                      'id': 3,
                      'description': 'Start',
                    },
                  ],
                ),
                onMappingChanged: (_, _) async {},
                onClose: () {},
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('A (Fire)'), findsOneWidget);
    expect(find.text('X (Insert Coin)'), findsOneWidget);
    // A button the core said nothing about keeps its bare name.
    expect(find.text('Select'), findsOneWidget);
    expect(find.text('Start'), findsOneWidget);
    expect(find.text('Start (Start)'), findsNothing);
  });

  testWidgets('a remote gets no player selector', (tester) async {
    await tester.pumpWidget(
      assignmentHarness(
        devices: const [
          NativeControllerDevice(
            id: 'remote',
            name: 'onn TV Remote',
            deviceClass: NativeControllerDeviceClass.remote,
            assignable: false,
            supported: false,
          ),
        ],
        assignments: const NativeControllerPlayerAssignments({}),
        onChanged: (_) async {},
      ),
    );
    await tester.pump();

    expect(find.text('Menu & navigation — onn TV Remote'), findsOneWidget);
    expect(find.text('Player assignment'), findsNothing);
  });

  testWidgets('an unpinned keyboard can be given a player slot', (
    tester,
  ) async {
    NativeControllerPlayerAssignments? applied;
    await tester.pumpWidget(
      assignmentHarness(
        devices: const [
          NativeControllerDevice(
            id: 'kbd',
            name: 'USB Keyboard',
            deviceClass: NativeControllerDeviceClass.keyboard,
            supported: false,
          ),
        ],
        assignments: const NativeControllerPlayerAssignments({}),
        onChanged: (next) async => applied = next,
      ),
    );
    await tester.pump();

    expect(find.text('Menu & navigation — USB Keyboard'), findsOneWidget);
    await tester.tap(find.text('Player assignment'));
    await tester.pump();
    await tester.tap(find.text('Player 2'));
    await tester.pump();

    expect(applied?.profileIdByPlayer, {2: 'kbd'});
  });
}
