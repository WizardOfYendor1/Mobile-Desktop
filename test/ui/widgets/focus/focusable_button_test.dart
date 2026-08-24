import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/ui/widgets/focus/focusable_button.dart';
import 'package:moonfin_design/moonfin_design.dart';

void main() {
  setUp(() => ThemeRegistry.setActiveById(ThemeRegistry.moonfinId));

  /// [FocusableButton] uses `useBackgroundFocus`, which normally suppresses
  /// the border overlay drawn by [FocusableWrapper] (bug: game-detail action
  /// pills looked identical whether focused or not except for a subtle
  /// opacity/fill change). `showFocusRing` opts a button back into the ring.
  testWidgets('showFocusRing draws the focus border on top of the background fill', (
    tester,
  ) async {
    final node = FocusNode();
    addTearDown(node.dispose);

    Finder ringContainer() => find.byWidgetPredicate(
      (w) =>
          w is Container &&
          (w.decoration as BoxDecoration?)?.border != null,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FocusableButton(
            focusNode: node,
            showFocusRing: true,
            onPressed: () {},
            child: const Text('Core'),
          ),
        ),
      ),
    );

    expect(ringContainer(), findsNothing, reason: 'no ring while unfocused');

    node.requestFocus();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(ringContainer(), findsOneWidget, reason: 'ring appears once focused');
  });

  testWidgets('the ring stays off without showFocusRing (default)', (
    tester,
  ) async {
    final node = FocusNode();
    addTearDown(node.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FocusableButton(
            focusNode: node,
            onPressed: () {},
            child: const Text('Core'),
          ),
        ),
      ),
    );

    node.requestFocus();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    final ring = find.byWidgetPredicate(
      (w) =>
          w is Container &&
          (w.decoration as BoxDecoration?)?.border != null,
    );
    expect(ring, findsNothing, reason: 'default behaviour is unchanged');
  });

  /// Regression for the game-detail "can't scroll back to the top" bug: a
  /// button that regains focus (e.g. the D-pad travelling back up past
  /// non-focusable synopsis/metadata text) must be able to pull the
  /// scrollable back into view, the same way [GamePosterCard] already does.
  testWidgets('autoScroll brings an off-screen button into view when focused', (
    tester,
  ) async {
    final topNode = FocusNode();
    final bottomNode = FocusNode();
    addTearDown(topNode.dispose);
    addTearDown(bottomNode.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: Column(
              children: [
                FocusableButton(
                  focusNode: topNode,
                  autoScroll: true,
                  onPressed: () {},
                  child: const SizedBox(height: 40, child: Text('Top')),
                ),
                const SizedBox(height: 2000),
                FocusableButton(
                  focusNode: bottomNode,
                  autoScroll: true,
                  onPressed: () {},
                  child: const SizedBox(height: 40, child: Text('Bottom')),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    final scrollable = tester.state<ScrollableState>(find.byType(Scrollable));

    bottomNode.requestFocus();
    await tester.pump();
    await tester.pumpAndSettle();
    expect(scrollable.position.pixels, greaterThan(0));

    topNode.requestFocus();
    await tester.pump();
    await tester.pumpAndSettle();
    expect(
      scrollable.position.pixels,
      lessThan(50),
      reason: 'autoScroll:true pulls the top button back into view',
    );
  });

  testWidgets('without autoScroll, focusing an off-screen button leaves the scroll offset alone', (
    tester,
  ) async {
    final topNode = FocusNode();
    final bottomNode = FocusNode();
    addTearDown(topNode.dispose);
    addTearDown(bottomNode.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: Column(
              children: [
                FocusableButton(
                  focusNode: topNode,
                  onPressed: () {},
                  child: const SizedBox(height: 40, child: Text('Top')),
                ),
                const SizedBox(height: 2000),
                FocusableButton(
                  focusNode: bottomNode,
                  autoScroll: true,
                  onPressed: () {},
                  child: const SizedBox(height: 40, child: Text('Bottom')),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    final scrollable = tester.state<ScrollableState>(find.byType(Scrollable));

    bottomNode.requestFocus();
    await tester.pump();
    await tester.pumpAndSettle();
    final scrolledDown = scrollable.position.pixels;
    expect(scrolledDown, greaterThan(0));

    topNode.requestFocus();
    await tester.pump();
    await tester.pumpAndSettle();
    expect(
      scrollable.position.pixels,
      scrolledDown,
      reason: 'default autoScroll:false leaves the offset stuck, reproducing the bug',
    );
  });
}
