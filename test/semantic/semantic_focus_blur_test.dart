import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rive_native/rive_native.dart' as rive;
import 'package:rive_native/semantics.dart';
import 'rive_semantics_test_helpers.dart';

import '../src/utils.dart';

/// semantic_list_scroll_focus_fixed.riv - a list of focusable cards
/// ("Element 1".."Element 5") wired into the focus system.
///
/// Regression tests for accessibility focus and blur:
/// - focus leaving Rive entirely must clear the Rive Focused state
///   (without blur wiring it sticks on the old node forever);
/// - a blur for a node that is no longer the Rive-focused one must be
///   ignored. The platform delivers didLose/didGain as separate messages
///   with no ordering guarantee, so a stale blur arriving after the next
///   element's gain must not wipe the fresh focus.
/// Painter that creates its state machine once and keeps it across
/// mounts - the RiveWidgetController lifecycle, where native semantic
/// state deliberately survives widget teardown.
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
  testWidgets('losing accessibility focus clears the Rive Focused state',
      (tester) async {
    final handle = tester.ensureSemantics();

    final bytes =
        loadFile('assets/semantic/semantic_list_scroll_focus_fixed.riv');
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

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 500,
            height: 600,
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
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    final overlay = find.byType(RiveSemanticsOverlay);
    final element = tester.getSemantics(overlay).findByLabel('Element 1');
    expect(element, isNotNull, reason: 'Element 1 must be in the tree');

    SemanticNodeData? rideNode() => painter.semanticTree
        ?.flattened()
        .map((r) => r.node)
        .where((n) => n.label == 'Element 1')
        .firstOrNull;

    bool isFocused() => SemanticState.has(
        rideNode()?.stateFlags ?? 0, SemanticState.focused);

    final owner = tester.renderObject(overlay).owner!.semanticsOwner!;

    owner.performAction(
        element!.id, SemanticsAction.didGainAccessibilityFocus);
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(isFocused(), isTrue,
        reason: 'gaining accessibility focus must set the Focused state');

    owner.performAction(
        element.id, SemanticsAction.didLoseAccessibilityFocus);
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(isFocused(), isFalse,
        reason: 'losing accessibility focus must clear the Focused state - '
            'otherwise it sticks on the old node');

    painter.dispose();
    artboard.dispose();
    file.dispose();
    handle.dispose();
  });

  testWidgets('a within-widget handoff (blur then gain, same frame) keeps '
      'focus on the new node', (tester) async {
    final handle = tester.ensureSemantics();

    final bytes =
        loadFile('assets/semantic/semantic_list_scroll_focus_fixed.riv');
    final file =
        await rive.File.decode(bytes, riveFactory: rive.Factory.flutter);
    final artboard = file!.defaultArtboard()!;
    final viewModel = file.defaultArtboardViewModel(artboard);
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
            height: 600,
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
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    final overlay = find.byType(RiveSemanticsOverlay);
    final one = tester.getSemantics(overlay).findByLabel('Element 1');
    final two = tester.getSemantics(overlay).findByLabel('Element 2');
    final owner = tester.renderObject(overlay).owner!.semanticsOwner!;

    bool isFocused(String label) => SemanticState.has(
        painter.semanticTree
                ?.flattened()
                .map((r) => r.node)
                .where((n) => n.label == label)
                .firstOrNull
                ?.stateFlags ??
            0,
        SemanticState.focused);

    owner.performAction(one!.id, SemanticsAction.didGainAccessibilityFocus);
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(isFocused('Element 1'), isTrue);

    // The common platform ordering: the old node's blur and the new
    // node's gain land in the same frame. The handoff must resolve to
    // Element 2 focused - the deferred widget-level blur is superseded.
    owner.performAction(one.id, SemanticsAction.didLoseAccessibilityFocus);
    owner.performAction(two!.id, SemanticsAction.didGainAccessibilityFocus);
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(isFocused('Element 2'), isTrue,
        reason: 'the same-frame blur must not win over the handoff');
    expect(isFocused('Element 1'), isFalse,
        reason: 'exclusive focus: the old node is cleared by the gain');

    painter.dispose();
    artboard.dispose();
    file.dispose();
    handle.dispose();
  });

  testWidgets('a mode-only widget update preserves the focus tracker',
      (tester) async {
    final handle = tester.ensureSemantics();

    final bytes =
        loadFile('assets/semantic/semantic_list_scroll_focus_fixed.riv');
    final file =
        await rive.File.decode(bytes, riveFactory: rive.Factory.flutter);
    final artboard = file!.defaultArtboard()!;
    final viewModel = file.defaultArtboardViewModel(artboard);
    final viewModelInstance = viewModel!.createDefaultInstance()!;
    artboard.bindViewModelInstance(viewModelInstance);

    final painter = rive.RivePainter.stateMachine(
      withStateMachine: (machine) {
        machine.bindViewModelInstance(viewModelInstance);
      },
    );

    Widget buildRive({required bool activateOnPlatformRequest}) =>
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 500,
              height: 600,
              child: rive.RiveSemanticsWidget(
                artboard: artboard,
                painter: painter,
                activateOnPlatformRequest: activateOnPlatformRequest,
                child: rive.RiveArtboardWidget(
                  artboard: artboard,
                  painter: painter,
                ),
              ),
            ),
          ),
        );

    await tester.pumpWidget(buildRive(activateOnPlatformRequest: false));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    bool isFocused() => SemanticState.has(
        painter.semanticTree
                ?.flattened()
                .map((r) => r.node)
                .where((n) => n.label == 'Element 1')
                .firstOrNull
                ?.stateFlags ??
            0,
        SemanticState.focused);

    final overlay = find.byType(RiveSemanticsOverlay);
    final element = tester.getSemantics(overlay).findByLabel('Element 1');
    final owner = tester.renderObject(overlay).owner!.semanticsOwner!;

    owner.performAction(
        element!.id, SemanticsAction.didGainAccessibilityFocus);
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(isFocused(), isTrue, reason: 'sanity: focused before the update');

    // Same painter and artboard, only the mode flag changes.
    await tester.pumpWidget(buildRive(activateOnPlatformRequest: true));
    await tester.pump();

    // The screen reader now moves away; the blur must still be honored.
    owner.performAction(
        element.id, SemanticsAction.didLoseAccessibilityFocus);
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(isFocused(), isFalse,
        reason: 'a mode-only update must not forget which node holds '
            'focus - the following blur was ignored and Focused stuck');

    painter.dispose();
    artboard.dispose();
    file.dispose();
    handle.dispose();
  });

  testWidgets('unmounting while a node holds focus clears it for remount',
      (tester) async {
    final handle = tester.ensureSemantics();

    final bytes =
        loadFile('assets/semantic/semantic_list_scroll_focus_fixed.riv');
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
              height: 600,
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

    bool isFocused() => SemanticState.has(
        painter.semanticTree
                ?.flattened()
                .map((r) => r.node)
                .where((n) => n.label == 'Element 1')
                .firstOrNull
                ?.stateFlags ??
            0,
        SemanticState.focused);

    final overlay = find.byType(RiveSemanticsOverlay);
    final element = tester.getSemantics(overlay).findByLabel('Element 1');
    tester.renderObject(overlay).owner!.semanticsOwner!.performAction(
        element!.id, SemanticsAction.didGainAccessibilityFocus);
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(isFocused(), isTrue, reason: 'sanity: focused before unmount');

    // Navigate away - the widget unmounts, the machine (and its
    // semantic state) survives. The accessibility nodes are gone, so
    // Rive's focus must not survive with it.
    await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: SizedBox.expand())));

    await tester.pumpWidget(buildRive());
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(isFocused(), isFalse,
        reason: 'the Focused state must not reappear on remount - the '
            'screen reader focus died with the unmounted nodes');

    painter.dispose();
    artboard.dispose();
    file.dispose();
    handle.dispose();
  });

  testWidgets('a stale blur after focus moved to another node is ignored',
      (tester) async {
    final handle = tester.ensureSemantics();

    final bytes =
        loadFile('assets/semantic/semantic_list_scroll_focus_fixed.riv');
    final file =
        await rive.File.decode(bytes, riveFactory: rive.Factory.flutter);
    final artboard = file!.defaultArtboard()!;
    final viewModel = file.defaultArtboardViewModel(artboard);
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
            height: 600,
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
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    final overlay = find.byType(RiveSemanticsOverlay);
    final one = tester.getSemantics(overlay).findByLabel('Element 1');
    final two = tester.getSemantics(overlay).findByLabel('Element 2');
    expect(one, isNotNull);
    expect(two, isNotNull);

    bool isFocused(String label) => SemanticState.has(
        painter.semanticTree
                ?.flattened()
                .map((r) => r.node)
                .where((n) => n.label == label)
                .firstOrNull
                ?.stateFlags ??
            0,
        SemanticState.focused);

    final owner = tester.renderObject(overlay).owner!.semanticsOwner!;

    // Focus 1, then 2, THEN deliver 1's blur - the platform sends
    // didLose/didGain as separate messages, so this ordering happens.
    owner.performAction(one!.id, SemanticsAction.didGainAccessibilityFocus);
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    owner.performAction(two!.id, SemanticsAction.didGainAccessibilityFocus);
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(isFocused('Element 2'), isTrue,
        reason: 'sanity: Element 2 holds Rive focus after its gain');

    owner.performAction(one.id, SemanticsAction.didLoseAccessibilityFocus);
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(isFocused('Element 2'), isTrue,
        reason: 'the stale blur for Element 1 must not clear Element 2\'s '
            'focus - blur only applies to the node that still holds it');

    painter.dispose();
    artboard.dispose();
    file.dispose();
    handle.dispose();
  });
}
