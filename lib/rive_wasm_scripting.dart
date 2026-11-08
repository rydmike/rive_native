/// The wasm scripting backend as the editor drives it: a VM booted from a
/// baked module, and hosts that run a stage scripted object on it through the
/// runtime's own ScriptBackend seam. Only available when the native library
/// was built with `--scripting_vm=wasm` or `both`; see [riveScriptingWasm].
library;

import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ChangeNotifier;
import 'package:rive_native/rive_luau.dart' show ConsoleEntry;
import 'package:rive_native/rive_native.dart';

import 'src/ffi/rive_wasm_ffi.dart'
    if (dart.library.js_interop) 'src/web/rive_wasm_web.dart';

export 'src/scripting_flavor.dart';

/// Whether the loaded native library carries the wasm scripting backend.
bool get wasmScriptingAvailable =>
    riveScriptingWasm && wasmScriptingAvailableNative;

/// What a booted module executes on: the interpreter, native code wamrc
/// compiled ahead of time at -O0 or -O3, or the browser's own engine.
enum WasmExecutionTier { interp, aotO0, aotO3, browser }

/// Points the AOT compiler at [wamrcPath] and the directory its artifacts
/// persist in. An empty [wamrcPath] falls back to RIVE_WAMRC.
void configureWasmAotCompiler({
  required String wamrcPath,
  required String cacheDir,
}) =>
    configureWasmAotNative(wamrcPath, cacheDir);

/// Outcome of [WasmScriptingVM.boot]: a VM, or the boot error.
class WasmVMBoot {
  final WasmScriptingVM? vm;
  final String error;
  WasmVMBoot({this.vm, this.error = ''});
}

abstract class WasmScriptingVM {
  /// Boots [module] on the wasm engine. The module's top level, including
  /// every riveRegister call, runs here; its prints land in the console.
  static WasmVMBoot boot(Uint8List module, Factory riveFactory) =>
      bootWasmScriptingVM(module, riveFactory);

  /// The execution budget VMs booted after this call start with, so a
  /// module's top level gets the one its hooks get. 0 runs them unbounded.
  static void setDefaultExecutionTimeout(int timeoutMs) =>
      setDefaultWasmExecutionTimeoutNative(timeoutMs);

  /// While [on], modules start only under a bound the host can enforce, their
  /// own fuel or natively the watchdog, and others fail to start.
  static void requireBounds(bool on) => requireWasmBoundsNative(on);

  bool get isDisposed;

  /// The console fills from module prints and host call failures.
  final consoleHasData = ChangeNotifier();
  bool readConsole(List<ConsoleEntry> entries);
  void writeConsole(ConsoleEntry entry);

  String get lastError;

  WasmExecutionTier get executionTier;

  /// Device pixels per layout point, re-announced to every layout script.
  void displayScale(double scale);

  void setExecutionTimeout(int timeoutMs);

  /// Hands the VM a shader the workspace compiled for this bake, since the
  /// file it booted onto carries no compiled WGSL of its own.
  void registerShaderRstb(String name, Uint8List bytes);

  /// Whether [registerShaderRstb] gave the VM a shader of that name.
  bool hasShaderRstb(String name);
  void setPlaying(bool playing);

  void dispose();
}

/// Polls completed async work (image decodes) for every wasm VM in the
/// process; the stage calls it once per frame like artboard advance does.
void pollWasmAsyncWork() => pollWasmAsyncWorkNative();

enum ScriptDataKind { none, number, string, boolean, color }

class ScriptDataResult {
  final ScriptDataKind kind;
  final double number;
  final String string;
  final bool boolean;
  final int color;
  const ScriptDataResult({
    this.kind = ScriptDataKind.none,
    this.number = 0,
    this.string = '',
    this.boolean = false,
    this.color = 0,
  });
}

/// The paint snapshot a path effect script reads from its node argument.
class PathEffectPaint {
  final bool isStroke;
  final int cap;
  final int join;
  final int blendMode;
  final int color;
  final double thickness;
  final double feather;
  const PathEffectPaint({
    required this.isStroke,
    this.cap = 0,
    this.join = 0,
    this.blendMode = 0,
    this.color = 0xFF000000,
    this.thickness = 1,
    this.feather = 0,
  });
}

/// A gamepad invocation as the editor's stage sees it.
class GamepadWire {
  /// 0 connected, 1 event, 2 disconnected.
  final int kind;
  final int deviceId;
  final int buttonMask;
  final List<double> buttonValues;
  final List<double> axes;
  final int mapping;

  /// 0 button, 1 axis.
  final int changeKind;
  final int changeIndex;
  final double changeValue;
  const GamepadWire({
    required this.kind,
    required this.deviceId,
    this.buttonMask = 0,
    this.buttonValues = const [],
    this.axes = const [],
    this.mapping = 0,
    this.changeKind = 0,
    this.changeIndex = 0,
    this.changeValue = 0,
  });
}

/// One stage scripted object running on a file's wasm VM. The Dart core
/// object owns it and forwards every protocol call.
abstract class ScriptedHost {
  /// [protocol] is the runtime's ScriptProtocol index.
  static ScriptedHost? make(File file, int protocol) =>
      makeScriptedHost(file, protocol);

  /// Frees the native host; disposes the script first.
  void dispose();

  void setDataContext(InternalDataContext? dataContext);
  void setImplementedMethods(int bits);

  /// Runs the generator registered for [moduleName] in the file.
  bool instantiate(String moduleName);

  /// Calls init once the inputs are set; false tears the instance down.
  bool userInit();
  bool get isActive;

  /// True once since the last call when the script asked for an update.
  bool takeNeedsUpdate();
  bool takeDisplayScaleChanged();

  bool advance(double elapsedSeconds);
  void update();
  void trigger(String name);
  void setNumberInput(String name, double value);
  void setIntegerInput(String name, int value);
  void setBooleanInput(String name, bool value);
  void setStringInput(String name, String value);
  void setViewModelInput(String name, InternalViewModelInstanceValue value);
  void setArtboardInput(String name, Artboard artboard);

  void draw(Renderer renderer);

  /// Null when the script does not implement [method].
  HitResult? pointerEvent(
    String method,
    int pointerId,
    Vec2D localPosition, {
    required int hitType,
    required double timeStamp,
  });
  bool keyboardEvent(int key, int modifiers, bool isPressed, bool isRepeat);
  bool textEvent(String text);
  bool gamepadEvent(String method, GamepadWire gamepad);

  void listenerPointer(
    int pointerId,
    Vec2D position,
    Vec2D previousPosition,
    int hitType,
    double timeStamp,
  );
  void listenerKeyboard(int key, int modifiers, bool isPressed, bool isRepeat);
  void listenerTextInput(String text);
  void listenerFocus(bool isFocus);
  void listenerReportedEvent(double delaySeconds);
  void listenerViewModelChange();
  void listenerNone();
  void listenerGamepad(GamepadWire gamepad);

  ScriptDataResult dataConvert(
    String method,
    ScriptDataKind kind, {
    double number = 0,
    String text = '',
    bool boolean = false,
    int color = 0,
  });

  /// Null when the script did not run; the caller keeps the source path.
  RenderPath? pathEffect(
    Factory factory,
    RenderPath source,
    PathEffectPaint paint,
  );

  /// Null when the script does not implement [name].
  double? numberMethod(String name, List<double> args);
  bool booleanMethod(String name);

  void layoutResize(double width, double height);

  /// Null when the script does not implement measure.
  Vec2D? layoutMeasure();
}
