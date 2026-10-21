import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rive_native/rive_native.dart' as rive;
import 'package:rive_native/semantics.dart';
import 'rive_semantics_test_helpers.dart';

import '../src/utils.dart';

/// zero_area_semantics.riv - authored fixture for the zero-area contracts
/// (see semantic_zero_area_fixture_test.cpp for the full scene layout).
/// These tests exercise the whole pipeline: core diffs -> FFI -> Dart tree
/// -> Flutter semantics nodes -> screen reader actions -> view model.
class _Harness {
  late rive.File file;
  late rive.Artboard artboard;
  late rive.BindableViewModelInstance viewModelInstance;
  late rive.StateMachinePainter painter;

  Future<void> mount(WidgetTester tester) async {
    final bytes = loadFile('assets/semantic/zero_area_semantics.riv');
    file = (await rive.File.decode(bytes,
        riveFactory: rive.Factory.flutter))!;
    artboard = file.defaultArtboard()!;
    final viewModel = file.defaultArtboardViewModel(artboard)!;
    viewModelInstance = viewModel.createDefaultInstance()!;
    artboard.bindViewModelInstance(viewModelInstance);

    painter = rive.RivePainter.stateMachine(
      withStateMachine: (machine) {
        machine.bindViewModelInstance(viewModelInstance);
      },
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 600,
            height: 800,
            child: rive.RiveSemanticsWidget(
              artboard: artboard,
              painter: painter,
              child: rive.RiveArtboardWidget(
                artboard: artboard,
                painter: painter,
              ),
            ),
          ),
        ),
      ),
    );
  }

  String? get lastPressed => viewModelInstance.string('lastPressed')?.value;

  SemanticNodeData? treeNode(String label) => painter.semanticTree
      ?.flattened()
      .map((r) => r.node)
      .where((n) => n.label == label)
      .firstOrNull;

  double treeWidth(String label) {
    final node = treeNode(label);
    return node == null ? -1 : node.maxX - node.minX;
  }

  void dispose() {
    painter.dispose();
    artboard.dispose();
    file.dispose();
  }
}

Future<void> _pump(WidgetTester tester, int frames) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('fixture exposes the labelled tree and prunes Hidden',
      (tester) async {
    final handle = tester.ensureSemantics();
    final h = _Harness();
    await h.mount(tester);
    await _pump(tester, 2);

    final root =
        tester.getSemantics(find.byType(RiveSemanticsOverlay));
    for (final label in [
      'Invisible group',
      'Button A',
      'Button B',
      'Inside collapsing',
      'Empty root',
      'Root child button',
    ]) {
      expect(root.findByLabel(label), isNotNull,
          reason: '"$label" must be a reachable screen reader node');
    }
    expect(root.findByLabel('Hidden group'), isNull,
        reason: 'the Hidden subtree must be pruned');
    expect(root.findByLabel('Hidden button'), isNull);

    h.dispose();
    handle.dispose();
  });

  testWidgets('semantic taps drive the view model end to end',
      (tester) async {
    final handle = tester.ensureSemantics();
    final h = _Harness();
    await h.mount(tester);
    await _pump(tester, 2);

    expect(h.lastPressed, 'none');

    final overlay = find.byType(RiveSemanticsOverlay);
    final owner = tester.renderObject(overlay).owner!.semanticsOwner!;

    final buttonA =
        tester.getSemantics(overlay).findByLabel('Button A');
    owner.performAction(buttonA!.id, SemanticsAction.tap);
    await _pump(tester, 2);
    expect(h.lastPressed, 'A',
        reason: 'a screen reader tap inside the zero-size group must '
            'activate the promoted button');

    final rootChild =
        tester.getSemantics(overlay).findByLabel('Root child button');
    owner.performAction(rootChild!.id, SemanticsAction.tap);
    await _pump(tester, 2);
    expect(h.lastPressed, 'root-child');

    h.dispose();
    handle.dispose();
  });

  testWidgets('transform-animated geometry flows; the chip stays reachable',
      (tester) async {
    final handle = tester.ensureSemantics();
    final h = _Harness();
    await h.mount(tester);
    await _pump(tester, 2); // 0.2s in

    expect(h.treeWidth('Scaled button'), greaterThan(100),
        reason: 'sanity: scaled button starts wide');

    // Both timelines cross zero at 1.5s; land near it.
    await _pump(tester, 14);

    // The scaled group animates a node transform, which flows to bounds.
    expect(h.treeWidth('Scaled button'), lessThan(15),
        reason: 'node-scale animation must move the semantic bounds');

    // The card animates a rectangle PATH width. Semantic bounds do not
    // follow path geometry (deferred - see backlog), so the card stays at
    // roughly its authored width. When that follow-up lands, this
    // assertion should flip.
    expect(h.treeWidth('Collapsing card'), greaterThan(100),
        reason: 'path-driven size changes are not reflected in bounds');

    // The chip keeps its own bounds and stays a working screen reader
    // stop.
    expect(h.treeWidth('Inside collapsing'), greaterThan(50));
    final overlay = find.byType(RiveSemanticsOverlay);
    final chip =
        tester.getSemantics(overlay).findByLabel('Inside collapsing');
    expect(chip, isNotNull, reason: 'the chip must remain reachable');
    tester
        .renderObject(overlay)
        .owner!
        .semanticsOwner!
        .performAction(chip!.id, SemanticsAction.tap);
    await _pump(tester, 2);
    expect(h.lastPressed, 'inside',
        reason: 'activating the chip must still work');

    // The scaled button recovers after the zero crossing.
    await _pump(tester, 15); // past 3.0s, cycle restarts
    expect(h.treeWidth('Scaled button'), greaterThan(100),
        reason: 'the scaled button recovers');

    h.dispose();
    handle.dispose();
  });
}
