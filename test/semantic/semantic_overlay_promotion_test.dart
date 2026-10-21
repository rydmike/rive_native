import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rive_native/math.dart';
import 'package:rive_native/rive_native.dart' show Fit;
import 'package:rive_native/semantics.dart';
import 'rive_semantics_test_helpers.dart';

/// Regression test: a zero-area node cannot be emitted (Flutter asserts
/// non-root SemanticsNodes have a non-empty rect), but its children must be
/// promoted into the parent's child list, not pruned with it. A zero-area
/// grouping node with visible children is a legitimate authored shape;
/// intentional hiding has its own mechanism (the Hidden state). Matches the
/// Android runtime's projection.
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
  testWidgets('children of a zero-area node are promoted, not pruned',
      (tester) async {
    final handle = tester.ensureSemantics();

    final model = SemanticTreeModel();
    model.applyDiff(SemanticsDiff(
      treeVersion: 1,
      frameNumber: 0,
      rootId: 1,
      added: [
        _node(
            id: 1,
            role: SemanticRole.group,
            maxX: 200,
            maxY: 200),
        // Zero-width container: minX == maxX makes the rect empty.
        _node(
            id: 2,
            parentId: 1,
            role: SemanticRole.group,
            minX: 50,
            minY: 50,
            maxX: 50,
            maxY: 150),
        _node(
            id: 3,
            parentId: 2,
            role: SemanticRole.button,
            label: 'Press',
            minX: 50,
            minY: 60,
            maxX: 150,
            maxY: 100),
        // NaN-bounds container: must also promote, not crash or leak a
        // non-finite rect into the Flutter semantics tree.
        _node(
            id: 5,
            parentId: 1,
            siblingIndex: 2,
            role: SemanticRole.group,
            minX: double.nan,
            minY: 50,
            maxX: 150,
            maxY: 150),
        _node(
            id: 6,
            parentId: 5,
            role: SemanticRole.button,
            label: 'Nested',
            minX: 60,
            minY: 60,
            maxX: 140,
            maxY: 140),
        // Sibling with valid bounds, as an ordering sanity check.
        _node(
            id: 4,
            parentId: 1,
            siblingIndex: 1,
            role: SemanticRole.text,
            label: 'After',
            minX: 0,
            minY: 160,
            maxX: 200,
            maxY: 200),
      ],
      removed: const [],
      moved: const [],
      updatedSemantic: const [],
      updatedGeometry: const [],
      childrenUpdated: const [
        SemanticsChildrenUpdate(parentId: -1, childIds: [1]),
        SemanticsChildrenUpdate(parentId: 1, childIds: [2, 5, 4]),
        SemanticsChildrenUpdate(parentId: 2, childIds: [3]),
        SemanticsChildrenUpdate(parentId: 5, childIds: [6]),
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
    await tester.pump();

    final root = tester.getSemantics(find.byType(RiveSemanticsOverlay));
    expect(root.findByLabel('Press'), isNotNull,
        reason: 'the button must survive its zero-area parent - promoted '
            'into the grandparent, not pruned with the container');
    expect(root.findByLabel('After'), isNotNull,
        reason: 'sanity: valid-bounds sibling is present');
    expect(root.findByLabel('Nested'), isNotNull,
        reason: 'the child of a NaN-bounds container must be promoted - '
            'NaN rects must never reach the Flutter semantics tree');
    expect(tester.takeException(), isNull,
        reason: 'a NaN rect reaching SemanticsNode.rect asserts');

    model.dispose();
    handle.dispose();
  });
}
