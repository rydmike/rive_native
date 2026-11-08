// PaintDirt that we receive from the C++ bindings (slightly different).
class PaintDirtFromNative {
  static const int style = 1 << 0;
  static const int color = 1 << 1;
  static const int thickness = 1 << 2;
  static const int join = 1 << 3;
  static const int cap = 1 << 4;
  static const int blendMode = 1 << 5;
  static const int linear = 1 << 6;
  static const int radial = 1 << 7;
  static const int removeGradient = 1 << 8;
}

// Stop count that tells native to drop the gradient.
const int removeGradientStops = 0xFFFF;

// PaintDirt that we send to the C++ bindings.
class PaintDirt {
  static const int style = 1 << 0;
  static const int color = 1 << 1;
  static const int thickness = 1 << 2;
  static const int join = 1 << 3;
  static const int cap = 1 << 4;
  static const int blendMode = 1 << 5;
  static const int radial =
      1 << 6; // 0 == linear, 1 == radial only valid if stops != 0
  static const int done = 1 << 7; // 1 when no more gradient stops will follow

  static const int feather = 1 << 8;
  static const int additiveness = 1 << 9;
  // Written with the fields before the gradient, right after blendMode.
  static const int strokePosition = 1 << 10;
  static const int gradientTransform = 1 << 11;
  // A sweep. `radial` says linear or radial; this overrides both, and its
  // payload is the linear one (start then end), which the factory does not
  // read yet.
  static const int angular = 1 << 12;

  // This flag is only used on the Dart side to set a bit in the dirty flags
  // indicating that the gradient has changed. It is not actually read on the
  // native side, so it's set to a high bit that native will ignore.
  static const int gradient = 1 << 15;
}
