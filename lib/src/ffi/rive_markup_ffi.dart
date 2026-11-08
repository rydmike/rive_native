import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:rive_native/src/ffi/dynamic_library_helper.dart';
import 'package:rive_native/src/rml_commit_diff.dart';
import 'package:rive_native/src/rml_files.dart';
import 'package:rive_native/src/rml_problem.dart';

export 'package:rive_native/src/rml_commit_diff.dart';
export 'package:rive_native/src/rml_compile_result.dart';
export 'package:rive_native/src/rml_files.dart';
export 'package:rive_native/src/rml_problem.dart';

final DynamicLibrary _nativeLib = DynamicLibraryHelper.nativeLib;

/// Every symbol this file looks up in the native library, kept in one place
/// so [markupAvailable] can probe all of them. Not exported from
/// rive_markup.dart.
const List<String> markupSymbols = [
  'revToRml',
  'freeRmlExport',
  'rmlToRev',
  'freeRmlCompile',
  'rmlSchemaDescribe',
  'rmlSchemaSearch',
  'rmlSchemaTypes',
  'freeRmlSchemaText',
  'rmlInspect',
  'freeRmlInspect',
  'rmlCommitDiff',
  'freeRmlCommitDiff',
  'revToRmlFiles',
  'freeRmlExportFiles',
  'rmlToRevFiles',
  'freeRmlProjectCompile',
  'rmlCommitDiffFiles',
];

/// Whether the loaded native library carries the markup symbols. False in
/// flutter_runtime builds, where rml is excluded (editor-only); callers (and
/// tests) must check before using [revToRml] or [rmlToRev] -- the
/// lazily-initialized lookups below throw on first use otherwise. Every
/// markup symbol is probed: they come from one translation unit, so a
/// library carrying only some of them is a stale build, and failing closed
/// sends callers down their fallback instead of throwing.
final bool markupAvailable = () {
  try {
    for (final symbol in markupSymbols) {
      _nativeLib.lookup<NativeFunction<Void Function(Pointer<Void>)>>(symbol);
    }
    return true;
  } on ArgumentError {
    return false;
  }
}();

// Before the empty-input shortcuts, which would otherwise answer without the
// library and read as "no such type" or a clean document.
void _requireMarkup() {
  if (!markupAvailable) {
    throw StateError('markup is not available');
  }
}

final class _RmlExportResponseStruct extends Struct {
  external Pointer<Uint8> data;

  @Size()
  external int size;
}

final bool Function(
  Pointer<Uint8> bytes,
  int length,
  Pointer<_RmlExportResponseStruct> response,
)
_revToRml = _nativeLib
    .lookup<
      NativeFunction<
        Bool Function(Pointer<Uint8>, Uint64, Pointer<_RmlExportResponseStruct>)
      >
    >('revToRml')
    .asFunction();

final void Function(Pointer<_RmlExportResponseStruct> response)
_freeRmlExport = _nativeLib
    .lookup<NativeFunction<Void Function(Pointer<_RmlExportResponseStruct>)>>(
      'freeRmlExport',
    )
    .asFunction();

/// Converts the bytes of a .rev file into the equivalent .rml markup
/// document, with every payload embedded. Returns null when the bytes are not
/// a readable .rev.
Uint8List? revToRml(Uint8List revBytes) {
  if (revBytes.isEmpty) {
    return null;
  }
  final source = calloc<Uint8>(revBytes.length);
  final response = calloc<_RmlExportResponseStruct>();
  try {
    source.asTypedList(revBytes.length).setAll(0, revBytes);
    final ok = _revToRml(source, revBytes.length, response);
    if (!ok || response.ref.data == nullptr || response.ref.size <= 0) {
      return null;
    }
    // A view over native memory; copy it out before freeing.
    return Uint8List.fromList(response.ref.data.asTypedList(response.ref.size));
  } finally {
    _freeRmlExport(response);
    calloc.free(response);
    calloc.free(source);
  }
}

