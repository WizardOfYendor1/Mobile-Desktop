import 'dart:async';

import '../data/services/auto_download_service.dart';
import '../preference/user_preferences.dart';
import 'ios_background_refresh.dart';

/// Keeps the iOS background refresh task in step with the auto-download
/// state: scheduled only while the setting is on and at least one series is
/// followed, so the OS never wakes the app for nothing.
class AutoDownloadBackgroundBinding {
  AutoDownloadBackgroundBinding({
    required this.service,
    required this.prefs,
    IosBackgroundRefresh? refresh,
  }) : _refresh = refresh ?? IosBackgroundRefresh.instance;

  final AutoDownloadService service;
  final UserPreferences prefs;
  final IosBackgroundRefresh _refresh;
  StreamSubscription<List<Object?>>? _subscriptionsSub;
  bool _hasSubscriptions = false;
  bool? _lastConfiguredEnabled;

  void attach() {
    prefs.addListener(_sync);
    _subscriptionsSub = service.watchSubscriptions().listen((subscriptions) {
      _hasSubscriptions = subscriptions.isNotEmpty;
      _sync();
    });
  }

  void detach() {
    prefs.removeListener(_sync);
    _subscriptionsSub?.cancel();
    _subscriptionsSub = null;
  }

  void _sync() {
    final enabled =
        _hasSubscriptions &&
        prefs.get(UserPreferences.autoDownloadEnabled) &&
        prefs.get(UserPreferences.autoDownloadBackgroundRefresh);
    if (enabled == _lastConfiguredEnabled) return;
    _lastConfiguredEnabled = enabled;
    unawaited(_refresh.configure(enabled: enabled));
  }
}
