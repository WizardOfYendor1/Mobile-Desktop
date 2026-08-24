import 'dart:async';

import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';

import '../data/services/log_service.dart';
import '../util/platform_detection.dart';
import 'audio_capability_profile.dart';
import 'device_capability_cache.dart';

/// Cross-platform front-end for the native audio capability probe.
///
/// Android TV exposes a real probe (codec passthrough + route) over the
/// platform method channel; tvOS exposes a channel-count / route probe via
/// `AVAudioSession`. Both return a map shaped for
/// [AudioCapabilityProfile.fromMap]. Other platforms have no probe.
///
/// Used by app startup ([query]/[queryWithRetry]) and by the audio settings
/// screen's "Re-detect" action.
class AudioCapabilityProbe {
  AudioCapabilityProbe._();

  static const _androidMethodChannel = MethodChannel(
    'org.moonfin.androidtv/platform',
  );
  static const _androidEventChannel = EventChannel(
    'org.moonfin.androidtv/audioCapabilitiesEvents',
  );
  static const _tvosMethodChannel = MethodChannel('moonfin/appletv_audio');
  static const _tvosEventChannel = EventChannel('moonfin/appletv_audio_events');

  /// Whether the running platform exposes a native probe.
  static bool get isSupported =>
      (PlatformDetection.isAndroid && PlatformDetection.isTV) ||
      PlatformDetection.isAppleTV;

  static MethodChannel? get _methodChannel {
    if (PlatformDetection.isAndroid && PlatformDetection.isTV) {
      return _androidMethodChannel;
    }
    if (PlatformDetection.isAppleTV) {
      return _tvosMethodChannel;
    }
    return null;
  }

  static EventChannel? get _eventChannel {
    if (PlatformDetection.isAndroid && PlatformDetection.isTV) {
      return _androidEventChannel;
    }
    if (PlatformDetection.isAppleTV) {
      return _tvosEventChannel;
    }
    return null;
  }

  /// Queries the native probe once. Returns null if unsupported or the probe
  /// returned nothing.
  static Future<AudioCapabilityProfile?> query() async {
    final channel = _methodChannel;
    if (channel == null) return null;
    try {
      final raw = await channel.invokeMethod<Map<dynamic, dynamic>>(
        'audioCapabilities',
      );
      if (raw == null) return null;
      return AudioCapabilityProfile.fromMap(
        raw.map((key, value) => MapEntry(key.toString(), value)),
      );
    } catch (_) {
      return null;
    }
  }

  /// A result that looks like the "nothing connected / not yet enumerated"
  /// state: no recognizable route and no passthrough. A real sink always
  /// reports a route, even a downgraded one like the TV speakers, so this
  /// combination only appears when enumeration hasn't happened yet. The
  /// channel count deliberately plays no part: the unenumerated state reports
  /// eight PCM channels, which is exactly what let it pass for a real answer.
  static bool looksEmpty(AudioCapabilityProfile p) =>
      p.activeRouteType == AudioRouteType.other &&
      !p.hasCompressedPassthroughRoute;

  /// Queries with a backoff so a startup race (audio outputs not yet
  /// enumerated when the app launches) doesn't strand detection on an empty
  /// result. The window has to be sized against an HDMI handshake, which
  /// takes seconds, not the milliseconds a plain in-app race would need.
  /// Returns the last non-null result, or null if every attempt failed.
  static Future<AudioCapabilityProfile?> queryWithRetry({
    int attempts = 5,
    Duration delay = const Duration(milliseconds: 500),
  }) async {
    AudioCapabilityProfile? last;
    for (var i = 0; i < attempts; i++) {
      final result = await query();
      if (result != null) {
        last = result;
        if (!looksEmpty(result)) return result;
      }
      if (i < attempts - 1) {
        await Future<void>.delayed(delay);
        delay *= 2;
      }
    }
    return last;
  }

  /// Publishes a freshly-detected profile to [PlatformDetection]; the next
  /// `getDeviceProfile()` (computed per playback) picks it up. Good results
  /// are persisted so the next launch starts from them instead of the
  /// fallback.
  ///
  /// A probe that came back with nothing, or with the unenumerated state, is
  /// a failure to read the hardware, not a device that lost its capabilities,
  /// so it leaves whatever was detected before in place. Clearing it would
  /// drop the app onto the fallback, which reports no route and no
  /// passthrough, and every playback would transcode until a restart.
  static void apply(AudioCapabilityProfile? profile) {
    if (profile == null ||
        (looksEmpty(profile) && PlatformDetection.hasAudioCapabilities)) {
      _log(
        'audio probe: ${profile == null ? 'no result' : 'unenumerated result'},'
        ' keeping '
        '${PlatformDetection.hasAudioCapabilities ? 'the last detection' : 'the fallback profile'}',
        level: LogLevel.warning,
      );
      return;
    }
    final values = profile.toMap();
    PlatformDetection.setAudioCapabilities(values);
    if (!looksEmpty(profile)) {
      unawaited(
        DeviceCapabilityCache.writeMap(DeviceCapabilityCache.audioKey, values),
      );
    }
    _log(
      'audio probe: route=${profile.activeRouteType.name} '
      'maxPcmChannels=${profile.maxPcmChannels} '
      'passthrough ac3=${profile.canPassthroughAc3} '
      'eac3=${profile.canPassthroughEac3} dts=${profile.canPassthroughDts} '
      'truehd=${profile.canPassthroughTrueHd}',
      level: LogLevel.info,
    );
  }

  static void _log(String message, {required LogLevel level}) {
    if (GetIt.instance.isRegistered<LogService>()) {
      GetIt.instance<LogService>().media(message, level: level);
    }
  }

  /// Subscribes to native route-change events (HDMI/ARC/eARC connect/disconnect)
  /// and re-applies capabilities on each change. The subscription lives for the
  /// app's lifetime.
  static StreamSubscription<dynamic>? listenForRouteChanges() {
    final channel = _eventChannel;
    if (channel == null) return null;
    return channel.receiveBroadcastStream().listen((event) {
      if (event is Map) {
        // A route flap can transiently enumerate to "nothing connected".
        // The guard inside apply keeps that from clobbering a good
        // snapshot, while a genuine downgrade like unplugging an AVR
        // reports a real route such as speaker and still lands.
        apply(
          AudioCapabilityProfile.fromMap(
            event.map((key, value) => MapEntry(key.toString(), value)),
          ),
        );
      }
    }, onError: (_) {});
  }
}
