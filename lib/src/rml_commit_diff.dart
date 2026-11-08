import 'dart:convert';
import 'dart:typed_data';

import 'package:rive_native/src/rml_compile_result.dart';

export 'package:rive_native/src/rml_compile_result.dart';

/// forKey 0: the whole entry needs [unit]; otherwise only its update of
/// forKey does. Read from the report's "requires" list, whose "for" field is
/// omitted (and so defaults to 0) when it applies to the whole entry.
class RmlCommitRequire {
  final int forKey;
  final String op;

  /// The id ("c:o") of the change this one depends on.
  final String id;

  /// Set only when [op] is 'update'.
  final int? key;

  const RmlCommitRequire({
    this.forKey = 0,
    required this.op,
    required this.id,
    this.key,
  });

  static RmlCommitRequire fromJson(Map<String, dynamic> json) =>
      RmlCommitRequire(
        forKey: json['for'] as int? ?? 0,
        op: json['op'] as String,
        id: json['id'] as String,
        key: json['key'] as int?,
      );
}

/// One create, update or remove `rmlCommitDiff` reports, describing one of
/// `changes.objects` in the same order.
class RmlCommitEntry {
  final String op;

  /// The final id ("c:o"); new objects are already remapped.
  final String id;

  /// Sandbox id before remap, when it differs from [id]. Set on creates.
  final String? from;

  final String type;

  /// The element name, then its name attribute when it has one, e.g.
  /// `Shape "Star"`.
  final String label;

  /// Property keys written; only set when [op] is 'update'.
  final List<int> keys;

  /// The name of each key in [keys], coop keys only.
  final List<String> names;

  /// Non-foreign ids written, grouped by property key; unset when [op] is
  /// 'remove'.
  final Map<int, List<String>> refs;

  final List<RmlCommitRequire> requires;

  const RmlCommitEntry({
    required this.op,
    required this.id,
    this.from,
    required this.type,
    required this.label,
    this.keys = const [],
    this.names = const [],
    this.refs = const {},
    this.requires = const [],
  });

  static RmlCommitEntry fromJson(Map<String, dynamic> json) {
    final rawRefs = json['refs'] as Map<String, dynamic>? ?? const {};
    return RmlCommitEntry(
      op: json['op'] as String,
      id: json['id'] as String,
      from: json['from'] as String?,
      type: json['type'] as String,
      label: json['label'] as String,
      keys: List<int>.from(json['keys'] as List<dynamic>? ?? const []),
      names: List<String>.from(json['names'] as List<dynamic>? ?? const []),
      refs: rawRefs.map(
        (key, value) =>
            MapEntry(int.parse(key), List<String>.from(value as List<dynamic>)),
      ),
      requires: (json['requires'] as List<dynamic>? ?? const [])
          .cast<Map<String, dynamic>>()
          .map(RmlCommitRequire.fromJson)
          .toList(),
    );
  }
}

/// One change `rmlCommitDiff` left out of the commit: an object not
/// created/removed, or (when [key] is non-zero) one property of an update.
///
/// Reasons 'script' and 'asset' are the exception: for [op] 'update' they
/// leave [key] at 0, but that does not skip the whole entry -- only the
/// asset's script source ('script') or embedded bytes ('asset') are
/// uncommitted, and its other property changes, if any, are a separate
/// 'update' entry for the same [id].
///
/// Reason 'backboard' also leaves [key] at 0: for [op] 'remove' the live
/// Backboard is kept, for [op] 'create' it is not created; the [id] is the
/// sandbox's and must not be looked up in the live file.
///
/// A 'script' remove is a script asset, or something whose removal would
/// take a kept script asset with it (its folder, a tag it uses); [target]
/// names that script. Reason 'order' is an existing root moved among the
/// live roots; reordering them is not committed.
class RmlCommitSkip {
  final String op;
  final String id;

  /// The property skipped, when [op] is 'update' and [reason] is 'compiler'
  /// or 'order'; 0 otherwise, including every 'script' skip.
  final int key;

  final String type;
  final String label;

  /// Why the change was skipped: 'script', 'asset', 'compiler', 'order' or
  /// 'backboard'.
  final String reason;

  /// The paired element's type name when [reason] is 'compiler'; the kept
  /// script's label on a 'script' remove of something else; null otherwise.
  final String? target;

  /// Sandbox id before remap, when it differs from [id]. Set on skipped
  /// creates.
  final String? from;

  const RmlCommitSkip({
    required this.op,
    required this.id,
    this.key = 0,
    required this.type,
    required this.label,
    required this.reason,
    this.target,
    this.from,
  });

