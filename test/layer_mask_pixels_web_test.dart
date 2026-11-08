@TestOn('browser')
// Draws real content through WebGL, so the publishing CI runner skips it with
// the rest of this tag (see rive_renderer_web_smoke_test.dart).
// layer_mask_web_test.dart covers the bindings where this cannot run.
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

const _red = Color(0xFFFF0000);
const _green = Color(0xFF00FF00);
const _blue = Color(0xFF0000FF);
const _white = Color(0xFFFFFFFF);

/// Layer masks drawn through the Dart renderer on web, end to end: the
/// bracket calls, the canvases they open, the GPU op and the composite. On
/// WebGL2 without pixel local storage every frame is depthStencil, so this is
/// the BlendEquation::layerMask path.
void main() {
  testWidgets('a partial mask keeps only what its source covers',
      (tester) async {
    final painter = await _hostPainter(tester);

    painter.mode = _Mode.empty;
    final empty = await _repaint(tester, painter);

    painter.mode = _Mode.partial;
    final masked = await _repaint(tester, painter);

    // Content is a red box; the source covers its left half.
    _expectColor(masked.rgbaAt(0.25, 0.5), _red, 'inside the source');
    _expectSame(
      masked.rgbaAt(0.75, 0.5),
      empty.rgbaAt(0.75, 0.5),
      'outside the source',
    );
  });

  testWidgets('a nested mask hands back to the outer layer and then the root',
      (tester) async {
    final painter = await _hostPainter(tester);

    painter.mode = _Mode.empty;
    final empty = await _repaint(tester, painter);

    painter.mode = _Mode.nested;
    final nested = await _repaint(tester, painter);

    // Green is masked to the top half by the inner mask, blue is drawn into
    // the outer layer after the inner one closes, and the outer mask keeps the
    // left half of both. The white marker is drawn on the root afterwards.
    _expectColor(nested.rgbaAt(0.25, 0.25), _green, 'inner mask, kept');
    _expectColor(nested.rgbaAt(0.25, 0.75), _blue, 'outer layer after inner');
    _expectSame(
      nested.rgbaAt(0.6, 0.25),
      empty.rgbaAt(0.6, 0.25),
      'outer mask, cut',
    );
    _expectColor(nested.rgbaAt(0.9, 0.9), _white, 'root after outer');
  });
}

/// Hosts a [_MaskPainter] over rewards.riv, whose artboard only provides the
/// box; web gives the file a recording session of its own, which the masks
/// need as their offscreen host.
Future<_MaskPainter> _hostPainter(WidgetTester tester) async {
  final file = await tester.runAsync(() => rive.File.decode(
        loadFile('assets/rewards.riv'),
        riveFactory: rive.Factory.rive,
      ));
  expect(file, isNotNull);
  addTearDown(file!.dispose);
  final artboard = file.defaultArtboard()!;
  addTearDown(artboard.dispose);

  final painter = _MaskPainter(file.riveFactory);
  addTearDown(painter.dispose);
  await pumpSettled(
    tester,
    host(rive.RiveArtboardWidget(artboard: artboard, painter: painter)),
  );
  return painter;
}

void _expectColor(List<int> actual, Color expected, String what) {
  _expectSame(
    actual,
    [
      (expected.r * 255).round(),
      (expected.g * 255).round(),
      (expected.b * 255).round(),
      (expected.a * 255).round(),
    ],
    what,
  );
}

void _expectSame(List<int> actual, List<int> expected, String what) {
  for (var i = 0; i < 4; i++) {
    expect(actual[i], closeTo(expected[i], 8),
        reason: 'channel $i, $what: $actual vs $expected');
  }
}

Future<_Pixels> _repaint(WidgetTester tester, _MaskPainter painter) async {
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

enum _Mode { artboard, empty, partial, nested }

/// The stock state machine painter, which draws masked boxes over the
/// artboard's box instead of the artboard once [mode] says so. Everything is
/// in the artboard's 0..1 space, scaled to its box.
final class _MaskPainter extends rive.StateMachinePainter {
  final rive.Factory factory;
  final List<rive.RenderPath> _paths = [];
  final List<rive.RenderPaint> _paints = [];
  final int _outerHandle = rive.Renderer.acquireMaskHandle();
  final int _innerHandle = rive.Renderer.acquireMaskHandle();
  _Mode mode = _Mode.artboard;

  _MaskPainter(this.factory) : super(fit: rive.Fit.fill);

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
    renderer.save();
    renderer.translate(box.minX, box.minY);
    renderer.scale(box.width, box.height);
    // The masks' raster box, in the space the brackets are opened in.
    final unit = AABB.fromValues(0, 0, 1, 1);
    switch (mode) {
      case _Mode.partial:
        expect(
          renderer.beginMask(rive.MaskMode.alpha, unit, handle: _outerHandle),
          isTrue,
        );
        _fill(renderer, 0, 0, 1, 1, _red);
        renderer.beginMaskSource();
        _fill(renderer, 0, 0, .5, 1, _white);
        renderer.endMask();
      case _Mode.nested:
        expect(
          renderer.beginMask(rive.MaskMode.alpha, unit, handle: _outerHandle),
          isTrue,
        );
        expect(
          renderer.beginMask(rive.MaskMode.alpha, unit, handle: _innerHandle),
          isTrue,
        );
        _fill(renderer, 0, 0, 1, 1, _green);
        renderer.beginMaskSource();
        _fill(renderer, 0, 0, 1, .5, _white);
        renderer.endMask();
        // Lands only if the inner endMask handed back the outer content.
        _fill(renderer, 0, .5, 1, 1, _blue);
        renderer.beginMaskSource();
        _fill(renderer, 0, 0, .5, 1, _white);
        renderer.endMask();
        // Lands only if the outer endMask handed back the root.
        _fill(renderer, .8, .8, 1, 1, _white);
      case _Mode.empty:
      case _Mode.artboard:
        break;
    }
    renderer.restore();
  }

  void _fill(rive.Renderer renderer, double l, double t, double r, double b,
      Color color) {
    final path = factory.makePath()
      ..moveTo(l, t)
      ..lineTo(r, t)
      ..lineTo(r, b)
      ..lineTo(l, b)
      ..close();
    final paint = factory.makePaint()
      ..style = rive.PaintingStyle.fill
      ..color = color;
    // Kept until dispose: the session replays them after this returns.
    _paths.add(path);
    _paints.add(paint);
    renderer.drawPath(path, paint);
  }

  @override
  void dispose() {
    for (final path in _paths) {
      path.dispose();
    }
    for (final paint in _paints) {
      paint.dispose();
    }
    rive.Renderer.releaseMaskHandle(_outerHandle);
    rive.Renderer.releaseMaskHandle(_innerHandle);
    super.dispose();
  }
}
