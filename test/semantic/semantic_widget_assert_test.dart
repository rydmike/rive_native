import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rive_native/rive_native.dart' as rive;

import '../src/utils.dart';

/// RiveSemanticsWidget requires a painter that mixes in RiveSemanticsMixin;
/// anything else silently produced no semantics. Debug builds now assert.
void main() {
  testWidgets('a painter without RiveSemanticsMixin asserts in debug mode',
      (tester) async {
    final bytes = loadFile('assets/semantic/tabtest.riv');
    final file =
        await rive.File.decode(bytes, riveFactory: rive.Factory.flutter);
    final artboard = file!.defaultArtboard()!;

    // BasicArtboardPainter does not mix in RiveSemanticsMixin.
    final painter = rive.BasicArtboardPainter();

    await tester.pumpWidget(
      MaterialApp(
        home: rive.RiveSemanticsWidget(
          artboard: artboard,
          painter: painter,
          child: const SizedBox.expand(),
        ),
      ),
    );

    expect(tester.takeException(), isA<AssertionError>(),
        reason: 'a semantics widget over a painter that cannot produce '
            'semantics is a silent no-op without the assert');

    painter.dispose();
    artboard.dispose();
    file.dispose();
  });
}
