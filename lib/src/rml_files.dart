import 'dart:convert';
import 'dart:typed_data';

import 'package:rive_native/src/rml_compile_result.dart';

export 'package:rive_native/src/rml_compile_result.dart';

/// One file of a project handed to the compiler. Null [bytes] means the file
/// exists but its bytes are withheld: a binary asset naming it compiles
/// without contents.
class RmlFileInput {
  final String path;
  final Uint8List? bytes;

  const RmlFileInput(this.path, [this.bytes]);

  /// A file that exists but whose bytes stay with the caller.
  const RmlFileInput.withheld(this.path) : bytes = null;

  bool get withheld => bytes == null;
}

/// A file an export split out of the markup. [bytesOmitted] files only name an
/// asset: [bytes] is empty and the real bytes live elsewhere.
class RmlExportedFile {
  final String path;
  final Uint8List bytes;
  final bool bytesOmitted;

  const RmlExportedFile({
    required this.path,
    required this.bytes,
    this.bytesOmitted = false,
  });
}

/// A `.rev` exported as `main.rml`'s markup plus the files it references with
/// `file=`: a script or shader per file, and a byteless file per binary asset.
class RmlExportedProject {
  final String rml;
  final List<RmlExportedFile> files;

  const RmlExportedProject({required this.rml, required this.files});
}

/// An asset element's `file=`, as the compile resolved it.
class RmlFileReference {
  /// The asset's id in the compiled rev, `client:object`.
  final String id;

  /// The `file=` value.
  final String path;

  /// 1-based line in the markup.
  final int line;

  const RmlFileReference({
    required this.id,
    required this.path,
    required this.line,
  });

  /// Reads the `refs` array native sends across FFI/wasm. Never throws: text
  /// that is not the expected shape yields no references.
  static List<RmlFileReference> listFromJson(String json) {
    try {
      final decoded = jsonDecode(json);
      if (decoded is! List) {
        return const [];
      }
      return [
        for (final entry in decoded.cast<Map<String, dynamic>>())
          RmlFileReference(
            id: entry['id'] as String,
            path: entry['path'] as String,
            line: entry['line'] as int,
          ),
      ];
    } catch (_) {
      return const [];
    }
  }
}

/// The outcome of compiling a project: exactly one of [bytes] and [errors] is
/// set. [fileReferences] is set whenever the compile ran, failed or not.
class RmlProjectCompileResult {
  /// The compiled `.rev`, or null when the compile failed.
  final Uint8List? bytes;

  final List<RmlCompileError> errors;

  final List<RmlFileReference> fileReferences;

  const RmlProjectCompileResult.success(
    Uint8List this.bytes, {
    this.fileReferences = const [],
  }) : errors = const [];

  const RmlProjectCompileResult.failure(
    this.errors, {
    this.fileReferences = const [],
  }) : bytes = null;

  bool get isSuccess => bytes != null;
}

/// The wire format of a file bundle, both directions: a varuint count, then
/// per file a varuint length and utf-8 path, a varuint flags (bit 0: withheld
/// going in, bytes omitted coming out) and a varuint length and bytes.
const int _flagBytesOmitted = 1;

/// Lengths stay below 2^28 so the shifts are exact where bit operations are
/// 32 bit.
const int _maxVarUint = 0x0fffffff;

void _writeVarUint(BytesBuilder out, int value) {
  if (value < 0 || value > _maxVarUint) {
    throw RangeError.range(value, 0, _maxVarUint, 'length');
  }
  var rest = value;
  while (rest >= 0x80) {
    out.addByte((rest & 0x7f) | 0x80);
    rest >>= 7;
  }
  out.addByte(rest);
}

int _readVarUint(Uint8List data, List<int> cursor) {
  var result = 0;
  var shift = 0;
  while (true) {
    if (cursor[0] >= data.length) {
      throw const FormatException('file bundle ends early');
    }
    final byte = data[cursor[0]++];
    result |= (byte & 0x7f) << shift;
    if (byte & 0x80 == 0) {
      return result;
    }
    shift += 7;
    if (shift > 21) {
      throw const FormatException('file bundle length is too large');
    }
  }
}

Uint8List _readBytes(Uint8List data, List<int> cursor) {
  final length = _readVarUint(data, cursor);
  if (length > data.length - cursor[0]) {
    throw const FormatException('file bundle ends early');
  }
  final bytes = Uint8List.sublistView(data, cursor[0], cursor[0] + length);
  cursor[0] += length;
  return bytes;
}

/// Encodes [files] for the compiler. A file with null bytes is withheld.
Uint8List encodeRmlFileInputs(List<RmlFileInput> files) {
  final out = BytesBuilder(copy: false);
  _writeVarUint(out, files.length);
  for (final file in files) {
    final path = utf8.encode(file.path);
    _writeVarUint(out, path.length);
    out.add(path);
    final bytes = file.bytes;
    _writeVarUint(out, bytes == null ? _flagBytesOmitted : 0);
    _writeVarUint(out, bytes?.length ?? 0);
    if (bytes != null) {
      out.add(bytes);
    }
  }
  return out.takeBytes();
}

/// Decodes the bundle an export returns. Throws a [FormatException] when the
/// bundle is cut short or runs past its last file.
List<RmlExportedFile> decodeRmlExportedFiles(Uint8List bundle) {
  if (bundle.isEmpty) {
    return const [];
  }
  final cursor = [0];
  final count = _readVarUint(bundle, cursor);
  final files = <RmlExportedFile>[];
  for (var i = 0; i < count; i++) {
    final path = utf8.decode(_readBytes(bundle, cursor), allowMalformed: true);
    final flags = _readVarUint(bundle, cursor);
    final bytes = _readBytes(bundle, cursor);
    files.add(
      RmlExportedFile(
        path: path,
        bytes: Uint8List.fromList(bytes),
        bytesOmitted: flags & _flagBytesOmitted != 0,
      ),
    );
  }
  if (cursor[0] != bundle.length) {
    throw const FormatException('file bundle has bytes past its last file');
  }
  return files;
}
