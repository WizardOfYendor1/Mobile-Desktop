import '../models/aggregated_item.dart';
import '../models/download_quality.dart';
import '../models/download_source.dart';

/// A batch handed to the download queue: what was accepted, and a future
/// for when every transfer in it has finished or failed.
class DownloadBatch {
  const DownloadBatch({required this.queued, required this.done});

  final List<AggregatedItem> queued;
  final Future<void> done;
}

/// The slice of the download service the auto-download check needs, so the
/// check can be tested against a fake instead of the real transfer engine.
abstract class AutoDownloadDownloader {
  Set<String> get inFlightItemIds;

  Future<List<AggregatedItem>> fetchEpisodes(
    String seriesId, {
    String? seasonId,
  });

  Future<DownloadBatch> queueDownloads(
    List<AggregatedItem> items, {
    DownloadQuality quality,
    DownloadSource source,
  });

  Future<bool> deleteDownloadedFiles(AggregatedItem item);

  Future<bool> wifiPolicyAllowsDownload();

  /// Bytes still allowed under the storage limit, counting transfers that
  /// were admitted but have not written their file yet; null when unlimited.
  Future<int?> storageHeadroomBytes();
}
