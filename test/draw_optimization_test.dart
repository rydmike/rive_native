import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rive_native/rive_native.dart' as rive;

import 'src/render_texture_probe.dart';
import 'src/utils.dart';

/// [rive.DrawOptimization] on both render paths: the Rive renderer texture
/// box ([rive.RiveNativeRenderBox]) and the Flutter renderer box
/// ([rive.FlutterRiveRenderBox]). The painter keeps asking for frames, so
/// every frame advances and only the draw is gated.
class _NoopRenderer extends rive.Renderer {
  @override
  dynamic noSuchMethod(Invocation invocation) {}
}

base class _SpyRenderTexture extends rive.RenderTexture {
  int clearCount = 0;
  int flushCount = 0;
  bool acceptDeferredFrames = true;
  final _NoopRenderer _renderer = _NoopRenderer();

  @override
  bool get canAcceptDeferredFrame => acceptDeferredFrames;
  @override
  bool clear(Color color, [bool write = true]) {
    clearCount++;
    return true;
  }

  @override
  bool flush(double devicePixelRatio) {
    flushCount++;
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

/// Paints a real artboard and advances until [keepAdvancing] is cleared, without
/// advancing the artboard itself. Each paint draws the
/// artboard into a throwaway Flutter canvas, which consumes its change the
/// way a real draw does, whichever renderer the box hands over.
base class _CountingPainter extends rive.ArtboardPainter
    with rive.RiveArtboardLayoutMixin {
  _CountingPainter(this._artboard);

  final rive.Artboard _artboard;
  int paints = 0;
  Size? lastPaintSize;
  bool keepAdvancing = true;

  @override
  rive.Artboard get artboard => _artboard;

  @override
  void artboardChanged(rive.Artboard artboard) {}

  @override
  bool advance(double elapsedSeconds) => keepAdvancing;

  @override
  void paint(rive.Renderer renderer, Size size, double paintPixelRatio) {
    paints++;
    lastPaintSize = size;
    final recorder = ui.PictureRecorder();
    final flutterRenderer = rive.Renderer.make(ui.Canvas(recorder));
    _artboard.draw(flutterRenderer);
    flutterRenderer.dispose();
    recorder.endRecording().dispose();
  }
}

class _ProbeRenderBox extends rive.RiveNativeRenderBox {
  _ProbeRenderBox(super.renderTexture);
}

class _ProbeWidget extends LeafRenderObjectWidget {
  final rive.RenderTexture texture;
  final rive.RenderTexturePainter painter;
  const _ProbeWidget(this.texture, this.painter);

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _ProbeRenderBox(texture)..painter = painter;

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _ProbeRenderBox renderObject,
  ) => renderObject.painter = painter;
}

const _frame = Duration(milliseconds: 16);

void main() {
  late rive.File riveFile;
  late rive.Artboard artboard;
  late rive.StateMachine stateMachine;
  late _CountingPainter painter;
  // The box's size inside the 100x80 host; a test shrinks it to resize.
  late ValueNotifier<Size> boxSize;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    riveFile = await rive.File.decode(
      loadFile('assets/rewards.riv'),
      riveFactory: rive.Factory.flutter,
    ) as rive.File;
    artboard = riveFile.defaultArtboard()!;
    stateMachine = artboard.defaultStateMachine()!;
    stateMachine.advanceAndApply(0);
    painter = _CountingPainter(artboard);
    boxSize = ValueNotifier(const Size(100, 80));
  });

  tearDown(() {
    boxSize.dispose();
    painter.dispose();
    stateMachine.dispose();
    artboard.dispose();
    riveFile.dispose();
  });

  Widget sizedHost(Widget box) => host(Center(
        child: ValueListenableBuilder<Size>(
          valueListenable: boxSize,
          builder: (context, size, child) =>
              SizedBox.fromSize(size: size, child: child),
          child: box,
        ),
      ));

  Future<void> pumpFrames(WidgetTester tester, int count) async {
    for (var i = 0; i < count; i++) {
      await tester.pump(_frame);
    }
  }

  /// The gate on one render path. [pumpBox] mounts the box and runs its first
  /// frame; [clears] and [flushes] read the texture's counts where there is
  /// one.
  void gateTests(
    Future<void> Function(WidgetTester, rive.DrawOptimization) pumpBox, {
    int Function()? clears,
    int Function()? flushes,
  }) {
    testWidgets('drawWhenChanged keeps advancing but skips unchanged frames', (
      tester,
    ) async {
      await pumpBox(tester, rive.DrawOptimization.drawWhenChanged);
      expect(painter.paints, greaterThan(0), reason: 'the first frame draws');
      // That draw consumed the artboard's first change, so one more follows.
      await tester.pump(_frame);
      final paints = painter.paints;
      final clearsBefore = clears?.call();

      await pumpFrames(tester, 5);

      expect(painter.paints, paints);
      expect(clears?.call(), clearsBefore);
      expect(flushes?.call(), clearsBefore);
      final box = tester.renderObject<rive.RiveRenderBox>(
        find.byWidgetPredicate((w) => w is LeafRenderObjectWidget),
      );
      expect(box.isTickerActive, isTrue, reason: 'still advancing');
    });

    testWidgets('drawWhenChanged draws a change, then once more', (
      tester,
    ) async {
      await pumpBox(tester, rive.DrawOptimization.drawWhenChanged);
      await pumpFrames(tester, 2);
      final paints = painter.paints;

      stateMachine.advanceAndApply(0.1);
      await tester.pump(_frame);
      expect(painter.paints, paints + 1);
      expect(artboard.didChange, isFalse, reason: 'the draw consumed it');

      // The draw can show dirt added after the update pass, so the next
      // frame draws again although the flag is clear.
      await tester.pump(_frame);
      expect(painter.paints, paints + 2);

      await pumpFrames(tester, 3);
      expect(painter.paints, paints + 2);
    });

    testWidgets('drawWhenChanged runs one tick for the trailing draw', (
      tester,
    ) async {
      await pumpBox(tester, rive.DrawOptimization.drawWhenChanged);
      await pumpFrames(tester, 2);
      final paints = painter.paints;
      final box = tester.renderObject<rive.RiveRenderBox>(
        find.byWidgetPredicate((w) => w is LeafRenderObjectWidget),
      );

      // The content settles on the frame that draws the change.
      stateMachine.advanceAndApply(0.1);
      painter.keepAdvancing = false;
      await tester.pump(_frame);
      expect(painter.paints, paints + 1);
      expect(box.isTickerActive, isTrue, reason: 'one tick for the trailing draw');

      await tester.pump(_frame);
      expect(painter.paints, paints + 2);

      await pumpFrames(tester, 3);
      expect(painter.paints, paints + 2);
      expect(box.isTickerActive, isFalse);
    });

    testWidgets('drawWhenChanged draws once when the painter notifies', (
      tester,
    ) async {
      await pumpBox(tester, rive.DrawOptimization.drawWhenChanged);
      await pumpFrames(tester, 2);
      final paints = painter.paints;

      painter.alignment = Alignment.topLeft;
      await pumpFrames(tester, 3);

      expect(painter.paints, paints + 1);
    });

    testWidgets('drawWhenChanged draws a resize although nothing changed', (
      tester,
    ) async {
      await pumpBox(tester, rive.DrawOptimization.drawWhenChanged);
      await pumpFrames(tester, 2);
      final paints = painter.paints;
      expect(painter.lastPaintSize, const Size(100, 80));
      expect(artboard.didChange, isFalse);

      boxSize.value = const Size(60, 40);
      await pumpFrames(tester, 3);

      expect(painter.paints, greaterThan(paints));
      expect(painter.lastPaintSize, const Size(60, 40));
    });

    testWidgets('alwaysDraw draws every frame', (tester) async {
      await pumpBox(tester, rive.DrawOptimization.alwaysDraw);
      final paints = painter.paints;
      final clearsBefore = clears?.call();

      await pumpFrames(tester, 5);

      expect(painter.paints, paints + 5);
      if (clearsBefore != null) {
        expect(clears!(), clearsBefore + 5);
      }
    });
  }

  group('Rive renderer texture', () {
    late _SpyRenderTexture texture;

    gateTests((tester, drawOptimization) async {
      texture = _SpyRenderTexture();
      final texturePainter = rive.ArtboardWidgetPainter(
        painter,
        drawOptimization: drawOptimization,
      );
      addTearDown(texturePainter.dispose);
      await tester.pumpWidget(
        sizedHost(_ProbeWidget(texture, texturePainter)),
      );
      await tester.pump(_frame);
    }, clears: () => texture.clearCount, flushes: () => texture.flushCount);

    testWidgets('a texture change draws although nothing changed', (
      tester,
    ) async {
      texture = _SpyRenderTexture();
      final texturePainter = rive.ArtboardWidgetPainter(painter);
      addTearDown(texturePainter.dispose);
      await tester.pumpWidget(host(_ProbeWidget(texture, texturePainter)));
      await pumpFrames(tester, 3);
      final paints = painter.paints;

      texture.textureChanged();

      expect(painter.paints, paints + 1);
    });

    testWidgets('a texture change the pacing gate blocked draws on retry', (
      tester,
    ) async {
      texture = _SpyRenderTexture();
      final texturePainter = rive.ArtboardWidgetPainter(painter);
      addTearDown(texturePainter.dispose);
      await tester.pumpWidget(host(_ProbeWidget(texture, texturePainter)));
      await pumpFrames(tester, 3);
      final paints = painter.paints;

      texture.acceptDeferredFrames = false;
      texture.textureChanged();
      await tester.pump(_frame);
      expect(painter.paints, paints, reason: 'the replay worker is behind');

      texture.acceptDeferredFrames = true;
      await tester.pump(_frame);

      expect(painter.paints, paints + 1);
    });
  });

  group('Flutter renderer', () {
    gateTests((tester, drawOptimization) async {
      await tester.pumpWidget(sizedHost(rive.FlutterRiveRendererWidget(
        painter: painter,
        drawOptimization: drawOptimization,
      )));
      await tester.pump(_frame);
    });

    testWidgets('the first advance draws after a paint that preceded it', (
      tester,
    ) async {
      // The first paint runs at layout, before the ticker's first advance.
      await tester.pumpWidget(host(rive.FlutterRiveRendererWidget(
        painter: painter,
      )));
      expect(painter.paints, 1);

      await tester.pump(_frame);

      expect(painter.paints, 2);
    });

    testWidgets('a paint it did not request with nothing changed draws once',
        (tester) async {
      await tester.pumpWidget(host(rive.FlutterRiveRendererWidget(
        painter: painter,
      )));
      await pumpFrames(tester, 3);
      final paints = painter.paints;
      final box = tester.renderObject<rive.FlutterRiveRenderBox>(
        find.byType(rive.FlutterRiveRendererWidget),
      );

      expect(artboard.didChange, isFalse);

      // Stands in for an ancestor repainting between two advances. With
      // nothing changed, it schedules no further draw.
      box.markNeedsPaint();
      await pumpFrames(tester, 3);

      expect(painter.paints, paints + 1);
    });

    testWidgets('a paint it did not request that consumes a change after '
        'settling gets its trailing draw', (tester) async {
      await tester.pumpWidget(host(rive.FlutterRiveRendererWidget(
        painter: painter,
      )));
      await pumpFrames(tester, 2);
      final box = tester.renderObject<rive.FlutterRiveRenderBox>(
        find.byType(rive.FlutterRiveRendererWidget),
      );

      // Settle through a trailing draw.
      stateMachine.advanceAndApply(0.1);
      painter.keepAdvancing = false;
      await pumpFrames(tester, 3);
      expect(box.isTickerActive, isFalse);
      final paints = painter.paints;

      // A change while idle, drawn by an ancestor's repaint.
      stateMachine.advanceAndApply(0.1);
      box.markNeedsPaint();
      await tester.pump(_frame);
      expect(painter.paints, paints + 1);
      expect(box.isTickerActive, isTrue, reason: 'one tick for the trailing draw');

      await tester.pump(_frame);
      expect(painter.paints, paints + 2);
      expect(box.isTickerActive, isFalse);
    });

    testWidgets('RiveFileWidget passes drawOptimization on', (tester) async {
      await tester.pumpWidget(host(rive.RiveFileWidget(
        file: riveFile,
        painter: painter,
        drawOptimization: rive.DrawOptimization.alwaysDraw,
      )));

      final box = tester.renderObject<rive.FlutterRiveRenderBox>(
        find.byType(rive.FlutterRiveRendererWidget),
      );
      expect(box.drawOptimization, rive.DrawOptimization.alwaysDraw);
    });

    testWidgets('RiveProceduralRenderingWidget passes drawOptimization on', (
      tester,
    ) async {
      await tester.pumpWidget(host(rive.RiveProceduralRenderingWidget(
        riveFactory: rive.Factory.flutter,
        painter: painter,
        drawOptimization: rive.DrawOptimization.alwaysDraw,
      )));

      final box = tester.renderObject<rive.FlutterRiveRenderBox>(
        find.byType(rive.FlutterRiveRendererWidget),
      );
      expect(box.drawOptimization, rive.DrawOptimization.alwaysDraw);
    });
  });
}
