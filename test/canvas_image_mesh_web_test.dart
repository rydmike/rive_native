@TestOn('browser')
// Draws real artboard content through WebGL, so the publishing CI runner skips
// it with the rest of this tag (see rive_renderer_web_smoke_test.dart).
@Tags(['webgl_content'])
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rive_native/math.dart';
import 'package:rive_native/rive_deferred.dart' as rive_deferred;
import 'package:rive_native/rive_native.dart' as rive;

import 'src/render_texture_probe.dart';
import 'src/utils.dart';

/// A mesh that samples a canvas image (how a meshed Node-mode Component
/// draws) on web. The deferred replay builds the mesh buffers with the CPU
/// side WebGL2Factory, so the renderer has to sync them to its context; when
/// it didn't, the GL flush dropped the draw and the Component vanished.
void main() {
  testWidgets('an artboard drawn through a mesh matches its plain draw',
      (tester) async {
    // Web decodes every file into a recording session of its own, which is
    // what gives the artboard a canvas host to rasterize into.
    final file = await tester.runAsync(() => rive.File.decode(
          loadFile('assets/rewards.riv'),
          riveFactory: rive.Factory.rive,
        ));
    expect(file, isNotNull);
    addTearDown(file!.dispose);
    final session = file.riveFactory;
    expect(rive_deferred.deferredSessionAddress(session), isNot(0));
    final artboard = file.defaultArtboard()!;
    addTearDown(artboard.dispose);

    final painter = _MeshPainter(session);
    addTearDown(painter.dispose);

    await pumpSettled(
      tester,
      host(rive.RiveArtboardWidget(artboard: artboard, painter: painter)),
    );
    final plain = await _readPixels(tester);

    painter.throughMesh = true;
    painter.scheduleRepaint();
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    final meshed = await _readPixels(tester);

    expect(painter.drewThroughMesh, isTrue,
        reason: 'the mesh path must have run, or the comparison is vacuous');

    // The quad maps the whole raster onto the artboard's box, so the meshed
    // draw lands where the plain one does. Interior probes only: the edges
    // are where a raster and vectors may legitimately differ.
    for (final (fx, fy) in const [
      (0.25, 0.25),
      (0.5, 0.5),
      (0.75, 0.4),
      (0.5, 0.85),
    ]) {
      final expected = plain.rgbaAt(fx, fy);
      final actual = meshed.rgbaAt(fx, fy);
      expect(expected[3], greaterThan(200),
          reason: 'probe ($fx, $fy) must sit on opaque content');
      for (var i = 0; i < 4; i++) {
        expect(actual[i], closeTo(expected[i], 8),
            reason: 'channel $i at ($fx, $fy): meshed $actual vs plain '
                '$expected');
      }
    }
  });
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

/// The stock state machine painter, which draws through a quad mesh over the
/// artboard's box (sampling the artboard's own raster) once [throughMesh] is
/// set.
final class _MeshPainter extends rive.StateMachinePainter {
  final rive.VertexRenderBuffer vertices;
  final rive.VertexRenderBuffer uvs;
  final rive.IndexRenderBuffer indices;
  bool throughMesh = false;
  bool drewThroughMesh = false;

  _MeshPainter(rive.Factory factory)
      : vertices = factory.makeVertexBuffer(4)!,
        uvs = factory.makeVertexBuffer(4)!,
        indices = factory.makeIndexBuffer(6)!,
        super(fit: rive.Fit.fill) {
    indices.setIndices(Uint16List.fromList([0, 1, 2, 0, 2, 3]));
  }

  @override
  void artboardChanged(rive.Artboard artboard) {
    super.artboardChanged(artboard);
    final box = artboard.bounds;
    vertices.setVertices(Float32List.fromList([
      box.minX, box.minY, //
      box.maxX, box.minY, //
      box.maxX, box.maxY, //
      box.minX, box.maxY, //
    ]));
  }

  @override
  void paint(rive.Renderer renderer, Size size, double paintPixelRatio) {
    final artboard = this.artboard;
    if (!throughMesh || artboard == null) {
      super.paint(renderer, size, paintPixelRatio);
      return;
    }
    // super.paint's layout, with the mesh in place of drawInternal.
    renderer.align(
      fit,
      alignment,
      AABB.fromValues(0, 0, size.width, size.height),
      artboard.bounds,
      layoutScaleFactor,
    );
    artboard.advanceFrameId();
    final uv = artboard.meshUVTransform(1);
    if (uv == null) {
      return;
    }
    final corners = [0.0, 0.0, 1.0, 0.0, 1.0, 1.0, 0.0, 1.0];
    final mapped = Float32List(8);
    for (var i = 0; i < 8; i += 2) {
      final u = corners[i], v = corners[i + 1];
      mapped[i] = uv[0] * u + uv[2] * v + uv[4];
      mapped[i + 1] = uv[1] * u + uv[3] * v + uv[5];
    }
    uvs.setVertices(mapped);
    drewThroughMesh = artboard.drawThroughMesh(
        renderer, 1, vertices, uvs, indices, ui.BlendMode.srcOver, 1);
  }

  @override
  void dispose() {
    vertices.dispose();
    uvs.dispose();
    indices.dispose();
    super.dispose();
  }
}
