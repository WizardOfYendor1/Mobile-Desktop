import 'emulator_host_messages_io.dart'
    if (dart.library.js_interop) 'emulator_host_messages_web.dart' as impl;

/// Delivers messages the EmulatorJS player shell posts to `window.parent`.
///
/// On Android/iOS/desktop these arrive through the `flutter_inappwebview`
/// JavaScript handler registered in `game_emulator_screen.dart`, so this is a
/// no-op there. On Flutter web, `flutter_inappwebview_web` never implements
/// that handler inside an iframe, so nothing reaches Dart unless something
/// listens for the `postMessage` the player shell falls back to -- this does.
abstract class EmulatorHostMessages {
  /// Subscribes to messages posted to `window.parent`. Returns a dispose
  /// callback that cancels the subscription (or does nothing off the web).
  static void Function() subscribe({
    required String allowedOrigin,
    required void Function(Object? message) onMessage,
  }) => impl.subscribe(allowedOrigin: allowedOrigin, onMessage: onMessage);
}
