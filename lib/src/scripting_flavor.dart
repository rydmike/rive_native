/// Which scripting backend the native library carries, fixed at build time:
/// `luau` (default), `wasm`, or `both`. Every Luau only or wasm only code
/// path branches on these constants so the other backend's bindings are
/// never looked up in a library that does not export them.
const String riveScriptingFlavor = String.fromEnvironment(
  'RIVE_SCRIPTING',
  defaultValue: 'luau',
);

/// True when the library links the Luau VM.
const bool riveScriptingLuau = riveScriptingFlavor != 'wasm';

/// True when the library links the wasm VM.
const bool riveScriptingWasm = riveScriptingFlavor != 'luau';
