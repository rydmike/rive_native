import 'dart:convert';
import 'dart:js_interop' as js;
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:rive_native/src/rive_native_web.dart';
import 'package:rive_native/src/rml_commit_diff.dart';
import 'package:rive_native/src/rml_files.dart';
import 'package:rive_native/src/rml_problem.dart';

export 'package:rive_native/src/rml_commit_diff.dart';
export 'package:rive_native/src/rml_compile_result.dart';
export 'package:rive_native/src/rml_files.dart';
export 'package:rive_native/src/rml_problem.dart';

late js.JSObject _module;
late js.JSFunction _revToRml;
late js.JSFunction _freeRmlExport;
late js.JSFunction _rmlToRev;
late js.JSFunction _freeRmlCompile;
late js.JSFunction _rmlSchemaDescribe;
late js.JSFunction _rmlSchemaSearch;
late js.JSFunction _rmlSchemaTypes;
late js.JSFunction _freeRmlSchemaText;
late js.JSFunction _rmlInspect;
late js.JSFunction _freeRmlInspect;
late js.JSFunction _rmlCommitDiff;
late js.JSFunction _freeRmlCommitDiff;
late js.JSFunction _revToRmlFiles;
late js.JSFunction _freeRmlExportFiles;
late js.JSFunction _rmlToRevFiles;
late js.JSFunction _freeRmlProjectCompile;
late js.JSFunction _rmlCommitDiffFiles;
bool _linked = false;

/// Whether the wasm module carries the markup exports. False in
/// flutter_runtime builds, where rml is excluded (editor-only).
bool get markupAvailable => _linked;

// Before the empty-input shortcuts, which would otherwise answer without the
// library and read as "no such type" or a clean document.
void _requireLinked() {
  if (!_linked) {
    throw StateError('markup is not available');
  }
}

/// Links the markup wasm exports. Only present in editor builds of the wasm
/// module (rml is excluded from flutter_runtime builds).
class MarkupWasm {
  static void link(js.JSObject module) {
    bool callable(js.JSAny? export) =>
        export != null && export.isA<js.JSFunction>();
    final convert = module['revToRmlWasm'];
    final free = module['freeRmlExportWasm'];
    final compile = module['rmlToRevWasm'];
    final freeCompile = module['freeRmlCompileWasm'];
    final describe = module['rmlSchemaDescribeWasm'];
    final search = module['rmlSchemaSearchWasm'];
    final types = module['rmlSchemaTypesWasm'];
    final freeSchemaText = module['freeRmlSchemaTextWasm'];
    final inspect = module['rmlInspectWasm'];
    final freeInspect = module['freeRmlInspectWasm'];
    final commitDiff = module['rmlCommitDiffWasm'];
    final freeCommitDiff = module['freeRmlCommitDiffWasm'];
    final convertFiles = module['revToRmlFilesWasm'];
    final freeExportFiles = module['freeRmlExportFilesWasm'];
    final compileFiles = module['rmlToRevFilesWasm'];
    final freeProjectCompile = module['freeRmlProjectCompileWasm'];
    final commitDiffFiles = module['rmlCommitDiffFilesWasm'];
    if (!callable(convert) ||
        !callable(free) ||
        !callable(compile) ||
        !callable(freeCompile) ||
        !callable(describe) ||
        !callable(search) ||
        !callable(types) ||
        !callable(freeSchemaText) ||
        !callable(inspect) ||
        !callable(freeInspect) ||
        !callable(commitDiff) ||
        !callable(freeCommitDiff) ||
        !callable(convertFiles) ||
        !callable(freeExportFiles) ||
        !callable(compileFiles) ||
        !callable(freeProjectCompile) ||
        !callable(commitDiffFiles)) {
      // flutter_runtime wasm module (rml not compiled in), or a
      // partial/mismatched module: fail closed, markupAvailable stays false.
      return;
    }
    _module = module;
    _revToRml = convert as js.JSFunction;
    _freeRmlExport = free as js.JSFunction;
    _rmlToRev = compile as js.JSFunction;
    _freeRmlCompile = freeCompile as js.JSFunction;
    _rmlSchemaDescribe = describe as js.JSFunction;
    _rmlSchemaSearch = search as js.JSFunction;
    _rmlSchemaTypes = types as js.JSFunction;
    _freeRmlSchemaText = freeSchemaText as js.JSFunction;
    _rmlInspect = inspect as js.JSFunction;
    _freeRmlInspect = freeInspect as js.JSFunction;
    _rmlCommitDiff = commitDiff as js.JSFunction;
    _freeRmlCommitDiff = freeCommitDiff as js.JSFunction;
    _revToRmlFiles = convertFiles as js.JSFunction;
    _freeRmlExportFiles = freeExportFiles as js.JSFunction;
    _rmlToRevFiles = compileFiles as js.JSFunction;
    _freeRmlProjectCompile = freeProjectCompile as js.JSFunction;
    _rmlCommitDiffFiles = commitDiffFiles as js.JSFunction;
    _linked = true;
  }
}

