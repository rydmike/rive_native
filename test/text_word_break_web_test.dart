@TestOn('browser')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:rive_native/rive_native.dart' as rive;
import 'package:rive_native/rive_text.dart';

import 'src/utils.dart';

/// The web backend reaches breakLines by a different route than FFI does:
/// callAsFunction tops out at four arguments, so rive_text_web.dart passes the
/// fifth -- the word break mode -- through callMethodVarArgs instead, and
/// init.js re-wraps the wasm export to match. Neither of those is exercised by
/// the dart:io tests, so this pins that the mode actually survives the trip.
void main() {
  late Font font;

  setUpAll(() async {
    await rive.RiveNative.init();
    font = Font.decode(loadFile('assets/fonts/Inter-594377.ttf'))!;
  });

  tearDownAll(() => font.dispose());

  /// Lines the breaker produces for [text] at [width] in [mode].
  int lineCount(String text, double width, TextWordBreak mode) {
    final runs = [
      TextRun(
        font: font,
        fontSize: 24,
        unicharCount: text.runes.length,
        styleId: 0,
      )
    ];
    final shape = font.shape(text, runs);
    try {
      final lines =
          shape.breakLines(width, TextAlign.left, TextWrap.wrap, mode);
      var count = 0;
      for (final paragraph in lines) {
        count += paragraph.length;
      }
      return count;
    } finally {
      shape.dispose();
    }
  }

  test('the word break mode survives the wasm boundary', () {
    // One long word with no break opportunity in it, narrower box than the
    // word, so the three modes cannot agree.
    const text = 'Ag Unbreakablelongword';

    final normal = lineCount(text, 140, TextWordBreak.normal);
    final breakWord = lineCount(text, 140, TextWordBreak.breakWord);

    // normal never cuts the long word, so it needs strictly fewer lines. If
    // the fifth argument were dropped on the way through, every mode would
    // come back as the breakWord default and these would be equal.
    expect(normal, lessThan(breakWord));
  });

  test('breakAll packs lines the historical mode would not', () {
    const text = 'Ag Unbreakablelongword';

    final breakAll = lineCount(text, 200, TextWordBreak.breakAll);
    final breakWord = lineCount(text, 200, TextWordBreak.breakWord);

    // breakAll starts cutting the long word on the line the short one is
    // already on, where breakWord moves it down first.
    expect(breakAll, lessThan(breakWord));
  });

  test('the default matches the historical mode', () {
    const text = 'Ag Unbreakablelongword';

    final shape = font.shape(text, [
      TextRun(
        font: font,
        fontSize: 24,
        unicharCount: text.runes.length,
        styleId: 0,
      )
    ]);
    try {
      final byDefault = shape.breakLines(140, TextAlign.left, TextWrap.wrap);
      var count = 0;
      for (final paragraph in byDefault) {
        count += paragraph.length;
      }
      expect(count, lineCount(text, 140, TextWordBreak.breakWord));
    } finally {
      shape.dispose();
    }
  });
}
