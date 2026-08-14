/// Core-supplied, human-readable descriptions for RetroPad inputs, delivered
/// through RETRO_ENVIRONMENT_SET_INPUT_DESCRIPTORS (see libretro_host.c's
/// `lh_input_descriptor` and LibretroBridge.kt's `NativeInputDescriptor`).
/// Cores populate labels such as "Coin", "Start", or "Fire" for specific
/// (port, device, index, id) combinations, and this file turns that raw list
/// into a lookup a mapping UI can consult per button.
library;

import 'native_controller_mapping.dart' show retroDeviceJoypad;

/// One RETRO_ENVIRONMENT_SET_INPUT_DESCRIPTORS entry.
class CoreInputDescriptor {
  const CoreInputDescriptor({
    required this.port,
    required this.device,
    required this.index,
    required this.id,
    required this.description,
  });

  final int port;
  final int device;
  final int index;
  final int id;
  final String description;

  factory CoreInputDescriptor.fromMap(Map<String, dynamic> map) {
    return CoreInputDescriptor(
      port: (map['port'] as num?)?.toInt() ?? -1,
      device: (map['device'] as num?)?.toInt() ?? -1,
      index: (map['index'] as num?)?.toInt() ?? -1,
      id: (map['id'] as num?)?.toInt() ?? -1,
      description: map['description']?.toString() ?? '',
    );
  }
}

/// Looks up a core's advertised label for a button by (port, id).
///
/// NAMING TRAP: libretro's own RETRO_DEVICE_ID_JOYPAD_B is 0 and
/// RETRO_DEVICE_ID_JOYPAD_A is 8 (SNES positional naming: B/Y are the
/// "bottom" face buttons). This codebase's `RetroPadButton` in
/// native_controller_mapping.dart instead calls index 0 'A' and index 8 'B',
/// using Android/Xbox physical naming. The two enumerations use the SAME
/// integers for the SAME physical buttons, so looking a description up by
/// the raw integer id (as [describe] does below) is correct: a core's label
/// for the button this UI shows as "A" genuinely arrives tagged with
/// libretro's id 0, i.e. under libretro's own name "B". Do not "fix" this by
/// remapping the id here -- that would turn a correct lookup into a real bug.
class CoreInputDescriptors {
  const CoreInputDescriptors._(this._byPortDeviceAndId);

  /// port -> device (controller type) -> libretro id -> description.
  ///
  /// `device` is part of the key, not decoration. FBNeo running Spy Hunter
  /// advertises `port=0 device=1 id=0 'Missiles'` *and*
  /// `port=0 device=5 id=0 'Wheel'` -- the same button under two controller
  /// types. Keying on (port, id) alone let the later entry silently overwrite
  /// the earlier one and label the button for a layout the user is not using.
  final Map<int, Map<int, Map<int, String>>> _byPortDeviceAndId;

  static const empty = CoreInputDescriptors._({});

  /// Builds a lookup from the raw channel payload (a list of maps shaped like
  /// [CoreInputDescriptor.fromMap] expects). Entries with a negative port/id
  /// or an empty/whitespace-only description are dropped: an empty
  /// description must never produce a placeholder suffix, so it is simplest
  /// to never store it at all.
  factory CoreInputDescriptors.fromChannelPayload(List<dynamic>? raw) {
    if (raw == null || raw.isEmpty) return empty;
    final byPortDeviceAndId = <int, Map<int, Map<int, String>>>{};
    for (final entry in raw) {
      if (entry is! Map) continue;
      final descriptor = CoreInputDescriptor.fromMap(
        entry.cast<String, dynamic>(),
      );
      if (descriptor.port < 0 || descriptor.id < 0 || descriptor.device < 0) {
        continue;
      }
      final description = descriptor.description.trim();
      if (description.isEmpty) continue;
      final byDevice = byPortDeviceAndId.putIfAbsent(descriptor.port, () => {});
      final byId = byDevice.putIfAbsent(descriptor.device, () => {});
      byId[descriptor.id] = description;
    }
    if (byPortDeviceAndId.isEmpty) return empty;
    return CoreInputDescriptors._(byPortDeviceAndId);
  }

  /// The core's label for [id] on [port], or null when the core described
  /// nothing for it. Many cores only ever emit descriptors for port 0 and
  /// intend them for every port (RetroArch treats port-0-only descriptor
  /// sets the same way), so a missing exact-port entry falls back to port 0
  /// before giving up. Never returns an empty string -- see
  /// [CoreInputDescriptors.fromChannelPayload], which drops those at build
  /// time.
  /// [device] is the controller type currently selected for [port] --
  /// [retroDeviceJoypad] unless the user picked a core-specific layout.
  ///
  /// Resolution order, most specific first: this port under this device type,
  /// this port under the plain joypad, then the same two against port 0 (many
  /// cores describe only port 0 and mean it for every port). No blind "any
  /// device" fallback: a description that belongs to a layout the user is not
  /// using is worse than no description.
  String? describe(int port, int id, {int device = retroDeviceJoypad}) {
    for (final candidatePort in port == 0 ? const [0] : [port, 0]) {
      final byDevice = _byPortDeviceAndId[candidatePort];
      if (byDevice == null) continue;
      final exact = byDevice[device]?[id];
      if (exact != null) return exact;
      final generic = byDevice[retroDeviceJoypad]?[id];
      if (generic != null) return generic;
    }
    return null;
  }
}