/// Converts the bytes of a .rev file into the equivalent .rml markup
/// document, with every payload embedded. Returns null when the bytes are not
/// a readable .rev.
Uint8List? revToRml(Uint8List revBytes) {
  if (!_linked || revBytes.isEmpty) {
    return null;
  }
  final source = WasmBuffer.fromBytes(revBytes);
  try {
    final response =
        _revToRml.callAsFunction(_module, source.pointer, revBytes.length.toJS)
            as js.JSObject;
    final data = (response['data'] as js.JSNumber).toDartInt;
    final size = (response['size'] as js.JSNumber).toDartInt;
    if (data == 0 || size <= 0) {
      return null;
    }
    try {
      // A view over the wasm heap; copy it out before freeing.
      return Uint8List.fromList(RiveWasm.heap(data, size));
    } finally {
      _freeRmlExport.callAsFunction(_module, response);
    }
  } finally {
    source.dispose();
  }
}

/// Compiles a .rml markup document into the equivalent .rev bytes -- the
/// inverse of [revToRml]. Every payload the document needs must be embedded
/// in it: a `file=` reference has no directory to resolve against here and
/// compiles as an error.
RmlCompileResult rmlToRev(Uint8List rmlBytes) {
  if (!_linked) {
    return RmlCompileResult.failure(const [
      RmlCompileError(line: 0, message: 'markup is not available'),
    ]);
  }
  if (rmlBytes.isEmpty) {
    return RmlCompileResult.failure(const [
      RmlCompileError(line: 0, message: 'no markup to compile'),
    ]);
  }
  final source = WasmBuffer.fromBytes(rmlBytes);
  try {
    final response =
        _rmlToRev.callAsFunction(_module, source.pointer, rmlBytes.length.toJS)
            as js.JSObject;
    try {
      final data = (response['data'] as js.JSNumber).toDartInt;
      final size = (response['size'] as js.JSNumber).toDartInt;
      if (data != 0 && size > 0) {
        // A view over the wasm heap; copy it out before freeing.
        return RmlCompileResult.success(
          Uint8List.fromList(RiveWasm.heap(data, size)),
        );
      }
      final error = (response['error'] as js.JSNumber).toDartInt;
      final errorSize = (response['errorSize'] as js.JSNumber).toDartInt;
      if (error != 0 && errorSize > 0) {
        return RmlCompileResult.failure(
          RmlCompileError.listFromJson(
            utf8.decode(RiveWasm.heap(error, errorSize), allowMalformed: true),
          ),
        );
      }
      return RmlCompileResult.failure(const [
        RmlCompileError(line: 0, message: 'markup compile failed'),
      ]);
    } finally {
      _freeRmlCompile.callAsFunction(_module, response);
    }
  } finally {
    source.dispose();
  }
}

