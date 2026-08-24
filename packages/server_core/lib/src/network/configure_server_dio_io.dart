import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import 'server_user_agent.dart';

void configureServerDio(Dio dio) {
  dio.transformer = FusedTransformer(contentLengthIsolateThreshold: 50 * 1024);

  dio.httpClientAdapter = IOHttpClientAdapter(
    createHttpClient: () {
      final client = HttpClient();

      client.userAgent = serverUserAgent;

      client.badCertificateCallback = (_, _, _) => true;

      // A fixed 30 seconds here outlived callers that give up sooner, so a
      // stalled server left connects nobody was waiting for holding the 15
      // per host slots, and every retry refilled them. Following the caller
      // frees the slot when it gives up, and the margin leaves the reporting
      // to Dio.
      client.connectionTimeout =
          (dio.options.connectTimeout ?? const Duration(seconds: 30)) +
          const Duration(seconds: 2);
      client.idleTimeout = const Duration(seconds: 120);

      client.maxConnectionsPerHost = 15;

      return client;
    },
  );
}
