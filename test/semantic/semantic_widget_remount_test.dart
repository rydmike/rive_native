import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rive_native/rive_native.dart' as rive;
import 'package:rive_native/semantics.dart';
import 'rive_semantics_test_helpers.dart';

import '../src/utils.dart';

/// Regression test: unmounting and remounting RiveSemanticsWidget with the
/// same (still-alive) painter - e.g. navigating away from a route and back
/// with a kept controller - must not permanently empty the semantics tree.
///
/// The native manager cannot replay its full tree on request (diffs are
/// incremental against its own snapshot), so the Dart tree must survive
/// widget teardown: semantics stays enabled on the painter, whose own
/// dispose tears it down.
/// Painter that creates its state machine once and keeps it across
/// artboardChanged calls - the same lifecycle as rive_flutter's
/// RiveWidgetController. The native semantic manager then survives widget
/// teardown, and only ever emits incremental diffs.
base class _KeptMachinePainter extends rive.BasicArtboardPainter
    with rive.RiveSemanticsMixin {
  final rive.BindableViewModelInstance viewModelInstance;
  _KeptMachinePainter(this.viewModelInstance);

  rive.StateMachine? machine;

  @override
  rive.StateMachine? get semanticsStateMachine => machine;

  @override
  void artboardChanged(rive.Artboard artboard) {
    super.artboardChanged(artboard);
    if (machine == null) {
      machine = artboard.defaultStateMachine();
      machine?.bindViewModelInstance(viewModelInstance);
      if (isSemanticsEnabled) {
        machine?.enableSemantics();
      }
    }
  }

  @override
  bool advance(double elapsedSeconds) {
    final advanced = machine?.advanceAndApply(elapsedSeconds) ?? false;
    updateSemantics();
    return advanced;
  }

  @override
  void dispose() {
    machine?.dispose();
    machine = null;
    disposeSemantics();
    super.dispose();
  }
}

void main() {
  testWidgets(
      'semantics survive widget unmount/remount with a kept state machine',
      (tester) async {
    final handle = tester.ensureSemantics();

    final bytes = loadFile('assets/semantic/tabtest.riv');
    final file =
        await rive.File.decode(bytes, riveFactory: rive.Factory.flutter);
    final artboard = file!.defaultArtboard()!;
    final viewModel = file.defaultArtboardViewModel(artboard);
    final viewModelInstance = viewModel!.createDefaultInstance()!;
    artboard.bindViewModelInstance(viewModelInstance);

    final painter = _KeptMachinePainter(viewModelInstance);

    Widget buildRive() => MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 500,
              height: 400,
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
        );

    await tester.pumpWidget(buildRive());
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    final overlay = find.byType(RiveSemanticsOverlay);
    expect(tester.getSemantics(overlay).findByLabel('Parent'), isNotNull,
        reason: 'sanity: semantics populated on first mount');

    // Unmount; the painter and its state machine stay alive, so the
    // native semantic manager keeps its snapshot.
    await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: SizedBox.expand())));

    await tester.pumpWidget(buildRive());
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    final overlay2 = find.byType(RiveSemanticsOverlay);
    expect(overlay2, findsOneWidget);
    expect(tester.getSemantics(overlay2).findByLabel('Parent'), isNotNull,
        reason: 'the tree must survive teardown: the native manager only '
            'emits incremental diffs, so a discarded Dart tree can never '
            'repopulate for a kept state machine');

    painter.dispose();
    artboard.dispose();
    file.dispose();
    handle.dispose();
  });

  testWidgets('semantics survive widget unmount/remount with a kept painter',
      (tester) async {
    final handle = tester.ensureSemantics();

    final bytes = loadFile('assets/semantic/tabtest.riv');
    final file =
        await rive.File.decode(bytes, riveFactory: rive.Factory.flutter);
    expect(file, isNotNull);

    final artboard = file!.defaultArtboard();
    expect(artboard, isNotNull);

    final viewModel = file.defaultArtboardViewModel(artboard!);
    final viewModelInstance = viewModel!.createDefaultInstance()!;
    artboard.bindViewModelInstance(viewModelInstance);

    final painter = rive.RivePainter.stateMachine(
      withStateMachine: (machine) {
        machine.bindViewModelInstance(viewModelInstance);
      },
    );

    Widget buildRive() => MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 500,
              height: 400,
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
        );

    await tester.pumpWidget(buildRive());
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    final overlay = find.byType(RiveSemanticsOverlay);
    expect(overlay, findsOneWidget);
    expect(tester.getSemantics(overlay).findByLabel('Parent'), isNotNull,
        reason: 'sanity: semantics populated on first mount');

    // Unmount (painter stays alive - the app keeps its controller).
    await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: SizedBox.expand())));

    // Remount with the same painter.
    await tester.pumpWidget(buildRive());
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    final overlay2 = find.byType(RiveSemanticsOverlay);
    expect(overlay2, findsOneWidget,
        reason: 'the overlay must come back after remount');
    expect(tester.getSemantics(overlay2).findByLabel('Parent'), isNotNull,
        reason: 'the semantic tree must repopulate after remount - the '
            'native side only emits incremental diffs, so the tree must '
            'survive widget teardown');

    painter.dispose();
    artboard.dispose();
    file.dispose();
    handle.dispose();
  });
}
