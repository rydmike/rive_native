import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rive_native/rive_native.dart' as rive;
import 'package:rive_native/src/deferred_pacing_diagnostics.dart';

import 'src/render_texture_probe.dart';

/// Pacing tests for the dedicated-texture paint path
/// ([rive.RiveNativeRenderBox.paintTexture]).
///
/// A tick skipped by a pacing gate (worker behind, failed clear) banks its
/// elapsed time and hands the sum to the next paint - matching the
/// shared-panel path - so gating changes cadence, never animation speed.
/// Paused ticks drop theirs instead.
class _NoopRenderer extends rive.Renderer {
  @override
  dynamic noSuchMethod(Invocation invocation) {}
}

/// A render texture whose native pacing gates the tests toggle.
base class _SpyRenderTexture extends rive.RenderTexture {
  bool acceptDeferredFrames = true;
  bool paused = false;
  bool clearResult = true;
  final _NoopRenderer _renderer = _NoopRenderer();

  @override
  bool get deferredPaused => paused;

  @override
  bool get canAcceptDeferredFrame => acceptDeferredFrames;

  @override
  bool clear(Color color, [bool write = true]) {
    return clearResult;
  }

  @override
  bool flush(double devicePixelRatio) {
    return true;
  }

  @override
  rive.Renderer get renderer => _renderer;
  @override
  int get textureId => -1;
  @override
  dynamic get nativeTexture => null;
  @override
  int get actualWidth => 0;
  @override
  int get actualHeight => 0;
  @override
  bool get isReady => true;
  @override
  bool get isDisposed => false;
  @override
  bool needsResize(int width, int height) => false;
  @override
  Future<void> makeRenderTexture(int width, int height) async {}
  @override
  Future<ui.Image> toImage() => throw UnimplementedError();
  @override
  Widget widget({
    rive.RenderTexturePainter? painter,
    rive.RenderResolution resolution = rive.RenderResolution.defaultValue,
    Key? key,
  }) => throw UnimplementedError();
  @override
  void dispose() {}
}

/// Records the elapsed seconds each paint receives. A null [riveFactory]
/// keeps `_ensureDeferredSession` off the FFI.
final class _RecordingPainter extends rive.RenderTexturePainter {
  final List<double> elapsedLog = [];
  bool advance = true;

  @override
  rive.Factory? get riveFactory => null;

  @override
  Color get background => const Color(0x00000000);

  @override
  bool paint(
    rive.RenderTexture texture,
    double devicePixelRatio,
    Size size,
    double elapsedSeconds,
  ) {
    elapsedLog.add(elapsedSeconds);
    return advance;
  }
}

class _ProbeRenderBox extends rive.RiveNativeRenderBox {
  _ProbeRenderBox(super.renderTexture);
}

class _ProbeWidget extends LeafRenderObjectWidget {
  final rive.RenderTexture texture;
  final rive.RenderTexturePainter painter;
  const _ProbeWidget(this.texture, this.painter);

  void _configure(BuildContext context, _ProbeRenderBox renderObject) {
    renderObject
      ..painter = painter
      ..devicePixelRatio = MediaQuery.devicePixelRatioOf(context)
      ..tickerModeEnabled = TickerMode.of(context);
  }

  @override
  RenderObject createRenderObject(BuildContext context) {
    final renderObject = _ProbeRenderBox(texture);
    _configure(context, renderObject);
    return renderObject;
  }

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _ProbeRenderBox renderObject,
  ) => _configure(context, renderObject);
}

const _frame = Duration(milliseconds: 16);
const _frameSeconds = 0.016;

