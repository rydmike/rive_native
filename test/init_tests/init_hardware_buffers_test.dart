@TestOn('!browser')
library; // needs to own the process's first init; the web harness pre-initializes

import 'package:flutter_test/flutter_test.dart';
import 'package:rive_native/rive_native.dart' as rive;

void main() {
  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  test('the first init call decides androidHardwareBuffers', () async {
    expect(rive.RiveNative.androidHardwareBuffers, false);
    await rive.RiveNative.init(androidHardwareBuffers: true);
    expect(rive.RiveNative.androidHardwareBuffers, true);

    // The runtime calls init() again internally; those calls must not reset it.
    await rive.RiveNative.init();
    expect(rive.RiveNative.androidHardwareBuffers, true);
  });
}
