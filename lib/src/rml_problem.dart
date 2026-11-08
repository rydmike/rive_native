import 'dart:convert';

/// Something rml's inspect found wrong with a document: the compiler accepts
/// it, but it is wired to the wrong thing.
///
/// Shared by the ffi and web implementations of `rmlInspect` so callers see
/// one type on both platforms.
class RmlProblem {
  /// 'error' or 'warning'.
  final String severity;

  /// One of inspect.hpp's Problem kinds, e.g. 'unresolved-bind-path' or
  /// 'artboards-overlap'; 'syntax' for a parse or naming failure.
  final String kind;

  final String message;

  /// 1-based; 0 when the problem is not tied to a line (a document-wide
  /// finding).
  final int line;

  /// The authored ids of the elements the problem is about, the element at
  /// [line] first when it has one; when it has none, the id of the element
  /// whose check produced the problem instead (not necessarily the element
  /// at [line]). Elements whose id doesn't identify them (none, malformed,
  /// reserved, or claimed by an earlier element) are left out; empty for a
  /// document-wide finding.
  final List<String> ids;

  const RmlProblem({
    required this.severity,
    required this.kind,
    required this.message,
    required this.line,
    this.ids = const [],
  });

  /// Reads the `problemsJson` array native sends across FFI/wasm.
  static List<RmlProblem> listFromJson(String json) =>
      (jsonDecode(json) as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .map(
            (problem) => RmlProblem(
              severity: problem['severity'] as String,
              kind: problem['kind'] as String,
              message: problem['message'] as String,
              line: problem['line'] as int,
              ids: (problem['ids'] as List<dynamic>?)?.cast<String>() ??
                  const [],
            ),
          )
          .toList();
}
