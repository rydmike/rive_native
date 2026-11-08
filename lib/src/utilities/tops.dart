abstract class Parentable<T> {
  T? get parent;
}

/// Get the top most components (any child that has an ancestor in the set
/// should be pruned).
Set<T> tops<T extends Parentable<T>>(Iterable<T> parentables) {
  // Materialize once: on a lazy iterable every contains below would re-run
  // the whole chain, quadratic in the selection size.
  final lookup = parentables is Set<T> ? parentables : parentables.toSet();
  var tips = <T>{};
  outerLoop:
  for (final item in lookup) {
    for (T? parent = item.parent; parent != null; parent = parent.parent) {
      if (lookup.contains(parent)) {
        continue outerLoop;
      }
    }
    tips.add(item);
  }
  return tips;
}

bool isChildOf<T extends Parentable<T>>(T child, Iterable<T> parents) {
  for (T? parent = child; parent != null; parent = parent.parent) {
    if (parents.contains(parent)) {
      return true;
    }
  }
  return false;
}
