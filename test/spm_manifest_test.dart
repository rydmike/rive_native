@TestOn('mac-os')
library;

import 'package:flutter_test/flutter_test.dart';

import 'src/spm_manifest_io.dart'
    if (dart.library.js_interop) 'src/vm_only_test_stub_web.dart'
    as impl;

void main() => impl.main();
