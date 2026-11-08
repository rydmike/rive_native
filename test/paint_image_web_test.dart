@TestOn('browser')
// Draws real content through WebGL, so the publishing CI runner skips it with
// the rest of this tag (see rive_renderer_web_smoke_test.dart).
@Tags(['webgl_content'])
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rive_native/math.dart';
import 'package:rive_native/rive_native.dart' as rive;

import 'src/render_texture_probe.dart';
import 'src/utils.dart';

// referenced-image-2929282.png: white text on a dark gray field.
const _imageWidth = 460.0;
const _imageHeight = 158.0;

// Points on the image's dark field, away from the text, in its 0..1 space. A
// dropped image draws the fill's own white there instead.
const _darkField = [(0.05, 0.1), (0.95, 0.1), (0.05, 0.9), (0.5, 0.9)];

/// A path filled with a paint modulated by a decoded image asset, on web. The
/// deferred replay decodes images as WebGL2RenderImages, which only become
/// drawable once prepped for the replaying context, and the browser decodes
/// them asynchronously.
void main() {
  testWidgets('a paint modulated by a decoded image draws the image',
      (tester) async {
    final painter = await _hostPainter(tester);

    // The reference: drawImage, which the renderer already preps. Wait for
    // the decode to land before the paint takes the image.
    painter.mode = _Mode.drawImage;
    final reference = await _repaintUntilDecoded(tester, painter, (0.05, 0.1));

    // The paint took the image as is and dropped it, so the fill drew white.
    painter.mode = _Mode.paintImage;
    final painted = await _repaint(tester, painter);

    for (final (u, v) in _darkField) {
      _expectSame(painted.rgbaAt(u, v), reference.rgbaAt(u, v),
          'paint image vs drawImage at ($u, $v)');
    }
  });

  testWidgets('a paint set before its image decodes takes it once it lands',
      (tester) async {
    final painter = await _hostPainter(tester);

    // From the very first frame: the paint image on the left half, drawImage
    // on the right. The producer records an unchanged image only once, so
    // the replay has to retry the paint after the decode lands, or the left
    // half stays white for good.
    painter.mode = _Mode.sideBySide;
    final both = await _repaintUntilDecoded(tester, painter, (0.525, 0.1));

    for (final (u, v) in _darkField) {
      _expectSame(both.rgbaAt(u / 2, v), both.rgbaAt(0.5 + u / 2, v),
          'paint image vs drawImage at ($u, $v)');
    }
  });
}

/// Hosts an [_ImagePainter] over rewards.riv, whose artboard only provides
/// the box; web gives the file a recording session of its own, which the
/// image decodes into too.
Future<_ImagePainter> _hostPainter(WidgetTester tester) async {
  final file = await tester.runAsync(() => rive.File.decode(
        loadFile('assets/rewards.riv'),
        riveFactory: rive.Factory.rive,
      ));
  expect(file, isNotNull);
  addTearDown(file!.dispose);
  final session = file.riveFactory;
  final artboard = file.defaultArtboard()!;
  addTearDown(artboard.dispose);

  final image = await tester.runAsync(() => session
      .decodeImage(loadFile('assets/images/referenced-image-2929282.png')));
  expect(image, isNotNull);
  addTearDown(image!.dispose);

  final painter = _ImagePainter(session, image);
  addTearDown(painter.dispose);
  await pumpSettled(
    tester,
    host(rive.RiveArtboardWidget(artboard: artboard, painter: painter)),
  );
  return painter;
}

/// Repaints until the drawImage at [probe] shows the dark field, i.e. the
/// browser decode landed.
Future<_Pixels> _repaintUntilDecoded(
    WidgetTester tester, _ImagePainter painter, (double, double) probe) async {
  final (px, py) = probe;
  var pixels = await _repaint(tester, painter);
  for (var i = 0; i < 40 && !_isDark(pixels.rgbaAt(px, py)); i++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)));
    pixels = await _repaint(tester, painter);
  }
  expect(_isDark(pixels.rgbaAt(px, py)), isTrue,
      reason: 'the image never decoded, so there is nothing to compare');
  return pixels;
}

bool _isDark(List<int> rgba) => rgba[3] > 200 && rgba[0] < 100;

void _expectSame(List<int> actual, List<int> expected, String what) {
  for (var i = 0; i < 4; i++) {
    expect(actual[i], closeTo(expected[i], 8),
        reason: 'channel $i, $what: $actual vs $expected');
  }
}

