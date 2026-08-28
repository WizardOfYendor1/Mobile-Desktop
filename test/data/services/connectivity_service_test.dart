import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:mocktail/mocktail.dart';
import 'package:moonfin/data/services/connectivity_service.dart';
import 'package:server_core/server_core.dart';

class _MockConnectivity extends Mock implements Connectivity {}

class _MockMediaServerClient extends Mock implements MediaServerClient {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late HttpServer server;
  late _MockConnectivity connectivity;
  var failuresLeft = 0;
  var probes = 0;

  setUp(() async {
    // The test binding answers every request with a 400, and the probe has to
    // reach the server on the loopback for these to mean anything.
    HttpOverrides.global = null;
    await GetIt.instance.reset();
    failuresLeft = 0;
    probes = 0;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      probes++;
      request.response.statusCode = failuresLeft > 0
          ? HttpStatus.serviceUnavailable
          : HttpStatus.ok;
      if (failuresLeft > 0) failuresLeft--;
      await request.response.close();
    });

    final client = _MockMediaServerClient();
    when(
      () => client.baseUrl,
    ).thenReturn('http://${server.address.address}:${server.port}');
    GetIt.instance.registerSingleton<MediaServerClient>(client);

    connectivity = _MockConnectivity();
    when(
      () => connectivity.onConnectivityChanged,
    ).thenAnswer((_) => const Stream.empty());
  });

  tearDown(() async {
    await server.close(force: true);
    await GetIt.instance.reset();
  });

  ConnectivityService serviceOnline({required bool online}) {
    when(() => connectivity.checkConnectivity()).thenAnswer(
      (_) async => [online ? ConnectivityResult.wifi : ConnectivityResult.none],
    );
    return ConnectivityService(
      connectivity: connectivity,
      retryBase: const Duration(milliseconds: 50),
    );
  }

  // Nothing else re-asks while the verdict stands, so a lost probe has to be
  // retried on its own.
  test('keeps probing until the server answers', () async {
    failuresLeft = 2;
    final service = serviceOnline(online: true);
    addTearDown(service.dispose);

    await service.recheckNow();
    expect(service.canReachServer, isFalse);

    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(service.canReachServer, isTrue);
    expect(probes, 3);
  });

  // Startup, a network flip and the retry can all ask at once. Two probes would
  // each open a connection and each read the verdict from before either
  // answered, which reported the server unreachable twice over.
  test('overlapping probes share one request', () async {
    final service = serviceOnline(online: true);
    addTearDown(service.dispose);

    await Future.wait([
      service.recheckNow(),
      service.recheckNow(),
      service.recheckNow(),
    ]);

    expect(probes, 1);
    expect(service.canReachServer, isTrue);
  });

  test('leaves the server alone while the device itself is offline', () async {
    failuresLeft = 99;
    final service = serviceOnline(online: false);
    addTearDown(service.dispose);

    await service.recheckNow();
    expect(service.canReachServer, isFalse);

    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(probes, 0);
  });
}
