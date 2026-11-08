# rive_native

Rive Native is a Dart plugin that interfaces with the [core Rive C++ runtime](https://github.com/rive-app/rive-runtime), powered by the [Rive Renderer](https://rive.app/renderer).

Additional documentation:

- [Rive Flutter getting started guide](https://rive.app/docs/runtimes/flutter/flutter)
- [What is Rive Native](https://rive.app/docs/runtimes/flutter/rive-native)
- [Migration guides](https://rive.app/docs/runtimes/flutter/migration-guide)

For up to date information on Rive Native, see the [official documentation](https://rive.app/docs/runtimes/flutter/rive-native).

## Which Package to use

While you can use `rive_native` on its own, we recommend using the [Rive Flutter package](https://pub.dev/packages/rive) (version `0.14.0+`). The `rive` package includes `rive_native` as a dependency and provides a more intuitive runtime API.

## Getting started

`rive_native` is not yet publicly available on GitHub but will be soon. For now, you can pull the source code and example by running:

```bash
dart pub unpack rive_native # Unpack the package source code and example app
cd rive_native/example      # Navigate to the example folder
flutter create .            # Create the platform folders
flutter pub get             # Fetch dependencies
flutter run                 # Run the example app
```

A higher-level declarative API is under development to simplify working with Rive graphics in Flutter.

For an example implementation, see the `rive_player.dart` file in `rive_native/example/rive_player.dart`.

---

## Platform support

| Platform | Flutter Renderer | Rive Renderer |
| -------- | ---------------- | ------------- |
| iOS      | ✅               | ✅            |
| Android  | ✅               | ✅            |
| macOS    | ✅               | ✅            |
| Windows  | ✅               | ✅            |
| Linux    | ✅               | ✅            |
| Web      | ✅               | ✅            |

---

## Feature support

All core Rive features are supported. See [Feature Support](https://rive.app/docs/feature-support) for more information.

---

## Troubleshooting

The required native libraries should be automatically downloaded during the build step (`flutter run` or `flutter build`). If you encounter issues, try the following:

1. Run `flutter clean`
2. Run `flutter pub get`
3. Run `flutter run`

Alternatively, you can manually run the `rive_native` setup script. In the root of your Flutter app, execute:

```bash
dart run rive_native:setup --verbose --clean --platform macos
```

This will clean the `rive_native` setup and download the platform-specific libraries specified with the `--platform` flag. Refer to the **Platform Support** section above for details.

---

## Building `rive_native`

By default, prebuilt native libraries are downloaded and used. If you prefer to build the libraries yourself, use the `--build` flag with the setup script. In the root of your Flutter app:

```bash
flutter clean # Important
flutter pub get
dart run rive_native:setup --verbose --clean --build --platform macos
```

See [Building rive_native](https://rive.app/docs/runtimes/flutter/rive-native#building-rive_native) in the official docs for the required tooling per platform, supported `--platform` values, web specifics, and how to return to the prebuilt libraries.

### Scripting flavors

The editor library carries a scripting backend chosen at build time with
`--scripting_vm=<luau|wasm|both>` on `native/build.sh`, for every lane the
script builds (native and wasm). The artifact layout, the podspec and the web
glue are the same for every flavor; only the library differs.

| Flavor | Library carries | Scripts run on |
|---|---|---|
| `luau` (default) | the Luau VM | Luau |
| `wasm` | WAMR; the runtime and bindings carry no Luau, only the analyzer's type function interpreter keeps `libluau_vm.a` | the wasm VM; Luau scripts still type check, complete and report problems, they just do not run |
| `both` | both VMs | whichever the file's backboard picks |

Each flavor keeps its own intermediate tree under `native/out`, so switching
flavors never needs a `clean`. Every native flavor folds the bake's binaryen
into `librive.a`, and the wasm and both flavors fold WAMR in as well.

The Dart side follows the library through the `RIVE_SCRIPTING` define, read
once as `riveScriptingFlavor` in `rive_native` and defaulting to `luau`. Every
Luau only or wasm only code path branches on it, so the unused backend is tree
shaken and its bindings are never looked up. Build the editor with the define
matching the library:

```bash
cd packages/rive_native/native && ./build.sh --scripting_vm=wasm release
cd packages/editor && flutter run -d macos --dart-define=RIVE_SCRIPTING=wasm
```

Exports bake AnimaScript scripts into one wasm module per file in the
exporting process, written unsigned as the `scripts_as` module asset ahead
of the scripts it serves. Every flavor carries the bake and rasc's std, so a
Luau only library, such as the one peon_worker exports with, bakes AnimaScript
too. Only Luau and WGSL reach the signer, so the scripts compile worker needs
neither the library flavor nor rasc's std tree.

For web: `./build.sh --scripting_vm=wasm wasm release` then
`flutter build web --dart-define=RIVE_ENVIRONMENT=development --dart-define=RIVE_SCRIPTING=wasm`.
WAMR has no emscripten platform layer, so the browser lane of the wasm and
both flavors builds without a wasm VM: `both` runs Luau there and `wasm` runs
no scripts until the browser engine backend lands.

With `both`, each file runs on the VM its backboard picks, and the
`ENABLE_WASM_SCRIPTING` feature flag gates choosing the wasm VM and porting to
it. Desktop releases ship `both`, with the flag on in UAT and off in prod.
AnimaScript
sources bake through rasc, whose std tree the editor finds in a repo checkout
or through `RIVE_RASC_STD`.

---

## Testing

Shared libraries are included in the download/build process. If you've done `flutter run` on the native platform, the libraries should already be available.

Otherwise, manually download the prebuilt libraries by doing:

```bash
dart run rive_native:setup --verbose --clean --platform macos
```

Specify the desired `--platform`, options are `macos`, `windows`, and `linux`.

Now you can run `flutter test`.

Optionally build the libraries if desired:

```bash
dart run rive_native:setup --verbose --clean --build --platform macos
```

If you encounter issues using `rive_native` in your tests, please reach out to us for assistance.

## Support

- Reach out to us on our [Community](https://community.rive.app/feed)
- File an issue on the [Rive Flutter repository](https://github.com/rive-app/rive-flutter/issues)