Future<_Pixels> _repaint(WidgetTester tester, _ImagePainter painter) async {
  painter.scheduleRepaint();
  await tester.pump(const Duration(milliseconds: 16));
  await tester.pump(const Duration(milliseconds: 16));
  await tester.pump(const Duration(milliseconds: 16));
  return _readPixels(tester);
}

final class _Pixels {
  final Uint8List bytes;
  final int width;
  final int height;
  _Pixels(this.bytes, this.width, this.height);

  List<int> rgbaAt(double fx, double fy) {
    final i = ((fy * height).floor() * width + (fx * width).floor()) * 4;
    return [bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3]];
  }
}

Future<_Pixels> _readPixels(WidgetTester tester) async {
  final texture = tester.allRenderObjects
      .whereType<rive.RiveNativeRenderBox>()
      .toSet()
      .single
      .renderTexture;
  return (await tester.runAsync(() async {
    final image = await texture.toImage();
    final data =
        await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
    return _Pixels(data!.buffer.asUint8List(), image.width, image.height);
  }))!;
}

enum _Mode { artboard, drawImage, paintImage, sideBySide }

/// The stock state machine painter, which fills the artboard's box with
/// [image] instead of drawing the artboard once [mode] says so: with
/// drawImage, as a white fill modulated by the image, or the two side by side.
final class _ImagePainter extends rive.StateMachinePainter {
  final rive.RenderImage image;
  final rive.RenderPath fullPath;
  final rive.RenderPath leftPath;
  final rive.RenderPaint fill;
  _Mode mode = _Mode.artboard;

  _ImagePainter(rive.Factory factory, this.image)
      : fullPath = factory.makePath(),
        leftPath = factory.makePath(),
        fill = factory.makePaint()
          ..style = rive.PaintingStyle.fill
          ..color = const Color(0xFFFFFFFF),
        super(fit: rive.Fit.fill);

  @override
  void artboardChanged(rive.Artboard artboard) {
    super.artboardChanged(artboard);
    final box = artboard.bounds;
    _rect(fullPath, box.minX, box.minY, box.maxX, box.maxY);
    _rect(leftPath, box.minX, box.minY, box.minX + box.width / 2, box.maxY);
  }

  static void _rect(rive.RenderPath path, double l, double t, double r,
          double b) =>
      path
        ..moveTo(l, t)
        ..lineTo(r, t)
        ..lineTo(r, b)
        ..lineTo(l, b)
        ..close();

  @override
  void paint(rive.Renderer renderer, Size size, double paintPixelRatio) {
    final artboard = this.artboard;
    if (mode == _Mode.artboard || artboard == null) {
      super.paint(renderer, size, paintPixelRatio);
      return;
    }
    final box = artboard.bounds;
    renderer.align(
      fit,
      alignment,
      AABB.fromValues(0, 0, size.width, size.height),
      box,
      layoutScaleFactor,
    );
    switch (mode) {
      case _Mode.drawImage:
        _drawImage(renderer, box.minX, box.minY, box.width, box.height);
      case _Mode.paintImage:
        _paintImage(renderer, fullPath, box.minX, box.minY, box.width,
            box.height);
      case _Mode.sideBySide:
        final half = box.width / 2;
        _paintImage(renderer, leftPath, box.minX, box.minY, half, box.height);
        _drawImage(renderer, box.minX + half, box.minY, half, box.height);
      case _Mode.artboard:
        break;
    }
  }

  void _drawImage(
      rive.Renderer renderer, double x, double y, double w, double h) {
    renderer.save();
    renderer.translate(x, y);
    renderer.scale(w / _imageWidth, h / _imageHeight);
    renderer.drawImage(image, ui.BlendMode.srcOver, 1);
    renderer.restore();
  }

  // Maps the image's 0..1 texture space onto (x, y, w, h). Re-applied every
  // draw, as the editor's shape paints do; the producer records it once.
  void _paintImage(rive.Renderer renderer, rive.RenderPath path, double x,
      double y, double w, double h) {
    final imageTransform = Mat2D()
      ..[0] = w
      ..[3] = h
      ..[4] = x
      ..[5] = y;
    fill.modulatedImage(image, rive.ImageSampler.linearClamp, imageTransform);
    renderer.drawPath(path, fill);
  }

  @override
  void dispose() {
    fullPath.dispose();
    leftPath.dispose();
    fill.dispose();
    super.dispose();
  }
}
