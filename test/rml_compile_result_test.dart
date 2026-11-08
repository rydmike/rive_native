import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rive_native/rive_markup.dart';

void main() {
  group('RmlCompileError.listFromJson', () {
    test('reads line, message and id', () {
      final errors = RmlCompileError.listFromJson(
        '[{"line": 3, "message": "bad attribute", "id": "0:5"}]',
      );
      expect(errors, hasLength(1));
      expect(errors.single.line, 3);
      expect(errors.single.message, 'bad attribute');
      expect(errors.single.id, '0:5');
    });

    test('maps an empty id to null', () {
      final errors = RmlCompileError.listFromJson(
        '[{"line": 1, "message": "no id here", "id": ""}]',
      );
      expect(errors.single.id, isNull);
    });

    test('turns text that is not JSON into one error', () {
      final errors = RmlCompileError.listFromJson('not json at all');
      expect(errors, hasLength(1));
      expect(errors.single.line, 0);
      expect(errors.single.message, 'not json at all');
    });

    test('turns a JSON array of the wrong shape into one error', () {
      final errors = RmlCompileError.listFromJson('[1]');
      expect(errors, hasLength(1));
      expect(errors.single.line, 0);
      expect(errors.single.message, '[1]');
    });

    test('turns a JSON entry missing "line" into one error', () {
      final errors =
          RmlCompileError.listFromJson('[{"message": "no line here"}]');
      expect(errors, hasLength(1));
      expect(errors.single.line, 0);
      expect(errors.single.message, '[{"message": "no line here"}]');
    });
  });

  group('RmlCompileResult.error', () {
    test('lists each error as line: message', () {
      const result = RmlCompileResult.failure([
        RmlCompileError(line: 3, message: 'first'),
        RmlCompileError(line: 7, message: 'second'),
      ]);
      expect(result.error, '3: first\n7: second\n');
    });

    test('is null on success', () {
      final result = RmlCompileResult.success(Uint8List(0));
      expect(result.error, isNull);
    });
  });
}
