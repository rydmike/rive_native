import 'package:rive_native/math.dart';

/// Where a scroll event sits within its gesture. A phaseless wheel only ever
/// reports [update]. The ordinals cross the native binding as-is, so do not
/// reorder them.
enum ScrollPhase {
  /// Stops any running fling and primes velocity tracking.
  begin,

  /// The user is still driving the gesture, and the only phase a detented
  /// wheel reports.
  update,

  /// Contact ended; the runtime flings from the velocity it accumulated.
  /// Hosts whose platform generates its own momentum never send this.
  end,

  /// Platform-generated after release. Applied directly, never flung on top
  /// of; closed by going idle rather than by an end.
  momentum,

  /// Contact landed during momentum. Halts motion; delta is ignored.
  inertiaCancel,
}

/// A scroll delta from indirect input: a wheel, or a trackpad gesture the
/// platform already classified as a scroll. Direct touch stays on the pointer
/// path.
class ScrollEvent {
  /// Distance the content moves, in artboard-space pixels; revealing later
  /// content is negative. Hosts normalize; the runtime never sees platform
  /// units.
  final Vec2D delta;

  final ScrollPhase phase;

  /// Pixel-precise source (trackpad) rather than a detented wheel.
  final bool precise;

  ScrollEvent({
    required this.delta,
    this.phase = ScrollPhase.update,
    this.precise = false,
  });
}
