import 'package:flutter_test/flutter_test.dart';
import 'package:rive_native/rive_native.dart' as rive;
import 'package:rive_native/semantics.dart';

import '../src/utils.dart';

/// Regression test: swapping the artboard on a painter with semantics
/// enabled must reset the semantic tree. Each state machine's semantic
/// node ids restart at 1, so stale nodes from the previous artboard would
/// collide with (and corrupt) the new machine's diff stream.
void main() {
  test('artboardChanged resets the semantic tree', () async {
    TestWidgetsFlutterBinding.ensureInitialized();

    final bytes = loadFile('assets/semantic/tabtest.riv');
    final file =
        await rive.File.decode(bytes, riveFactory: rive.Factory.flutter);
    expect(file, isNotNull);

    final artboardA = file!.defaultArtboard()!;
    final artboardB = file.defaultArtboard()!;

    final painter = rive.RivePainter.stateMachine();
    painter.artboardChanged(artboardA);
    painter.semanticsEnabled = true;

    for (var i = 0; i < 10; i++) {
      painter.advance(0.1);
    }
    final tree = painter.semanticTree!;
    expect(tree.nodeCount, greaterThan(0),
        reason: 'semantics must populate for the first artboard');
    final versionBeforeSwap = tree.version;

    painter.artboardChanged(artboardB);

    expect(painter.semanticTree, same(tree),
        reason: 'the tree instance must survive the swap so widget '
            'listeners stay attached');
    expect(tree.nodeCount, 0,
        reason: 'stale nodes from the old artboard must be cleared on '
            'swap - the new machine reuses the same node ids');
    expect(tree.version, greaterThan(versionBeforeSwap),
        reason: 'clearing is a change; listeners must be notified');

    // The new machine repopulates the tree from a clean slate.
    for (var i = 0; i < 10; i++) {
      painter.advance(0.1);
    }
    expect(tree.nodeCount, greaterThan(0),
        reason: 'semantics must repopulate for the swapped-in artboard');

    painter.dispose();
    artboardA.dispose();
    artboardB.dispose();
    file.dispose();
  });
}