final class _RmlCompileResponseStruct extends Struct {
  external Pointer<Uint8> data;

  @Size()
  external int size;

  external Pointer<Uint8> error;

  @Size()
  external int errorSize;
}

final void Function(
  Pointer<Uint8> bytes,
  int length,
  Pointer<_RmlCompileResponseStruct> response,
)
_rmlToRev = _nativeLib
    .lookup<
      NativeFunction<
        Void Function(
          Pointer<Uint8>,
          Uint64,
          Pointer<_RmlCompileResponseStruct>,
        )
      >
    >('rmlToRev')
    .asFunction();

final void Function(Pointer<_RmlCompileResponseStruct> response)
_freeRmlCompile = _nativeLib
    .lookup<NativeFunction<Void Function(Pointer<_RmlCompileResponseStruct>)>>(
      'freeRmlCompile',
    )
    .asFunction();

/// Compiles a .rml markup document into the equivalent .rev bytes -- the
/// inverse of [revToRml]. Every payload the document needs must be embedded
/// in it: a `file=` reference has no directory to resolve against here and
/// compiles as an error.
RmlCompileResult rmlToRev(Uint8List rmlBytes) {
  if (rmlBytes.isEmpty) {
    return RmlCompileResult.failure(const [
      RmlCompileError(line: 0, message: 'no markup to compile'),
    ]);
  }
  final source = calloc<Uint8>(rmlBytes.length);
  final response = calloc<_RmlCompileResponseStruct>();
  try {
    source.asTypedList(rmlBytes.length).setAll(0, rmlBytes);
    _rmlToRev(source, rmlBytes.length, response);
    if (response.ref.data != nullptr && response.ref.size > 0) {
      // A view over native memory; copy it out before freeing.
      return RmlCompileResult.success(
        Uint8List.fromList(response.ref.data.asTypedList(response.ref.size)),
      );
    }
    if (response.ref.error != nullptr && response.ref.errorSize > 0) {
      return RmlCompileResult.failure(
        RmlCompileError.listFromJson(
          utf8.decode(
            response.ref.error.asTypedList(response.ref.errorSize),
            allowMalformed: true,
          ),
        ),
      );
    }
    return RmlCompileResult.failure(const [
      RmlCompileError(line: 0, message: 'markup compile failed'),
    ]);
  } finally {
    _freeRmlCompile(response);
    calloc.free(response);
    calloc.free(source);
  }
}

final class _RmlSchemaTextResponseStruct extends Struct {
  external Pointer<Uint8> data;

  @Size()
  external int size;
}

final bool Function(
  Pointer<Uint8> typeName,
  int typeNameLength,
  bool includeEditorOnly,
  bool animatableOnly,
  bool bindableOnly,
  bool json,
  Pointer<_RmlSchemaTextResponseStruct> response,
)
_rmlSchemaDescribe = _nativeLib
    .lookup<
      NativeFunction<
        Bool Function(
          Pointer<Uint8>,
          Uint64,
          Bool,
          Bool,
          Bool,
          Bool,
          Pointer<_RmlSchemaTextResponseStruct>,
        )
      >
    >('rmlSchemaDescribe')
    .asFunction();

final void Function(
  Pointer<Uint8> text,
  int textLength,
  bool json,
  Pointer<_RmlSchemaTextResponseStruct> response,
)
_rmlSchemaSearch = _nativeLib
    .lookup<
      NativeFunction<
        Void Function(
          Pointer<Uint8>,
          Uint64,
          Bool,
          Pointer<_RmlSchemaTextResponseStruct>,
        )
      >
    >('rmlSchemaSearch')
    .asFunction();

final void Function(bool json, Pointer<_RmlSchemaTextResponseStruct> response)
_rmlSchemaTypes = _nativeLib
    .lookup<
      NativeFunction<Void Function(Bool, Pointer<_RmlSchemaTextResponseStruct>)>
    >('rmlSchemaTypes')
    .asFunction();

