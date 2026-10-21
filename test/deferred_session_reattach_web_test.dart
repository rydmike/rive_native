@TestOn('browser')
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rive_native/rive_deferred.dart' as rive_deferred;
import 'package:rive_native/rive_native.dart' as rive;

import 'src/render_texture_probe.dart';

/// Pooled textures never read isDisposed; a stale back-pointer blocked attach.
void main() {
  test('texture dispose clears the session back-pointer naming it', () {
    final session = rive_deferred.makeDeferredRiveFactory();
    expect(session, isNotNull);
    addTearDown(() => rive_deferred.detachAndDisposeDeferredSession(session));

    final texture = rive.RiveNative.instance.makeRenderTexture(deferred: true);
    rive_deferred.setDeferredAttachedTexture(session!, texture);
    texture.useDeferredSession(session);
    expect(rive_deferred.deferredAttachedTexture(session), same(texture));

    texture.dispose();
    expect(rive_deferred.deferredAttachedTexture(session), isNull,
        reason: 'a pooled texture must not read as the session\'s live '
            'holder');
  });

  testWidgets(
      're-showing a widget on the same session attaches its new texture '
      'after the pool recycled the old one', (tester) async {
    final session = rive_deferred.makeDeferredRiveFactory();
    expect(session, isNotNull);
    rive_deferred.enableDeferredAutoAttach(session!);
    addTearDown(() => rive_deferred.detachAndDisposeDeferredSession(session));

    Widget show() => host(rive.RiveProceduralRenderingWidget(
          riveFactory: session,
          painter: _NoopProceduralPainter(),
        ));

    await pumpSettled(tester, show());
    final first = rive_deferred.deferredAttachedTexture(session);
    expect(first, isNotNull,
        reason: 'the first widget must attach the session');

    await pumpSettled(tester, const SizedBox());
    final recycled =
        rive.RiveNative.instance.makeRenderTexture(deferred: true);
    addTearDown(recycled.dispose);

    await pumpSettled(tester, show());
    final boxes =
        tester.allRenderObjects.whereType<rive.RiveNativeRenderBox>().toList();
    expect(boxes, isNotEmpty);
    final texture = boxes.last.renderTexture;
    expect(
      identical(rive_deferred.deferredAttachedTexture(session), texture),
      isTrue,
      reason: 'the session must attach to the re-shown widget\'s texture, '
          'not stay pinned to the recycled one',
    );
  });
}

final class _NoopProceduralPainter extends rive.ProceduralPainter {
  @override
  bool advance(double elapsedSeconds) => true;

  @override
  void paint(rive.Renderer renderer, Size size, double paintPixelRatio) {}
}
