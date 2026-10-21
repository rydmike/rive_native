import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rive_native/rive_native.dart' as rive;
import 'package:rive_native/semantics.dart';
import 'rive_semantics_test_helpers.dart';

import '../src/utils.dart';

/// tabtest.riv - Row with three tabs (All / Parent / Child). Tapping a tab
/// sets the view model's enumProperty to the tab's name.
///
/// Regression test: semantic actions must work after the state machine has
/// settled and the ticker has stopped. fireSemanticAction only queues the
/// event natively (processed on the next state machine advance), so without
/// an explicit advance + repaint the action would be silently dropped -
/// exactly like pointer input, which advances immediately on down/up and
/// schedules a repaint.
void main() {
  testWidgets('semantic tap is processed after the state machine settles',
      (tester) async {
    final handle = tester.ensureSemantics();

    final bytes = loadFile('assets/semantic/tabtest.riv');
    final file =
        await rive.File.decode(bytes, riveFactory: rive.Factory.flutter);
    expect(file, isNotNull);

    final artboard = file!.defaultArtboard();
    expect(artboard, isNotNull);

    final viewModel = file.defaultArtboardViewModel(artboard!);
    expect(viewModel, isNotNull);
    final viewModelInstance = viewModel!.createDefaultInstance()!;
    artboard.bindViewModelInstance(viewModelInstance);

    final painter = rive.RivePainter.stateMachine(
      withStateMachine: (machine) {
        machine.bindViewModelInstance(viewModelInstance);
      },
    );

    await tester.pumpWidget(
      MaterialApp(
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
      ),
    );

    // Pump until the machine settles and the render box stops its ticker.
    var settled = false;
    for (var i = 0; i < 120; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (!painter.isTickerActive) {
        settled = true;
        break;
      }
    }
    expect(settled, isTrue,
        reason: 'tabtest.riv must settle so the ticker stops; if this '
            'fails the asset changed and the test needs a new settling '
            'asset');

    expect(viewModelInstance.enumerator('enumProperty')?.value, 'All');

    final overlay = find.byType(RiveSemanticsOverlay);
    expect(overlay, findsOneWidget);
    final root = tester.getSemantics(overlay);
    final parentTab = root.findByLabel('Parent');
    expect(parentTab, isNotNull,
        reason: 'Parent tab must be in the Flutter semantics tree');

    tester
        .renderObject(overlay)
        .owner!
        .semanticsOwner!
        .performAction(parentTab!.id, SemanticsAction.tap);

    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(viewModelInstance.enumerator('enumProperty')?.value, 'Parent',
        reason: 'the semantic tap must be processed even though the '
            'ticker had stopped');

    painter.dispose();
    artboard.dispose();
    file.dispose();
    handle.dispose();
  });
}