final void Function(Pointer<_RmlSchemaTextResponseStruct> response)
_freeRmlSchemaText = _nativeLib
    .lookup<
      NativeFunction<Void Function(Pointer<_RmlSchemaTextResponseStruct>)>
    >('freeRmlSchemaText')
    .asFunction();

String? _decodeSchemaText(Pointer<_RmlSchemaTextResponseStruct> response) {
  if (response.ref.data == nullptr || response.ref.size <= 0) {
    return null;
  }
  return utf8.decode(response.ref.data.asTypedList(response.ref.size));
}

/// A core type's properties, inherited included: the same answer
/// `rive schema <typeName>` gives. Null for a type that does not exist --
/// [json] does not change that, an unknown type is empty either way.
///
/// [includeEditorOnly] is `--all`; [animatableOnly] and [bindableOnly] narrow
/// to properties that can be keyed or data bound, respectively.
///
/// Throws when [markupAvailable] is false.
String? rmlSchemaDescribe(
  String typeName, {
  bool includeEditorOnly = false,
  bool animatableOnly = false,
  bool bindableOnly = false,
  bool json = false,
}) {
  _requireMarkup();
  // No real type has an empty name; short-circuits the zero-length alloc
  // below, which calloc need not accept.
  if (typeName.isEmpty) {
    return null;
  }
  final nameBytes = utf8.encode(typeName);
  final namePtr = calloc<Uint8>(nameBytes.length);
  final response = calloc<_RmlSchemaTextResponseStruct>();
  try {
    namePtr.asTypedList(nameBytes.length).setAll(0, nameBytes);
    final found = _rmlSchemaDescribe(
      namePtr,
      nameBytes.length,
      includeEditorOnly,
      animatableOnly,
      bindableOnly,
      json,
      response,
    );
    if (!found) {
      return null;
    }
    return _decodeSchemaText(response);
  } finally {
    _freeRmlSchemaText(response);
    calloc.free(response);
    calloc.free(namePtr);
  }
}

/// Types and properties whose names contain [text], case-insensitively: the
/// same answer `rive schema --search <text>` gives. Empty when nothing
/// matches -- including an empty [text], which the CLI never passes through
/// to a search either.
///
/// Throws when [markupAvailable] is false.
String rmlSchemaSearch(String text, {bool json = false}) {
  _requireMarkup();
  if (text.isEmpty) {
    return json ? '[]\n' : '';
  }
  final textBytes = utf8.encode(text);
  final textPtr = calloc<Uint8>(textBytes.length);
  final response = calloc<_RmlSchemaTextResponseStruct>();
  try {
    textPtr.asTypedList(textBytes.length).setAll(0, textBytes);
    _rmlSchemaSearch(textPtr, textBytes.length, json, response);
    return _decodeSchemaText(response) ?? '';
  } finally {
    _freeRmlSchemaText(response);
    calloc.free(response);
    calloc.free(textPtr);
  }
}

/// Every authorable core type name: the same answer `rive schema --list`
/// gives.
///
/// Throws when [markupAvailable] is false.
String rmlSchemaTypes({bool json = false}) {
  _requireMarkup();
  final response = calloc<_RmlSchemaTextResponseStruct>();
  try {
    _rmlSchemaTypes(json, response);
    return _decodeSchemaText(response) ?? '';
  } finally {
    _freeRmlSchemaText(response);
    calloc.free(response);
  }
}

final class _RmlInspectResponseStruct extends Struct {
  external Pointer<Uint8> data;

  @Size()
  external int size;
}

final void Function(
  Pointer<Uint8> rml,
  int rmlLength,
  Pointer<_RmlInspectResponseStruct> response,
)
_rmlInspect = _nativeLib
    .lookup<
      NativeFunction<
        Void Function(
          Pointer<Uint8>,
          Uint64,
          Pointer<_RmlInspectResponseStruct>,
        )
      >
    >('rmlInspect')
    .asFunction();

