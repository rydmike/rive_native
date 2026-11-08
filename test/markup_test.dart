import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rive_native/rive_markup.dart';

import 'src/utils.dart';

void main() {
  group(
    'native markup bindings',
    skip: markupAvailable ? false : 'needs the editor native library',
    () {
      test('rev bytes convert to the markup the generator produces', () {
        final rml = revToRml(loadFile('assets/markup/rectangle.rev'));

        expect(rml, isNotNull);
        expect(
          utf8.decode(rml!),
          utf8.decode(loadFile('assets/markup/rectangle.rml')),
        );
      });

      test('rmlToRev errors carry their line and the id of their element', () {
        const markup =
            '<Artboard width="100" height="100" name="A" id="0:2">\n'
            '    <Node name="anchor" id="0:3" bogus="1"/>\n'
            '</Artboard>\n'
            '<Backboard coreVersion="1" activeArtboardId="0:2" '
            'mainArtboardId="0:2"/>\n';
        final compiled = rmlToRev(Uint8List.fromList(utf8.encode(markup)));

        expect(compiled.bytes, isNull);
        final error = compiled.errors.single;
        expect(error.line, 2);
        expect(error.id, '0:3');
        expect(compiled.error, '2: ${error.message}\n');
      });

      test('bytes that are not a rev convert to null', () {
        expect(revToRml(Uint8List.fromList([1, 2, 3, 4])), isNull);
        expect(revToRml(Uint8List(0)), isNull);
        // A supported version byte and nothing else: the header reads run
        // off the end rather than failing outright.
        for (final version in [4, 5, 6]) {
          expect(revToRml(Uint8List.fromList([version])), isNull);
        }
      });

      test('a rev claiming more objects than it holds converts to null', () {
        // A well-formed v6 header -- version, ids, the ART extension --
        // followed by an object count of 2^40. The objects are not there, so
        // the count is only a loop bound: reading past the end yields zeroes
        // rather than stopping, and the parse has to notice that itself.
        final bytes = Uint8List.fromList([
          6, // version
          1, 1, 1, // nextClientId, fileId, serverChangeId
          0x41, 0x52, 0x54, // "ART"
          0x80, 0x80, 0x80, 0x80, 0x80, 0x20, // object count: 2^40
        ]);
        expect(revToRml(bytes), isNull);
      });

      test(
        'markup compiles to a rev that converts back to the same markup',
        () {
          // Not a byte comparison against rectangle.rev: that file came out of
          // the editor, and the compiler lays a rev out its own way. What has
          // to hold is that the compile loses nothing -- the rev it produces
          // carries the whole document back.
          final markup = loadFile('assets/markup/rectangle.rml');
          final compiled = rmlToRev(markup);

          expect(compiled.error, isNull);
          expect(compiled.bytes, isNotNull);
          expect(utf8.decode(revToRml(compiled.bytes!)!), utf8.decode(markup));
        },
      );

      test('the same markup always compiles to the same bytes', () {
        // The editor compiles its bundled TextInput library on every launch and
        // holds committed attributes captured from one such compile, so the
        // compile has to be a function of the document and nothing else.
        final markup = loadFile('assets/markup/rectangle.rml');
        expect(rmlToRev(markup).bytes, rmlToRev(markup).bytes);
      });

      test('markup that is not markup compiles to an error, not to bytes', () {
        for (final source in <Uint8List>[
          Uint8List(0),
          Uint8List.fromList(utf8.encode('not markup')),
          Uint8List.fromList(utf8.encode('<Artboard name="unclosed">')),
          // A rev fed in the wrong direction.
          loadFile('assets/markup/rectangle.rev'),
        ]) {
          final compiled = rmlToRev(source);
          expect(
            compiled.bytes,
            isNull,
            reason: 'compiled ${source.length} bytes',
          );
          expect(compiled.error, isNotNull);
          expect(compiled.error, isNotEmpty);
        }
      });

      test('markup referencing a file it cannot embed is an error, not a '
          'quietly smaller rev', () {
        // rml answers an unreadable file= with "this asset has no contents"
        // and still writes a successful rev -- 63 bytes here, against the
        // ~876KB the font would have made. This binding has no directory to
        // resolve file= against, so it has to turn that miss into a failure
        // rather than hand back the stub.
        const markup =
            '<Artboard name="Art" width="100" height="100" id="1:1"/>\n'
            '<FontAsset file="Inter.ttf" isCustom="false" assetId="102112" '
            'name="Inter" id="1:10"/>\n';
        final compiled = rmlToRev(Uint8List.fromList(utf8.encode(markup)));

        expect(compiled.bytes, isNull);
        expect(compiled.error, contains('Inter.ttf'));
        final unreadable = compiled.errors.firstWhere(
          (e) => e.message.contains('referenced file cannot be read here'),
        );
        expect(unreadable.line, 0);
        expect(unreadable.id, isNull);
      });

      test('a truncated rev converts to null, not to partial markup', () {
        // Reading past the end yields zeros instead of stopping, so a short
        // rev parses into whatever objects fit. Returning that markup would
        // hand the caller a document that looks whole and is not.
        final full = loadFile('assets/markup/rectangle.rev');
        for (final percent in [30, 50, 70, 90, 99]) {
          final truncated = Uint8List.sublistView(
            full,
            0,
            full.length * percent ~/ 100,
          );
          expect(revToRml(truncated), isNull, reason: 'truncated at $percent%');
        }
      });

      test('rmlSchemaDescribe describes a known type', () {
        final text = rmlSchemaDescribe('Rectangle');
        expect(text, isNotNull);
        expect(text, startsWith('Rectangle  (typeKey '));
        expect(text, contains('cornerRadiusTL'));

        final json = rmlSchemaDescribe('Rectangle', json: true);
        expect(json, isNotNull);
        expect(json, startsWith('{"type": "Rectangle"'));
        expect(json, contains('"cornerRadiusTL"'));
      });

      test('rmlSchemaDescribe is null for an unknown type', () {
        expect(rmlSchemaDescribe('NoSuchThing'), isNull);
        expect(rmlSchemaDescribe('NoSuchThing', json: true), isNull);
      });

      test('rmlSchemaDescribe filters match the CLI flags', () {
        // --all: editor-only properties join the runtime ones, so the fuller
        // answer is never shorter than the default.
        final withoutAll = rmlSchemaDescribe('Rectangle')!;
        final withAll = rmlSchemaDescribe(
          'Rectangle',
          includeEditorOnly: true,
        )!;
        expect(withAll.length, greaterThanOrEqualTo(withoutAll.length));

        // --bindable narrows to a subset of the unfiltered answer.
        final bindableOnly = rmlSchemaDescribe(
          'Rectangle',
          bindableOnly: true,
        )!;
        expect(bindableOnly.length, lessThan(withoutAll.length));
      });

      test('rmlSchemaSearch finds types and properties by substring', () {
        final text = rmlSchemaSearch('rectangle');
        expect(text, contains('types:'));
        expect(text, contains('Rectangle'));

        final json = rmlSchemaSearch('rectangle', json: true);
        expect(json, contains('"name": "Rectangle"'));
        expect(json, contains('"kind": "type"'));
      });

      test('rmlSchemaSearch is empty when nothing matches', () {
        expect(rmlSchemaSearch('zzzznotathing'), isEmpty);
        expect(rmlSchemaSearch('zzzznotathing', json: true), '[]\n');
      });

      test('rmlSchemaTypes lists every authorable type', () {
        final text = rmlSchemaTypes();
        expect(text, contains('Rectangle\n'));
        expect(text, contains(' types.\n'));

        final json = rmlSchemaTypes(json: true);
        expect(json, startsWith('['));
        expect(json, contains('"Rectangle"'));
      });

      test('rmlInspect finds nothing wrong with a clean document', () {
        final problems = rmlInspect(
          '<Artboard x="0" y="0" width="300" height="300" styleId="0:5" '
          'name="A" id="0:2">\n'
          '    <LayoutComponentStyle name="S" id="0:5"/>\n'
          '</Artboard>\n'
          '<Backboard coreVersion="1" activeArtboardId="0:2" '
          'mainArtboardId="0:2"/>\n',
        );
        expect(problems, isEmpty);
      });

      test('rmlInspect reports a known wiring problem with its line', () {
        // Two artboards left at the origin stack when the file opens in the
        // editor -- accepted by the compiler, wrong once authored. Each
        // carries a style so the only problem left is the overlap this test
        // is after.
        final problems = rmlInspect(
          '<Artboard width="300" height="300" styleId="0:5" name="A" '
          'id="0:2">\n'
          '    <LayoutComponentStyle name="S" id="0:5"/>\n'
          '</Artboard>\n'
          '<Artboard width="300" height="300" styleId="0:15" name="B" '
          'id="0:3">\n'
          '    <LayoutComponentStyle name="S" id="0:15"/>\n'
          '</Artboard>\n'
          '<Backboard coreVersion="1" activeArtboardId="0:2" '
          'mainArtboardId="0:2"/>\n',
        );
        expect(problems, hasLength(1));
        expect(problems.single.severity, 'warning');
        expect(problems.single.kind, 'artboards-overlap');
        expect(problems.single.line, 4);
        expect(problems.single.ids, unorderedEquals(['0:3', '0:2']));
      });

      test('rmlInspect reports malformed markup as a syntax problem', () {
        final problems = rmlInspect('<Artboard name="unclosed">');
        expect(problems, isNotEmpty);
        expect(problems.every((p) => p.kind == 'syntax'), isTrue);
        expect(problems.every((p) => p.severity == 'error'), isTrue);
      });

      test('rmlInspect names the element a syntax problem is on', () {
        const markup =
            '<Artboard width="100" height="100" name="A" id="0:2">\n'
            '    <Node name="anchor" id="0:3" bogus="1"/>\n'
            '</Artboard>\n'
            '<Backboard coreVersion="1" activeArtboardId="0:2" '
            'mainArtboardId="0:2"/>\n';
        final problems = rmlInspect(markup);
        final syntax = problems.singleWhere((p) => p.kind == 'syntax');
        expect(syntax.ids, ['0:3']);
      });

      test('rmlInspect of empty markup is a syntax problem', () {
        final problems = rmlInspect('');
        expect(problems, hasLength(1));
        expect(problems.single.kind, 'syntax');
        expect(problems.single.severity, 'error');
        expect(problems.single.line, 0);
      });

      test('rmlCommitDiff turns a rename into one update and nothing else', () {
        const base =
            '<Rive version="1" kind="bundle">\n'
            '    <Artboard width="100" height="100" name="A" id="1:2"/>\n'
            '    <Backboard coreVersion="1" activeArtboardId="1:2" '
            'mainArtboardId="1:2" id="1:3"/>\n'
            '</Rive>\n';
        const sandbox =
            '<Rive version="1" kind="bundle">\n'
            '    <Artboard width="100" height="100" name="Hero" id="1:2"/>\n'
            '    <Backboard coreVersion="1" activeArtboardId="1:2" '
            'mainArtboardId="1:2" id="1:3"/>\n'
            '</Rive>\n';
        final diff = rmlCommitDiff(base, sandbox, client: 5, firstObject: 100);

        expect(diff.isSuccess, isTrue);
        expect(diff.changes, isNotNull);
        expect(diff.skipped, isEmpty);
        expect(diff.orders, isEmpty);
        final entry = diff.entries.single;
        expect(entry.op, 'update');
        expect(entry.id, '1:2');
        expect(entry.type, 'Artboard');
        expect(entry.names, ['name']);
      });

      test('rmlCommitDiff reports a sandbox that does not compile', () {
        const base =
            '<Rive version="1" kind="bundle">\n'
            '    <Artboard width="100" height="100" name="A" id="1:2"/>\n'
            '    <Backboard coreVersion="1" activeArtboardId="1:2" '
            'mainArtboardId="1:2" id="1:3"/>\n'
            '</Rive>\n';
        const broken =
            '<Rive version="1" kind="bundle">\n'
            '    <Artboard width="100" height="100" name="A" id="1:2">\n'
            '</Rive>\n';
        final diff = rmlCommitDiff(base, broken, client: 5, firstObject: 100);

        expect(diff.isSuccess, isFalse);
        expect(diff.baseFailed, isFalse);
        expect(diff.errors, isNotEmpty);
        expect(diff.changes, isNull);
        expect(diff.entries, isEmpty);
      });

      test('rmlCommitDiff blames an empty base on the base', () {
        const rml = '<Rive version="1" kind="bundle"/>\n';
        final noBase = rmlCommitDiff('', rml, client: 5, firstObject: 100);
        expect(noBase.isSuccess, isFalse);
        expect(noBase.baseFailed, isTrue);

        final noSandbox = rmlCommitDiff(rml, '', client: 5, firstObject: 100);
        expect(noSandbox.isSuccess, isFalse);
        expect(noSandbox.baseFailed, isFalse);
      });

      test('rmlCommitDiff throws on a negative id', () {
        const rml = '<Rive version="1" kind="bundle"/>\n';
        expect(
          () => rmlCommitDiff(rml, rml, client: -1, firstObject: 100),
          throwsArgumentError,
        );
        expect(
          () => rmlCommitDiff(rml, rml, client: 5, firstObject: -1),
          throwsArgumentError,
        );
      });

      group('project files', () {
        const project =
            '<Rive version="1" kind="bundle">\n'
            '    <Artboard width="100" height="100" name="A" id="1:2"/>\n'
            '    <CodeFile id="1:20"><![CDATA[return 1]]></CodeFile>\n'
            '    <ScriptAsset codeFileId="1:20" name="Mover" id="1:21"/>\n'
            '    <ImageAsset name="logo" id="1:22"/>\n'
            '    <Backboard coreVersion="1" activeArtboardId="1:2" '
            'mainArtboardId="1:2" id="1:23"/>\n'
            '</Rive>\n';

        RmlExportedProject exported() {
          final rev = rmlToRev(Uint8List.fromList(utf8.encode(project)));
          expect(rev.error, isNull);
          final exported = revToRmlFiles(rev.bytes!);
          expect(exported, isNotNull);
          return exported!;
        }

        List<RmlFileInput> inputsOf(RmlExportedProject project) => [
          for (final file in project.files)
            file.bytesOmitted
                ? RmlFileInput.withheld(file.path)
                : RmlFileInput(file.path, file.bytes),
        ];

        test('revToRmlFiles splits a script and a byteless image out', () {
          final project = exported();

          expect(project.rml, contains('file="Mover.luau"'));
          expect(project.rml, contains('file="logo.png"'));
          final script = project.files.singleWhere(
            (file) => file.path == 'Mover.luau',
          );
          expect(script.bytesOmitted, isFalse);
          expect(utf8.decode(script.bytes), 'return 1');
          final image = project.files.singleWhere(
            (file) => file.path == 'logo.png',
          );
          expect(image.bytesOmitted, isTrue);
          expect(image.bytes, isEmpty);
        });

        test('rmlToRevFiles compiles a withheld image and names its id', () {
          final project = exported();
          final compiled = rmlToRevFiles(project.rml, inputsOf(project));

          expect(compiled.errors, isEmpty);
          expect(compiled.isSuccess, isTrue);
          final byPath = {
            for (final reference in compiled.fileReferences)
              reference.path: reference,
          };
          expect(byPath['logo.png']!.id, '1:22');
          expect(byPath['Mover.luau']!.id, '1:21');
          expect(byPath['logo.png']!.line, greaterThan(0));
        });

        test('rmlToRevFiles names the asset and path of a missing file', () {
          final project = exported();
          final compiled = rmlToRevFiles(project.rml, [
            for (final input in inputsOf(project))
              if (input.path != 'logo.png') input,
          ]);

          expect(compiled.isSuccess, isFalse);
          final error = compiled.errors.singleWhere(
            (error) => error.message.contains('logo.png'),
          );
          expect(error.message, contains('logo'));
          expect(error.id, '1:22');
          expect(compiled.fileReferences, isNotEmpty);
        });

        test('a file= with leading ./ segments is reported without them', () {
          const rml =
              '<Rive version="1" kind="bundle">\n'
              '    <Artboard width="100" height="100" name="A" id="1:2"/>\n'
              '    <ImageAsset name="logo" id="1:22" file="./logo.png"/>\n'
              '    <FontAsset name="Mono" id="1:24" file="././fonts/Mono.ttf"/>\n'
              '    <Backboard coreVersion="1" activeArtboardId="1:2" '
              'mainArtboardId="1:2" id="1:23"/>\n'
              '</Rive>\n';

          final compiled = rmlToRevFiles(rml, [
            RmlFileInput.withheld('logo.png'),
            RmlFileInput.withheld('fonts/Mono.ttf'),
          ]);

          expect(compiled.errors, isEmpty);
          expect(
            {
              for (final reference in compiled.fileReferences)
                reference.id: reference.path,
            },
            {'1:22': 'logo.png', '1:24': 'fonts/Mono.ttf'},
          );
        });

        test('an empty script file compiles, an absent one does not', () {
          const rml =
              '<Rive version="1" kind="bundle">\n'
              '    <Artboard width="100" height="100" name="A" id="1:2"/>\n'
              '    <ScriptAsset name="Blank" id="1:21" file="blank.luau"/>\n'
              '    <Backboard coreVersion="1" activeArtboardId="1:2" '
              'mainArtboardId="1:2" id="1:23"/>\n'
              '</Rive>\n';

          final present = rmlToRevFiles(rml, [
            RmlFileInput('blank.luau', Uint8List(0)),
          ]);
          final absent = rmlToRevFiles(rml, const []);

          expect(present.errors, isEmpty);
          expect(present.isSuccess, isTrue);
          expect(absent.errors.single.message, contains('missing or empty'));
        });

        test('an empty image file is still an error', () {
          const rml =
              '<Rive version="1" kind="bundle">\n'
              '    <Artboard width="100" height="100" name="A" id="1:2"/>\n'
              '    <ImageAsset name="logo" id="1:22" file="logo.png"/>\n'
              '    <Backboard coreVersion="1" activeArtboardId="1:2" '
              'mainArtboardId="1:2" id="1:23"/>\n'
              '</Rive>\n';

          final compiled = rmlToRevFiles(rml, [
            RmlFileInput('logo.png', Uint8List(0)),
          ]);

          expect(compiled.errors.single.message, contains('missing or empty'));
        });

        test('a script pointing at a withheld binary file is one error', () {
          const rml =
              '<Rive version="1" kind="bundle">\n'
              '    <Artboard width="100" height="100" name="A" id="1:2"/>\n'
              '    <ScriptAsset name="Mover" id="1:21" file="logo.png"/>\n'
              '    <Backboard coreVersion="1" activeArtboardId="1:2" '
              'mainArtboardId="1:2" id="1:23"/>\n'
              '</Rive>\n';

          final compiled = rmlToRevFiles(rml, [
            RmlFileInput.withheld('logo.png'),
          ]);

          final error = compiled.errors.single;
          expect(error.message, contains('holds binary bytes'));
          expect(error.message, isNot(contains('missing or empty')));
          expect(error.id, '1:21');
          expect(error.line, 3);
        });

        test('an Assets-panel folder named builtins exports elsewhere', () {
          const rml =
              '<Rive version="1" kind="bundle">\n'
              '    <Artboard width="100" height="100" name="A" id="1:2"/>\n'
              '    <Folder name="builtins" id="1:30">\n'
              '        <ImageAsset name="pic" id="1:31"/>\n'
              '    </Folder>\n'
              '    <Backboard coreVersion="1" activeArtboardId="1:2" '
              'mainArtboardId="1:2" id="1:23"/>\n'
              '</Rive>\n';
          final rev = rmlToRev(Uint8List.fromList(utf8.encode(rml)));
          expect(rev.error, isNull);

          final exported = revToRmlFiles(rev.bytes!)!;

          expect(exported.files.map((file) => file.path), [
            'builtins_2/pic.png',
          ]);
          expect(exported.rml, contains('file="builtins_2/pic.png"'));
        });

        test('an Assets-panel folder named main.rml exports elsewhere', () {
          const rml =
              '<Rive version="1" kind="bundle">\n'
              '    <Artboard width="100" height="100" name="A" id="1:2"/>\n'
              '    <Folder name="main.rml" id="1:30">\n'
              '        <ImageAsset name="pic" id="1:31"/>\n'
              '    </Folder>\n'
              '    <Backboard coreVersion="1" activeArtboardId="1:2" '
              'mainArtboardId="1:2" id="1:23"/>\n'
              '</Rive>\n';
          final rev = rmlToRev(Uint8List.fromList(utf8.encode(rml)));
          expect(rev.error, isNull);

          final exported = revToRmlFiles(rev.bytes!)!;

          expect(exported.files.map((file) => file.path), [
            'main.rml_2/pic.png',
          ]);
          expect(exported.rml, contains('file="main.rml_2/pic.png"'));
        });

        test('rmlCommitDiffFiles of an unchanged project has no entries', () {
          final project = exported();
          final files = inputsOf(project);
          final diff = rmlCommitDiffFiles(
            base: project.rml,
            baseFiles: files,
            sandbox: project.rml,
            sandboxFiles: files,
            client: 5,
            firstObject: 100,
          );

          expect(diff.isSuccess, isTrue);
          expect(diff.entries, isEmpty);
          expect(diff.skipped, isEmpty);
        });

        test('rmlCommitDiffFiles skips a changed script file', () {
          final project = exported();
          final base = inputsOf(project);
          final sandbox = [
            for (final input in base)
              input.path == 'Mover.luau'
                  ? RmlFileInput(
                      input.path,
                      Uint8List.fromList(utf8.encode('return 2')),
                    )
                  : input,
          ];
          final diff = rmlCommitDiffFiles(
            base: project.rml,
            baseFiles: base,
            sandbox: project.rml,
            sandboxFiles: sandbox,
            client: 5,
            firstObject: 100,
          );

          expect(diff.isSuccess, isTrue);
          expect(diff.entries, isEmpty);
          expect(diff.skipped.single.reason, 'script');
        });

        test('rmlCommitDiffFiles blames an empty base on the base', () {
          final noBase = rmlCommitDiffFiles(
            base: '',
            baseFiles: const [],
            sandbox: project,
            sandboxFiles: const [],
            client: 5,
            firstObject: 100,
          );
          expect(noBase.isSuccess, isFalse);
          expect(noBase.baseFailed, isTrue);
        });

        test('rmlCommitDiffFiles throws on a negative id', () {
          expect(
            () => rmlCommitDiffFiles(
              base: project,
              baseFiles: const [],
              sandbox: project,
              sandboxFiles: const [],
              client: 5,
              firstObject: -1,
            ),
            throwsArgumentError,
          );
        });
      });
    },
  );
}
