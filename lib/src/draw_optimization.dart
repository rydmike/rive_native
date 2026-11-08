/// Controls when a Rive widget redraws its artboard.
///
/// Advancing is unaffected: the widget keeps advancing while its content is
/// animating, and stops once it settles, in either mode.
enum DrawOptimization {
  /// Redraw on every advanced frame.
  alwaysDraw,

  /// Redraw only when the artboard changed since it was last drawn. Layout,
  /// fit, alignment and texture changes still redraw.
  drawWhenChanged,
}