final void Function(Pointer<_RmlInspectResponseStruct> response)
_freeRmlInspect = _nativeLib
    .lookup<NativeFunction<Void Function(Pointer<_RmlInspectResponseStruct>)>>(
      'freeRmlInspect',
    )
    .asFunction();

/// Problems rml's inspect finds in a single RML document: the compiler
/// accepts these but they are wired wrong. Treats [rml] as one document --
/// no fragments, default InspectOptions.
///
/// A document that fails to parse comes back with one problem of kind
/// 'syntax' per parse error rather than throwing -- inspect folds parse
/// failures into the same problems list.
///
/// Throws when [markupAvailable] is false.
List<RmlProblem> rmlInspect(String rml) {
  _requireMarkup();
  if (rml.isEmpty) {
    // Mirrors rmlToRev's empty guard: avoids a zero-byte calloc, and an
    // empty document is not well-formed XML either way.
    return const [
      RmlProblem(
        severity: 'error',
        kind: 'syntax',
        message: 'no markup to inspect',
        line: 0,
      ),
    ];
  }
  final rmlBytes = utf8.encode(rml);
  final source = calloc<Uint8>(rmlBytes.length);
  final response = calloc<_RmlInspectResponseStruct>();
  try {
    source.asTypedList(rmlBytes.length).setAll(0, rmlBytes);
    _rmlInspect(source, rmlBytes.length, response);
    final json = response.ref.data == nullptr || response.ref.size <= 0
        ? '[]'
        : utf8.decode(
            response.ref.data.asTypedList(response.ref.size),
            allowMalformed: true,
          );
    return RmlProblem.listFromJson(json);
  } finally {
    _freeRmlInspect(response);
    calloc.free(response);
    calloc.free(source);
  }
}

final class _RmlCommitDiffResponseStruct extends Struct {
  external Pointer<Uint8> data;

  @Size()
  external int size;

  external Pointer<Uint8> report;

  @Size()
  external int reportSize;
}

final void Function(
  Pointer<Uint8> base,
  int baseLength,
  Pointer<Uint8> sandbox,
  int sandboxLength,
  int client,
  int firstObject,
  Pointer<_RmlCommitDiffResponseStruct> response,
)
_rmlCommitDiff = _nativeLib
    .lookup<
      NativeFunction<
        Void Function(
          Pointer<Uint8>,
          Uint64,
          Pointer<Uint8>,
          Uint64,
          Uint64,
          Uint64,
          Pointer<_RmlCommitDiffResponseStruct>,
        )
      >
    >('rmlCommitDiff')
    .asFunction();

final void Function(Pointer<_RmlCommitDiffResponseStruct> response)
_freeRmlCommitDiff = _nativeLib
    .lookup<
      NativeFunction<Void Function(Pointer<_RmlCommitDiffResponseStruct>)>
    >('freeRmlCommitDiff')
    .asFunction();

