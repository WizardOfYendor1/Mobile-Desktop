import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import 'server_user_agent.dart';

/// How many requests may be reaching the server at once.
///
/// dart:io speaks HTTP/1.1 with no ALPN, so every request in flight is its own
/// TCP and TLS handshake, where a browser multiplexes a whole screen over one
/// HTTP/2 connection. Six is what a browser allows itself per host without
/// multiplexing, and it keeps a screen from opening a burst that a reverse
/// proxy reads as a flood.
const _requestSlots = 6;

void configureServerDio(Dio dio) {
  dio.transformer = FusedTransformer(contentLengthIsolateThreshold: 50 * 1024);

  dio.httpClientAdapter = _SlotLimitedAdapter(
    IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient();

        client.userAgent = serverUserAgent;

        client.badCertificateCallback = (_, _, _) => true;

        client.idleTimeout = const Duration(seconds: 120);

        client.maxConnectionsPerHost = _requestSlots;

        return client;
      },
    ),
    _requestSlots,
  );
}

/// Holds a request back until one of a fixed number of slots is free.
///
/// Dio starts its connect timeout only once the request is handed on, so the
/// wait sits outside it and a busy screen queues without any of it reading as
/// the host failing to answer. A slot covers the connect and the wait for the
/// headers. The body drains after that, bounded by the client's per host limit.
class _SlotLimitedAdapter implements HttpClientAdapter {
  _SlotLimitedAdapter(this._inner, this._free);

  final HttpClientAdapter _inner;
  int _free;
  final _waiting = Queue<Completer<void>>();

  Future<void> _acquire() {
    if (_free > 0) {
      _free--;
      return Future.value();
    }
    final waiter = Completer<void>();
    _waiting.add(waiter);
    return waiter.future;
  }

  void _release() {
    if (_waiting.isNotEmpty) {
      _waiting.removeFirst().complete();
    } else {
      _free++;
    }
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    await _acquire();
    try {
      return await _inner.fetch(options, requestStream, cancelFuture);
    } finally {
      _release();
    }
  }

  @override
  void close({bool force = false}) => _inner.close(force: force);
}
