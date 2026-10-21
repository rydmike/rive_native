import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:rive_native/math.dart';
import 'package:rive_native/rive_native.dart';
import 'package:rive_native/src/buffered_render_paint.dart';
import 'package:rive_native/src/paint_dirt.dart';

/// One flush of the paint buffer: the flags native would receive and the bytes
/// that accompany them.
class _Chunk {
  _Chunk(this.dirty, this.stops, this.bytes);
  final int dirty;
  final int stops;
  final Uint8List bytes;
}

/// Mirrors the native scratch buffer so we can assert what updatePaint sends.
class _TestPaint extends BufferedRenderPaint {
  static const int bufferSize = 1024;
  final ByteData _buffer = ByteData(bufferSize);
  final List<_Chunk> chunks = [];

  @override
  ByteData get scratchBufferByteData => _buffer;

  @override
  void updatePaint(int dirty, int wroteStops) {
    chunks.add(_Chunk(dirty, wroteStops,
        Uint8List.fromList(_buffer.buffer.asUint8List(0, bufferSize))));
  }

  @override
  void dispose() {}
}

void main() {
  group('BufferedRenderPaint trailing fields', () {
    /// A gradient with enough stops to fill the scratch buffer, forcing the
    /// stop loop to flush at least one intermediate chunk.
    RenderLinearGradient bigGradient(int count) => RenderLinearGradient(
          Vec2D.fromValues(0, 0),
          Vec2D.fromValues(1, 1),
          List<ui.Color>.generate(count, (i) => const ui.Color(0xFF00FF00)),
          List<double>.generate(count, (i) => i / count),
        );

    test('a huge gradient never writes past the scratch buffer', () {
      // Regression: the stop loop reserved only the 16 byte terminator, so the
      // fields written after it ran off the end of the 1024 byte buffer.
      for (final count in [120, 124, 125, 126, 127, 128, 200]) {
        final paint = _TestPaint()
          ..feather = 4
          ..additiveness = 0.5
          ..gradient = bigGradient(count);
        expect(paint.update, returnsNormally,
            reason: '$count stops overflowed the buffer');
      }
    });

    test('an intermediate chunk does not claim trailing fields it lacks', () {
      // Native reads one float per trailing flag. If an intermediate chunk
      // advertises feather/additiveness without writing them, it consumes
      // gradient stop bytes as floats and the real values are lost.
      final paint = _TestPaint()
        ..feather = 4
        ..additiveness = 0.5
        ..gradient = bigGradient(200);
      paint.update();

      expect(paint.chunks.length, greaterThan(1),
          reason: 'this gradient should need more than one chunk');
      const trailing = PaintDirt.feather | PaintDirt.additiveness;
      for (final chunk in paint.chunks.take(paint.chunks.length - 1)) {
        expect(chunk.dirty & trailing, 0,
            reason: 'an intermediate chunk advertised a trailing field');
      }
      // ...and the final chunk still carries both, so nothing is dropped.
      expect(paint.chunks.last.dirty & PaintDirt.feather,
          PaintDirt.feather);
      expect(paint.chunks.last.dirty & PaintDirt.additiveness,
          PaintDirt.additiveness);
    });

    test('a single chunk still carries the trailing fields', () {
      final paint = _TestPaint()
        ..feather = 4
        ..additiveness = 0.5;
      paint.update();
      expect(paint.chunks.length, 1);
      expect(paint.chunks.single.dirty & PaintDirt.feather, PaintDirt.feather);
      expect(paint.chunks.single.dirty & PaintDirt.additiveness,
          PaintDirt.additiveness);
    });
  });
}