/// Diffs a sandbox markup document against its base, both compiled here: the
/// result classifies every change into a ChangeSet the live file can apply,
/// remapping new objects from `(client, firstObject)`. When
/// [markupAvailable] is false, or [base] or [sandbox] is empty, it returns a
/// failure without calling native; an empty [base] is the base's failure.
/// A negative [client] or [firstObject] throws an [ArgumentError].
RmlCommitDiff rmlCommitDiff(
  String base,
  String sandbox, {
  required int client,
  required int firstObject,
}) {
  RangeError.checkNotNegative(client, 'client');
  RangeError.checkNotNegative(firstObject, 'firstObject');
  if (!markupAvailable) {
    return const RmlCommitDiff.failure([
      RmlCompileError(line: 0, message: 'markup is not available'),
    ]);
  }
  if (base.isEmpty || sandbox.isEmpty) {
    return RmlCommitDiff.failure(const [
      RmlCompileError(line: 0, message: 'no markup to diff'),
    ], baseFailed: base.isEmpty);
  }
  final baseBytes = utf8.encode(base);
  final sandboxBytes = utf8.encode(sandbox);
  final basePtr = calloc<Uint8>(baseBytes.length);
  final sandboxPtr = calloc<Uint8>(sandboxBytes.length);
  final response = calloc<_RmlCommitDiffResponseStruct>();
  try {
    basePtr.asTypedList(baseBytes.length).setAll(0, baseBytes);
    sandboxPtr.asTypedList(sandboxBytes.length).setAll(0, sandboxBytes);
    _rmlCommitDiff(
      basePtr,
      baseBytes.length,
      sandboxPtr,
      sandboxBytes.length,
      client,
      firstObject,
      response,
    );
    final report =
        response.ref.report == nullptr || response.ref.reportSize <= 0
        ? '{}'
        : utf8.decode(
            response.ref.report.asTypedList(response.ref.reportSize),
            allowMalformed: true,
          );
    final changes = response.ref.data == nullptr || response.ref.size <= 0
        ? null
        : Uint8List.fromList(response.ref.data.asTypedList(response.ref.size));
    return RmlCommitDiff.fromJson(report, changes);
  } finally {
    _freeRmlCommitDiff(response);
    calloc.free(response);
    calloc.free(basePtr);
    calloc.free(sandboxPtr);
  }
}

final class _RmlExportFilesResponseStruct extends Struct {
  external Pointer<Uint8> data;

  @Size()
  external int size;

  external Pointer<Uint8> files;

  @Size()
  external int filesSize;
}

final bool Function(
  Pointer<Uint8> bytes,
  int length,
  Pointer<_RmlExportFilesResponseStruct> response,
)
_revToRmlFiles = _nativeLib
    .lookup<
      NativeFunction<
        Bool Function(
          Pointer<Uint8>,
          Uint64,
          Pointer<_RmlExportFilesResponseStruct>,
        )
      >
    >('revToRmlFiles')
    .asFunction();

final void Function(Pointer<_RmlExportFilesResponseStruct> response)
_freeRmlExportFiles = _nativeLib
    .lookup<
      NativeFunction<Void Function(Pointer<_RmlExportFilesResponseStruct>)>
    >('freeRmlExportFiles')
    .asFunction();

/// Converts the bytes of a .rev file into `main.rml`'s markup plus the files
/// it references with `file=`: scripts and shaders with their source, binary
/// assets as byteless files that only name them. Returns null when the bytes
/// are not a readable .rev or [markupAvailable] is false.
///
/// No file lands on the path `main.rml` or in a top-level folder named
/// `builtins` or `main.rml`; one that would gets another name
/// (`builtins_2/…`).
RmlExportedProject? revToRmlFiles(Uint8List revBytes) {
  if (!markupAvailable || revBytes.isEmpty) {
    return null;
  }
  final source = calloc<Uint8>(revBytes.length);
  final response = calloc<_RmlExportFilesResponseStruct>();
  try {
    source.asTypedList(revBytes.length).setAll(0, revBytes);
    final ok = _revToRmlFiles(source, revBytes.length, response);
    if (!ok || response.ref.data == nullptr || response.ref.size <= 0) {
      return null;
    }
    // Views over native memory; copy them out before freeing.
    final rml = utf8.decode(
      response.ref.data.asTypedList(response.ref.size),
      allowMalformed: true,
    );
    // Native always sends a bundle, at least its count; none means the copy
    // out failed.
    if (response.ref.files == nullptr || response.ref.filesSize <= 0) {
      return null;
    }
    final bundle = Uint8List.fromList(
      response.ref.files.asTypedList(response.ref.filesSize),
    );
    try {
      return RmlExportedProject(
        rml: rml,
        files: decodeRmlExportedFiles(bundle),
      );
    } on FormatException {
      return null;
    }
  } finally {
    _freeRmlExportFiles(response);
    calloc.free(response);
    calloc.free(source);
  }
}

