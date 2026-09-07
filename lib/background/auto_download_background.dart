import 'package:get_it/get_it.dart';

import '../data/services/auto_download_service.dart';
import '../playback/headless_session_bootstrap.dart';

/// The work behind a background refresh, on any platform that can wake the
/// app: restore the session when the wake-up launched the app cold (no
/// window scene, so the startup screen never signs in), then run one
/// budgeted check. Returns whether the check finished without errors.
Future<bool> runAutoDownloadBackgroundRefresh(Duration budget) async {
  final started = DateTime.now();
  final getIt = GetIt.instance;
  if (!getIt.isRegistered<AutoDownloadService>()) {
    // Restoring the session registers the service as a side effect of
    // setActiveServerClient; nothing registered afterwards means nobody
    // is signed in.
    if (!getIt.isRegistered<HeadlessSessionBootstrap>()) return false;
    await getIt<HeadlessSessionBootstrap>().ensureSession();
    if (!getIt.isRegistered<AutoDownloadService>()) return false;
  }
  final remaining = budget - DateTime.now().difference(started);
  final summary = await getIt<AutoDownloadService>().runCheck(
    trigger: AutoDownloadTrigger.backgroundRefresh,
    deadline: remaining.isNegative ? Duration.zero : remaining,
  );
  return summary.error == null;
}
