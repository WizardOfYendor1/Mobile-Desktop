import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:path_provider/path_provider.dart';
import 'package:server_core/server_core.dart';

import '../data/services/retro_artwork/retro_artwork_disk_cache_io.dart';
import 'game_artwork_cache.dart';
import 'platform_detection.dart';

final Set<String> _sweepingCacheKeys = <String>{};
final Map<String, DateTime> _lastSweepByCacheKey = <String, DateTime>{};

// Point cached_network_image at a cache manager with a shorter stale period and
// a higher object count than the library default. Files stay in the library's
// default directory so an existing cache is never orphaned on update.
Future<void> configureImageDiskCache() async {
  try {
    final key = DefaultCacheManager.key;
    const stalePeriod = Duration(days: 14);
    const maxObjects = 600;
    // Images fetch through the cache manager's own client rather than Dio, so
    // this is the one place they can pick up the server User-Agent. Without it
    // a proxy that filters on the agent blocks every image while API calls
    // still succeed.
    final fileService = HttpFileService(
      httpClient: _ServerUserAgentHttpClient(IOClient(buildImageHttpClient())),
    );
    Config config;
    if (PlatformDetection.isAppleTV) {
      final cacheDir = await getApplicationCacheDirectory();
      config = Config(
        key,
        stalePeriod: stalePeriod,
        maxNrOfCacheObjects: maxObjects,
        fileService: fileService,
        repo: JsonCacheInfoRepository.withFile(
          File('${cacheDir.path}/$key.json'),
        ),
      );
    } else {
      config = Config(
        key,
        stalePeriod: stalePeriod,
        maxNrOfCacheObjects: maxObjects,
        fileService: fileService,
      );
    }
    CachedNetworkImageProvider.defaultCacheManager = CacheManager(config);
  } catch (_) {}
}

// Game artwork has its own fixed budget, so browsing games never displaces
// movie, TV, or music artwork from the user's media cache allocation.
Future<void> enforceImageCacheBudget(
  int budgetBytes, {
  bool throttle = false,
}) async {
  await _enforceCacheDirectoryBudget(
    DefaultCacheManager.key,
    budgetBytes,
    throttle: throttle,
  );
}

Future<void> enforceGameArtworkCacheBudget({bool throttle = false}) =>
    _enforceGameArtworkCacheBudget(throttle: throttle);

const _gameArtworkScopeAccessFileName = '.moonfin-scope-access';
const _gameArtworkBudgetSweepKey = '$gameArtworkCacheKey-budget';
final Map<String, int> _activeGameArtworkScopes = <String, int>{};

/// The user just left but scope is still protected while their in-flight transfers
/// land. Flutter cache manager can't cancel a download, so releasing a scope
/// only stops new work; the writes already issued finish on their own.
final Map<String, DateTime> _coolingGameArtworkScopes = <String, DateTime>{};
const _gameArtworkScopeCooldown = Duration(seconds: 30);

/// Marks a system as actively browsed. Active systems are never evicted by a
/// resume/startup cache sweep, even if the global game-art budget is exceeded.
Future<void> retainGameArtworkCacheScope(String scope) async {
  _activeGameArtworkScopes.update(
    scope,
    (count) => count + 1,
    ifAbsent: () => 1,
  );
  _coolingGameArtworkScopes.remove(scope);
  try {
    final temp = await getTemporaryDirectory();
    final dir = Directory('${temp.path}/${gameArtworkCacheKeyForScope(scope)}');
    await dir.create(recursive: true);
    await File(
      '${dir.path}/$_gameArtworkScopeAccessFileName',
    ).writeAsString('', flush: true);
  } catch (_) {}
}

void releaseGameArtworkCacheScope(String scope) {
  final count = _activeGameArtworkScopes[scope];
  if (count == null || count <= 1) {
    _activeGameArtworkScopes.remove(scope);
    _coolingGameArtworkScopes[scope] = DateTime.now();
  } else {
    _activeGameArtworkScopes[scope] = count - 1;
  }
}

