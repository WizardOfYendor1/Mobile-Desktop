import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/platform/ios_background_refresh.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(IosBackgroundRefresh.channelName);
  const notImplemented = Object();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  /// Simulates the native side calling into Dart.
  Future<Object?> callFromNative(String method, [Object? arguments]) async {
    final reply = await messenger.handlePlatformMessage(
      IosBackgroundRefresh.channelName,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall(method, arguments),
      ),
      null,
    );
    // A handler that throws MissingPluginException answers with no reply.
    if (reply == null) return notImplemented;
    return const StandardMethodCodec().decodeEnvelope(reply);
  }

  late List<MethodCall> nativeCalls;
  late IosBackgroundRefresh refresh;

  setUp(() {
    nativeCalls = [];
    messenger.setMockMethodCallHandler(channel, (call) async {
      nativeCalls.add(call);
      if (call.method == 'refreshStatus') return 'denied';
      return null;
    });
    refresh = IosBackgroundRefresh(channel: channel);
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMessageHandler(IosBackgroundRefresh.channelName, null);
    // bind() installs a handler on the channel itself, which outlives the
    // IosBackgroundRefresh instance under test.
    channel.setMethodCallHandler(null);
  });

  test('configure forwards the switch to native', () async {
    await refresh.configure(enabled: true);
    expect(nativeCalls, hasLength(1));
    expect(nativeCalls.single.method, 'configure');
    expect(nativeCalls.single.arguments, {'enabled': true});
  });

  test('refreshStatus returns the native answer', () async {
    expect(await refresh.refreshStatus(), 'denied');
  });

  test('performRefresh runs the handler with the granted budget', () async {
    Duration? received;
    refresh.bind((budget) async {
      received = budget;
      return true;
    });
    final result = await callFromNative('performRefresh', {
      'budgetSeconds': 20,
    });
    expect(result, isTrue);
    expect(received, const Duration(seconds: 20));
  });

  test('a call before bind is reported as not implemented', () async {
    expect(
      await callFromNative('performRefresh', {'budgetSeconds': 20}),
      same(notImplemented),
    );
  });

  test('a handler that throws or exceeds the budget answers false', () async {
    refresh.bind((_) async => throw StateError('boom'));
    expect(
      await callFromNative('performRefresh', {'budgetSeconds': 20}),
      isFalse,
    );

    refresh.bind((_) => Completer<bool>().future); // never completes
    expect(
      await callFromNative('performRefresh', {'budgetSeconds': 0}),
      isFalse,
    );
  });

  test('unknown methods are reported as not implemented', () async {
    refresh.bind((_) async => true);
    expect(await callFromNative('somethingElse'), same(notImplemented));
  });
}
