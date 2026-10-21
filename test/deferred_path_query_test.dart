import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_test/flutter_test.dart';
import 'package:rive_native/rive_deferred.dart';
import 'package:rive_native/rive_native.dart';

/// Deferred render paths stream their geometry into the command buffer and
/// retain none, so every query here answers from the binding's shadow copy.
/// The editor swaps to the flutter factory under test, which is how these
/// queries once regressed to always-empty without a single test failing.
/// The same battery runs against both factories so their answers can never
/// silently diverge again.
void main() {
  final deferred = makeHeadlessDeferredFactory();

  if (!kIsWeb) {
    test('headless deferred factory is available', () {
      expect(deferred, isNotNull);
    });
  }

  final factories = <String, Factory>{
    'flutter': Factory.flutter,
    if (deferred != null) 'deferred': deferred,
  };

  // Clockwise unit square scaled to 100.
  RenderPath square(Factory factory) {
    final path = factory.makePath(true);
    path.moveTo(0, 0);
    path.lineTo(100, 0);
    path.lineTo(100, 100);
    path.lineTo(0, 100);
    path.close();
    return path;
  }

  for (final MapEntry(key: name, value: factory) in factories.entries) {
    group('$name factory', () {
      test('hit tests a path', () {
        final path = square(factory);
        expect(path.hitTest(Vec2D.fromValues(50, 50)), true);
        expect(path.hitTest(Vec2D.fromValues(150, 50)), false);
      });

      test('hit tests a transformed path', () {
        final path = square(factory);
        final transform = Mat2D.fromTranslate(200, 0);
        expect(path.hitTest(Vec2D.fromValues(20, 20), transform: transform),
            false);
        expect(path.hitTest(Vec2D.fromValues(220, 20), transform: transform),
            true);
      });

      test('computes precise bounds', () {
        final path = square(factory);
        final bounds = path.computePreciseBounds(Mat2D.identity);
        expect(bounds.left, 0);
        expect(bounds.top, 0);
        expect(bounds.right, 100);
        expect(bounds.bottom, 100);
      });

      test('reports winding direction', () {
        expect(square(factory).isClockwise(Mat2D.identity), true);
        final reversed = factory.makePath(true);
        reversed.moveTo(0, 0);
        reversed.lineTo(0, 100);
        reversed.lineTo(100, 100);
        reversed.lineTo(100, 0);
        reversed.close();
        expect(reversed.isClockwise(Mat2D.identity), false);
      });

      test('detects a collinear path', () {
        final line = factory.makePath(true);
        line.moveTo(0, 0);
        line.lineTo(100, 0);
        expect(line.isColinear, isNotNull);
        expect(square(factory).isColinear, isNull);
      });

      test('measures a path', () {
        final measure = PathMeasure.make(square(factory));
        expect(measure.length, 400);
        final (pos, _) = measure.atDistance(50);
        expect(pos, Vec2D.fromValues(50, 0));
      });

      test('rewind empties queries', () {
        final path = square(factory);
        expect(path.hitTest(Vec2D.fromValues(50, 50)), true);
        path.reset();
        expect(path.hitTest(Vec2D.fromValues(50, 50)), false);
      });

      test('accumulates geometry across flushes', () {
        final path = factory.makePath(true);
        path.moveTo(0, 0);
        path.lineTo(100, 0);
        path.lineTo(100, 100);
        // Force a native flush mid-build, then keep appending.
        expect(path.computePreciseBounds(Mat2D.identity).height, 100);
        path.lineTo(0, 100);
        path.close();
        expect(path.hitTest(Vec2D.fromValues(50, 50)), true);
      });

      test('honors fill rule', () {
        final path = factory.makePath(true);
        path.fillType = PathFillType.evenOdd;
        path.moveTo(0, 0);
        path.lineTo(100, 0);
        path.lineTo(100, 100);
        path.lineTo(0, 100);
        path.close();
        path.moveTo(25, 25);
        path.lineTo(75, 25);
        path.lineTo(75, 75);
        path.lineTo(25, 75);
        path.close();
        expect(path.hitTest(Vec2D.fromValues(50, 50)), false);
        expect(path.hitTest(Vec2D.fromValues(10, 50)), true);
      });

      test('composes with addPath', () {
        final composed = factory.makePath(true);
        composed.addPath(square(factory), Mat2D.fromTranslate(200, 0));
        expect(composed.hitTest(Vec2D.fromValues(220, 20)), true);
        expect(composed.hitTest(Vec2D.fromValues(20, 20)), false);
        expect(composed.computePreciseBounds(Mat2D.identity).left, 200);
      });

      test('dash effect measures the source path', () {
        final dash = Renderer.makeDashPath();
        dash.addToDashArray(10, false);
        final effect = dash.effectPath(square(factory));
        expect(dash.pathLength, 400);
        expect(effect.computePreciseBounds(Mat2D.identity).width, 100);
      });

      test('trim effect produces a measurable path', () {
        final trim = Renderer.makeTrimPath();
        trim.start = 0;
        trim.end = 0.5;
        trim.mode = TrimPathMode.sequential;
        final effect = square(factory);
        final trimmed = trim.effectPath(effect, 0);
        expect(PathMeasure.make(trimmed).length, 200);
      });
    });
  }
}
