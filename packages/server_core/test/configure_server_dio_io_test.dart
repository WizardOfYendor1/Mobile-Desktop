import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:server_core/server_core.dart';
import 'package:test/test.dart';

void main() {
  group('configureServerDio', () {
    late HttpServer server;
    StreamSubscription<HttpRequest>? requests;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    });

    tearDown(() async {
      await requests?.cancel();
      await server.close(force: true);
      // The version is process-wide, so clear it to keep tests independent.
      setServerUserAgentVersion('');
    });

    // Answers one request and reports the user agent it arrived with.
    Future<String?> userAgentOfNextRequest() async {
      final received = Completer<String?>();
      requests = server.listen((request) async {
        if (!received.isCompleted) {
          received.complete(request.headers.value(HttpHeaders.userAgentHeader));
        }
        request.response.statusCode = HttpStatus.noContent;
        await request.response.close();
      });

      final dio = Dio();
      configureServerDio(dio);

      try {
        await dio.get<void>('http://127.0.0.1:${server.port}/');
        return await received.future;
      } finally {
        dio.close(force: true);
      }
    }

    test('uses a browser-compatible Moonfin user agent', () async {
      expect(
        await userAgentOfNextRequest(),
        'Mozilla/5.0 (compatible; Moonfin/Flutter)',
      );
    });

    test('includes the app version once startup records it', () async {
      setServerUserAgentVersion('2.3.2');

      expect(
        await userAgentOfNextRequest(),
        'Mozilla/5.0 (compatible; Moonfin/2.3.2)',
      );
    });

    test('truncates at anything that would break the header', () async {
      setServerUserAgentVersion('2.3.2 (beta)\r\nX-Injected: 1');

      expect(
        await userAgentOfNextRequest(),
        'Mozilla/5.0 (compatible; Moonfin/2.3.2)',
      );
    });

    test('falls back to an unversioned agent for a blank version', () async {
      setServerUserAgentVersion('   ');

      expect(
        await userAgentOfNextRequest(),
        'Mozilla/5.0 (compatible; Moonfin/Flutter)',
      );
    });
  });

  // A screen that asks for more at once than the slots hold has to queue, and
  // none of that wait may count against the connect timeout.
  group('slot limited requests', () {
    late HttpServer server;
    const slowResponse = Duration(milliseconds: 300);
    const moreRequestsThanSlots = 60;
    var inFlight = 0;
    var mostInFlight = 0;
    var failEveryRequest = false;

    setUp(() async {
      inFlight = 0;
      mostInFlight = 0;
      failEveryRequest = false;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        inFlight++;
        if (inFlight > mostInFlight) mostInFlight = inFlight;
        await Future<void>.delayed(slowResponse);
        inFlight--;
        request.response.statusCode = failEveryRequest
            ? HttpStatus.internalServerError
            : HttpStatus.ok;
        await request.response.close();
      });
    });

    tearDown(() => server.close(force: true));

    Dio dioWith(Duration connectTimeout) {
      final dio = Dio(
        BaseOptions(
          baseUrl: 'http://${server.address.address}:${server.port}',
          connectTimeout: connectTimeout,
        ),
      );
      configureServerDio(dio);
      return dio;
    }

    Future<List<Object?>> fireConcurrently(Dio dio) => Future.wait(
      List.generate(
        moreRequestsThanSlots,
        (i) => dio
            .get<void>('/$i')
            .then<Object?>((r) => r)
            .catchError((Object e) => e),
      ),
    );

    test('queueing is never billed to the connect timeout', () async {
      final results = await fireConcurrently(
        dioWith(const Duration(milliseconds: 400)),
      );
      expect(results.whereType<DioException>(), isEmpty);
    });

    test('holds the rest back once the slots are taken', () async {
      await fireConcurrently(dioWith(const Duration(seconds: 30)));
      // A browser allows itself six per host without multiplexing, and going
      // past that is what a proxy reads as a flood.
      expect(mostInFlight, lessThanOrEqualTo(6));
      expect(mostInFlight, greaterThan(1));
    });

    test('hands a slot back when the request fails', () async {
      final dio = dioWith(const Duration(seconds: 30));
      failEveryRequest = true;
      final failed = await fireConcurrently(dio);
      expect(
        failed.whereType<DioException>(),
        hasLength(moreRequestsThanSlots),
      );

      failEveryRequest = false;
      final response = await dio
          .get<void>('/after')
          .timeout(const Duration(seconds: 5));
      expect(response.statusCode, HttpStatus.ok);
    });
  });
}