Future<void> _enforceGameArtworkCacheBudget({required bool throttle}) async {
  if (_sweepingCacheKeys.contains(_gameArtworkBudgetSweepKey)) return;
  final now = DateTime.now();
  final lastSweep = _lastSweepByCacheKey[_gameArtworkBudgetSweepKey];
  if (throttle &&
      lastSweep != null &&
      now.difference(lastSweep) < const Duration(minutes: 3)) {
    return;
  }

  _sweepingCacheKeys.add(_gameArtworkBudgetSweepKey);
  _lastSweepByCacheKey[_gameArtworkBudgetSweepKey] = now;
  try {
    _coolingGameArtworkScopes.removeWhere(
      (_, releasedAt) => now.difference(releasedAt) >= _gameArtworkScopeCooldown,
    );
    final temp = await getTemporaryDirectory();
    await evictInactiveGameArtworkCaches(
      temp,
      budgetBytes: gameArtworkCacheBudgetBytes,
      protectedCacheKeys: <String>{
        ..._activeGameArtworkScopes.keys,
        ..._coolingGameArtworkScopes.keys,
      }.map(gameArtworkCacheKeyForScope).toSet(),
    );
  } catch (_) {
  } finally {
    _sweepingCacheKeys.remove(_gameArtworkBudgetSweepKey);
  }
}

/// Evicts whole inactive system caches, least-recently-used first, until the
/// game-art budget is met: dropping a scope entire avoids puncturing an
/// in-progress browse with scattered missing artwork. Public for filesystem
/// tests; callers keep a just-left scope in protectedCacheKeys for a cooldown.
Future<List<String>> evictInactiveGameArtworkCaches(
  Directory temporaryDirectory, {
  required int budgetBytes,
  required Set<String> protectedCacheKeys,
}) async {
  if (budgetBytes <= 0 || !await temporaryDirectory.exists()) return const [];
  final caches = <_GameArtworkCacheDirectory>[];
  await for (final entity in temporaryDirectory.list(followLinks: false)) {
    if (entity is! Directory ||
        !isGameArtworkCacheDirectoryName(_directoryName(entity))) {
      continue;
    }
    final stats = await _inspectGameArtworkCacheDirectory(entity);
    if (stats != null) caches.add(stats);
  }

  var total = caches.fold<int>(0, (sum, cache) => sum + cache.bytes);
  if (total <= budgetBytes) return const [];

  final target = (budgetBytes * 0.9).round();
  final inactive =
      caches.where((cache) => !protectedCacheKeys.contains(cache.key)).toList()
        ..sort((a, b) => a.lastUsed.compareTo(b.lastUsed));

  final evicted = <String>[];
  for (final cache in inactive) {
    if (total <= target) break;
    try {
      final clearedLiveManager = await clearLiveGameArtworkCache(cache.key);
      if (clearedLiveManager) {
        // Keep the manager's metadata database intact; only remove our access
        // marker so the empty directory no longer represents retained artwork.
        final accessFile = File(
          '${cache.directory.path}/$_gameArtworkScopeAccessFileName',
        );
        if (await accessFile.exists()) await accessFile.delete();
      } else {
        await cache.directory.delete(recursive: true);
      }
      total -= cache.bytes;
      evicted.add(cache.key);
    } catch (_) {}
  }
  return evicted;
}

class _GameArtworkCacheDirectory {
  const _GameArtworkCacheDirectory({
    required this.directory,
    required this.key,
    required this.bytes,
    required this.lastUsed,
  });

  final Directory directory;
  final String key;
  final int bytes;
  final DateTime lastUsed;
}

