
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rive_native/src/ffi/rive_semantic_ffi.dart';

/// The semantics diff decoder must never throw on malformed UTF-8 in a
/// label/value/hint: by drain time the native dirty state is already
/// cleared, so an aborted decode would lose the update permanently.
/// (The strict decoder used previously threw FormatException.)
void main() {
  Pointer<Utf8> allocBytes(List<int> bytes) {
    final ptr = malloc.allocate<Uint8>(bytes.length + 1);
    ptr.asTypedList(bytes.length + 1)
      ..setAll(0, bytes)
      ..[bytes.length] = 0;
    return ptr.cast<Utf8>();
  }

  test('malformed UTF-8 decodes leniently instead of throwing', () {
    // 'Hi' followed by a truncated 2-byte sequence (0xC3 with no valid
    // continuation) and a stray continuation byte.
    final ptr = allocBytes([0x48, 0x69, 0xC3, 0x28, 0x80]);
    try {
      final decoded = SemanticsFFI.decodeUtf8(ptr);
      expect(decoded, startsWith('Hi'));
      expect(decoded, contains('\u{FFFD}'),
          reason: 'malformed bytes must become replacement characters');
    } finally {
      malloc.free(ptr);
    }
  });

  test('valid UTF-8 decodes unchanged', () {
    final ptr = allocBytes(const [
      0x42, 0x6F, 0x75, 0x74, 0x6F, 0x6E, 0x20, // 'Bouton '
      0xC3, 0xA9, 0x20, // 'é '
      0xF0, 0x9F, 0x8E, 0xA8, // U+1F3A8
    ]);
    try {
      expect(SemanticsFFI.decodeUtf8(ptr), 'Bouton é \u{1F3A8}');
    } finally {
      malloc.free(ptr);
    }
  });

  test('null and empty pointers decode to the empty string', () {
    expect(SemanticsFFI.decodeUtf8(nullptr), '');
    final ptr = allocBytes(const []);
    try {
      expect(SemanticsFFI.decodeUtf8(ptr), '');
    } finally {
      malloc.free(ptr);
    }
  });
}
