import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:server_core/server_core.dart';
import 'package:gamepads/gamepads.dart';
import 'package:moonfin/util/native_controller_mapping.dart';

void main() {
  _dataLossGuardTests();
  test('round-trips through JSON', () {
    const mapping = NativeControllerMapping({
      96: RetroPadButton.a,
      97: RetroPadButton.b,
    });

    final restored = NativeControllerMapping.fromJson(mapping.toJson());

    expect(restored.keycodeToButton, mapping.keycodeToButton);
  });

  test('withBinding replaces any existing binding of the same button', () {
    const mapping = NativeControllerMapping({96: RetroPadButton.a});

    final rebound = mapping.withBinding(97, RetroPadButton.a);

    expect(rebound.keycodeToButton[96], isNull);
    expect(rebound.keycodeToButton[97], RetroPadButton.a);
  });

  test('withBinding replaces any existing binding of the same key', () {
    const mapping = NativeControllerMapping({96: RetroPadButton.a});

    final rebound = mapping.withBinding(96, RetroPadButton.b);

    expect(rebound.keycodeToButton[96], RetroPadButton.b);
  });

  test('copy creates an independent immutable snapshot', () {
    final source = NativeControllerMapping({
      96: RetroPadButton.a,
      97: RetroPadButton.b,
    });

    final copy = source.copy();

    expect(copy.keycodeToButton, source.keycodeToButton);
    expect(identical(copy.keycodeToButton, source.keycodeToButton), isFalse);
    expect(
      () => (copy.keycodeToButton as Map)[98] = RetroPadButton.x,
      throwsA(isA<UnsupportedError>()),
    );
  });

  test('ignores malformed persisted bindings', () {
    final restored = NativeControllerMapping.fromJson('{"96": 99, "bad": 0}');

    expect(restored.keycodeToButton, isEmpty);
  });

  test('persists alternate controller types per canonical core', () {
    const mapping = NativeControllerMapping(
      {96: RetroPadButton.a},
      controllerTypesByCore: {'fbneo': 517},
    );

    final restored = NativeControllerMapping.fromJson(mapping.toJson());
    final encoded = jsonDecode(mapping.toJson()) as Map<String, dynamic>;

    expect(restored.keycodeToButton, mapping.keycodeToButton);
    expect(encoded['96'], RetroPadButton.a.retroPadIndex);
    expect(encoded, isNot(contains('bindings')));
    expect(restored.controllerTypeForCore('fbneo'), 517);
    expect(restored.controllerTypeForCore('snes9x'), retroDeviceJoypad);
    expect(
      restored
          .withControllerType('fbneo', retroDeviceJoypad)
          .controllerTypesByCore,
      isNot(contains('fbneo')),
      reason: 'Auto is an unset default, not a persisted advertised choice',
    );
  });

  test('only exposes the implemented FBNeo controller layouts', () {
    const modern = CoreControllerType(port: 0, id: 517, label: 'Modern');
    const foreignSubclass = CoreControllerType(
      port: 0,
      id: 517,
      label: 'Not an FBNeo layout',
    );
    const mouse = CoreControllerType(port: 0, id: 2, label: 'Mouse');
    const auto = CoreControllerType(
      port: 0,
      id: retroDeviceJoypad,
      label: 'Joypad',
    );

    expect(modern.isSupportedForCore('fbneo'), isTrue);
    expect(foreignSubclass.isSupportedForCore('snes9x'), isFalse);
    expect(mouse.isSupportedForCore('fbneo'), isFalse);
    expect(auto.isSupportedForCore('snes9x'), isTrue);
  });

  // These codes are persisted in users' saved desktop mappings, so the table
  // has to stay both complete and stable across gamepads-package upgrades. A
  // new button arriving upstream is silently unmappable without the first
  // check; a duplicated code would make two physical buttons share one
  // binding. Neither shows up as a compile error.
  test('every normalized gamepad button has a unique persisted code', () {
    expect(
      desktopGamepadButtonCodes.keys.toSet(),
      GamepadButton.values.toSet(),
      reason: 'gamepads upgrade changed GamepadButton; update the code table',
    );
    expect(
      desktopGamepadButtonCodes.values.toSet().length,
      GamepadButton.values.length,
      reason: 'two buttons share a persisted code',
    );
    expect(desktopGamepadButtonsByCode.length, GamepadButton.values.length);
  });

  test('desktop device ids are namespaced away from Android hashes', () {
    expect(desktopControllerDeviceId('0'), 'pad:0');
  });
}

class _UnreachableGamesApi extends Mock implements GamesApi {}

void _dataLossGuardTests() {
  group('loadControllerMappingChecked', () {
    test('an unreachable server is reported, not reported as empty', () async {
      final api = _UnreachableGamesApi();
      when(
        () => api.getSave(any(), kind: any(named: 'kind')),
      ).thenThrow(Exception('offline'));

      final result = await loadControllerMappingChecked(api, 'pad-1');

      // The distinction that prevents data loss: a failed read must not look
      // like "this pad has no mapping", or the next edit persists blank
      // bindings over the real ones.
      expect(result.reachable, isFalse);
      expect(result.mapping, NativeControllerMapping.empty);
    });

    test('a genuinely absent mapping is reachable and empty', () async {
      final api = _UnreachableGamesApi();
      when(
        () => api.getSave(any(), kind: any(named: 'kind')),
      ).thenAnswer((_) async => null);

      final result = await loadControllerMappingChecked(api, 'pad-1');

      expect(result.reachable, isTrue);
      expect(result.mapping, NativeControllerMapping.empty);
    });
  });

  group('saveControllerMapping', () {
    test('retries a dropped connection instead of losing the edit', () async {
      final api = _UnreachableGamesApi();
      var calls = 0;
      when(() => api.putSave(any(), any(), kind: any(named: 'kind'))).thenAnswer(
        (_) async {
          calls++;
          if (calls < 2) {
            throw DioException(
              requestOptions: RequestOptions(path: '/'),
              type: DioExceptionType.connectionError,
            );
          }
        },
      );

      await saveControllerMapping(
        api,
        'pad-1',
        NativeControllerMapping.empty,
        retryDelay: (_) async {},
      );

      expect(calls, 2);
    });

    test('rethrows once retries are exhausted, so callers can say so', () async {
      final api = _UnreachableGamesApi();
      when(() => api.putSave(any(), any(), kind: any(named: 'kind'))).thenThrow(
        DioException(
          requestOptions: RequestOptions(path: '/'),
          type: DioExceptionType.connectionError,
        ),
      );

      await expectLater(
        saveControllerMapping(
          api,
          'pad-1',
          NativeControllerMapping.empty,
          retryDelay: (_) async {},
        ),
        throwsA(isA<DioException>()),
      );
    });
  });
}
