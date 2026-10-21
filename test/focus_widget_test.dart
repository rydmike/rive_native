import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'dart:ui' show Tristate;

import 'package:flutter/semantics.dart' show SemanticsNode;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rive_native/rive_native.dart' as rive;

import 'src/utils.dart';

/// focus.riv (trays/testing/focus): one artboard per keyboard-focus
/// scenario. Every focusable is a placement of a Button component whose
/// keyboard listener claims Enter and Space; the TextInput
/// artboard mirrors its field into the `text` view model property.

/// A Rive graphic between two Flutter buttons, so traversal can enter from
/// either side and leave at either end.
class _Harness extends StatelessWidget {
  final rive.Artboard artboard;
  final rive.StateMachinePainter painter;
  const _Harness({required this.artboard, required this.painter});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            TextButton(onPressed: () {}, child: const Text('before')),
            SizedBox(
              width: 640,
              height: 360,
              child: rive.RiveFocusWidget(
                painter: painter,
                child: rive.RiveArtboardWidget(
                  artboard: artboard,
                  painter: painter,
                ),
              ),
            ),
            TextButton(onPressed: () {}, child: const Text('after')),
          ],
        ),
      ),
    );
  }
}

void main() {
  late rive.File file;
  rive.Artboard? artboard;
  rive.StateMachinePainter? painter;

  setUpAll(() async {
    file = (await rive.File.decode(
      loadFile('assets/focus.riv'),
      riveFactory: rive.Factory.flutter,
    ))!;
  });

  tearDownAll(() => file.dispose());

  tearDown(() {
    painter?.dispose();
    painter = null;
    artboard?.dispose();
    artboard = null;
  });

  rive.StateMachine sm() => painter!.stateMachine!;
  rive.FocusState focusState() => sm().focusState;
  ({double minX, double minY, double maxX, double maxY}) focusedBounds() =>
      sm().focusManager!.primaryFocusBounds()!;
  bool riveHasFlutterFocus() =>
      FocusManager.instance.primaryFocus?.debugLabel == 'RiveFocusWidget';
  FocusNode button(WidgetTester tester, String label) =>
      Focus.of(tester.element(find.text(label)));

  Future<void> pumpArtboard(WidgetTester tester, String name) async {
    artboard = file.artboard(name)!;
    painter = rive.StateMachinePainter(
      withStateMachine: (machine) => machine.bind(),
    );
    await tester.pumpWidget(_Harness(artboard: artboard!, painter: painter!));
    await tester.pump();
    expect(sm().hasFocusNodes, isTrue);
  }

  Future<void> focus(WidgetTester tester, String label) async {
    button(tester, label).requestFocus();
    await tester.pump();
    expect(button(tester, label).hasFocus, isTrue);
  }

  /// Presses Tab, with Shift when [backward]. Whether the key was "handled"
  /// says nothing here: Flutter's own traversal action handles a released
  /// Tab too, so the tests read focus state instead.
  Future<void> tab(WidgetTester tester, {bool backward = false}) async {
    if (backward) {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    if (backward) {
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    }
    await tester.pump();
  }

  Future<bool> press(
    WidgetTester tester,
    LogicalKeyboardKey key, {
    String? character,
  }) async {
    final handled = await tester.sendKeyEvent(key, character: character);
    await tester.pump();
    return handled;
  }

  /// Pumps until the graphic's ticker has stopped: the ring animation is
  /// over and nothing schedules frames any more.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 20 && painter!.isTickerActive; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(painter!.isTickerActive, isFalse);
  }

  String? lastPressed() =>
      sm().boundRuntimeViewModelInstance!.string('lastPressed')!.value;

  group('Tab traversal', () {
    // Forward from the button above, backward (Shift+Tab) from the one
    // below: each enters at its own end and leaves at the other.
    for (final (from, to, backward, further) in [
      ('before', 'after', false, greaterThan),
      ('after', 'before', true, lessThan),
    ]) {
      testWidgets('${backward ? 'Shift+Tab' : 'Tab'} enters from $from, walks '
          'the row, leaves to $to', (tester) async {
        await pumpArtboard(tester, 'Buttons');
        await focus(tester, from);
        expect(focusState().hasFocus, isFalse);

        await tab(tester, backward: backward);
        expect(riveHasFlutterFocus(), isTrue);
        expect(focusState().hasFocus, isTrue);
        var previous = focusedBounds();

        for (var i = 0; i < 3; i++) {
          await tab(tester, backward: backward);
          expect(riveHasFlutterFocus(), isTrue, reason: 'tab ${i + 2}');
          expect(
            focusedBounds().minX,
            further(previous.minX),
            reason: 'tab ${i + 2}',
          );
          previous = focusedBounds();
        }

        // Off the end: released to Flutter, which moves on.
        await tab(tester, backward: backward);
        expect(button(tester, to).hasFocus, isTrue);
        expect(focusState().hasFocus, isFalse);
      });
    }

    testWidgets(
      'leaving at the end processes the blur before Flutter moves on',
      (tester) async {
        await pumpArtboard(tester, 'Buttons');
        await focus(tester, 'before');
        for (var i = 0; i < 4; i++) {
          await tab(tester);
        }
        final lastFocused = sm().boundRuntimeViewModelInstance!
            .viewModel('p4')!
            .boolean('focused')!;
        expect(lastFocused.value, isTrue);

        // The blur listener has run by the time the release Tab returns, with
        // no frame in between: a settled graphic would not produce one.
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        expect(lastFocused.value, isFalse);
        await tester.pump();
        expect(button(tester, 'after').hasFocus, isTrue);
      },
    );

    testWidgets('wraps when nothing else can take focus', (tester) async {
      await pumpArtboard(tester, 'Buttons');
      button(tester, 'before').canRequestFocus = false;
      button(tester, 'after').canRequestFocus = false;
      await tester.tapAt(tester.getCenter(find.byType(rive.RiveFocusWidget)));
      await tester.pump();
      expect(riveHasFlutterFocus(), isTrue);

      for (var i = 0; i < 4; i++) {
        await tab(tester);
      }
      final last = focusedBounds();
      await tab(tester);
      expect(focusState().hasFocus, isFalse);
      // Flutter parks focus on a scope for a Tab or two before it comes
      // back round to the only focusable widget.
      for (var i = 0; i < 3 && !focusState().hasFocus; i++) {
        await tab(tester);
      }
      expect(focusState().hasFocus, isTrue);
      expect(focusedBounds().minX, lessThan(last.minX));
    });
  });

  group('Flutter focus leaving the widget', () {
    testWidgets('clears Rive focus', (tester) async {
      await pumpArtboard(tester, 'Buttons');
      await focus(tester, 'before');
      await tab(tester);
      expect(focusState().hasFocus, isTrue);

      await focus(tester, 'after');
      expect(focusState().hasFocus, isFalse);
    });

    testWidgets('unmounting clears Rive focus', (tester) async {
      await pumpArtboard(tester, 'Buttons');
      await focus(tester, 'before');
      await tab(tester);
      expect(focusState().hasFocus, isTrue);

      await tester.pumpWidget(const SizedBox());
      expect(focusState().hasFocus, isFalse);
    });
  });

  group('Pointer', () {
    testWidgets('a press focuses the widget without entering the tree', (
      tester,
    ) async {
      await pumpArtboard(tester, 'Buttons');
      await tester.tapAt(tester.getCenter(find.byType(rive.RiveFocusWidget)));
      await tester.pump();
      expect(riveHasFlutterFocus(), isTrue);
      expect(focusState().hasFocus, isFalse);

      await tab(tester);
      expect(focusState().hasFocus, isTrue);
    });

    testWidgets('a press on a TextInput keeps that node focused', (
      tester,
    ) async {
      await pumpArtboard(tester, 'TextInput');
      final widgetRect = tester.getRect(find.byType(rive.RiveFocusWidget));
      // The field spans x 32..432, y 136..184 in the 640*360 artboard.
      await tester.tapAt(widgetRect.topLeft + const Offset(200, 160));
      await tester.pump();
      expect(riveHasFlutterFocus(), isTrue);
      expect(focusState().hasFocus, isTrue);
      expect(sm().focusManager!.primaryFocusAcceptsText(), isTrue);
    });
  });

  group('Authored pointer focus', () {
    // PointerFocus: four TouchButtons whose press listener carries a
    // FocusActionTarget, over a background whose press clears focus. The
    // artboard mirrors Buttons: buttons at x 32..152, 168..288, 304..424,
    // 440..560, y 137..193.
    Future<void> pressAt(WidgetTester tester, Offset artboardPoint) async {
      final rect = tester.getRect(find.byType(rive.RiveFocusWidget));
      await tester.tapAt(rect.topLeft + artboardPoint);
      await tester.pump();
    }

    testWidgets('a press moves focus to the pressed button', (tester) async {
      await pumpArtboard(tester, 'PointerFocus');
      await focus(tester, 'before');
      await tab(tester);
      final first = focusedBounds();

      await pressAt(tester, const Offset(364, 165)); // button 3
      expect(riveHasFlutterFocus(), isTrue);
      expect(focusState().hasFocus, isTrue);
      expect(focusedBounds().minX, greaterThan(first.minX));
      expect(lastPressed(), '3');

      // Tab carries on from the pressed button.
      await tab(tester);
      expect(focusedBounds().minX, greaterThan(364));
    });

    testWidgets('a press on a settled graphic moves focus with no frame', (
      tester,
    ) async {
      await pumpArtboard(tester, 'PointerFocus');
      await focus(tester, 'before');
      await tab(tester);
      await settle(tester);

      final rect = tester.getRect(find.byType(rive.RiveFocusWidget));
      await tester.tapAt(rect.topLeft + const Offset(364, 165)); // button 3
      expect(focusedBounds().minX, closeTo(304, 1));
    });

    testWidgets('a press on the background clears focus', (tester) async {
      await pumpArtboard(tester, 'PointerFocus');
      await focus(tester, 'before');
      await tab(tester);
      expect(focusState().hasFocus, isTrue);

      await pressAt(tester, const Offset(320, 300));
      expect(focusState().hasFocus, isFalse);
      expect(riveHasFlutterFocus(), isTrue);

      // The next Tab enters again from the start.
      await tab(tester);
      expect(focusState().hasFocus, isTrue);
      expect(focusedBounds().minX, lessThan(100));
    });

    testWidgets('a press with no Flutter focus takes it and keeps the node', (
      tester,
    ) async {
      await pumpArtboard(tester, 'PointerFocus');
      await pressAt(tester, const Offset(228, 165)); // button 2
      expect(riveHasFlutterFocus(), isTrue);
      expect(focusState().hasFocus, isTrue);
      expect(focusedBounds().minX, closeTo(168, 1));
    });

    testWidgets('without authored pointer focus a press leaves focus alone', (
      tester,
    ) async {
      await pumpArtboard(tester, 'Buttons');
      await focus(tester, 'before');
      await tab(tester);
      final first = focusedBounds();

      await pressAt(tester, const Offset(364, 165)); // button 3
      expect(lastPressed(), '3');
      expect(focusedBounds(), first);
    });
  });

  group('Keys', () {
    testWidgets('Enter and Space reach the focused node', (tester) async {
      await pumpArtboard(tester, 'Buttons');
      await focus(tester, 'before');
      await tab(tester);
      expect(lastPressed(), '');

      // The listener claims the key, so Flutter is told it was handled and
      // the app around the graphic does not also act on it.
      expect(await press(tester, LogicalKeyboardKey.enter), isTrue);
      expect(lastPressed(), '1');
      await tab(tester);
      expect(await press(tester, LogicalKeyboardKey.space), isTrue);
      expect(lastPressed(), '2');
      // A key nothing listens for is released; focus stays put.
      expect(
        await press(tester, LogicalKeyboardKey.keyQ, character: 'q'),
        isFalse,
      );
      expect(focusState().hasFocus, isTrue);
    });

    testWidgets(
      'a key on a settled graphic applies its listener and restarts frames',
      (tester) async {
        await pumpArtboard(tester, 'Buttons');
        await focus(tester, 'before');
        await tab(tester);
        await settle(tester);
        expect(painter!.isTickerActive, isFalse);

        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        expect(lastPressed(), '1');
        expect(painter!.isTickerActive, isTrue);
      },
    );

    testWidgets('typing reaches a focused TextInput', (tester) async {
      await pumpArtboard(tester, 'TextInput');
      await focus(tester, 'before');
      await tab(tester);
      expect(focusState().expectsKeyboardInput, isTrue);
      expect(sm().focusManager!.primaryFocusAcceptsText(), isTrue);

      expect(
        await press(tester, LogicalKeyboardKey.keyH, character: 'h'),
        isTrue,
      );
      expect(
        await press(tester, LogicalKeyboardKey.keyI, character: 'i'),
        isTrue,
      );
      await tester.pump(const Duration(milliseconds: 16));
      expect(sm().boundRuntimeViewModelInstance!.string('text')!.value, 'hi');

      // A shortcut chord is not typing, even though macOS reports its
      // letter as the character.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await press(tester, LogicalKeyboardKey.keyC, character: 'c');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      expect(sm().boundRuntimeViewModelInstance!.string('text')!.value, 'hi');

      // AltGr is typing, not a chord: Windows reports it as Ctrl plus right
      // Alt, browsers as Ctrl plus AltGraph.
      // Only the web key map knows AltGraph, and no physical key maps to
      // it, so that event is sent as web on the right Alt key.
      for (final (altGr, platform) in [
        (LogicalKeyboardKey.altRight, null),
        (LogicalKeyboardKey.altGraph, 'web'),
      ]) {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyDownEvent(
          altGr,
          platform: platform,
          physicalKey: PhysicalKeyboardKey.altRight,
        );
        await press(tester, LogicalKeyboardKey.keyQ, character: '@');
        await tester.sendKeyUpEvent(
          altGr,
          platform: platform,
          physicalKey: PhysicalKeyboardKey.altRight,
        );
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      }
      await tester.pump(const Duration(milliseconds: 16));
      expect(sm().boundRuntimeViewModelInstance!.string('text')!.value, 'hi@@');

      // Ctrl with the left Alt is still a chord.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await press(tester, LogicalKeyboardKey.keyQ, character: '@');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      expect(sm().boundRuntimeViewModelInstance!.string('text')!.value, 'hi@@');

      await tab(tester);
      expect(sm().focusManager!.primaryFocusAcceptsText(), isFalse);
      await tab(tester, backward: true);
      expect(sm().focusManager!.primaryFocusAcceptsText(), isTrue);
    });
  });

  group('Scene claims Tab', () {
    testWidgets('entering still works, then the claim keeps focus put', (
      tester,
    ) async {
      await pumpArtboard(tester, 'ClaimsTab');
      await focus(tester, 'before');

      // Nothing is focused yet, so nothing can claim: Tab enters as usual.
      await tab(tester);
      expect(focusState().hasFocus, isTrue);
      expect(lastPressed(), '');
      final trap = focusedBounds();

      // The trap asked for Tab, so the press is the scene's: focus stays and
      // the listener fires instead of traversal moving on to After.
      await tab(tester);
      expect(lastPressed(), 'tab');
      expect(riveHasFlutterFocus(), isTrue);
      expect(focusedBounds(), trap);

      // Shift+Tab is claimed the same way.
      await tab(tester, backward: true);
      expect(riveHasFlutterFocus(), isTrue);
      expect(focusedBounds(), trap);

      // Only Tab is claimed: the arrows still move, and the button they
      // reach reports its own press rather than leaving 'tab' standing.
      expect(await press(tester, LogicalKeyboardKey.arrowDown), isTrue);
      expect(focusedBounds(), isNot(trap));
      await press(tester, LogicalKeyboardKey.enter);
      expect(lastPressed(), 'After');
    });

    testWidgets('a key the scene does not ask for still traverses', (
      tester,
    ) async {
      await pumpArtboard(tester, 'Buttons');
      await focus(tester, 'before');
      await tab(tester);
      final first = focusedBounds();
      await tab(tester);
      expect(focusedBounds(), isNot(first));
      expect(lastPressed(), '');
    });
  });

  group('Arrows', () {
    testWidgets('move by position and hand off to Flutter at an edge', (
      tester,
    ) async {
      await pumpArtboard(tester, 'Grid');
      await focus(tester, 'before');
      await tab(tester);
      final one = focusedBounds();

      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(focusedBounds().minX, greaterThan(one.minX));
      expect(focusedBounds().minY, one.minY);

      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focusedBounds().minY, greaterThan(one.minY));

      await press(tester, LogicalKeyboardKey.arrowLeft);
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(focusedBounds(), one);
      expect(riveHasFlutterFocus(), isTrue);

      // No node above 1: the key is released. On desktop Flutter's
      // directional traversal takes it and moves focus to the button above
      // the graphic; on the web Flutter binds arrows to scrolling instead,
      // so focus stays where it is.
      await press(tester, LogicalKeyboardKey.arrowUp);
      if (kIsWeb) {
        expect(riveHasFlutterFocus(), isTrue);
        expect(focusedBounds(), one);
      } else {
        expect(button(tester, 'before').hasFocus, isTrue);
        expect(focusState().hasFocus, isFalse);
      }
    });

    testWidgets('do nothing before a node is focused', (tester) async {
      await pumpArtboard(tester, 'Grid');
      await tester.tapAt(tester.getCenter(find.byType(rive.RiveFocusWidget)));
      await tester.pump();
      expect(riveHasFlutterFocus(), isTrue);
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(focusState().hasFocus, isFalse);
    });
  });

  group('Scopes', () {
    for (final (name, stops) in [
      // A group with a FocusData is a stop in its own right, visited before
      // its children, and its flags speak only for itself (core #14261).
      ('EdgeParentScope', 6),
      ('NoTraverse', 4),
      ('Nested', 7),
      ('Grid', 9),
      ('ScrollList', 12),
    ]) {
      testWidgets('$name has $stops tab stops', (tester) async {
        await pumpArtboard(tester, name);
        await focus(tester, 'before');
        for (var i = 0; i < stops; i++) {
          await tab(tester);
          expect(riveHasFlutterFocus(), isTrue, reason: 'stop ${i + 1}');
          expect(focusState().hasFocus, isTrue, reason: 'stop ${i + 1}');
        }
        await tab(tester);
        expect(button(tester, 'after').hasFocus, isTrue);
      });
    }

    for (final name in ['EdgeClosedLoop', 'EdgeStop']) {
      testWidgets('$name keeps focus inside the scope', (tester) async {
        await pumpArtboard(tester, name);
        await focus(tester, 'before');
        await tab(tester); // Before
        await tab(tester); // 1
        for (var i = 0; i < 6; i++) {
          await tab(tester);
          expect(riveHasFlutterFocus(), isTrue, reason: 'tab ${i + 3}');
          expect(focusState().hasFocus, isTrue, reason: 'tab ${i + 3}');
        }
        // Released only by moving Flutter focus elsewhere.
        await focus(tester, 'after');
        expect(focusState().hasFocus, isFalse);
      });
    }

    testWidgets('a scroll view keeps the focused item in view', (tester) async {
      await pumpArtboard(tester, 'ScrollList');
      await focus(tester, 'before');
      for (var i = 0; i < 10; i++) {
        await tab(tester);
      }
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(focusedBounds().maxY, lessThanOrEqualTo(360));
    });
  });

  testWidgets('adds no semantics node of its own', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpArtboard(tester, 'Buttons');
    await focus(tester, 'before');
    await tab(tester);
    expect(riveHasFlutterFocus(), isTrue);

    final focusable = <SemanticsNode>[];
    void visit(SemanticsNode node) {
      if (node.flagsCollection.isFocused != Tristate.none) focusable.add(node);
      node.visitChildren((child) {
        visit(child);
        return true;
      });
    }

    var root = tester.getSemantics(find.byType(Scaffold));
    while (root.parent != null) {
      root = root.parent!;
    }
    visit(root);
    // Only the two Flutter buttons; the Rive widget, though focused, exposes
    // nothing (semantics are RiveSemanticsWidget's job, when enabled).
    expect(focusable.map((n) => n.label), unorderedEquals(['before', 'after']));
    expect(
      focusable.where((n) => n.flagsCollection.isFocused == Tristate.isTrue),
      isEmpty,
    );
    handle.dispose();
  });

  testWidgets('content whose focus nodes cannot be entered is passed over', (
    tester,
  ) async {
    await pumpArtboard(tester, 'NoStops');
    expect(sm().hasFocusNodes, isTrue);

    await focus(tester, 'before');
    await tab(tester);
    expect(button(tester, 'after').hasFocus, isTrue);
    expect(focusState().hasFocus, isFalse);

    await tab(tester, backward: true);
    expect(button(tester, 'before').hasFocus, isTrue);
  });

  testWidgets('a settled graphic re-reads nothing per frame', (tester) async {
    await pumpArtboard(tester, 'Buttons');
    await focus(tester, 'before');
    await tab(tester);
    // While the ring animates, every frame re-reads the focus tree.
    final ticking = rive.RiveFocusWidget.debugSyncCount;
    await tester.pump(const Duration(milliseconds: 16));
    expect(rive.RiveFocusWidget.debugSyncCount, greaterThan(ticking));

    await settle(tester);
    // Frames produced by anything else on the page cost this widget nothing.
    final settled = rive.RiveFocusWidget.debugSyncCount;
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(rive.RiveFocusWidget.debugSyncCount, settled);

    // A key restarts frames, and with them the check.
    await press(tester, LogicalKeyboardKey.enter);
    expect(rive.RiveFocusWidget.debugSyncCount, greaterThan(settled));
  });

  testWidgets('content without focus nodes is not a tab stop', (tester) async {
    final plainFile = (await rive.File.decode(
      loadFile('assets/electrified_button_simple.riv'),
      riveFactory: rive.Factory.flutter,
    ))!;
    artboard = plainFile.defaultArtboard()!;
    painter = rive.StateMachinePainter();
    addTearDown(() {
      painter?.dispose();
      painter = null;
      artboard?.dispose();
      artboard = null;
      plainFile.dispose();
    });
    await tester.pumpWidget(_Harness(artboard: artboard!, painter: painter!));
    await tester.pump();
    expect(sm().hasFocusNodes, isFalse);

    await focus(tester, 'before');
    await tab(tester);
    expect(button(tester, 'after').hasFocus, isTrue);
  });
}
