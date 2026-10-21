import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rive_native/rive_markup.dart';

import 'src/utils.dart';

void main() {
  if (!markupAvailable) {
    // flutter_runtime builds exclude the rml symbols (editor-only), and on
    // the web the editor bindings are only linked when RIVE_ENVIRONMENT is
    // not 'runtime' — which is the default this suite runs under. Nothing to
    // test there.
    return;
  }

  test('rev bytes convert to the markup the generator produces', () {
    final rml = revToRml(loadFile('assets/markup/rectangle.rev'));

    expect(rml, isNotNull);
    expect(
      utf8.decode(rml!),
      utf8.decode(loadFile('assets/markup/rectangle.rml')),
    );
  });

  test('bytes that are not a rev convert to null', () {
    expect(revToRml(Uint8List.fromList([1, 2, 3, 4])), isNull);
    expect(revToRml(Uint8List(0)), isNull);
    // A supported version byte and nothing else: the header reads run off the
    // end rather than failing outright.
    for (final version in [4, 5, 6]) {
      expect(revToRml(Uint8List.fromList([version])), isNull);
    }
  });

  test('a rev claiming more objects than it holds converts to null', () {
    // A well-formed v6 header -- version, ids, the ART extension -- followed
    // by an object count of 2^40. The objects are not there, so the count is
    // only a loop bound: reading past the end yields zeroes rather than
    // stopping, and the parse has to notice that itself.
    final bytes = Uint8List.fromList([
      6, // version
      1, 1, 1, // nextClientId, fileId, serverChangeId
      0x41, 0x52, 0x54, // "ART"
      0x80, 0x80, 0x80, 0x80, 0x80, 0x20, // object count: 2^40
    ]);
    expect(revToRml(bytes), isNull);
  });

  test('markup compiles to a rev that converts back to the same markup', () {
    // Not a byte comparison against rectangle.rev: that file came out of the
    // editor, and the compiler lays a rev out its own way. What has to hold is
    // that the compile loses nothing -- the rev it produces carries the whole
    // document back.
    final markup = loadFile('assets/markup/rectangle.rml');
    final compiled = rmlToRev(markup);

    expect(compiled.error, isNull);
    expect(compiled.bytes, isNotNull);
    expect(utf8.decode(revToRml(compiled.bytes!)!), utf8.decode(markup));
  });

  test('the same markup always compiles to the same bytes', () {
    // The editor compiles its bundled TextInput library on every launch and
    // holds committed attributes captured from one such compile, so the
    // compile has to be a function of the document and nothing else.
    final markup = loadFile('assets/markup/rectangle.rml');
    expect(rmlToRev(markup).bytes, rmlToRev(markup).bytes);
  });

  test('markup that is not markup compiles to an error, not to bytes', () {
    for (final source in <Uint8List>[
      Uint8List(0),
      Uint8List.fromList(utf8.encode('not markup')),
      Uint8List.fromList(utf8.encode('<Artboard name="unclosed">')),
      // A rev fed in the wrong direction.
      loadFile('assets/markup/rectangle.rev'),
    ]) {
      final compiled = rmlToRev(source);
      expect(compiled.bytes, isNull, reason: 'compiled ${source.length} bytes');
      expect(compiled.error, isNotNull);
      expect(compiled.error, isNotEmpty);
    }
  });

  test('markup referencing a file it cannot embed is an error, not a '
      'quietly smaller rev', () {
    // rml answers an unreadable file= with "this asset has no contents" and
    // still writes a successful rev -- 63 bytes here, against the ~876KB the
    // font would have made. This binding has no directory to resolve file=
    // against, so it has to turn that miss into a failure rather than hand
    // back the stub.
    const markup =
        '<Artboard name="Art" width="100" height="100" id="1:1"/>\n'
        '<FontAsset file="Inter.ttf" isCustom="false" assetId="102112" '
        'name="Inter" id="1:10"/>\n';
    final compiled = rmlToRev(Uint8List.fromList(utf8.encode(markup)));

    expect(compiled.bytes, isNull);
    expect(compiled.error, contains('Inter.ttf'));
  });

  test('a truncated rev converts to null, not to partial markup', () {
    // Reading past the end yields zeros instead of stopping, so a short rev
    // parses into whatever objects fit. Returning that markup would hand the
    // caller a document that looks whole and is not.
    final full = loadFile('assets/markup/rectangle.rev');
    for (final percent in [30, 50, 70, 90, 99]) {
      final truncated = Uint8List.sublistView(
        full,
        0,
        full.length * percent ~/ 100,
      );
      expect(revToRml(truncated), isNull, reason: 'truncated at $percent%');
    }
  });
}