/// Reads a {data, size} schema response, freeing it either way: null when
/// there is nothing at `data` (an unknown type, or an empty result).
String? _readSchemaResponse(js.JSObject response) {
  try {
    final data = (response['data'] as js.JSNumber).toDartInt;
    final size = (response['size'] as js.JSNumber).toDartInt;
    if (data == 0 || size <= 0) {
      return null;
    }
    // A view over the wasm heap; copy it out before freeing.
    return utf8.decode(RiveWasm.heap(data, size));
  } finally {
    _freeRmlSchemaText.callAsFunction(_module, response);
  }
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
  _requireLinked();
  if (typeName.isEmpty) {
    return null;
  }
  final source = WasmBuffer.fromBytes(utf8.encode(typeName));
  try {
    // callAsFunction tops out at four arguments, so go through call().
    final response =
        _rmlSchemaDescribe.callMethodVarArgs('call'.toJS, [
              _module,
              source.pointer,
              source.size.toJS,
              includeEditorOnly.toJS,
              animatableOnly.toJS,
              bindableOnly.toJS,
              json.toJS,
            ])
            as js.JSObject;
    return _readSchemaResponse(response);
  } finally {
    source.dispose();
  }
}

/// Types and properties whose names contain [text], case-insensitively: the
/// same answer `rive schema --search <text>` gives. Empty when nothing
/// matches -- including an empty [text], which the CLI never passes through
/// to a search either.
///
/// Throws when [markupAvailable] is false.
String rmlSchemaSearch(String text, {bool json = false}) {
  _requireLinked();
  if (text.isEmpty) {
    return json ? '[]\n' : '';
  }
  final source = WasmBuffer.fromBytes(utf8.encode(text));
  try {
    final response =
        _rmlSchemaSearch.callAsFunction(
              _module,
              source.pointer,
              source.size.toJS,
              json.toJS,
            )
            as js.JSObject;
    return _readSchemaResponse(response) ?? '';
  } finally {
    source.dispose();
  }
}

/// Every authorable core type name: the same answer `rive schema --list`
/// gives.
///
/// Throws when [markupAvailable] is false.
String rmlSchemaTypes({bool json = false}) {
  _requireLinked();
  final response =
      _rmlSchemaTypes.callAsFunction(_module, json.toJS) as js.JSObject;
  return _readSchemaResponse(response) ?? '';
}

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
  _requireLinked();
  if (rml.isEmpty) {
    // Mirrors rmlToRev's empty guard: avoids a zero-byte wasm buffer, and an
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
  final source = WasmBuffer.fromBytes(utf8.encode(rml));
  try {
    final response =
        _rmlInspect.callAsFunction(_module, source.pointer, source.size.toJS)
            as js.JSObject;
    final json = () {
      try {
        final data = (response['data'] as js.JSNumber).toDartInt;
        final size = (response['size'] as js.JSNumber).toDartInt;
        if (data == 0 || size <= 0) {
          return '[]';
        }
        // A view over the wasm heap; copy it out before freeing.
        return utf8.decode(RiveWasm.heap(data, size), allowMalformed: true);
      } finally {
        _freeRmlInspect.callAsFunction(_module, response);
      }
    }();
    return RmlProblem.listFromJson(json);
  } finally {
    source.dispose();
  }
}

// An id crosses to wasm as a double, which holds an integer exactly only up
// to 2^53.
void _checkNewId(int value, String name) =>
    RangeError.checkValueInInterval(value, 0, 9007199254740992, name);