void main() {
  test('pacing diagnostics are silent by default', () {
    // The counters ship inside rive_native; they must cost nothing and print
    // nothing unless a diagnostic consumer turns them on.
    expect(RiveDeferredPacingDiagnostics.enabled, isFalse);
    expect(RiveDeferredPacingDiagnostics.logToConsole, isFalse);
    expect(RiveDeferredPacingDiagnostics.onWindow, isNull);
  });

  // One skeleton per banking gate: N gated ticks must not paint, their
  // elapsed banks into the next paint, and the bank must not leak into the
  // paint after that.
  final gates =
      <
        ({
          String name,
          void Function(_SpyRenderTexture texture, bool gated) set,
          int gatedTicks,
        })
      >[
        (
          name: 'worker-behind',
          set: (texture, gated) => texture.acceptDeferredFrames = !gated,
          gatedTicks: 2,
        ),
        (
          name: 'failed clear',
          set: (texture, gated) => texture.clearResult = !gated,
          gatedTicks: 1,
        ),
      ];
  for (final gate in gates) {
    testWidgets('${gate.name} gate banks elapsed into the next paint', (
      tester,
    ) async {
      final texture = _SpyRenderTexture();
      final painter = _RecordingPainter();
      await tester.pumpWidget(host(_ProbeWidget(texture, painter)));
      await tester.pump(_frame);
      expect(painter.elapsedLog, isNotEmpty);
      final paintsBefore = painter.elapsedLog.length;

      gate.set(texture, true);
      for (var i = 0; i < gate.gatedTicks; i++) {
        await tester.pump(_frame);
      }
      expect(
        painter.elapsedLog.length,
        paintsBefore,
        reason: 'gated ticks must not paint',
      );

      gate.set(texture, false);
      await tester.pump(_frame);
      expect(painter.elapsedLog.length, paintsBefore + 1);
      expect(
        painter.elapsedLog.last,
        closeTo((gate.gatedTicks + 1) * _frameSeconds, 1e-6),
        reason: 'the gated ticks bank their elapsed into this paint',
      );

      await tester.pump(_frame);
      expect(
        painter.elapsedLog.last,
        closeTo(_frameSeconds, 1e-6),
        reason: 'the bank is consumed exactly once',
      );
    });
  }

  testWidgets('paused ticks drop their elapsed instead of banking it', (
    tester,
  ) async {
    final texture = _SpyRenderTexture();
    final painter = _RecordingPainter();
    await tester.pumpWidget(host(_ProbeWidget(texture, painter)));
    await tester.pump(_frame);
    final paintsBefore = painter.elapsedLog.length;

    texture.paused = true;
    await tester.pump(_frame);
    await tester.pump(_frame);
    expect(
      painter.elapsedLog.length,
      paintsBefore,
      reason: 'paused ticks must not paint',
    );

    texture.paused = false;
    await tester.pump(_frame);
    expect(
      painter.elapsedLog.last,
      closeTo(_frameSeconds, 1e-6),
      reason:
          'a pause freezes the animation; resuming must not '
          'fast-forward it by the paused span',
    );
  });

  testWidgets('stopping the ticker drops banked elapsed', (tester) async {
    final texture = _SpyRenderTexture();
    final painter = _RecordingPainter();
    Widget probe({required bool ticking}) => TickerMode(
          enabled: ticking,
          child: host(_ProbeWidget(texture, painter)),
        );
    await tester.pumpWidget(probe(ticking: true));
    await tester.pump(_frame);

    // Bank three gated ticks, then stop the ticker before anything paints.
    texture.acceptDeferredFrames = false;
    for (var i = 0; i < 3; i++) {
      await tester.pump(_frame);
    }
    await tester.pumpWidget(probe(ticking: false));
    texture.acceptDeferredFrames = true;

    final paintsBefore = painter.elapsedLog.length;
    await tester.pumpWidget(probe(ticking: true));
    await tester.pump(_frame);
    await tester.pump(_frame);
    expect(painter.elapsedLog.length, greaterThan(paintsBefore));
    expect(painter.elapsedLog.skip(paintsBefore),
        everyElement(lessThan(2 * _frameSeconds)),
        reason: 'time banked before the stop must not fast-forward the '
            'animation when it restarts');
  });

  testWidgets('a gated forced paint restarts the ticker to retry', (
    tester,
  ) async {
    final texture = _SpyRenderTexture();
    final painter = _RecordingPainter()..advance = false;
    await tester.pumpWidget(host(_ProbeWidget(texture, painter)));
    await tester.pump(_frame);
    final paintsBefore = painter.elapsedLog.length;
    expect(paintsBefore, greaterThan(0));

    // Settled (ticker stopped); a texture-changed repaint arrives while the
    // worker cannot take a frame. The skipped paint must arm the ticker so
    // the repaint retries, otherwise the new texture stays blank until an
    // unrelated repaint.
    painter.advance = true;
    texture.acceptDeferredFrames = false;
    texture.textureChanged();
    await tester.pump(_frame);

    texture.acceptDeferredFrames = true;
    await tester.pump(_frame);
    expect(
      painter.elapsedLog.length,
      greaterThan(paintsBefore),
      reason:
          'the gated forced paint must keep retrying until the worker '
          'accepts a frame',
    );
  });
}