final class _RmlProjectCompileResponseStruct extends Struct {
  external Pointer<Uint8> data;

  @Size()
  external int size;

  external Pointer<Uint8> error;

  @Size()
  external int errorSize;

  external Pointer<Uint8> refs;

  @Size()
  external int refsSize;
}

final void Function(
  Pointer<Uint8> bytes,
  int length,
  Pointer<Uint8> files,
  int filesLength,
  Pointer<_RmlProjectCompileResponseStruct> response,
)
_rmlToRevFiles = _nativeLib
    .lookup<
      NativeFunction<
        Void Function(
          Pointer<Uint8>,
          Uint64,
          Pointer<Uint8>,
          Uint64,
          Pointer<_RmlProjectCompileResponseStruct>,
        )
      >
    >('rmlToRevFiles')
    .asFunction();

final void Function(Pointer<_RmlProjectCompileResponseStruct> response)
_freeRmlProjectCompile = _nativeLib
    .lookup<
      NativeFunction<Void Function(Pointer<_RmlProjectCompileResponseStruct>)>
    >('freeRmlProjectCompile')
    .asFunction();

/// Compiles [rml] against [files]: text files are served as they are, and a
/// file with null bytes is present but compiles without contents. A `file=`
/// the list does not hold is an error naming the asset and path. When
/// [markupAvailable] is false, it returns a failure without calling native.
RmlProjectCompileResult rmlToRevFiles(String rml, List<RmlFileInput> files) {
  if (!markupAvailable) {
    return const RmlProjectCompileResult.failure([
      RmlCompileError(line: 0, message: 'markup is not available'),
    ]);
  }
  if (rml.isEmpty) {
    return const RmlProjectCompileResult.failure([
      RmlCompileError(line: 0, message: 'no markup to compile'),
    ]);
  }
  final rmlBytes = utf8.encode(rml);
  final bundle = encodeRmlFileInputs(files);
  final source = calloc<Uint8>(rmlBytes.length);
  final filesPtr = calloc<Uint8>(bundle.length);
  final response = calloc<_RmlProjectCompileResponseStruct>();
  try {
    source.asTypedList(rmlBytes.length).setAll(0, rmlBytes);
    filesPtr.asTypedList(bundle.length).setAll(0, bundle);
    _rmlToRevFiles(source, rmlBytes.length, filesPtr, bundle.length, response);
    final references =
        response.ref.refs == nullptr || response.ref.refsSize <= 0
        ? const <RmlFileReference>[]
        : RmlFileReference.listFromJson(
            utf8.decode(
              response.ref.refs.asTypedList(response.ref.refsSize),
              allowMalformed: true,
            ),
          );
    if (response.ref.data != nullptr && response.ref.size > 0) {
      // A view over native memory; copy it out before freeing.
      return RmlProjectCompileResult.success(
        Uint8List.fromList(response.ref.data.asTypedList(response.ref.size)),
        fileReferences: references,
      );
    }
    if (response.ref.error != nullptr && response.ref.errorSize > 0) {
      return RmlProjectCompileResult.failure(
        RmlCompileError.listFromJson(
          utf8.decode(
            response.ref.error.asTypedList(response.ref.errorSize),
            allowMalformed: true,
          ),
        ),
        fileReferences: references,
      );
    }
    return RmlProjectCompileResult.failure(const [
      RmlCompileError(line: 0, message: 'markup compile failed'),
    ], fileReferences: references);
  } finally {
    _freeRmlProjectCompile(response);
    calloc.free(response);
    calloc.free(source);
    calloc.free(filesPtr);
  }
}

