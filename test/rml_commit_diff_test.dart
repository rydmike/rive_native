import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rive_native/rive_markup.dart';

void main() {
  group('RmlCommitDiff.fromJson', () {
    test(
        'reads entries, requires, skipped (with key and target) and orders '
        '(with a root group)', () {
      const report = '''
{
  "idsUsed": 4,
  "entries": [
    {"op": "create", "id": "5:120", "type": "Shape", "label": "Shape \\"Star\\"",
     "refs": {"5": ["1:2"]}},
    {"op": "update", "id": "1:2", "type": "Artboard", "label": "Artboard \\"Hero\\"",
     "keys": [4], "names": ["name"], "refs": {}},
    {"op": "update", "id": "1:14", "type": "Shape", "label": "Shape \\"Moved\\"",
     "keys": [5, 6], "names": ["parentId", "childOrder"], "refs": {"5": ["5:121"]},
     "requires": [{"for": 6, "op": "update", "id": "1:14", "key": 5}]},
    {"op": "remove", "id": "1:9", "type": "Node", "label": "Node \\"Group\\"",
     "requires": [{"op": "update", "id": "1:10", "key": 5},
                  {"op": "remove", "id": "1:11"}]}
  ],
  "skipped": [
    {"op": "update", "id": "1:30", "type": "ScriptAsset", "label": "ScriptAsset \\"Mover\\"",
     "reason": "script"},
    {"op": "update", "id": "1:40", "key": 151, "type": "StateTransition",
     "label": "StateTransition", "reason": "compiler", "target": "AnyState"}
  ],
  "orders": [
    {"parent": "1:2", "key": 6, "name": "childOrder", "via": 5,
     "sequence": ["1:3", "5:120", "1:4"], "placed": ["5:120"]},
    {"root": true, "key": 6, "name": "childOrder",
     "sequence": ["5:130"], "placed": ["5:130"]}
  ]
}
''';
      final changes = Uint8List.fromList([1, 2, 3]);
      final diff = RmlCommitDiff.fromJson(report, changes);

      expect(diff.isSuccess, isTrue);
      expect(diff.changes, changes);
      expect(diff.idsUsed, 4);

      expect(diff.entries, hasLength(4));
      final create = diff.entries[0];
      expect(create.op, 'create');
      expect(create.id, '5:120');
      expect(create.label, 'Shape "Star"');
      expect(create.refs, {5: ['1:2']});

      final update = diff.entries[1];
      expect(update.op, 'update');
      expect(update.keys, [4]);
      expect(update.names, ['name']);
      expect(update.refs, isEmpty);

      final requiring = diff.entries[2];
      expect(requiring.requires, hasLength(1));
      expect(requiring.requires.single.forKey, 6);
      expect(requiring.requires.single.op, 'update');
      expect(requiring.requires.single.id, '1:14');
      expect(requiring.requires.single.key, 5);

      final remove = diff.entries[3];
      expect(remove.op, 'remove');
      expect(remove.requires, hasLength(2));
      // A requirement without "for" applies to the whole entry.
      expect(remove.requires[0].forKey, 0);
      expect(remove.requires[0].key, 5);
      expect(remove.requires[1].op, 'remove');
      expect(remove.requires[1].key, isNull);

      expect(diff.skipped, hasLength(2));
      final scriptSkip = diff.skipped[0];
      expect(scriptSkip.key, 0);
      expect(scriptSkip.reason, 'script');
      expect(scriptSkip.target, isNull);
      final compilerSkip = diff.skipped[1];
      expect(compilerSkip.key, 151);
      expect(compilerSkip.reason, 'compiler');
      expect(compilerSkip.target, 'AnyState');

      expect(diff.orders, hasLength(2));
      final childGroup = diff.orders[0];
      expect(childGroup.root, isFalse);
      expect(childGroup.parent, '1:2');
      expect(childGroup.via, 5);
      expect(childGroup.sequence, ['1:3', '5:120', '1:4']);
      expect(childGroup.placed, ['5:120']);
      final rootGroup = diff.orders[1];
      expect(rootGroup.root, isTrue);
      expect(rootGroup.parent, isNull);
      expect(rootGroup.via, isNull);
    });

    test('reads a compile failure with its document', () {
      const report = '{"document": "base", "errors": '
          '[{"line": 3, "message": "bad attribute", "id": "0:5"}]}';
      final diff = RmlCommitDiff.fromJson(report, null);

      expect(diff.isSuccess, isFalse);
      expect(diff.baseFailed, isTrue);
      expect(diff.changes, isNull);
      expect(diff.errors, hasLength(1));
      expect(diff.errors.single.line, 3);
      expect(diff.errors.single.message, 'bad attribute');
      expect(diff.errors.single.id, '0:5');
      expect(diff.entries, isEmpty);
      expect(diff.skipped, isEmpty);
      expect(diff.orders, isEmpty);
    });

    test('reads a sandbox compile failure', () {
      const report = '{"document": "sandbox", "errors": '
          '[{"line": 2, "message": "unknown element"}]}';
      final diff = RmlCommitDiff.fromJson(report, null);

      expect(diff.isSuccess, isFalse);
      expect(diff.baseFailed, isFalse);
      expect(diff.errors.single.line, 2);
      expect(diff.errors.single.message, 'unknown element');
    });

    test('fails closed on an error report naming no known document', () {
      const errors = '[{"line": 2, "message": "unknown element"}]';
      for (final report in [
        '{"errors": $errors}',
        '{"document": "other", "errors": $errors}',
        '{"document": null, "errors": $errors}',
      ]) {
        final diff = RmlCommitDiff.fromJson(report, null);

        expect(diff.isSuccess, isFalse, reason: report);
        expect(diff.baseFailed, isFalse, reason: report);
        expect(diff.errors, hasLength(1), reason: report);
        expect(diff.errors.single.message, report, reason: report);
      }
    });

    test('a failure with no errors is still a failure', () {
      const diff = RmlCommitDiff.failure([]);

      expect(diff.isSuccess, isFalse);
      expect(diff.changes, isNull);
    });

    test('turns text that is not JSON into one error', () {
      final diff = RmlCommitDiff.fromJson('not json at all', null);

      expect(diff.isSuccess, isFalse);
      expect(diff.baseFailed, isFalse);
      expect(diff.errors, hasLength(1));
      expect(diff.errors.single.line, 0);
      expect(diff.errors.single.message, 'not json at all');
    });

    test('fails closed on an error report with no errors', () {
      const report = '{"document": "sandbox", "errors": []}';
      final diff = RmlCommitDiff.fromJson(report, null);

      expect(diff.isSuccess, isFalse);
      expect(diff.errors, hasLength(1));
      expect(diff.errors.single.message, report);
    });

    test('fails closed on a success report missing a required field', () {
      const report = '{"idsUsed": 0, "entries": [], "skipped": []}';
      final diff = RmlCommitDiff.fromJson(report, Uint8List(0));

      expect(diff.isSuccess, isFalse);
      expect(diff.errors, hasLength(1));
    });

    test('fails closed on a success with no ChangeSet bytes', () {
      const withEntries = '''
{"idsUsed": 1, "entries": [
  {"op": "create", "id": "5:100", "type": "Shape", "label": "Shape",
   "refs": {}}
], "skipped": [], "orders": []}
''';
      const empty = '{"idsUsed": 0, "entries": [], "skipped": [], '
          '"orders": []}';
      for (final report in [withEntries, empty]) {
        final diff = RmlCommitDiff.fromJson(report, null);

        expect(diff.isSuccess, isFalse, reason: report);
        expect(diff.changes, isNull, reason: report);
        expect(diff.errors, hasLength(1), reason: report);
        expect(diff.errors.single.message, report.trim(), reason: report);
      }
    });

    test('reads an empty success with its ChangeSet bytes', () {
      const report = '{"idsUsed": 0, "entries": [], "skipped": [], '
          '"orders": []}';
      final changes = Uint8List.fromList([1, 0]);
      final diff = RmlCommitDiff.fromJson(report, changes);

      expect(diff.isSuccess, isTrue);
      expect(diff.changes, changes);
      expect(diff.entries, isEmpty);
    });

    test(
        'a malformed keys list fails inside fromJson rather than throwing '
        'later, when nothing is catching it', () {
      // "keys" ought to be ints; a stale or mismatched native library could
      // send something else. list.cast<int>() would only throw once a
      // caller reads an element, outside this try/catch -- List<int>.from
      // throws here, where it is caught.
      const report = '''
{"idsUsed": 0, "entries": [
  {"op": "update", "id": "1:2", "type": "Artboard", "label": "Artboard",
   "keys": ["not an int"], "names": ["name"], "refs": {}}
], "skipped": [], "orders": []}
''';
      final diff = RmlCommitDiff.fromJson(report, Uint8List(0));

      expect(diff.isSuccess, isFalse);
      expect(diff.errors, hasLength(1));
    });
  });
}
