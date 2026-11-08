import 'package:meta/meta.dart';

/// Dart interpolators a native artboard runs by handle.
///
/// The editor evaluates its own artboards' layouts in Dart, while the
/// artboards they host (nested artboards, list items) run natively. When one of
/// those inherits a scripted layout interpolator from a Dart parent, the parent
/// registers its interpolator here and passes the handle down with the
/// cascade; native then calls back into the parent's own instance (see
/// HostedInterpolator in rive_binding.cpp) instead of running a copy of the
/// script.
abstract final class InterpolatorCallbacks {
  static final Map<int, double Function(double)> _transforms = {};
  static int _lastHandle = 0;

  /// Registers [transform] and returns the (non-zero, 32-bit) handle native
  /// calls it by.
  static int register(double Function(double) transform) {
    do {
      _lastHandle = (_lastHandle + 1) & 0xFFFFFFFF;
    } while (_lastHandle == 0 || _transforms.containsKey(_lastHandle));
    _transforms[_lastHandle] = transform;
    return _lastHandle;
  }

  static void unregister(int handle) => _transforms.remove(handle);

  @visibleForTesting
  static bool isRegistered(int handle) => _transforms.containsKey(handle);

  /// Runs the transform registered for [handle], or returns [factor]
  /// unchanged once that handle is gone.
  static double transform(int handle, double factor) =>
      _transforms[handle]?.call(factor) ?? factor;
}
