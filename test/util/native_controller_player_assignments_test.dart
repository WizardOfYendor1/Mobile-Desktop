import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/util/native_controller_player_assignments.dart';

void main() {
  group('NativeControllerPlayerAssignments', () {
    test('round-trips through JSON', () {
      const assignments = NativeControllerPlayerAssignments({
        1: 'android-aaa',
        3: 'android-bbb',
      });

      final restored = NativeControllerPlayerAssignments.fromJson(
        assignments.toJson(),
      );

      expect(restored.profileIdByPlayer, {1: 'android-aaa', 3: 'android-bbb'});
    });

    test('drops players outside 1..4 and blank profiles', () {
      final parsed = NativeControllerPlayerAssignments.fromJson(
        '{"players":{"0":"a","5":"b","two":"c","2":"","3":"ok"}}',
      );

      expect(parsed.profileIdByPlayer, {3: 'ok'});
    });

    test('malformed payloads yield no assignments', () {
      expect(
        NativeControllerPlayerAssignments.fromJson('not json').isEmpty,
        isTrue,
      );
      expect(NativeControllerPlayerAssignments.fromJson('[]').isEmpty, isTrue);
      expect(
        NativeControllerPlayerAssignments.fromJson('{"players":[]}').isEmpty,
        isTrue,
      );
    });

    test('assigning an unheld player leaves others alone', () {
      const assignments = NativeControllerPlayerAssignments({1: 'a'});

      final next = assignments.withPlayer('b', 2);

      expect(next.profileIdByPlayer, {1: 'a', 2: 'b'});
    });

    test('assigning an occupied player swaps the two devices', () {
      const assignments = NativeControllerPlayerAssignments({1: 'a', 2: 'b'});

      final next = assignments.withPlayer('b', 1);

      expect(next.profileIdByPlayer, {1: 'b', 2: 'a'});
    });

    test('an unassigned device taking an occupied player displaces it', () {
      const assignments = NativeControllerPlayerAssignments({1: 'a'});

      final next = assignments.withPlayer('b', 1);

      // 'a' held nothing to swap into, so it becomes unassigned rather than
      // being silently duplicated somewhere.
      expect(next.profileIdByPlayer, {1: 'b'});
      expect(next.playerFor('a'), isNull);
    });

    test('clearing removes only that device', () {
      const assignments = NativeControllerPlayerAssignments({1: 'a', 2: 'b'});

      final next = assignments.withPlayer('a', null);

      expect(next.profileIdByPlayer, {2: 'b'});
    });

    test('reassigning to the player already held is a no-op', () {
      const assignments = NativeControllerPlayerAssignments({1: 'a', 2: 'b'});

      final next = assignments.withPlayer('a', 1);

      expect(next.profileIdByPlayer, {1: 'a', 2: 'b'});
    });

    test('out-of-range players are rejected', () {
      const assignments = NativeControllerPlayerAssignments({1: 'a'});

      expect(assignments.withPlayer('b', 0).profileIdByPlayer, {1: 'a'});
      expect(assignments.withPlayer('b', 5).profileIdByPlayer, {1: 'a'});
    });

    test('playerFor finds the assigned slot', () {
      const assignments = NativeControllerPlayerAssignments({3: 'a'});

      expect(assignments.playerFor('a'), 3);
      expect(assignments.playerFor('missing'), isNull);
    });
  });
}
