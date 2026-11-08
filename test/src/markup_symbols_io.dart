import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rive_native/src/ffi/rive_markup_ffi.dart' show markupSymbols;

void main() {
  test('markupAvailable probes every symbol the ffi bindings look up', () {
    final source = File(
      'lib/src/ffi/rive_markup_ffi.dart',
    ).readAsStringSync();
    // Tolerates the symbol moving onto its own line with a trailing comma
    // under tall-style formatting; bounded so a missing `>(` cannot make a
    // lazy match run on into the next lookup<...> call.
    final looked =
        RegExp(r"lookup<(?:(?!lookup<)[\s\S])*?>\(\s*'(\w+)'\s*,?\s*\)")
            .allMatches(source)
            .map((m) => m.group(1)!)
            .toSet();
    expect(looked, markupSymbols.toSet());
  });
}
