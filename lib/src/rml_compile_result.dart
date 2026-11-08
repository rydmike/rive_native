import 'dart:convert';
import 'dart:typed_data';

/// One error `rmlToRev` reported: the compiler's own, or one added for a
/// `file=` this binding could not embed.
///
/// Shared by the ffi and web implementations so callers see one type on both
/// platforms.
class RmlCompileError {
  /// 1-based; 0 when the error is not tied to a line.
  final int line;

  final String message;

  /// The authored id of the element the error is about; null when the error
  /// is not about one element, or that element's id doesn't identify it
  /// (none, malformed, reserved, or claimed by an earlier element).
  final String? id;

  const RmlCompileError({required this.line, required this.message, this.id});

  /// Reads the `errorsJson` array native sends across FFI/wasm. Never
  /// throws: text that is not the expected JSON shape becomes one error
  /// carrying that text verbatim, since a stale native library must not
  /// crash the caller.
  static List<RmlCompileError> listFromJson(String json) {
    try {
      final decoded = jsonDecode(json);
      if (decoded is! List) {
        throw const FormatException('not a JSON array');
      }
      return decoded
          .cast<Map<String, dynamic>>()
          .map(
            (error) => RmlCompileError(
              line: error['line'] as int,
              message: error['message'] as String,
              id: (error['id'] as String?)?.isEmpty ?? true
                  ? null
                  : error['id'] as String,
            ),
          )
          .toList();
    } catch (_) {
      return [RmlCompileError(line: 0, message: json.trim())];
    }
  }
}

/// The outcome of compiling a markup document into `.rev` bytes: exactly one
/// of [bytes] and [errors] is set.
///
/// Shared by the ffi and web implementations of `rmlToRev` so callers see one
/// type on both platforms.
class RmlCompileResult {
  /// The compiled `.rev`, or null when the compile failed.
  final Uint8List? bytes;

  /// Why the compile produced nothing, in the order the compiler reported
  /// them. Empty when [bytes] is set.
  final List<RmlCompileError> errors;

  const RmlCompileResult.success(Uint8List this.bytes) : errors = const [];
  const RmlCompileResult.failure(this.errors) : bytes = null;

  bool get isSuccess => bytes != null;

  /// `<line>: <message>` per error, for callers that only want text. Null on
  /// success.
  String? get error => bytes != null
      ? null
      : errors.map((e) => '${e.line}: ${e.message}\n').join();
}
