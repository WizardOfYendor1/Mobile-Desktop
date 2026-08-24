import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/playback/audio_capability_probe.dart';
import 'package:moonfin/playback/audio_capability_profile.dart';
import 'package:moonfin/playback/device_capability_cache.dart';
import 'package:moonfin/util/platform_detection.dart';
import 'package:shared_preferences/shared_preferences.dart';

AudioCapabilityProfile _profile({
  AudioRouteType route = AudioRouteType.hdmi,
  bool passthroughAc3 = true,
  int maxPcmChannels = 8,
}) {
  return AudioCapabilityProfile.fromMap({
    'activeRouteType': route.name,
    'canPassthroughAc3': passthroughAc3,
    'canPassthroughEac3': passthroughAc3,
    'maxPcmChannels': maxPcmChannels,
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PlatformDetection.setAudioCapabilities(null);
  });

  tearDown(() {
    PlatformDetection.setAudioCapabilities(null);
  });

  group('looksEmpty', () {
    test('flags the unenumerated state regardless of channel count', () {
      // The not-yet-enumerated state reports eight channels, which is what
      // used to let it pass for a real answer.
      final unenumerated = _profile(
        route: AudioRouteType.other,
        passthroughAc3: false,
        maxPcmChannels: 8,
      );
      expect(AudioCapabilityProbe.looksEmpty(unenumerated), isTrue);
    });

    test('a real route is never empty, even downgraded to stereo', () {
      final tvSpeakers = _profile(
        route: AudioRouteType.speaker,
        passthroughAc3: false,
        maxPcmChannels: 2,
      );
      expect(AudioCapabilityProbe.looksEmpty(tvSpeakers), isFalse);
    });

    test('passthrough on an unknown route counts as a real answer', () {
      final oddButCapable = _profile(
        route: AudioRouteType.other,
        passthroughAc3: true,
      );
      expect(AudioCapabilityProbe.looksEmpty(oddButCapable), isFalse);
    });
  });

  group('apply', () {
    test('a good result lands and persists for the next launch', () async {
      AudioCapabilityProbe.apply(_profile());

      expect(PlatformDetection.hasAudioCapabilities, isTrue);
      expect(PlatformDetection.supportsAc3Audio, isTrue);

      // The persistence write is fire and forget, so give it a beat.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final cached = await DeviceCapabilityCache.readMap(
        DeviceCapabilityCache.audioKey,
      );
      expect(cached, isNotNull);
      expect(cached!['canPassthroughAc3'], isTrue);
    });

    test('an unenumerated result never clobbers a good snapshot', () {
      AudioCapabilityProbe.apply(_profile());

      AudioCapabilityProbe.apply(
        _profile(route: AudioRouteType.other, passthroughAc3: false),
      );

      expect(PlatformDetection.supportsAc3Audio, isTrue);
      expect(
        PlatformDetection.audioCapabilitiesSnapshot['activeRouteType'],
        AudioRouteType.hdmi.name,
      );
    });

    test('a genuine downgrade with a real route still lands', () {
      AudioCapabilityProbe.apply(_profile());

      AudioCapabilityProbe.apply(
        _profile(
          route: AudioRouteType.speaker,
          passthroughAc3: false,
          maxPcmChannels: 2,
        ),
      );

      expect(PlatformDetection.supportsAc3Audio, isFalse);
      expect(
        PlatformDetection.audioCapabilitiesSnapshot['activeRouteType'],
        AudioRouteType.speaker.name,
      );
    });

    test('null keeps whatever was detected before', () {
      AudioCapabilityProbe.apply(_profile());
      AudioCapabilityProbe.apply(null);
      expect(PlatformDetection.supportsAc3Audio, isTrue);
    });

    test('the unenumerated state still applies when nothing better exists', () {
      // With no prior detection there is nothing to protect, and applying it
      // at least records what the hardware said instead of the fallback.
      AudioCapabilityProbe.apply(
        _profile(route: AudioRouteType.other, passthroughAc3: false),
      );
      expect(PlatformDetection.hasAudioCapabilities, isTrue);
    });
  });

  group('DeviceCapabilityCache', () {
    test('maps round-trip', () async {
      await DeviceCapabilityCache.writeMap('test_key', {
        'a': 1,
        'nested': {'b': true},
      });
      final read = await DeviceCapabilityCache.readMap('test_key');
      expect(read, {
        'a': 1,
        'nested': {'b': true},
      });
    });

    test('a build-keyed entry dies with its build', () async {
      await DeviceCapabilityCache.writeMap('test_key', {
        'hevc': true,
      }, build: 'firmware-1');

      expect(
        await DeviceCapabilityCache.readMap('test_key', build: 'firmware-1'),
        isNotNull,
      );
      expect(
        await DeviceCapabilityCache.readMap('test_key', build: 'firmware-2'),
        isNull,
        reason: 'a firmware update can change what the hardware decodes',
      );
    });

    test('string lists round-trip and remove clears both entries', () async {
      await DeviceCapabilityCache.writeStringList('hdr', ['HDR10', 'HLG']);
      expect(await DeviceCapabilityCache.readStringList('hdr'), [
        'HDR10',
        'HLG',
      ]);

      await DeviceCapabilityCache.remove('hdr');
      expect(await DeviceCapabilityCache.readStringList('hdr'), isNull);
    });
  });
}
