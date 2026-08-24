import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

void Function() subscribe({
  required String allowedOrigin,
  required void Function(Object? message) onMessage,
}) {
  final StreamSubscription<web.MessageEvent> sub = web.window.onMessage
      .listen((event) {
        // moonfin-bridge.js posts with target origin '*' (there is no other option
        // from inside a cross-origin iframe), so this listener -- unlike the
        // handler it complements on other platforms -- is reachable by any window
        // and MUST filter by origin itself, or any page could drive menu
        // navigation and gamepad input through _onPlayerMessage.
        if (event.origin != allowedOrigin) return;
        onMessage(event.data.dartify());
      });
  return () => unawaited(sub.cancel());
}
