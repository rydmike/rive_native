import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rive_native/utilities.dart';

void main() {
  test('writer preserves content across many growth reallocations', () {
    final writer = BinaryWriter(alignment: 16);
    final expected = BytesBuilder();
    for (var i = 0; i < 200000; i++) {
      writer.writeUint8(i & 0xff);
      expected.addByte(i & 0xff);
      if (i % 7 == 0) {
        writer.writeUint32(i);
        expected.add(
          Uint8List(4)..buffer.asByteData().setUint32(0, i, Endian.little),
        );
      }
    }
    final bytes = expected.takeBytes();
    expect(writer.size, bytes.length);
    expect(writer.uint8Buffer, bytes);
  });
}
