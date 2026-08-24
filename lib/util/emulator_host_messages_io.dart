/// Non-web platforms deliver player messages through the
/// `flutter_inappwebview` JavaScript handler, so there is nothing to
/// subscribe to here.
void Function() subscribe({
  required String allowedOrigin,
  required void Function(Object? message) onMessage,
}) => () {};
