import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  // SwiftPM compiles each manifest on its own; a Foundation API used without
  // `import Foundation` fails to resolve on newer toolchains.
  for (final platform in ['ios', 'macos']) {
    test('$platform Package.swift compiles as a SwiftPM manifest', () async {
      final scratch = Directory.systemTemp.createTempSync('rive_spm_');
      addTearDown(() => scratch.deleteSync(recursive: true));
      final result = await Process.run('swift', [
        'package',
        '--scratch-path',
        scratch.path,
        'dump-package',
      ], workingDirectory: '$platform/rive_native');
      expect(result.exitCode, 0, reason: '${result.stderr}');
    });
  }
}