Future<_GameArtworkCacheDirectory?> _inspectGameArtworkCacheDirectory(
  Directory directory,
) async {
  try {
    var bytes = 0;
    DateTime? lastUsed;
    final accessFile = File(
      '${directory.path}/$_gameArtworkScopeAccessFileName',
    );
    if (await accessFile.exists()) {
      lastUsed = (await accessFile.stat()).modified;
    }
    await for (final entity in directory.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) continue;
      final stat = await entity.stat();
      if (!entity.path.endsWith(_gameArtworkScopeAccessFileName)) {
        bytes += stat.size;
      }
    }
    final directoryStat = await directory.stat();
    return _GameArtworkCacheDirectory(
      directory: directory,
      key: _directoryName(directory),
      bytes: bytes,
      lastUsed: lastUsed ?? directoryStat.modified,
    );
  } catch (_) {
    return null;
  }
}

String _directoryName(Directory directory) {
  final path = directory.path;
  final separatorIndex = path.lastIndexOf(Platform.pathSeparator);
  return separatorIndex == -1 ? path : path.substring(separatorIndex + 1);
}

// A missing file is a cache miss the manager re-downloads, so deleting it
// directly is safe. Best effort only, so a failure never blocks the UI.
Future<void> _enforceCacheDirectoryBudget(
  String cacheKey,
  int budgetBytes, {
  required bool throttle,
}) async {
  if (budgetBytes <= 0 || _sweepingCacheKeys.contains(cacheKey)) return;
  final now = DateTime.now();
  final lastSweep = _lastSweepByCacheKey[cacheKey];
  if (throttle &&
      lastSweep != null &&
      now.difference(lastSweep) < const Duration(minutes: 3)) {
    return;
  }
  _sweepingCacheKeys.add(cacheKey);
  _lastSweepByCacheKey[cacheKey] = now;
  try {
    final temp = await getTemporaryDirectory();
    final entries = <({File file, int size, DateTime modified})>[];
    var total = 0;
    final dir = Directory('${temp.path}/$cacheKey');
    if (!await dir.exists()) return;
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File) continue;
      try {
        final stat = await entity.stat();
        total += stat.size;
        entries.add((file: entity, size: stat.size, modified: stat.modified));
      } catch (_) {}
    }
    if (total <= budgetBytes) return;

    entries.sort((a, b) => a.modified.compareTo(b.modified));
    final target = (budgetBytes * 0.9).round();
    for (final entry in entries) {
      if (total <= target) break;
      if (now.difference(entry.modified) < const Duration(seconds: 30)) {
        continue;
      }
      try {
        await entry.file.delete();
        total -= entry.size;
      } catch (_) {}
    }
  } catch (_) {
  } finally {
    _sweepingCacheKeys.remove(cacheKey);
  }
}

Future<void> clearImageDiskCache() async {
  try {
    await CachedNetworkImageProvider.defaultCacheManager.emptyCache();
    final temp = await getTemporaryDirectory();
    await for (final entity in temp.list(followLinks: false)) {
      if (entity is Directory &&
          isGameArtworkCacheDirectoryName(_directoryName(entity))) {
        if (!await clearLiveGameArtworkCache(_directoryName(entity))) {
          await entity.delete(recursive: true);
        }
      }
    }
    await gameSystemArtworkCacheManager.emptyCache();
    final retroArtworkCacheDir = await defaultRetroArtworkDiskCacheDirectory();
    if (await retroArtworkCacheDir.exists()) {
      await retroArtworkCacheDir.delete(recursive: true);
    }
  } catch (_) {}
}

/// The client every artwork request goes through.
///
/// A grid asks for dozens of images at once, and with no bound this opened a
/// connection per image and waited for the system to give up on each one that
/// hung. That is what fails on a link that drops connection attempts while the
/// API calls beside it, which are bounded, succeed.
@visibleForTesting
HttpClient buildImageHttpClient() => HttpClient()
  ..maxConnectionsPerHost = imageRequestSlots
  ..connectionTimeout = const Duration(seconds: 8)
  ..idleTimeout = const Duration(seconds: 120);

/// Artwork shares the link with the API calls, so it takes the smaller share.
const imageRequestSlots = 4;

class _ServerUserAgentHttpClient extends http.BaseClient {
  _ServerUserAgentHttpClient(this._inner);

  final http.Client _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.headers['User-Agent'] = serverUserAgent;
    return _inner.send(request);
  }
}
