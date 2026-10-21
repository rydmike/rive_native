import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rive_native/math.dart';
import 'package:rive_native/rive_native.dart' show Fit;
import 'package:rive_native/semantics.dart';
import 'rive_semantics_test_helpers.dart';

/// Regression test: turning platform semantics off and back on while the
/// overlay's render box survives (screen reader disconnects and
/// reconnects, or the example's force-switch is toggled) must not crash.
/// The render box caches SemanticsNode instances; when the SemanticsOwner
/// is disposed those instances reference a dead owner, and reusing them
/// under the new owner hits framework asserts
/// ('owner!._nodes.containsKey(id)', 'node.built').
SemanticsDiffNode _node({
  required int id,
  int parentId = -1,
  int siblingIndex = 0,
  SemanticRole role = SemanticRole.none,
  String label = '',
  double minX = 0,
  double minY = 0,
  double maxX = 0,
  double maxY = 0,
}) =>
    SemanticsDiffNode(
      id: id,
      role: role,
      label: label,
      value: '',
      hint: '',
      stateFlags: 0,
      traitFlags: 0,
      headingLevel: 0,
      minX: minX,
      minY: minY,
      maxX: maxX,
      maxY: maxY,
      parentId: parentId,
      siblingIndex: siblingIndex,
    );

void main() {
  testWidgets('semantics owner off/on cycle over a live overlay',
      semanticsEnabled: false, (tester) async {
    final model = SemanticTreeModel();
    model.applyDiff(SemanticsDiff(
      treeVersion: 1,
      frameNumber: 0,
      rootId: 1,
      added: [
        _node(id: 1, role: SemanticRole.group, maxX: 200, maxY: 200),
        _node(
            id: 2,
            parentId: 1,
            role: SemanticRole.button,
            label: 'Press',
            minX: 50,
            minY: 60,
            maxX: 150,
            maxY: 100),
      ],
      removed: const [],
      moved: const [],
      updatedSemantic: const [],
      updatedGeometry: const [],
      childrenUpdated: const [
        SemanticsChildrenUpdate(parentId: -1, childIds: [1]),
        SemanticsChildrenUpdate(parentId: 1, childIds: [2]),
      ],
    ));

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 200,
          height: 200,
          child: RiveSemanticsOverlay(
            tree: model,
            artboardBounds: () => AABB.fromValues(0, 0, 200, 200),
            fit: Fit.contain,
            alignment: Alignment.center,
            layoutScaleFactor: 1,
          ),
        ),
      ),
    );

    // Screen reader connects.
    var handle = tester.ensureSemantics();
    await tester.pump();
    expect(
        tester
            .getSemantics(find.byType(RiveSemanticsOverlay))
            .findByLabel('Press'),
        isNotNull,
        reason: 'sanity: populated under the first owner');

    // Screen reader disconnects - the SemanticsOwner is disposed while
    // the render box (and its caches) survive.
    handle.dispose();
    await tester.pump();

    // Reconnect. The overlay must rebuild cleanly under the new owner.
    handle = tester.ensureSemantics();
    await tester.pump();

    expect(tester.takeException(), isNull,
        reason: 'stale cached SemanticsNodes from the disposed owner must '
            'not be reused under the new one');
    expect(
        tester
            .getSemantics(find.byType(RiveSemanticsOverlay))
            .findByLabel('Press'),
        isNotNull,
        reason: 'the tree must repopulate under the new owner');

    model.dispose();
    handle.dispose();
  });
}
