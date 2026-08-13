import 'dart:convert';

import 'package:server_core/server_core.dart';

/// The durable "this pad is Player 1" choice, keyed by the privacy-safe profile
/// id the native side reports for a physical controller.
///
/// Stored by player number rather than libretro port index so the saved file
/// reads the way the UI talks. libretro port N is in-core player N + 1; that
/// conversion happens at the platform channel boundary, not here.
///
/// Identical controllers can report the same profile id (it is derived from
/// vendor, product and descriptor, and identical USB devices can share all
/// three). Assignment is therefore per profile: which *physical* twin becomes
/// Player 1 is arbitrary, though the native registry keeps it stable for the
/// life of a session.
class NativeControllerPlayerAssignments {
  const NativeControllerPlayerAssignments(this.profileIdByPlayer);

  static const empty = NativeControllerPlayerAssignments({});

  /// Player number (1..[maxPlayers]) to controller profile id.
  final Map<int, String> profileIdByPlayer;

  static const maxPlayers = 4;

  bool get isEmpty => profileIdByPlayer.isEmpty;

  int? playerFor(String profileId) {
    for (final entry in profileIdByPlayer.entries) {
      if (entry.value == profileId) return entry.key;
    }
    return null;
  }

  /// Assigns [profileId] to [player], or clears its assignment when [player] is
  /// null.
  ///
  /// Assigning to an occupied slot swaps the two devices rather than dropping
  /// the occupant: the displaced device takes the slot this one vacated, or
  /// becomes unassigned if this one held none. Silently unassigning someone
  /// while the user was assigning someone else is never the intent.
  NativeControllerPlayerAssignments withPlayer(String profileId, int? player) {
    final previous = playerFor(profileId);
    final next = Map<int, String>.from(profileIdByPlayer);

    if (player == null) {
      if (previous != null) next.remove(previous);
      return NativeControllerPlayerAssignments(Map.unmodifiable(next));
    }
    if (player < 1 || player > maxPlayers) return this;

    final displaced = next[player];
    next[player] = profileId;
    if (previous != null && previous != player) next.remove(previous);
    if (displaced != null && displaced != profileId && previous != null) {
      next[previous] = displaced;
    }
    return NativeControllerPlayerAssignments(Map.unmodifiable(next));
  }

  factory NativeControllerPlayerAssignments.fromJson(String json) {
    try {
      final decoded = jsonDecode(json);
      if (decoded is! Map) return empty;
      final players = decoded['players'];
      if (players is! Map) return empty;
      final parsed = <int, String>{};
      for (final entry in players.entries) {
        final player = int.tryParse(entry.key.toString());
        final profileId = entry.value?.toString() ?? '';
        if (player == null || player < 1 || player > maxPlayers) continue;
        if (profileId.isEmpty) continue;
        parsed[player] = profileId;
      }
      return NativeControllerPlayerAssignments(Map.unmodifiable(parsed));
    } catch (_) {
      return empty;
    }
  }

  String toJson() => jsonEncode({
    'players': {
      for (final entry in profileIdByPlayer.entries)
        entry.key.toString(): entry.value,
    },
  });
}

const _assignmentsSaveId = 'moonfin-native-controller-players';

/// A missing save or an unreachable server yields no assignments, which is the
/// pre-assignment behaviour: the native side falls back to discovery order.
/// Assignment never blocks a game from starting.
Future<NativeControllerPlayerAssignments> loadControllerPlayerAssignments(
  GamesApi games,
) async {
  try {
    final blob = await games.getSave(_assignmentsSaveId, kind: 'settings');
    if (blob == null || blob.isEmpty) {
      return NativeControllerPlayerAssignments.empty;
    }
    return NativeControllerPlayerAssignments.fromJson(utf8.decode(blob));
  } catch (_) {
    return NativeControllerPlayerAssignments.empty;
  }
}

Future<void> saveControllerPlayerAssignments(
  GamesApi games,
  NativeControllerPlayerAssignments assignments,
) => games.putSave(
  _assignmentsSaveId,
  utf8.encode(assignments.toJson()),
  kind: 'settings',
);
