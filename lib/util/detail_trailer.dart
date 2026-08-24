import '../data/models/aggregated_item.dart';

/// A standalone trailer carries the item type, one attached to a film carries
/// the extra type, and which of the two arrives depends on how the server
/// found the file.
bool isTrailerFeature(AggregatedItem feature) =>
    feature.rawData['ExtraType'] == 'Trailer' || feature.type == 'Trailer';

/// Whether a trailer exists for [item], from any of the places one can live.
///
/// The count is checked before the trailer links, since reading it avoids
/// building a list. Special features come last and only answer for servers
/// that file a trailer as an ordinary extra, because a server that keeps the
/// two apart leaves trailers out of that list.
bool hasTrailer(AggregatedItem item, List<AggregatedItem> features) {
  if (item.localTrailerCount > 0) return true;
  if (item.remoteTrailers.isNotEmpty) return true;
  return features.any(isTrailerFeature);
}
