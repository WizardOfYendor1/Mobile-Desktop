import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/ui/navigation/focus_route_observer.dart';
import 'package:moonfin/util/platform_detection.dart';

/// Mirrors the left navbar layout: content fills the stack and the rail sits
/// on the left edge, so reading order traversal reaches the rail first.
Widget _appWithRail({
  required FocusNode rail,
  required FocusNode card,
}) {
  return MaterialApp(
    navigatorObservers: [FocusRouteObserver()],
    home: Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: Center(
              child: Focus(
                focusNode: card,
                child: const SizedBox(width: 200, height: 120),
              ),
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            bottom: 0,
            child: Focus(
              focusNode: rail,
              child: const SizedBox(width: 72),
            ),
          ),
        ],
      ),
    ),
  );
}

void main() {
  tearDown(() {
    PlatformDetection.setTvMode(false);
  });

  testWidgets('leaves focus alone on desktop so the rail stays collapsed',
      (tester) async {
    final rail = FocusNode(debugLabel: 'Rail');
    final card = FocusNode(debugLabel: 'Card');
    addTearDown(rail.dispose);
    addTearDown(card.dispose);

    await tester.pumpWidget(_appWithRail(rail: rail, card: card));
    // Outlast the observer's full retry window.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(rail.hasFocus, isFalse);
    expect(card.hasFocus, isFalse);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('still hands the d-pad a starting point on TV', (tester) async {
    PlatformDetection.setTvMode(true);
    final rail = FocusNode(debugLabel: 'Rail');
    final card = FocusNode(debugLabel: 'Card');
    addTearDown(rail.dispose);
    addTearDown(card.dispose);

    await tester.pumpWidget(_appWithRail(rail: rail, card: card));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(rail.hasFocus || card.hasFocus, isTrue);
  });
}
