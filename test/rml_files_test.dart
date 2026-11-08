import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rive_native/rive_markup.dart';

void main() {
  group('encodeRmlFileInputs', () {
    test('writes count, path, flags and bytes', () {
      final bundle = encodeRmlFileInputs([
        RmlFileInput('a.luau', Uint8List.fromList([1, 2, 3])),
        const RmlFileInput.withheld('b.png'),
      ]);

      expect(bundle, [
        2, // count
        6, ...utf8.encode('a.luau'), 0, 3, 1, 2, 3,
        5, ...utf8.encode('b.png'), 1, 0,
      ]);
    });

    test('an empty list is a count of zero', () {
      expect(encodeRmlFileInputs(const []), [0]);
    });

    test('a length past one byte takes a continuation byte', () {
      final bytes = Uint8List(200);
      final bundle = encodeRmlFileInputs([RmlFileInput('f', bytes)]);
      // 200 = 0xC8 -> 0xC8, 0x01
      expect(bundle.sublist(0, 6), [1, 1, 102, 0, 0xC8, 1]);
    });
  });

  group('decodeRmlExportedFiles', () {
    // The same wire format the native side writes: flags bit 0 marks a file
    // whose bytes were omitted.
    test('round trips text, empty and omitted entries', () {
      final bundle = encodeRmlFileInputs([
        RmlFileInput('scripts/mover.luau', Uint8List.fromList([114, 101])),
        RmlFileInput('empty.txt', Uint8List(0)),
        const RmlFileInput.withheld('assets/logo.png'),
        RmlFileInput('big.bin', Uint8List.fromList(List.filled(300, 7))),
      ]);
      final files = decodeRmlExportedFiles(bundle);

      expect(files.map((file) => file.path), [
        'scripts/mover.luau',
        'empty.txt',
        'assets/logo.png',
        'big.bin',
      ]);
      expect(files[0].bytes, [114, 101]);
      expect(files[0].bytesOmitted, isFalse);
      expect(files[1].bytes, isEmpty);
      expect(files[1].bytesOmitted, isFalse);
      expect(files[2].bytes, isEmpty);
      expect(files[2].bytesOmitted, isTrue);
      expect(files[3].bytes, hasLength(300));
    });

    test('keeps non-ascii paths', () {
      final bundle = encodeRmlFileInputs([
        RmlFileInput('fonts/Noto Sans/日本語.ttf', Uint8List(1)),
      ]);
      expect(
        decodeRmlExportedFiles(bundle).single.path,
        'fonts/Noto Sans/日本語.ttf',
      );
    });

    test('an empty buffer holds no files', () {
      expect(decodeRmlExportedFiles(Uint8List(0)), isEmpty);
    });

    test('a bundle that ends early throws', () {
      final bundle = encodeRmlFileInputs([
        RmlFileInput('a.luau', Uint8List.fromList([1, 2, 3])),
      ]);
      expect(
        () => decodeRmlExportedFiles(
          Uint8List.sublistView(bundle, 0, bundle.length - 1),
        ),
        throwsFormatException,
      );
      expect(
        () => decodeRmlExportedFiles(Uint8List.fromList([1, 5, 65])),
        throwsFormatException,
      );
    });

    test('a count above the files present throws', () {
      final bundle = encodeRmlFileInputs([
        RmlFileInput('a.luau', Uint8List.fromList([1])),
      ]);
      bundle[0] = 2;
      expect(() => decodeRmlExportedFiles(bundle), throwsFormatException);
    });

    test('bytes past the last file throw', () {
      final bundle = encodeRmlFileInputs([
        RmlFileInput('a.luau', Uint8List.fromList([1])),
      ]);
      expect(
        () => decodeRmlExportedFiles(Uint8List.fromList([...bundle, 0])),
        throwsFormatException,
      );
      expect(
        () => decodeRmlExportedFiles(Uint8List.fromList([0, 7, 7])),
        throwsFormatException,
      );
    });
  });

  group('RmlFileReference.listFromJson', () {
    test('reads id, path and line', () {
      final references = RmlFileReference.listFromJson(
        '[{"id":"1:22","path":"assets/logo.png","line":5}]',
      );
      expect(references.single.id, '1:22');
      expect(references.single.path, 'assets/logo.png');
      expect(references.single.line, 5);
    });

    test('text that is not the expected shape yields none', () {
      expect(RmlFileReference.listFromJson('nope'), isEmpty);
      expect(RmlFileReference.listFromJson('{}'), isEmpty);
    });
  });
}
