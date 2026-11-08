@TestOn('browser')
// Draws real content through WebGL, so the publishing CI runner skips it with
// the rest of this tag (see rive_renderer_web_smoke_test.dart).
@Tags(['webgl_content'])
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rive_native/rive_native.dart' as rive;

import 'src/render_texture_probe.dart';
import 'src/utils.dart';

/// A RenderTexturePainter drawing image meshes decoded by the texture
/// renderer's own factory, one image added at a time. With
/// WEBGL_shader_pixel_local_storage, every flush after the first failed its
/// copy back to the canvas with "Blit feedback loop: the read and draw
/// framebuffers are the same", and rendering stopped.
///
/// Keep the content image meshes only: paths flush through passes that
/// rebind both framebuffer targets, which hides the bug.
///
/// Chrome exposes the extension only behind --enable-webgl-draft-extensions,
/// so the test skips without it. Run it with CHROME_EXECUTABLE pointed at a
/// script that launches Chrome with that flag.
void main() {
  testWidgets('image meshes flush without a blit error',
      skip: !_hasPixelLocalStorage(), (tester) async {
    _recordBlits();

    final texture = rive.RiveNative.instance.makeRenderTexture();
    addTearDown(texture.dispose);
    final painter = _ImageMeshPainter();
    addTearDown(painter.dispose);

    await pumpSettled(tester, host(texture.widget(painter: painter)));
    final factory = painter.factory;
    expect(factory, isNotNull, reason: 'the painter never painted');

    final bytes = loadFile('assets/images/referenced-image-2929282.png');
    for (var i = 0; i < 6; i++) {
      final image = await tester.runAsync(() => factory!.decodeImage(bytes));
      expect(image, isNotNull);
      addTearDown(image!.dispose);
      painter.add(image);
      // Let the browser decode land, then paint a few frames with it.
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      for (var f = 0; f < 3; f++) {
        painter.repaint();
        await tester.pump(const Duration(milliseconds: 16));
      }
    }

    expect(painter.paints, greaterThan(10));
    expect(_blitCount('__riveBlitErrors'), 0,
        reason: 'glBlitFramebuffer failed');
    expect(_blitCount('__riveBlitsNotToCanvas'), 0,
        reason: 'the copy-back must read the offscreen FBO into the canvas');
  });
}

/// Whether this Chrome exposes WEBGL_shader_pixel_local_storage in the form
/// the renderer takes (coherent, five-argument framebufferTexture call; see
/// pls_impl_webgl.cpp), probed on a throwaway context that is released again.
/// Any other variant falls back to MSAA and would pass vacuously.
bool _hasPixelLocalStorage() =>
    (globalContext.callMethod<JSBoolean>(
            'eval'.toJS,
            '''
(function () {
  const gl = document.createElement("canvas").getContext("webgl2");
  if (!gl) return false;
  const pls = gl.getExtension("WEBGL_shader_pixel_local_storage");
  const usable = !!pls && pls.isCoherent() &&
      pls.framebufferTexturePixelLocalStorageWEBGL.length == 5;
  const lose = gl.getExtension("WEBGL_lose_context");
  if (lose) lose.loseContext();
  return usable;
})()
'''
                .toJS))
        .toDart;

/// Wraps WebGL2's blitFramebuffer for this test to count calls that raise
/// GL_INVALID_OPERATION, and calls that do not copy an offscreen FBO into the
/// canvas. The client-side bindings look fine when the feedback loop hits, so
/// only the GL error shows that; a blit bound the wrong way round raises no
/// error and leaves the canvas blank, so only the bindings show that.
void _recordBlits() {
  globalContext.callMethod<JSAny?>(
      'eval'.toJS,
      '''
(function () {
  window.__riveBlitErrors = 0;
  window.__riveBlitsNotToCanvas = 0;
  const proto = WebGL2RenderingContext.prototype;
  const blit = proto.blitFramebuffer;
  window.__riveRestoreBlit = function () { proto.blitFramebuffer = blit; };
  proto.blitFramebuffer = function () {
    if (this.getParameter(this.READ_FRAMEBUFFER_BINDING) === null ||
        this.getParameter(this.DRAW_FRAMEBUFFER_BINDING) !== null) {
      window.__riveBlitsNotToCanvas++;
    }
    const result = blit.apply(this, arguments);
    if (this.getError() === this.INVALID_OPERATION) {
      window.__riveBlitErrors++;
    }
    return result;
  };
})()
'''
          .toJS);
  addTearDown(
      () => globalContext.callMethod<JSAny?>('__riveRestoreBlit'.toJS));
}

int _blitCount(String name) =>
    globalContext.getProperty<JSNumber>(name.toJS).toDartInt;

/// The reported painter: takes the renderer's factory on first paint and
/// draws every image added so far as a quad mesh.
final class _ImageMeshPainter extends rive.RenderTexturePainter {
  rive.Factory? factory;
  rive.VertexRenderBuffer? _uvs;
  rive.IndexRenderBuffer? _indices;
  final List<(rive.RenderImage, rive.VertexRenderBuffer)> _meshes = [];
  int paints = 0;

  @override
  Color get background => const Color(0xFFFFFFFF);

  void repaint() => notifyListeners();

  void add(rive.RenderImage image) {
    final index = _meshes.length;
    final x = (index % 3) * 30.0;
    final y = (index ~/ 3) * 30.0;
    final vertices = factory!.makeVertexBuffer(4)!
      ..setVertices(Float32List.fromList([
        x, y, //
        x + 28, y, //
        x + 28, y + 28, //
        x, y + 28, //
      ]));
    _meshes.add((image, vertices));
  }

  @override
  bool advance(double elapsedSeconds) => false;

  @override
  void paint(rive.RenderTexture texture, double devicePixelRatio, Size size) {
    paints++;
    final renderer = texture.renderer;
    final factory = this.factory ??= renderer.riveFactory;
    final uvs = _uvs ??= factory.makeVertexBuffer(4)!
      ..setVertices(Float32List.fromList([0, 0, 1, 0, 1, 1, 0, 1]));
    final indices = _indices ??= factory.makeIndexBuffer(6)!
      ..setIndices(Uint16List.fromList([0, 1, 2, 0, 2, 3]));
    for (final (image, vertices) in _meshes) {
      renderer.drawImageMesh(
          image, vertices, uvs, indices, BlendMode.srcOver, 1);
    }
  }

  @override
  void dispose() {
    for (final (_, vertices) in _meshes) {
      vertices.dispose();
    }
    _uvs?.dispose();
    _indices?.dispose();
    super.dispose();
  }
}
