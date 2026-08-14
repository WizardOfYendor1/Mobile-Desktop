/// Core-supplied, human-readable descriptions for RetroPad inputs, delivered
/// through RETRO_ENVIRONMENT_SET_INPUT_DESCRIPTORS (see libretro_host.c's
/// `lh_input_descriptor` and LibretroBridge.kt's `NativeInputDescriptor`).
/// Cores populate labels such as "Coin", "Start", or "Fire" for specific
/// (port, device, index, id) combinations, and this file turns that raw list
/// into a lookup a mapping UI can consult per button.
library;

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
  const CoreInputDescriptors._(this._byPortAndId);

  final Map<int, Map<int, String>> _byPortAndId;

  static const empty = CoreInputDescriptors._({});

  /// Builds a lookup from the raw channel payload (a list of maps shaped like
  /// [CoreInputDescriptor.fromMap] expects). Entries with a negative port/id
  /// or an empty/whitespace-only description are dropped: an empty
  /// description must never produce a placeholder suffix, so it is simplest
  /// to never store it at all.
  factory CoreInputDescriptors.fromChannelPayload(List<dynamic>? raw) {
    if (raw == null || raw.isEmpty) return empty;
    final byPortAndId = <int, Map<int, String>>{};
    for (final entry in raw) {
      if (entry is! Map) continue;
      final descriptor = CoreInputDescriptor.fromMap(
        entry.cast<String, dynamic>(),
      );
      if (descriptor.port < 0 || descriptor.id < 0) continue;
      final description = descriptor.description.trim();
      if (description.isEmpty) continue;
      final byId = byPortAndId.putIfAbsent(descriptor.port, () => {});
      byId[descriptor.id] = description;
    }
    if (byPortAndId.isEmpty) return empty;
    return CoreInputDescriptors._(byPortAndId);
  }

  /// The core's label for [id] on [port], or null when the core described
  /// nothing for it. Many cores only ever emit descriptors for port 0 and
  /// intend them for every port (RetroArch treats port-0-only descriptor
  /// sets the same way), so a missing exact-port entry falls back to port 0
  /// before giving up. Never returns an empty string -- see
  /// [CoreInputDescriptors.fromChannelPayload], which drops those at build
  /// time.
  String? describe(int port, int id) {
    final exact = _byPortAndId[port]?[id];
    if (exact != null) return exact;
    if (port == 0) return null;
    return _byPortAndId[0]?[id];
  }
}
