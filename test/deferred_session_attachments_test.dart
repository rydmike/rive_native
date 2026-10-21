import 'package:flutter_test/flutter_test.dart';
import 'package:rive_native/rive_deferred.dart' as rive_deferred;
import 'package:rive_native/rive_native.dart' as rive;
import 'package:rive_native/src/deferred_session_factory.dart';

/// A session serves several textures, so disposal has to detach every one,
/// not only the last to attach.
void main() {
  setUpAll(() async {
    expect(await rive.RiveNative.init(), isTrue);
  });

  test('disposing a session detaches every texture it tracked', () {
    final session = rive_deferred.makeHeadlessDeferredFactory();
    if (session == null) {
      markTestSkipped('no deferred native library');
      return;
    }
    final a = rive.RiveNative.instance.makeRenderTexture(deferred: true);
    final b = rive.RiveNative.instance.makeRenderTexture(deferred: true);
    addTearDown(a.dispose);
    addTearDown(b.dispose);

    rive_deferred.setDeferredAttachedTexture(session, a);
    rive_deferred.setDeferredAttachedTexture(session, b);
    expect(rive_deferred.deferredAttachedTexture(session), same(b));
    expect(deferredAttachedTextures(session), unorderedEquals([a, b]));

    rive_deferred.detachAndDisposeDeferredSession(session);
    expect(deferredAttachedTextures(session), isEmpty);
    expect(rive_deferred.deferredAttachedTexture(session), isNull);
    expect(rive_deferred.deferredSessionAddress(session), 0);
  });

  test('a texture leaving a session drops out of its tracking', () {
    final session = rive_deferred.makeHeadlessDeferredFactory();
    if (session == null) {
      markTestSkipped('no deferred native library');
      return;
    }
    addTearDown(() => rive_deferred.detachAndDisposeDeferredSession(session));
    final a = rive.RiveNative.instance.makeRenderTexture(deferred: true);
    final b = rive.RiveNative.instance.makeRenderTexture(deferred: true);
    addTearDown(a.dispose);
    addTearDown(b.dispose);

    rive_deferred.setDeferredAttachedTexture(session, a);
    rive_deferred.setDeferredAttachedTexture(session, b);

    forgetDeferredAttachedTexture(session, b);
    expect(deferredAttachedTextures(session), [a]);
    expect(rive_deferred.deferredAttachedTexture(session), isNull,
        reason: 'the slot named b, so it must not keep naming a gone texture');

    forgetDeferredAttachedTexture(session, a);
    expect(deferredAttachedTextures(session), isEmpty);
  });
}