/// Diffs a sandbox markup document against its base, both compiled here: the
/// result classifies every change into a ChangeSet the live file can apply,
/// remapping new objects from `(client, firstObject)`. When
/// [markupAvailable] is false, or [base] or [sandbox] is empty, it returns a
/// failure without calling native; an empty [base] is the base's failure.
/// A negative [client] or [firstObject], or one past 2^53, throws an
/// [ArgumentError].
RmlCommitDiff rmlCommitDiff(
  String base,
  String sandbox, {
  required int client,
  required int firstObject,
}) {
  _checkNewId(client, 'client');
  _checkNewId(firstObject, 'firstObject');
  if (!_linked) {
    return const RmlCommitDiff.failure([
      RmlCompileError(line: 0, message: 'markup is not available'),
    ]);
  }
  if (base.isEmpty || sandbox.isEmpty) {
    return RmlCommitDiff.failure(const [
      RmlCompileError(line: 0, message: 'no markup to diff'),
    ], baseFailed: base.isEmpty);
  }
  final baseBuffer = WasmBuffer.fromBytes(utf8.encode(base));
  final sandboxBuffer = WasmBuffer.fromBytes(utf8.encode(sandbox));
  try {
    // callAsFunction tops out at four arguments, so go through call().
    final response =
        _rmlCommitDiff.callMethodVarArgs('call'.toJS, [
              _module,
              baseBuffer.pointer,
              baseBuffer.size.toJS,
              sandboxBuffer.pointer,
              sandboxBuffer.size.toJS,
              client.toJS,
              firstObject.toJS,
            ])
            as js.JSObject;
    try {
      final reportPtr = (response['report'] as js.JSNumber).toDartInt;
      final reportSize = (response['reportSize'] as js.JSNumber).toDartInt;
      final report = reportPtr == 0 || reportSize <= 0
          ? '{}'
          : utf8.decode(
              RiveWasm.heap(reportPtr, reportSize),
              allowMalformed: true,
            );
      final dataPtr = (response['data'] as js.JSNumber).toDartInt;
      final dataSize = (response['size'] as js.JSNumber).toDartInt;
      final changes = dataPtr == 0 || dataSize <= 0
          ? null
          : Uint8List.fromList(RiveWasm.heap(dataPtr, dataSize));
      return RmlCommitDiff.fromJson(report, changes);
    } finally {
      _freeRmlCommitDiff.callAsFunction(_module, response);
    }
  } finally {
    baseBuffer.dispose();
    sandboxBuffer.dispose();
  }
}

/// Converts the bytes of a .rev file into `main.rml`'s markup plus the files
/// it references with `file=`: scripts and shaders with their source, binary
/// assets as byteless files that only name them. Returns null when the bytes
/// are not a readable .rev or [markupAvailable] is false.
///
/// No file lands on the path `main.rml` or in a top-level folder named
/// `builtins` or `main.rml`; one that would gets another name
/// (`builtins_2/…`).
RmlExportedProject? revToRmlFiles(Uint8List revBytes) {
  if (!_linked || revBytes.isEmpty) {
    return null;
  }
  final source = WasmBuffer.fromBytes(revBytes);
  try {
    final response =
        _revToRmlFiles.callAsFunction(
              _module,
              source.pointer,
              revBytes.length.toJS,
            )
            as js.JSObject;
    try {
      final data = (response['data'] as js.JSNumber).toDartInt;
      final size = (response['size'] as js.JSNumber).toDartInt;
      if (data == 0 || size <= 0) {
        return null;
      }
      // Views over the wasm heap; copy them out before freeing.
      final rml = utf8.decode(RiveWasm.heap(data, size), allowMalformed: true);
      final files = (response['files'] as js.JSNumber).toDartInt;
      final filesSize = (response['filesSize'] as js.JSNumber).toDartInt;
      // Native always sends a bundle, at least its count; none means the
      // copy out failed.
      if (files == 0 || filesSize <= 0) {
        return null;
      }
      final bundle = Uint8List.fromList(RiveWasm.heap(files, filesSize));
      try {
        return RmlExportedProject(
          rml: rml,
          files: decodeRmlExportedFiles(bundle),
        );
      } on FormatException {
        return null;
      }
    } finally {
      _freeRmlExportFiles.callAsFunction(_module, response);
    }
  } finally {
    source.dispose();
  }
}

