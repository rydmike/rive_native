import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rive_native/rive_native.dart' as rive;

/// Every [rive.ArtboardWidgetPainter] the renderer creates is disposed,
/// including the one replaced when the `painter` prop changes
/// (rive-flutter #636). Tracked through [FlutterMemoryAllocations], the
/// events `leak_tracker` reports from.
void main() {
  testWidgets('swapping the painter disposes the outgoing painter',
      (tester) async {
    expect(await rive.RiveNative.init(), isTrue);

    final created = <Object>{};
    final disposed = <Object>{};
    void onEvent(ObjectEvent event) {
      if (event.object is! rive.ArtboardWidgetPainter) return;
      if (event is ObjectCreated) created.add(event.object);
      if (event is ObjectDisposed) disposed.add(event.object);
    }

    final allocations = FlutterMemoryAllocations.instance;
    allocations.addListener(onEvent);
    addTearDown(() => allocations.removeListener(onEvent));

    Widget renderer(rive.ProceduralPainter painter) => Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: SizedBox(
              width: 50,
              height: 50,
              child: rive.ArtboardWidgetRiveRenderer(
                painter: painter,
                riveFactory: rive.Factory.rive,
              ),
            ),
          ),
        );

    final painters = List.generate(3, (_) => _NoopProceduralPainter());
    addTearDown(() {
      for (final painter in painters) {
        painter.dispose();
      }
    });

    for (final painter in painters) {
      await tester.pumpWidget(renderer(painter));
    }
    expect(created, hasLength(painters.length));
    expect(disposed, hasLength(painters.length - 1),
        reason: 'each swap disposes the painter it replaced');

    await tester.pumpWidget(const SizedBox());
    expect(disposed, created);
  });

  testWidgets('two renderers exchanging painters keep both ticker states',
      (tester) async {
    expect(await rive.RiveNative.init(), isTrue);

    final a = _TickingPainter();
    final b = _TickingPainter();
    addTearDown(a.dispose);
    addTearDown(b.dispose);

    Widget renderers(rive.ProceduralPainter first,
            rive.ProceduralPainter second) =>
        Directionality(
          textDirection: TextDirection.ltr,
          child: Row(
            children: [
              for (final painter in [first, second])
                SizedBox(
                  width: 50,
                  height: 50,
                  child: rive.ArtboardWidgetRiveRenderer(
                    painter: painter,
                    riveFactory: rive.Factory.rive,
                  ),
                ),
            ],
          ),
        );

    await tester.pumpWidget(renderers(a, b));
    await tester.pump();
    expect([a.isTickerActive, b.isTickerActive], [true, true]);

    await tester.pumpWidget(renderers(b, a));
    await tester.pump();
    expect([a.isTickerActive, b.isTickerActive], [true, true],
        reason: 'disposing a replaced wrapper must not clear the ticker '
            'state another renderer just gave its painter');

    await tester.pumpWidget(const SizedBox());
  });
}

final class _NoopProceduralPainter extends rive.ProceduralPainter {
  @override
  bool advance(double elapsedSeconds) => false;

  @override
  void paint(rive.Renderer renderer, Size size, double paintPixelRatio) {}
}

final class _TickingPainter extends rive.ProceduralPainter
    with rive.RiveTickerAwarePainterMixin {
  @override
  bool advance(double elapsedSeconds) => true;

  @override
  void paint(rive.Renderer renderer, Size size, double paintPixelRatio) {}
}
