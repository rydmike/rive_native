@TestOn('browser')
library;

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:rive_native/rive_deferred.dart' as rive_deferred;
import 'package:rive_native/rive_native.dart' as rive;

import 'src/web_context_probe.dart';

/// A frame left open by a detached texture would hold the session's frame
/// window shut for every later frame.
void main() {
  test('disposing a texture mid-frame leaves no open frame in the session',
      () {
    final session = rive_deferred.makeDeferredRiveFactory();
    expect(session, isNotNull);
    addTearDown(() => rive_deferred.detachAndDisposeDeferredSession(session));
    final address = rive_deferred.deferredSessionAddress(session);

    final texture = rive.RiveNative.instance.makeRenderTexture(deferred: true);
    rive_deferred.setDeferredAttachedTexture(session!, texture);
    texture.useDeferredSession(session);

    // clear() opens the texture's frame; flush() would close it.
    expect(texture.clear(const Color(0xFF000000)), isTrue);
    expect(deferredSessionOpenTargets(address), 1);

    texture.dispose();
    expect(deferredSessionOpenTargets(address), 0);
  });

  test('moving a texture to another session mid-frame closes the first', () {
    final first = rive_deferred.makeDeferredRiveFactory();
    final second = rive_deferred.makeDeferredRiveFactory();
    expect(first, isNotNull);
    expect(second, isNotNull);
    addTearDown(() => rive_deferred.detachAndDisposeDeferredSession(first));
    addTearDown(() => rive_deferred.detachAndDisposeDeferredSession(second));
    final firstAddress = rive_deferred.deferredSessionAddress(first);

    final texture = rive.RiveNative.instance.makeRenderTexture(deferred: true);
    addTearDown(texture.dispose);
    rive_deferred.setDeferredAttachedTexture(first!, texture);
    texture.useDeferredSession(first);
    expect(texture.clear(const Color(0xFF000000)), isTrue);
    expect(deferredSessionOpenTargets(firstAddress), 1);

    rive_deferred.setDeferredAttachedTexture(second!, texture);
    texture.useDeferredSession(second);
    expect(deferredSessionOpenTargets(firstAddress), 0);
  });
}
