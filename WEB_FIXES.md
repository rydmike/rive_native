# rive_native 0.2.0-dev.4 with web fixes

This branch is `rive_native 0.2.0-dev.4` exactly as published on pub.dev, plus three suggested Flutter web fixes and wasm builds that contain them. It exists so an app can use the fixes until an official Rive release has them. It is not an official Rive release.

## Fixes

Each fix is also on its own branch from the verbatim baseline (`main`, tag `0.2.0-dev.4-verbatim`):

- [`fix-wasm-interop-0.2.0-dev.4`](https://github.com/rydmike/rive_native/compare/main...fix-wasm-interop-0.2.0-dev.4): Dart side, dart2wasm only. JavaScript enum values are converted to Dart strings, and live Wasm buffer views are refreshed before each access so heap growth cannot leave them detached.
- [`fix-web-image-views-0.2.0-dev.4`](https://github.com/rydmike/rive_native/compare/main...fix-web-image-views-0.2.0-dev.4): C++, in the wasm. A scripted GPU canvas that samples a file image through `Image:view()` gets a texture before the browser has decoded the image, so the view and its bind groups are not lost for good.

## Using the hosted wasm

Pass the folder holding `wasm/` and `wasm_compatibility/` to the Rive loader. It appends `wasm/rive_native.js` and falls back to `wasm_compatibility/rive_native.js`:

```text
--dart-define=RIVE_NATIVE_WASM_HOST=https://cdn.jsdelivr.net/gh/rydmike/rive_native@<tag>/native/wasm/
```

jsDelivr serves a tag of this repository unchanged, with `Access-Control-Allow-Origin: *`. The wasm carries only the C++ fix; the two Dart fixes need the package itself, as a git dependency on a tag of this branch.

## Building the wasm

The published package names the shader makefile `Makefile.rive`, so copy it back first. `build.sh` installs emsdk 4.0.23 and premake on its own.

```bash
cp runtime/renderer/src/shaders/Makefile.rive runtime/renderer/src/shaders/Makefile
cd native
./build.sh wasm release single-threaded flutter-runtime
./build.sh wasm release compatibility flutter-runtime
```

Built the same way, the unchanged baseline reproduces `wasm/rive_native.wasm` of `@rive-app/flutter-native-wasm@48.0.0` byte for byte.

## SHA-256

```text
41f48fc092b28fd5a363e81b60e7d6e132684fb1c4d85dd166a033a2ab7d35ed  native/wasm/wasm/rive_native.js
9af7107f9172a9a529093ed25399971b4add547485668de33242f304c8718cfa  native/wasm/wasm/rive_native.wasm
d22b844634246b6343f3cbcefd80874e1e99ac161f1b4dd48066f9ad67166df5  native/wasm/wasm_compatibility/rive_native.js
d5cb77451eb2c5faa9cead7fe09f7ce601afeae7b7199cafd61c55efadcc5613  native/wasm/wasm_compatibility/rive_native.wasm
```
