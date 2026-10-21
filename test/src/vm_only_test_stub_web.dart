/// Web stand-in for VM-only test implementations (dart:ffi / dart:io).
/// Web compiles test files before @TestOn filtering, so VM-only imports
/// must be kept out of the web compile via conditional import; the
/// wrapper test file delegates here on web and the @TestOn('!browser')
/// annotation keeps the empty suite from running.
void main() {}
