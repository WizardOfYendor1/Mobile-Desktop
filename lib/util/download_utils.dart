import 'package:background_downloader/background_downloader.dart' as bgd;
import 'package:path/path.dart' as p;

import '../data/models/aggregated_item.dart';
import '../data/models/download_quality.dart';
import 'platform_detection.dart';

/// The base directory, directory and filename a download task needs to write
/// [savePath].
///
/// On Windows, Task.split strips the drive and pairs what is left with the root
/// base directory, which resolves to an empty string there, so the task writes
/// relative to the working directory instead of the drive the user picked. The
/// package wants the drive kept in the directory when the base is root.
Future<(bgd.BaseDirectory, String, String)> splitDownloadPath(
  String savePath,
) async {
  if (PlatformDetection.isWindows) {
    return (
      bgd.BaseDirectory.root,
      p.windows.normalize(p.windows.dirname(savePath)),
      p.windows.basename(savePath),
    );
  }
  return bgd.Task.split(filePath: savePath);
}

/// A download ETA as a short "1h 04m" or "4m 30s" style figure, coarse on
/// purpose since a transcode's pace drifts.
String formatEta(int seconds) {
  if (seconds >= 3600) {
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    return '${hours}h ${minutes.toString().padLeft(2, '0')}m';
  }
  if (seconds >= 60) {
    return '${seconds ~/ 60}m ${(seconds % 60).toString().padLeft(2, '0')}s';
  }
  return '${seconds}s';
}

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}

int sourceSizeBytes(AggregatedItem item) {
  if (item.mediaSources.isEmpty) {
    return 0;
  }

  return item.mediaSources.first['Size'] as int? ?? 0;
}

Duration? runtimeForEstimate(AggregatedItem item) {
  final runtime = item.runtime;
  if (runtime != null && runtime.inMilliseconds > 0) {
    return runtime;
  }

  if (item.mediaSources.isEmpty) {
    return null;
  }

  final runTimeTicks = item.mediaSources.first['RunTimeTicks'] as int?;
  if (runTimeTicks == null || runTimeTicks <= 0) {
    return null;
  }

  return Duration(microseconds: runTimeTicks ~/ 10);
}

int? estimateTranscodedSizeBytes(AggregatedItem item, DownloadQuality quality) {
  if (!quality.isTranscoded) {
    return null;
  }

  final runtime = runtimeForEstimate(item);
  final totalBitRate = quality.totalBitRate;
  if (runtime == null || totalBitRate == null || totalBitRate <= 0) {
    return null;
  }

  return ((runtime.inMilliseconds * totalBitRate / 8000) * 1.03).round();
}

int estimateDownloadSizeBytes(AggregatedItem item, DownloadQuality quality) {
  if (!quality.isTranscoded) {
    return sourceSizeBytes(item);
  }

  return estimateTranscodedSizeBytes(item, quality) ?? sourceSizeBytes(item);
}
