@TestOn('browser')
library;

import 'dart:js_interop' as js;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:rive_native/rive_deferred.dart' as rive_deferred;
import 'package:rive_native/rive_native.dart' as rive;
import 'package:rive_native/src/web/rive_renderer_web.dart'
    show WebRiveRenderer;

/// The Dart half of layer masking on web: the wasm export lookups, the
/// uint64 handle crossing as a BigInt, and the renderer swap that routes every
/// draw into the offscreen canvases. The C++ pixel tests
/// (layer_mask_pixel_test.cpp) drive Artboard::drawInternal and reach none of
/// it.
///
/// Recording only: nothing here is replayed, so it needs no shader compile and
/// runs on the runners that skip webgl_content. The pixels are
/// layer_mask_pixels_web_test.dart's job.
void main() {
  test('a mask handle survives the BigInt round trip', () {
    final first = rive.Renderer.acquireMaskHandle();
    final second = rive.Renderer.acquireMaskHandle();
    // 0 is what the bindings answer when the exports are missing.
    expect(first, isNot(0));
    expect(second, isNot(first));
    // Passing a Number where the export takes an i64 throws a TypeError.
    rive.Renderer.releaseMaskHandle(first);
    rive.Renderer.releaseMaskHandle(second);
  });

  test('a mask swaps to its canvases and endMask restores the parent', () {
    final (renderer, factory) = _sessionRenderer();
    final handle = rive.Renderer.acquireMaskHandle();
    addTearDown(() => rive.Renderer.releaseMaskHandle(handle));
    final rect = _rect(factory);
    final paint = factory.makePaint();
    addTearDown(paint.dispose);

    final parent = _pointer(renderer);
    expect(_beginMask(renderer, handle), isTrue);
    final content = _pointer(renderer);
    expect(content, isNot(parent));
    // A dangling pointer would trap in the wasm rather than fail an expect.
    renderer.drawPath(rect, paint);

    renderer.beginMaskSource();
    final coverage = _pointer(renderer);
    expect(coverage, isNot(content));
    expect(coverage, isNot(parent));
    renderer.drawPath(rect, paint);

    renderer.endMask();
    expect(_pointer(renderer), parent);
    renderer.drawPath(rect, paint);

    // The native side keys open brackets by parent renderer and refuses a
    // second one, so this only succeeds if endMask closed the first.
    expect(_beginMask(renderer, handle), isTrue);
    renderer.beginMaskSource();
    renderer.endMask();
    expect(_pointer(renderer), parent);
  });

  test('a mask nested in a mask restores each level', () {
    final (renderer, factory) = _sessionRenderer();
    final outerHandle = rive.Renderer.acquireMaskHandle();
    final innerHandle = rive.Renderer.acquireMaskHandle();
    addTearDown(() => rive.Renderer.releaseMaskHandle(outerHandle));
    addTearDown(() => rive.Renderer.releaseMaskHandle(innerHandle));
    final rect = _rect(factory);
    final paint = factory.makePaint();
    addTearDown(paint.dispose);

    final root = _pointer(renderer);
    expect(_beginMask(renderer, outerHandle), isTrue);
    final outerContent = _pointer(renderer);

    expect(_beginMask(renderer, innerHandle), isTrue);
    final innerContent = _pointer(renderer);
    expect(innerContent, isNot(outerContent));
    renderer.drawPath(rect, paint);
    renderer.beginMaskSource();
    renderer.drawPath(rect, paint);
    renderer.endMask();

    // Back on the outer content, not the root: the rest of the outer layer
    // still has to land in its canvas.
    expect(_pointer(renderer), outerContent);
    renderer.drawPath(rect, paint);

    renderer.beginMaskSource();
    renderer.drawPath(rect, paint);
    renderer.endMask();
    expect(_pointer(renderer), root);
  });

  test('a renderer without a recording session declines and stays put', () {
    // An immediate texture draws through the WebGL2 factory, which has no
    // offscreen host, so the layer has to draw unmasked.
    final texture = rive.RiveNative.instance.makeRenderTexture();
    addTearDown(texture.dispose);
    final renderer = texture.renderer;
    expect(renderer, isA<WebRiveRenderer>());
    final handle = rive.Renderer.acquireMaskHandle();
    addTearDown(() => rive.Renderer.releaseMaskHandle(handle));

    final before = _pointer(renderer);
    expect(_beginMask(renderer, handle), isFalse);
    expect(_pointer(renderer), before);
    // Both are no-ops after a declined beginMask.
    renderer.beginMaskSource();
    renderer.endMask();
    expect(_pointer(renderer), before);
  });
}

/// A renderer recording into a fresh session, attached to a texture the way
/// the editor's stage is, mid-frame. Typed as the base Renderer because
/// WebRiveRenderer's draw methods take covariant web path and paint types.
(rive.Renderer, rive.Factory) _sessionRenderer() {
  final session = rive_deferred.makeDeferredRiveFactory();
  expect(session, isNotNull);
  addTearDown(() => rive_deferred.detachAndDisposeDeferredSession(session));
  final texture = rive.RiveNative.instance.makeRenderTexture(deferred: true);
  addTearDown(texture.dispose);
  rive_deferred.setDeferredAttachedTexture(session!, texture);
  texture.useDeferredSession(session);
  expect(texture.clear(const Color(0xFF000000)), isTrue);
  final renderer = texture.renderer;
  expect(renderer, isA<WebRiveRenderer>());
  // Masking needs the session as the factory: it is the offscreen host.
  expect(renderer.riveFactory, same(session));
  return (renderer, session);
}

bool _beginMask(rive.Renderer renderer, int handle) => renderer.beginMask(
      rive.MaskMode.alpha,
      rive.AABB.fromValues(0, 0, 64, 64),
      handle: handle,
    );

/// The wasm renderer every draw currently goes to.
int _pointer(rive.Renderer renderer) =>
    ((renderer as WebRiveRenderer).jsRendererPtr as js.JSNumber).toDartInt;

rive.RenderPath _rect(rive.Factory factory) {
  final path = factory.makePath()
    ..moveTo(8, 8)
    ..lineTo(56, 8)
    ..lineTo(56, 56)
    ..lineTo(8, 56)
    ..close();
  addTearDown(path.dispose);
  return path;
}
