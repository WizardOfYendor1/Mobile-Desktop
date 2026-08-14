import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/util/core_input_descriptors.dart';

void main() {
  group('CoreInputDescriptors.fromChannelPayload', () {
    test('looks up a description by exact port and id', () {
      final descriptors = CoreInputDescriptors.fromChannelPayload([
        {'port': 0, 'device': 1, 'index': 0, 'id': 0, 'description': 'Fire'},
        {'port': 1, 'device': 1, 'index': 0, 'id': 0, 'description': 'P2 Fire'},
      ]);

      expect(descriptors.describe(0, 0), 'Fire');
      expect(descriptors.describe(1, 0), 'P2 Fire');
    });

    test('falls back to port 0 when the exact port has no descriptor', () {
      final descriptors = CoreInputDescriptors.fromChannelPayload([
        {'port': 0, 'device': 1, 'index': 0, 'id': 0, 'description': 'Fire'},
      ]);

      // Many cores only emit descriptors for port 0 and intend them for
      // every port.
      expect(descriptors.describe(2, 0), 'Fire');
      expect(descriptors.describe(3, 0), 'Fire');
    });

    test('returns null when neither the exact port nor port 0 has it', () {
      final descriptors = CoreInputDescriptors.fromChannelPayload([
        {'port': 0, 'device': 1, 'index': 0, 'id': 0, 'description': 'Fire'},
      ]);

      expect(descriptors.describe(1, 9), isNull);
    });

    test('an empty descriptor payload never falls back to a wrong port', () {
      expect(CoreInputDescriptors.empty.describe(0, 0), isNull);
      expect(
        CoreInputDescriptors.fromChannelPayload([]).describe(0, 0),
        isNull,
      );
      expect(
        CoreInputDescriptors.fromChannelPayload(null).describe(0, 0),
        isNull,
      );
    });

    test('an empty or whitespace-only description yields no suffix', () {
      final descriptors = CoreInputDescriptors.fromChannelPayload([
        {'port': 0, 'device': 1, 'index': 0, 'id': 0, 'description': ''},
        {'port': 0, 'device': 1, 'index': 0, 'id': 1, 'description': '   '},
      ]);

      expect(descriptors.describe(0, 0), isNull);
      expect(descriptors.describe(0, 1), isNull);
    });

    test('malformed entries are dropped without throwing', () {
      final descriptors = CoreInputDescriptors.fromChannelPayload([
        'not a map',
        {'port': -1, 'device': 1, 'index': 0, 'id': 0, 'description': 'Bad'},
        {'device': 1, 'index': 0, 'description': 'Missing id and port'},
        {'port': 0, 'device': 1, 'index': 0, 'id': 5, 'description': 'Good'},
      ]);

      expect(descriptors.describe(0, 5), 'Good');
      expect(descriptors.describe(-1, 0), isNull);
    });

    test('id-keyed lookup ignores device and index, per the design', () {
      // Two entries sharing the same (port, id) but different device/index:
      // only the id is part of the lookup key, matching the naming-trap
      // comment in core_input_descriptors.dart (integers, not enum ordering,
      // are what line up between libretro and RetroPadButton).
      final descriptors = CoreInputDescriptors.fromChannelPayload([
        {'port': 0, 'device': 1, 'index': 0, 'id': 8, 'description': 'Jump'},
      ]);

      expect(descriptors.describe(0, 8), 'Jump');
    });

    test('a later duplicate (port, id) entry overwrites an earlier one', () {
      final descriptors = CoreInputDescriptors.fromChannelPayload([
        {'port': 0, 'device': 1, 'index': 0, 'id': 0, 'description': 'Old'},
        {'port': 0, 'device': 1, 'index': 0, 'id': 0, 'description': 'New'},
      ]);

      expect(descriptors.describe(0, 0), 'New');
    });
  });
}