final void Function(
  Pointer<Uint8> base,
  int baseLength,
  Pointer<Uint8> baseFiles,
  int baseFilesLength,
  Pointer<Uint8> sandbox,
  int sandboxLength,
  Pointer<Uint8> sandboxFiles,
  int sandboxFilesLength,
  int client,
  int firstObject,
  Pointer<_RmlCommitDiffResponseStruct> response,
)
_rmlCommitDiffFiles = _nativeLib
    .lookup<
      NativeFunction<
        Void Function(
          Pointer<Uint8>,
          Uint64,
          Pointer<Uint8>,
          Uint64,
          Pointer<Uint8>,
          Uint64,
          Pointer<Uint8>,
          Uint64,
          Uint64,
          Uint64,
          Pointer<_RmlCommitDiffResponseStruct>,
        )
      >
    >('rmlCommitDiffFiles')
    .asFunction();

/// [rmlCommitDiff] over projects: [base] compiles against [baseFiles] and
/// [sandbox] against [sandboxFiles]. A file with null bytes is withheld, so an
/// asset naming it diffs as unchanged without either side holding its bytes.
/// When [markupAvailable] is false, or [base] or [sandbox] is empty, it
/// returns a failure without calling native, and ids are checked, as in
/// [rmlCommitDiff].
RmlCommitDiff rmlCommitDiffFiles({
  required String base,
  required List<RmlFileInput> baseFiles,
  required String sandbox,
  required List<RmlFileInput> sandboxFiles,
  required int client,
  required int firstObject,
}) {
  RangeError.checkNotNegative(client, 'client');
  RangeError.checkNotNegative(firstObject, 'firstObject');
  if (!markupAvailable) {
    return const RmlCommitDiff.failure([
      RmlCompileError(line: 0, message: 'markup is not available'),
    ]);
  }
  if (base.isEmpty || sandbox.isEmpty) {
    return RmlCommitDiff.failure(const [
      RmlCompileError(line: 0, message: 'no markup to diff'),
    ], baseFailed: base.isEmpty);
  }
  final baseBytes = utf8.encode(base);
  final sandboxBytes = utf8.encode(sandbox);
  final baseBundle = encodeRmlFileInputs(baseFiles);
  final sandboxBundle = encodeRmlFileInputs(sandboxFiles);
  final basePtr = calloc<Uint8>(baseBytes.length);
  final baseFilesPtr = calloc<Uint8>(baseBundle.length);
  final sandboxPtr = calloc<Uint8>(sandboxBytes.length);
  final sandboxFilesPtr = calloc<Uint8>(sandboxBundle.length);
  final response = calloc<_RmlCommitDiffResponseStruct>();
  try {
    basePtr.asTypedList(baseBytes.length).setAll(0, baseBytes);
    baseFilesPtr.asTypedList(baseBundle.length).setAll(0, baseBundle);
    sandboxPtr.asTypedList(sandboxBytes.length).setAll(0, sandboxBytes);
    sandboxFilesPtr.asTypedList(sandboxBundle.length).setAll(0, sandboxBundle);
    _rmlCommitDiffFiles(
      basePtr,
      baseBytes.length,
      baseFilesPtr,
      baseBundle.length,
      sandboxPtr,
      sandboxBytes.length,
      sandboxFilesPtr,
      sandboxBundle.length,
      client,
      firstObject,
      response,
    );
    final report =
        response.ref.report == nullptr || response.ref.reportSize <= 0
        ? '{}'
        : utf8.decode(
            response.ref.report.asTypedList(response.ref.reportSize),
            allowMalformed: true,
          );
    final changes = response.ref.data == nullptr || response.ref.size <= 0
        ? null
        : Uint8List.fromList(response.ref.data.asTypedList(response.ref.size));
    return RmlCommitDiff.fromJson(report, changes);
  } finally {
    _freeRmlCommitDiff(response);
    calloc.free(response);
    calloc.free(basePtr);
    calloc.free(baseFilesPtr);
    calloc.free(sandboxPtr);
    calloc.free(sandboxFilesPtr);
  }
}
