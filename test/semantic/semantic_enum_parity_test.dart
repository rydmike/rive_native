@TestOn('!browser')
library;

import 'package:flutter_test/flutter_test.dart';

import '../src/semantic_enum_parity_io.dart'
    if (dart.library.js_interop) '../src/vm_only_test_stub_web.dart' as impl;

void main() => impl.main();
