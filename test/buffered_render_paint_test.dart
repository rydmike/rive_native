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
  group('BufferedRenderPaint fixed fields', () {
    /// A gradient with enough stops to fill the scratch buffer, forcing the
    /// stop loop to flush at least one intermediate chunk.
    RenderLinearGradient bigGradient(int count) => RenderLinearGradient(
          Vec2D.fromValues(0, 0),
          Vec2D.fromValues(1, 1),
          List<ui.Color>.generate(count, (i) => const ui.Color(0xFF00FF00)),
          List<double>.generate(count, (i) => i / count),
        );

    const fixedFields = PaintDirt.gradientTransform |
        PaintDirt.feather |
        PaintDirt.additiveness;

    test('a huge gradient never writes past the scratch buffer', () {
      // The stop loop has to leave room for the fields written ahead of the
      // stops, or a gradient that fills the buffer runs off its end.
      for (final count in [120, 124, 125, 126, 127, 128, 200]) {
        final paint = _TestPaint()
          ..gradientTransform = Mat2D.fromTranslate(3, 7)
          ..feather = 4
          ..additiveness = 0.5
          ..gradient = bigGradient(count);
        expect(paint.update, returnsNormally,
            reason: '$count stops overflowed the buffer');
      }
    });

    test('only the first chunk carries the fields written before the stops',
        () {
      // Native reads the fields each flag advertises before it reads stops. A
      // chunk that advertises a field it doesn't hold makes native consume
      // stop bytes as that field.
      final paint = _TestPaint()
        ..gradientTransform = Mat2D.fromTranslate(3, 7)
        ..feather = 4
        ..additiveness = 0.5
        ..gradient = bigGradient(200);
      paint.update();

      expect(paint.chunks.length, greaterThan(1),
          reason: 'this gradient should need more than one chunk');

      final first = paint.chunks.first;
      expect(first.dirty & fixedFields, fixedFields);
      // Laid out in the order native reads them.
      final view = ByteData.sublistView(first.bytes);
      final transform = [1.0, 0.0, 0.0, 1.0, 3.0, 7.0];
      for (int i = 0; i < 6; i++) {
        expect(view.getFloat32(i * 4, Endian.little), transform[i]);
      }
      expect(view.getFloat32(24, Endian.little), 4);
      expect(view.getFloat32(28, Endian.little), 0.5);

      for (final chunk in paint.chunks.skip(1)) {
        expect(chunk.dirty & fixedFields, 0,
            reason: 'a later chunk advertised a field it does not hold');
      }
    });

    test('a single chunk still carries the fields', () {
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

  group('BufferedRenderPaint stroke position', () {
    test('setting the default position sends nothing', () {
      final paint = _TestPaint()..strokePosition = StrokePosition.center;
      paint.update();
      expect(paint.chunks, isEmpty);
    });

    test('position is a byte right after blendMode', () {
      // Native reads style, color, thickness, join, cap, blendMode and then
      // the position, so it has to land in that slot.
      final paint = _TestPaint()
        ..style = PaintingStyle.stroke
        ..blendMode = ui.BlendMode.multiply
        ..strokePosition = StrokePosition.outside;
      paint.update();

      final chunk = paint.chunks.single;
      expect(chunk.dirty & PaintDirt.strokePosition, PaintDirt.strokePosition);
      expect(chunk.bytes[0], PaintingStyle.stroke.index);
      expect(chunk.bytes[1], ui.BlendMode.multiply.index);
      expect(chunk.bytes[2], StrokePosition.outside.index);
    });

    test('position rides the first chunk of a large gradient only', () {
      final paint = _TestPaint()
        ..strokePosition = StrokePosition.inside
        ..gradient = RenderLinearGradient(
          Vec2D.fromValues(0, 0),
          Vec2D.fromValues(1, 1),
          List<ui.Color>.generate(200, (i) => const ui.Color(0xFF00FF00)),
          List<double>.generate(200, (i) => i / 200),
        );
      paint.update();

      expect(paint.chunks.length, greaterThan(1));
      expect(paint.chunks.first.dirty & PaintDirt.strokePosition,
          PaintDirt.strokePosition);
      expect(paint.chunks.first.bytes[0], StrokePosition.inside.index);
      for (final chunk in paint.chunks.skip(1)) {
        expect(chunk.dirty & PaintDirt.strokePosition, 0,
            reason: 'a later chunk would make native read a stop byte as '
                'the position');
      }
    });
  });

  group('angular gradients on the wire', () {
    final start = Vec2D.fromValues(3, 5);
    final end = Vec2D.fromValues(11, 17);

    List<ui.Color> colors(int count) =>
        List<ui.Color>.generate(count, (i) => const ui.Color(0xFF00FF00));
    List<double> stops(int count) =>
        List<double>.generate(count, (i) => i / count);

    test('an angular gradient claims its own flag, not radial', () {
      final paint = _TestPaint()
        ..gradient = RenderAngularGradient(start, end, colors(2), stops(2));
      paint.update();

      final chunk = paint.chunks.single;
      expect(chunk.dirty & PaintDirt.angular, PaintDirt.angular);
      expect(chunk.dirty & PaintDirt.radial, 0,
          reason: 'angular overrides radial; both set would read as a radius');
      expect(chunk.dirty & PaintDirt.done, PaintDirt.done);
      expect(chunk.stops, 2);
    });

    test('its payload is the linear one, byte for byte', () {
      // Native reads the same four floats either way and tells them apart by
      // the flag alone, so a drift here is a drift in the format.
      final angular = _TestPaint()
        ..gradient = RenderAngularGradient(start, end, colors(3), stops(3));
      angular.update();
      final linear = _TestPaint()
        ..gradient = RenderLinearGradient(start, end, colors(3), stops(3));
      linear.update();

      expect(angular.chunks.single.bytes, linear.chunks.single.bytes);
      expect(angular.chunks.single.stops, linear.chunks.single.stops);
      expect(linear.chunks.single.dirty & PaintDirt.angular, 0);
    });

    test('the flag rides every chunk of a large gradient', () {
      // The flags reset on each flush, so a sweep whose stops span several
      // chunks has to say so again each time or native reads the rest as
      // linear.
      final paint = _TestPaint()
        ..gradient = RenderAngularGradient(start, end, colors(200), stops(200));
      paint.update();

      expect(paint.chunks.length, greaterThan(1),
          reason: 'this gradient should need more than one chunk');
      for (final chunk in paint.chunks) {
        expect(chunk.dirty & PaintDirt.angular, PaintDirt.angular);
      }
    });
  });
}
