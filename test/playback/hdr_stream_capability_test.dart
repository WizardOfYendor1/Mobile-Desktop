import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/playback/hdr_stream_capability.dart';
import 'package:moonfin/util/platform_detection.dart';

/// The one question both Android TV Dolby Vision gates share: does playing a
/// stream with its Dolby Vision metadata ignored lose anything.
void main() {
  Map<String, dynamic> video(String rangeType, {String codec = 'hevc'}) => {
    'Type': 'Video',
    'Codec': codec,
    'VideoRangeType': rangeType,
  };

  setUp(() {
    PlatformDetection.setDisplayHdrTypes(const ['HDR10']);
    PlatformDetection.setMediaCodecCapabilities(const {
      'supportsHevcHdr10': true,
      'supportsAv1Hdr10': false,
    });
  });

  tearDown(() {
    PlatformDetection.setDisplayHdrTypes(null);
    PlatformDetection.setMediaCodecCapabilities(null);
  });

  test('a profile 8.1 base layer needs no fallback on an HDR10 device', () {
    expect(
      HdrStreamCapability.needsDolbyVisionFallback(video('DOVIWithHDR10')),
      isFalse,
    );
    expect(
      HdrStreamCapability.needsDolbyVisionFallback(video('DOVIWithHDR10Plus')),
      isFalse,
    );
  });

  test('every other Dolby Vision layout still does', () {
    for (final rangeType in ['DOVI', 'DOVIWithEL', 'DOVIWithELHDR10Plus']) {
      expect(
        HdrStreamCapability.needsDolbyVisionFallback(video(rangeType)),
        isTrue,
        reason: rangeType,
      );
    }
  });

  test('a decoder without HDR10 still does', () {
    PlatformDetection.setMediaCodecCapabilities(const {
      'supportsHevcHdr10': false,
    });
    expect(
      HdrStreamCapability.needsDolbyVisionFallback(video('DOVIWithHDR10')),
      isTrue,
    );
  });

  test('a display without HDR10 still does', () {
    PlatformDetection.setDisplayHdrTypes(const ['HLG']);
    expect(
      HdrStreamCapability.needsDolbyVisionFallback(video('DOVIWithHDR10')),
      isTrue,
    );
  });

  test('the codec picks which decoder capability counts', () {
    expect(
      HdrStreamCapability.needsDolbyVisionFallback(
        video('DOVIWithHDR10', codec: 'av1'),
      ),
      isTrue,
    );
  });

  test('a non Dolby Vision stream is never a fallback case', () {
    expect(
      HdrStreamCapability.needsDolbyVisionFallback(video('HDR10')),
      isFalse,
    );
  });
}
