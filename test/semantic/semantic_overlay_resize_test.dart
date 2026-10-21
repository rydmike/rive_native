import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rive_native/math.dart';
import 'package:rive_native/rive_native.dart' show Fit;
import 'package:rive_native/semantics.dart';
import 'rive_semantics_test_helpers.dart';

/// Regression test: the overlay's artboard-to-widget transform must track a
/// widget resize even when the semantic tree itself does not change. The
/// transform is computed during the semantics build from the render box's
/// size, so a relayout must invalidate semantics - otherwise screen reader
/// focus rectangles and tap targets drift away from the visuals until the
/// next unrelated tree change.
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

/// Folds a semantics node's rect through its own and every ancestor's
/// transform into global coordinates.
Rect _globalRect(SemanticsNode node) {
  var rect = node.rect;
  SemanticsNode? current = node;
  while (current != null) {
    final transform = current.transform;
    if (transform != null) {
      rect = MatrixUtils.transformRect(transform, rect);
    }
    current = current.parent;
  }
  return rect;
}

void main() {
  testWidgets('semantic rects track a widget resize without a tree change',
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
            role: SemanticRole.button,
            label: 'Press',
            maxX: 200,
            maxY: 200),
      ],
      removed: const [],
      moved: const [],
      updatedSemantic: const [],
      updatedGeometry: const [],
      childrenUpdated: const [
        SemanticsChildrenUpdate(parentId: -1, childIds: [1]),
      ],
    ));

    // The overlay fills the surface directly, so resizing the surface
    // relayouts the render box WITHOUT rebuilding any widget - the case
    // a rebuild-driven invalidation would miss.
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(200, 200));
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: RiveSemanticsOverlay(
          tree: model,
          artboardBounds: () => AABB.fromValues(0, 0, 200, 200),
          fit: Fit.contain,
          alignment: Alignment.center,
          layoutScaleFactor: 1,
        ),
      ),
    );
    await tester.pump();

    // Global coordinates include the root's device-pixel-ratio transform,
    // so assert the relative change rather than absolute pixels.
    final before = _globalRect(
        tester.getSemantics(find.byType(RiveSemanticsOverlay)).findByLabel('Press')!);
    expect(before.width, greaterThan(0), reason: 'sanity: button present');

    // Shrink the surface; no widget changes, the tree is untouched.
    // Fit.contain now maps the 200-unit artboard into half the pixels.
    await tester.binding.setSurfaceSize(const Size(100, 100));
    await tester.pump();

    final after = _globalRect(
        tester.getSemantics(find.byType(RiveSemanticsOverlay)).findByLabel('Press')!);
    expect(after.width / before.width, closeTo(0.5, 0.01),
        reason: 'the semantics transform must be recomputed on relayout - '
            'a stale transform leaves screen reader targets misaligned');

    model.dispose();
    handle.dispose();
  });
}