/// Compiles [rml] against [files]: text files are served as they are, and a
/// file with null bytes is present but compiles without contents. A `file=`
/// the list does not hold is an error naming the asset and path. When
/// [markupAvailable] is false, it returns a failure without calling native.
RmlProjectCompileResult rmlToRevFiles(String rml, List<RmlFileInput> files) {
  if (!_linked) {
    return const RmlProjectCompileResult.failure([
      RmlCompileError(line: 0, message: 'markup is not available'),
    ]);
  }
  if (rml.isEmpty) {
    return const RmlProjectCompileResult.failure([
      RmlCompileError(line: 0, message: 'no markup to compile'),
    ]);
  }
  final source = WasmBuffer.fromBytes(utf8.encode(rml));
  final bundle = WasmBuffer.fromBytes(encodeRmlFileInputs(files));
  try {
    // callAsFunction tops out at four arguments, so go through call().
    final response =
        _rmlToRevFiles.callMethodVarArgs('call'.toJS, [
              _module,
              source.pointer,
              source.size.toJS,
              bundle.pointer,
              bundle.size.toJS,
            ])
            as js.JSObject;
    try {
      final refs = (response['refs'] as js.JSNumber).toDartInt;
      final refsSize = (response['refsSize'] as js.JSNumber).toDartInt;
      final references = refs == 0 || refsSize <= 0
          ? const <RmlFileReference>[]
          : RmlFileReference.listFromJson(
              utf8.decode(RiveWasm.heap(refs, refsSize), allowMalformed: true),
            );
      final data = (response['data'] as js.JSNumber).toDartInt;
      final size = (response['size'] as js.JSNumber).toDartInt;
      if (data != 0 && size > 0) {
        // A view over the wasm heap; copy it out before freeing.
        return RmlProjectCompileResult.success(
          Uint8List.fromList(RiveWasm.heap(data, size)),
          fileReferences: references,
        );
      }
      final error = (response['error'] as js.JSNumber).toDartInt;
      final errorSize = (response['errorSize'] as js.JSNumber).toDartInt;
      if (error != 0 && errorSize > 0) {
        return RmlProjectCompileResult.failure(
          RmlCompileError.listFromJson(
            utf8.decode(RiveWasm.heap(error, errorSize), allowMalformed: true),
          ),
          fileReferences: references,
        );
      }
      return RmlProjectCompileResult.failure(const [
        RmlCompileError(line: 0, message: 'markup compile failed'),
      ], fileReferences: references);
    } finally {
      _freeRmlProjectCompile.callAsFunction(_module, response);
    }
  } finally {
    source.dispose();
    bundle.dispose();
  }
}

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
  _checkNewId(client, 'client');
  _checkNewId(firstObject, 'firstObject');
  if (!_linked) {
    return const RmlCommitDiff.failure([
      RmlCompileError(line: 0, message: 'markup is not available'),
    ]);
  }
  if (base.isEmpty || sandbox.isEmpty) {
    return RmlCommitDiff.failure(const [
      RmlCompileError(line: 0, message: 'no markup to diff'),
    ], baseFailed: base.isEmpty);
  }
  final baseBuffer = WasmBuffer.fromBytes(utf8.encode(base));
  final baseFilesBuffer = WasmBuffer.fromBytes(encodeRmlFileInputs(baseFiles));
  final sandboxBuffer = WasmBuffer.fromBytes(utf8.encode(sandbox));
  final sandboxFilesBuffer = WasmBuffer.fromBytes(
    encodeRmlFileInputs(sandboxFiles),
  );
  try {
    // callAsFunction tops out at four arguments, so go through call().
    final response =
        _rmlCommitDiffFiles.callMethodVarArgs('call'.toJS, [
              _module,
              baseBuffer.pointer,
              baseBuffer.size.toJS,
              baseFilesBuffer.pointer,
              baseFilesBuffer.size.toJS,
              sandboxBuffer.pointer,
              sandboxBuffer.size.toJS,
              sandboxFilesBuffer.pointer,
              sandboxFilesBuffer.size.toJS,
              client.toJS,
              firstObject.toJS,
            ])
            as js.JSObject;
    try {
      final reportPtr = (response['report'] as js.JSNumber).toDartInt;
      final reportSize = (response['reportSize'] as js.JSNumber).toDartInt;
      final report = reportPtr == 0 || reportSize <= 0
          ? '{}'
          : utf8.decode(
              RiveWasm.heap(reportPtr, reportSize),
              allowMalformed: true,
            );
      final dataPtr = (response['data'] as js.JSNumber).toDartInt;
      final dataSize = (response['size'] as js.JSNumber).toDartInt;
      final changes = dataPtr == 0 || dataSize <= 0
          ? null
          : Uint8List.fromList(RiveWasm.heap(dataPtr, dataSize));
      return RmlCommitDiff.fromJson(report, changes);
    } finally {
      _freeRmlCommitDiff.callAsFunction(_module, response);
    }
  } finally {
    baseBuffer.dispose();
    baseFilesBuffer.dispose();
    sandboxBuffer.dispose();
    sandboxFilesBuffer.dispose();
  }
}