  static RmlCommitSkip fromJson(Map<String, dynamic> json) => RmlCommitSkip(
    op: json['op'] as String,
    id: json['id'] as String,
    key: json['key'] as int? ?? 0,
    type: json['type'] as String,
    label: json['label'] as String,
    reason: json['reason'] as String,
    target: json['target'] as String?,
    from: json['from'] as String?,
  );
}

/// A run of siblings under one property key that need a live order value.
/// A [root] group is not scoped to a parent ([parent] is meaningless): its
/// members are creates whose [key] no parent group orders, every order key
/// of a new root among them, placed after every live value of [key].
class RmlOrderGroup {
  final bool root;

  /// Null when [root] is true.
  final String? parent;

  final int key;
  final String name;

  /// The child's property naming the parent; unset when [root] is true.
  final int? via;

  /// The group in sandbox order, final ids.
  final List<String> sequence;

  /// The members of [sequence] that need a live order value.
  final List<String> placed;

  const RmlOrderGroup({
    this.root = false,
    this.parent,
    required this.key,
    required this.name,
    this.via,
    required this.sequence,
    required this.placed,
  });

  static RmlOrderGroup fromJson(Map<String, dynamic> json) => RmlOrderGroup(
    root: json['root'] as bool? ?? false,
    parent: json['parent'] as String?,
    key: json['key'] as int,
    name: json['name'] as String,
    via: json['via'] as int?,
    sequence: List<String>.from(json['sequence'] as List<dynamic>),
    placed: List<String>.from(json['placed'] as List<dynamic>),
  );
}

/// The outcome of diffing a sandbox markup document against its base
/// (`rmlCommitDiff`): either [errors] from compiling one of the two
/// documents, or a classified change set ready to apply to the live file.
class RmlCommitDiff {
  /// Compile errors; set only on failure, in which case every field below is
  /// empty.
  final List<RmlCompileError> errors;

  /// Whether it was the base document, rather than the sandbox, that failed
  /// to compile. Meaningless when [errors] is empty.
  final bool baseFailed;

  /// The ChangeSet wire bytes; null exactly on failure.
  final Uint8List? changes;

  final int idsUsed;
  final List<RmlCommitEntry> entries;
  final List<RmlCommitSkip> skipped;
  final List<RmlOrderGroup> orders;

  const RmlCommitDiff.success({
    required Uint8List this.changes,
    required this.idsUsed,
    required this.entries,
    required this.skipped,
    required this.orders,
  }) : errors = const [],
       baseFailed = false;

  const RmlCommitDiff.failure(this.errors, {this.baseFailed = false})
    : changes = null,
      idsUsed = 0,
      entries = const [],
      skipped = const [],
      orders = const [];

  bool get isSuccess => changes != null;

  /// Reads the report JSON native sends across FFI/wasm, pairing it with the
  /// ChangeSet bytes sent alongside (null on failure). Never throws: text
  /// that is not the expected JSON shape becomes one error, as in
  /// [RmlCompileError.listFromJson].
  static RmlCommitDiff fromJson(String report, Uint8List? changes) {
    try {
      final decoded = jsonDecode(report);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('not a JSON object');
      }
      if (decoded.containsKey('errors')) {
        final errors = RmlCompileError.listFromJson(
          jsonEncode(decoded['errors']),
        );
        // An empty list would read as success.
        if (errors.isEmpty) {
          throw const FormatException('an error report with no errors');
        }
        final document = decoded['document'];
        if (document != 'base' && document != 'sandbox') {
          throw const FormatException('an error report with no document');
        }
        return RmlCommitDiff.failure(errors, baseFailed: document == 'base');
      }
      // A success report always carries all four fields; anything less is
      // not the contract this reads, so it fails closed rather than
      // silently substituting empty defaults.
      if (!decoded.containsKey('idsUsed') ||
          !decoded.containsKey('entries') ||
          !decoded.containsKey('skipped') ||
          !decoded.containsKey('orders')) {
        throw const FormatException('missing a required success field');
      }
      final entries = (decoded['entries'] as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .map(RmlCommitEntry.fromJson)
          .toList();
      if (changes == null) {
        throw const FormatException('a success with no ChangeSet bytes');
      }
      return RmlCommitDiff.success(
        changes: changes,
        idsUsed: decoded['idsUsed'] as int,
        entries: entries,
        skipped: (decoded['skipped'] as List<dynamic>)
            .cast<Map<String, dynamic>>()
            .map(RmlCommitSkip.fromJson)
            .toList(),
        orders: (decoded['orders'] as List<dynamic>)
            .cast<Map<String, dynamic>>()
            .map(RmlOrderGroup.fromJson)
            .toList(),
      );
    } catch (_) {
      return RmlCommitDiff.failure([
        RmlCompileError(line: 0, message: report.trim()),
      ]);
    }
  }
}
