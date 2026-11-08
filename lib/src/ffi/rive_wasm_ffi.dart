import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:rive_native/rive_luau.dart' show ConsoleEntry;
import 'package:rive_native/rive_native.dart';
import 'package:rive_native/rive_wasm_scripting.dart';
import 'package:rive_native/src/console_reader.dart';
import 'package:rive_native/src/ffi/dynamic_library_helper.dart';
import 'package:rive_native/src/ffi/rive_ffi.dart';
import 'package:rive_native/src/ffi/rive_ffi_reference.dart';
import 'package:rive_native/src/ffi/rive_renderer_ffi.dart';
import 'package:rive_native/utilities.dart';

// Every lookup below is a lazy top level, resolved on first use, so a Luau
// flavored library never has these symbols looked up.
final DynamicLibrary _nativeLib = DynamicLibraryHelper.nativeLib;

typedef _Ptr = Pointer<Void>;

final _Ptr Function(
  Pointer<Uint8>,
  int,
  _Ptr,
  Pointer<NativeFunction<Void Function()>>,
) _vmBoot = _nativeLib
    .lookup<
        NativeFunction<
            _Ptr Function(
              Pointer<Uint8>,
              Uint64,
              _Ptr,
              Pointer<NativeFunction<Void Function()>>,
            )>>('riveWasmVMBoot')
    .asFunction();
final Pointer<Utf8> Function() _vmBootError = _nativeLib
    .lookup<NativeFunction<Pointer<Utf8> Function()>>('riveWasmVMBootError')
    .asFunction();
final void Function(_Ptr) _vmDelete = _nativeLib
    .lookup<NativeFunction<Void Function(_Ptr)>>('riveWasmVMDelete')
    .asFunction();
final void Function(_Ptr) _vmReleaseConsole = _nativeLib
    .lookup<NativeFunction<Void Function(_Ptr)>>('riveWasmVMReleaseConsole')
    .asFunction();
final Pointer<Uint8> Function(_Ptr) _vmConsoleData = _nativeLib
    .lookup<NativeFunction<Pointer<Uint8> Function(_Ptr)>>(
      'riveWasmVMConsoleData',
    )
    .asFunction();
final int Function(_Ptr) _vmConsoleSize = _nativeLib
    .lookup<NativeFunction<Uint64 Function(_Ptr)>>('riveWasmVMConsoleSize')
    .asFunction();
final void Function(_Ptr) _vmConsoleClear = _nativeLib
    .lookup<NativeFunction<Void Function(_Ptr)>>('riveWasmVMConsoleClear')
    .asFunction();
final Pointer<Utf8> Function(_Ptr) _vmLastError = _nativeLib
    .lookup<NativeFunction<Pointer<Utf8> Function(_Ptr)>>('riveWasmVMLastError')
    .asFunction();
final void Function(_Ptr, double) _vmDisplayScale = _nativeLib
    .lookup<NativeFunction<Void Function(_Ptr, Float)>>(
      'riveWasmVMDisplayScale',
    )
    .asFunction();
final void Function(_Ptr, int) _vmSetExecutionTimeout = _nativeLib
    .lookup<NativeFunction<Void Function(_Ptr, Int32)>>(
      'riveWasmVMSetExecutionTimeout',
    )
    .asFunction();
// Null on a native lib built before it, whose VMs boot under the default.
final void Function(int)? _setDefaultExecutionTimeout =
    _nativeLib.providesSymbol('riveWasmSetDefaultExecutionTimeout')
        ? _nativeLib
            .lookup<NativeFunction<Void Function(Int32)>>(
              'riveWasmSetDefaultExecutionTimeout',
            )
            .asFunction()
        : null;
// No fallback, so a library without it fails rather than leaving an editor
// unbounded.
final void Function(int) _requireBounds = _nativeLib
    .lookup<NativeFunction<Void Function(Uint8)>>('riveWasmRequireBounds')
    .asFunction();
final void Function(_Ptr, Pointer<Utf8>, Pointer<Uint8>, int)
    _vmRegisterShaderRstb = _nativeLib
        .lookup<
            NativeFunction<
                Void Function(_Ptr, Pointer<Utf8>, Pointer<Uint8>, Uint64)>>(
          'riveWasmVMRegisterShaderRstb',
        )
        .asFunction();
final bool Function(_Ptr, Pointer<Utf8>) _vmHasShaderRstb = _nativeLib
    .lookup<NativeFunction<Bool Function(_Ptr, Pointer<Utf8>)>>(
      'riveWasmVMHasShaderRstb',
    )
    .asFunction();
final void Function(_Ptr, int) _vmSetPlaying = _nativeLib
    .lookup<NativeFunction<Void Function(_Ptr, Uint8)>>('riveWasmVMSetPlaying')
    .asFunction();
// Null on a native lib built before AOT, which then stays on interp.
final int Function(_Ptr)? _vmExecutionTier =
    _nativeLib.providesSymbol('riveWasmVMExecutionTier')
        ? _nativeLib
            .lookup<NativeFunction<Uint8 Function(_Ptr)>>(
              'riveWasmVMExecutionTier',
            )
            .asFunction()
        : null;
final void Function(Pointer<Utf8>, Pointer<Utf8>)? _configureAot =
    _nativeLib.providesSymbol('riveWasmConfigureAot')
        ? _nativeLib
            .lookup<
                NativeFunction<
                    Void Function(Pointer<Utf8>, Pointer<Utf8>)>>(
              'riveWasmConfigureAot',
            )
            .asFunction()
        : null;
final void Function() _pollAsyncWork = _nativeLib
    .lookup<NativeFunction<Void Function()>>('riveWasmPollAsyncWork')
    .asFunction();

final void Function(_Ptr, _Ptr) riveFileAdoptWasmScriptingVM = _nativeLib
    .lookup<NativeFunction<Void Function(_Ptr, _Ptr)>>(
      'riveFileAdoptWasmScriptingVM',
    )
    .asFunction();
final _Ptr Function(_Ptr) riveFileWasmScriptingVM = _nativeLib
    .lookup<NativeFunction<_Ptr Function(_Ptr)>>('riveFileWasmScriptingVM')
    .asFunction();
final bool Function(_Ptr, Pointer<Utf8>, Pointer<Utf8>)
    riveFileRegisterWasmScript = _nativeLib
        .lookup<
            NativeFunction<Bool Function(_Ptr, Pointer<Utf8>, Pointer<Utf8>)>>(
          'riveFileRegisterWasmScript',
        )
        .asFunction();

final _Ptr Function(_Ptr, int) _hostCreate = _nativeLib
    .lookup<NativeFunction<_Ptr Function(_Ptr, Uint8)>>(
      'riveScriptedHostCreate',
    )
    .asFunction();
final void Function(_Ptr) _hostDelete = _nativeLib
    .lookup<NativeFunction<Void Function(_Ptr)>>('riveScriptedHostDelete')
    .asFunction();
final void Function(_Ptr, _Ptr) _hostSetDataContext = _nativeLib
    .lookup<NativeFunction<Void Function(_Ptr, _Ptr)>>(
      'riveScriptedHostSetDataContext',
    )
    .asFunction();
final void Function(_Ptr, int) _hostSetImplementedMethods = _nativeLib
    .lookup<NativeFunction<Void Function(_Ptr, Int32)>>(
      'riveScriptedHostSetImplementedMethods',
    )
    .asFunction();
final bool Function(_Ptr, Pointer<Utf8>) _hostInstantiate = _nativeLib
    .lookup<NativeFunction<Bool Function(_Ptr, Pointer<Utf8>)>>(
      'riveScriptedHostInstantiate',
    )
    .asFunction();
final bool Function(_Ptr) _hostUserInit = _nativeLib
    .lookup<NativeFunction<Bool Function(_Ptr)>>('riveScriptedHostUserInit')
    .asFunction();
final bool Function(_Ptr) _hostActive = _nativeLib
    .lookup<NativeFunction<Bool Function(_Ptr)>>('riveScriptedHostActive')
    .asFunction();
final bool Function(_Ptr) _hostTakeNeedsUpdate = _nativeLib
    .lookup<NativeFunction<Bool Function(_Ptr)>>(
      'riveScriptedHostTakeNeedsUpdate',
    )
    .asFunction();
final bool Function(_Ptr) _hostTakeDisplayScaleChanged = _nativeLib
    .lookup<NativeFunction<Bool Function(_Ptr)>>(
      'riveScriptedHostTakeDisplayScaleChanged',
    )
    .asFunction();
final bool Function(_Ptr, double) _hostAdvance = _nativeLib
    .lookup<NativeFunction<Bool Function(_Ptr, Float)>>(
      'riveScriptedHostAdvance',
    )
    .asFunction();
final void Function(_Ptr) _hostUpdate = _nativeLib
    .lookup<NativeFunction<Void Function(_Ptr)>>('riveScriptedHostUpdate')
    .asFunction();
final void Function(_Ptr, Pointer<Utf8>) _hostTrigger = _nativeLib
    .lookup<NativeFunction<Void Function(_Ptr, Pointer<Utf8>)>>(
      'riveScriptedHostTrigger',
    )
    .asFunction();
final void Function(_Ptr, Pointer<Utf8>, double) _hostSetNumberInput =
    _nativeLib
        .lookup<NativeFunction<Void Function(_Ptr, Pointer<Utf8>, Float)>>(
          'riveScriptedHostSetNumberInput',
        )
        .asFunction();
final void Function(_Ptr, Pointer<Utf8>, int) _hostSetIntegerInput = _nativeLib
    .lookup<NativeFunction<Void Function(_Ptr, Pointer<Utf8>, Int32)>>(
      'riveScriptedHostSetIntegerInput',
    )
    .asFunction();
final void Function(_Ptr, Pointer<Utf8>, int) _hostSetBooleanInput = _nativeLib
    .lookup<NativeFunction<Void Function(_Ptr, Pointer<Utf8>, Uint8)>>(
      'riveScriptedHostSetBooleanInput',
    )
    .asFunction();
final void Function(_Ptr, Pointer<Utf8>, Pointer<Utf8>) _hostSetStringInput =
    _nativeLib
        .lookup<
            NativeFunction<Void Function(_Ptr, Pointer<Utf8>, Pointer<Utf8>)>>(
          'riveScriptedHostSetStringInput',
        )
        .asFunction();
final void Function(_Ptr, Pointer<Utf8>, _Ptr) _hostSetViewModelInput =
    _nativeLib
        .lookup<NativeFunction<Void Function(_Ptr, Pointer<Utf8>, _Ptr)>>(
          'riveScriptedHostSetViewModelInput',
        )
        .asFunction();
final void Function(_Ptr, Pointer<Utf8>, _Ptr) _hostSetArtboardInput =
    _nativeLib
        .lookup<NativeFunction<Void Function(_Ptr, Pointer<Utf8>, _Ptr)>>(
          'riveScriptedHostSetArtboardInput',
        )
        .asFunction();
final void Function(_Ptr, _Ptr) _hostDraw = _nativeLib
    .lookup<NativeFunction<Void Function(_Ptr, _Ptr)>>('riveScriptedHostDraw')
    .asFunction();
final int Function(_Ptr, Pointer<Utf8>, int, double, double, int, double)
    _hostPointerEvent = _nativeLib
        .lookup<
            NativeFunction<
                Uint8 Function(_Ptr, Pointer<Utf8>, Int32, Float, Float, Int32,
                    Float)>>('riveScriptedHostPointerEvent')
        .asFunction();
final bool Function(_Ptr, int, int, int, int) _hostKeyboardEvent = _nativeLib
    .lookup<NativeFunction<Bool Function(_Ptr, Uint32, Uint8, Uint8, Uint8)>>(
      'riveScriptedHostKeyboardEvent',
    )
    .asFunction();
final bool Function(_Ptr, Pointer<Utf8>) _hostTextEvent = _nativeLib
    .lookup<NativeFunction<Bool Function(_Ptr, Pointer<Utf8>)>>(
      'riveScriptedHostTextEvent',
    )
    .asFunction();

typedef _GamepadEventNative = Bool Function(
  _Ptr,
  Pointer<Utf8>,
  Uint8,
  Int32,
  Uint32,
  Uint32,
  Pointer<Float>,
  Uint32,
  Pointer<Float>,
  Uint32,
  Uint8,
  Uint8,
  Uint8,
  Float,
);
typedef _GamepadEventDart = bool Function(
  _Ptr,
  Pointer<Utf8>,
  int,
  int,
  int,
  int,
  Pointer<Float>,
  int,
  Pointer<Float>,
  int,
  int,
  int,
  int,
  double,
);
final _GamepadEventDart _hostGamepadEvent = _nativeLib
    .lookup<NativeFunction<_GamepadEventNative>>('riveScriptedHostGamepadEvent')
    .asFunction();

final void Function(_Ptr, int, double, double, double, double, int, double)
    _hostListenerPointer = _nativeLib
        .lookup<
            NativeFunction<
                Void Function(_Ptr, Uint8, Float, Float, Float, Float, Int32,
                    Float)>>('riveScriptedHostListenerPointer')
        .asFunction();
final void Function(_Ptr, int, int, int, int) _hostListenerKeyboard = _nativeLib
    .lookup<NativeFunction<Void Function(_Ptr, Uint32, Uint8, Uint8, Uint8)>>(
      'riveScriptedHostListenerKeyboard',
    )
    .asFunction();
final void Function(_Ptr, Pointer<Utf8>) _hostListenerTextInput = _nativeLib
    .lookup<NativeFunction<Void Function(_Ptr, Pointer<Utf8>)>>(
      'riveScriptedHostListenerTextInput',
    )
    .asFunction();
final void Function(_Ptr, int) _hostListenerFocus = _nativeLib
    .lookup<NativeFunction<Void Function(_Ptr, Uint8)>>(
      'riveScriptedHostListenerFocus',
    )
    .asFunction();
final void Function(_Ptr, double) _hostListenerReportedEvent = _nativeLib
    .lookup<NativeFunction<Void Function(_Ptr, Float)>>(
      'riveScriptedHostListenerReportedEvent',
    )
    .asFunction();
final void Function(_Ptr) _hostListenerViewModelChange = _nativeLib
    .lookup<NativeFunction<Void Function(_Ptr)>>(
      'riveScriptedHostListenerViewModelChange',
    )
    .asFunction();
final void Function(_Ptr) _hostListenerNone = _nativeLib
    .lookup<NativeFunction<Void Function(_Ptr)>>('riveScriptedHostListenerNone')
    .asFunction();

typedef _ListenerGamepadNative = Void Function(
  _Ptr,
  Uint8,
  Int32,
  Uint32,
  Uint32,
  Pointer<Float>,
  Uint32,
  Pointer<Float>,
  Uint32,
  Uint8,
  Uint8,
  Uint8,
  Float,
);
typedef _ListenerGamepadDart = void Function(
  _Ptr,
  int,
  int,
  int,
  int,
  Pointer<Float>,
  int,
  Pointer<Float>,
  int,
  int,
  int,
  int,
  double,
);
final _ListenerGamepadDart _hostListenerGamepad = _nativeLib
    .lookup<NativeFunction<_ListenerGamepadNative>>(
      'riveScriptedHostListenerGamepad',
    )
    .asFunction();

final int Function(_Ptr, Pointer<Utf8>, int, double, Pointer<Utf8>, int, int)
    _hostDataConvert = _nativeLib
        .lookup<
            NativeFunction<
                Uint8 Function(
                  _Ptr,
                  Pointer<Utf8>,
                  Uint8,
                  Float,
                  Pointer<Utf8>,
                  Uint8,
                  Int32,
                )>>('riveScriptedHostDataConvert')
        .asFunction();
final double Function(_Ptr) _hostConvertNumber = _nativeLib
    .lookup<NativeFunction<Float Function(_Ptr)>>(
      'riveScriptedHostConvertNumber',
    )
    .asFunction();
final Pointer<Utf8> Function(_Ptr) _hostConvertString = _nativeLib
    .lookup<NativeFunction<Pointer<Utf8> Function(_Ptr)>>(
      'riveScriptedHostConvertString',
    )
    .asFunction();
final bool Function(_Ptr) _hostConvertBoolean = _nativeLib
    .lookup<NativeFunction<Bool Function(_Ptr)>>(
      'riveScriptedHostConvertBoolean',
    )
    .asFunction();
final int Function(_Ptr) _hostConvertColor = _nativeLib
    .lookup<NativeFunction<Int32 Function(_Ptr)>>(
      'riveScriptedHostConvertColor',
    )
    .asFunction();

typedef _PathEffectNative = _Ptr Function(
  _Ptr,
  _Ptr,
  _Ptr,
  Uint32,
  Uint32,
  Uint32,
  Uint32,
  Uint32,
  Float,
  Float,
);
typedef _PathEffectDart = _Ptr Function(
    _Ptr, _Ptr, _Ptr, int, int, int, int, int, double, double);
final _PathEffectDart _hostPathEffect = _nativeLib
    .lookup<NativeFunction<_PathEffectNative>>('riveScriptedHostPathEffect')
    .asFunction();

final bool Function(_Ptr, Pointer<Utf8>, Pointer<Float>, int, Pointer<Float>)
    _hostNumberMethod = _nativeLib
        .lookup<
            NativeFunction<
                Bool Function(
                  _Ptr,
                  Pointer<Utf8>,
                  Pointer<Float>,
                  Uint32,
                  Pointer<Float>,
                )>>('riveScriptedHostNumberMethod')
        .asFunction();
final bool Function(_Ptr, Pointer<Utf8>) _hostBooleanMethod = _nativeLib
    .lookup<NativeFunction<Bool Function(_Ptr, Pointer<Utf8>)>>(
      'riveScriptedHostBooleanMethod',
    )
    .asFunction();
final void Function(_Ptr, double, double) _hostLayoutResize = _nativeLib
    .lookup<NativeFunction<Void Function(_Ptr, Float, Float)>>(
      'riveScriptedHostLayoutResize',
    )
    .asFunction();
final bool Function(_Ptr, Pointer<Float>) _hostLayoutMeasure = _nativeLib
    .lookup<NativeFunction<Bool Function(_Ptr, Pointer<Float>)>>(
      'riveScriptedHostLayoutMeasure',
    )
    .asFunction();

bool get wasmScriptingAvailableNative =>
    _nativeLib.providesSymbol('riveWasmVMBoot');

WasmVMBoot bootWasmScriptingVM(Uint8List module, Factory riveFactory) {
  final bytes = malloc.allocate<Uint8>(module.length);
  bytes.asTypedList(module.length).setAll(0, module);
  final vm = WasmScriptingVMFFI._();
  final pointer = _vmBoot(
    bytes,
    module.length,
    (riveFactory as FFIFactory).pointer,
    vm._callback!.nativeFunction,
  );
  malloc.free(bytes);
  if (pointer == nullptr) {
    vm._closeCallback();
    return WasmVMBoot(error: _vmBootError().toDartString());
  }
  vm._pointer = pointer;
  return WasmVMBoot(vm: vm);
}

void pollWasmAsyncWorkNative() => _pollAsyncWork();

void setDefaultWasmExecutionTimeoutNative(int timeoutMs) =>
    _setDefaultExecutionTimeout?.call(timeoutMs);

void requireWasmBoundsNative(bool on) {
  if (wasmScriptingAvailableNative) {
    _requireBounds(on ? 1 : 0);
  }
}

void configureWasmAotNative(String wamrcPath, String cacheDir) {
  final configureAot = _configureAot;
  if (configureAot == null) {
    return;
  }
  final wamrc = wamrcPath.toNativeUtf8();
  final cache = cacheDir.toNativeUtf8();
  configureAot(wamrc, cache);
  malloc.free(wamrc);
  malloc.free(cache);
}

class WasmScriptingVMFFI extends WasmScriptingVM implements RiveFFIReference {
  _Ptr _pointer = nullptr;
  NativeCallable<Void Function()>? _callback;
  bool _adopted = false;
  final _bufferedEntries = <ConsoleEntry>[];

  // Must be .listener (async): the callback fires from inside a module call.
  WasmScriptingVMFFI._() {
    _callback = NativeCallable<Void Function()>.listener(
      // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
      consoleHasData.notifyListeners,
    );
  }

  void _closeCallback() {
    _callback?.close();
    _callback = null;
  }

  @override
  Pointer<Void> get pointer => _pointer;

  @override
  bool get isDisposed => _pointer == nullptr;

  /// Called by the file that takes ownership.
  void markAdopted() => _adopted = true;

  bool _readNativeConsole(List<ConsoleEntry> entries) {
    if (isDisposed) {
      return false;
    }
    final size = _vmConsoleSize(_pointer);
    if (size == 0) {
      return false;
    }
    final data = _vmConsoleData(_pointer).asTypedList(size);
    final reader = BinaryReader.fromList(Uint8List.fromList(data));
    _vmConsoleClear(_pointer);
    return readConsoleEntries(reader, entries);
  }

  @override
  bool readConsole(List<ConsoleEntry> entries) {
    bool read = _bufferedEntries.isNotEmpty;
    if (read) {
      entries.addAll(_bufferedEntries);
      _bufferedEntries.clear();
    }
    return _readNativeConsole(entries) || read;
  }

  @override
  void writeConsole(ConsoleEntry entry) {
    _readNativeConsole(_bufferedEntries);
    _bufferedEntries.add(entry);
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    consoleHasData.notifyListeners();
  }

  @override
  String get lastError =>
      isDisposed ? '' : _vmLastError(_pointer).toDartString();

  @override
  WasmExecutionTier get executionTier {
    final executionTier = _vmExecutionTier;
    return isDisposed || executionTier == null
        ? WasmExecutionTier.interp
        : WasmExecutionTier.values[executionTier(_pointer)];
  }

  @override
  void displayScale(double scale) {
    if (!isDisposed) {
      _vmDisplayScale(_pointer, scale);
    }
  }

  @override
  void setExecutionTimeout(int timeoutMs) {
    if (!isDisposed) {
      _vmSetExecutionTimeout(_pointer, timeoutMs);
    }
  }

  @override
  void registerShaderRstb(String name, Uint8List bytes) {
    if (isDisposed) {
      return;
    }
    final nameNative = name.toNativeUtf8();
    final bytesNative = malloc.allocate<Uint8>(bytes.length);
    bytesNative.asTypedList(bytes.length).setAll(0, bytes);
    _vmRegisterShaderRstb(_pointer, nameNative, bytesNative, bytes.length);
    malloc.free(bytesNative);
    malloc.free(nameNative);
  }

  @override
  bool hasShaderRstb(String name) {
    if (isDisposed) {
      return false;
    }
    final nameNative = name.toNativeUtf8();
    final has = _vmHasShaderRstb(_pointer, nameNative);
    malloc.free(nameNative);
    return has;
  }

  @override
  void setPlaying(bool playing) {
    if (!isDisposed) {
      _vmSetPlaying(_pointer, playing ? 1 : 0);
    }
  }

  @override
  void dispose() {
    if (isDisposed) {
      return;
    }
    if (_adopted) {
      _vmReleaseConsole(_pointer);
    } else {
      _vmDelete(_pointer);
    }
    _pointer = nullptr;
    _closeCallback();
  }
}

ScriptedHost? makeScriptedHost(File file, int protocol) {
  final pointer = _hostCreate((file as FFIRiveFile).pointer, protocol);
  if (pointer == nullptr) {
    return null;
  }
  return ScriptedHostFFI._(pointer);
}

T _withUtf8<T>(String value, T Function(Pointer<Utf8>) body) {
  final native = value.toNativeUtf8(allocator: calloc);
  try {
    return body(native);
  } finally {
    calloc.free(native);
  }
}

T _withFloats<T>(List<double> values, T Function(Pointer<Float>, int) body) {
  final native = calloc.allocate<Float>(
    values.isEmpty ? sizeOf<Float>() : values.length * sizeOf<Float>(),
  );
  try {
    native.asTypedList(values.isEmpty ? 1 : values.length).setAll(0, values);
    return body(native, values.length);
  } finally {
    calloc.free(native);
  }
}

class ScriptedHostFFI extends ScriptedHost {
  _Ptr _pointer;
  ScriptedHostFFI._(this._pointer);

  @override
  void dispose() {
    if (_pointer == nullptr) {
      return;
    }
    _hostDelete(_pointer);
    _pointer = nullptr;
  }

  @override
  void setDataContext(InternalDataContext? dataContext) => _hostSetDataContext(
        _pointer,
        dataContext == null
            ? nullptr
            : (dataContext as FFIRiveInternalDataContext).pointer,
      );

  @override
  void setImplementedMethods(int bits) =>
      _hostSetImplementedMethods(_pointer, bits);

  @override
  bool instantiate(String moduleName) =>
      _withUtf8(moduleName, (name) => _hostInstantiate(_pointer, name));

  @override
  bool userInit() => _hostUserInit(_pointer);

  @override
  bool get isActive => _pointer != nullptr && _hostActive(_pointer);

  @override
  bool takeNeedsUpdate() => _hostTakeNeedsUpdate(_pointer);

  @override
  bool takeDisplayScaleChanged() => _hostTakeDisplayScaleChanged(_pointer);

  @override
  bool advance(double elapsedSeconds) => _hostAdvance(_pointer, elapsedSeconds);

  @override
  void update() => _hostUpdate(_pointer);

  @override
  void trigger(String name) =>
      _withUtf8(name, (native) => _hostTrigger(_pointer, native));

  @override
  void setNumberInput(String name, double value) =>
      _withUtf8(name, (native) => _hostSetNumberInput(_pointer, native, value));

  @override
  void setIntegerInput(String name, int value) => _withUtf8(
        name,
        (native) => _hostSetIntegerInput(_pointer, native, value),
      );

  @override
  void setBooleanInput(String name, bool value) => _withUtf8(
        name,
        (native) => _hostSetBooleanInput(_pointer, native, value ? 1 : 0),
      );

  @override
  void setStringInput(String name, String value) => _withUtf8(
        name,
        (native) => _withUtf8(
            value, (text) => _hostSetStringInput(_pointer, native, text)),
      );

  @override
  void setViewModelInput(String name, InternalViewModelInstanceValue value) =>
      _withUtf8(
        name,
        (native) => _hostSetViewModelInput(
          _pointer,
          native,
          Pointer<Void>.fromAddress(value.instancePointerAddress),
        ),
      );

  @override
  void setArtboardInput(String name, Artboard artboard) => _withUtf8(
        name,
        (native) => _hostSetArtboardInput(
          _pointer,
          native,
          (artboard as FFIRiveArtboard).pointer,
        ),
      );

  @override
  void draw(Renderer renderer) =>
      _hostDraw(_pointer, (renderer as RiveFFIReference).pointer);

  @override
  HitResult? pointerEvent(
    String method,
    int pointerId,
    Vec2D localPosition, {
    required int hitType,
    required double timeStamp,
  }) {
    final result = _withUtf8(
      method,
      (native) => _hostPointerEvent(
        _pointer,
        native,
        pointerId,
        localPosition.x,
        localPosition.y,
        hitType,
        timeStamp,
      ),
    );
    return result == 0 ? null : HitResult.values[result - 1];
  }

  @override
  bool keyboardEvent(int key, int modifiers, bool isPressed, bool isRepeat) =>
      _hostKeyboardEvent(
        _pointer,
        key,
        modifiers,
        isPressed ? 1 : 0,
        isRepeat ? 1 : 0,
      );

  @override
  bool textEvent(String text) =>
      _withUtf8(text, (native) => _hostTextEvent(_pointer, native));

  @override
  bool gamepadEvent(String method, GamepadWire gamepad) => _withUtf8(
        method,
        (native) => _withFloats(
          gamepad.buttonValues,
          (buttons, buttonCount) => _withFloats(
            gamepad.axes,
            (axes, axisCount) => _hostGamepadEvent(
              _pointer,
              native,
              gamepad.kind,
              gamepad.deviceId,
              gamepad.buttonMask & 0xFFFFFFFF,
              (gamepad.buttonMask >> 32) & 0xFFFFFFFF,
              buttons,
              buttonCount,
              axes,
              axisCount,
              gamepad.mapping,
              gamepad.changeKind,
              gamepad.changeIndex,
              gamepad.changeValue,
            ),
          ),
        ),
      );

  @override
  void listenerPointer(
    int pointerId,
    Vec2D position,
    Vec2D previousPosition,
    int hitType,
    double timeStamp,
  ) =>
      _hostListenerPointer(
        _pointer,
        pointerId,
        position.x,
        position.y,
        previousPosition.x,
        previousPosition.y,
        hitType,
        timeStamp,
      );

  @override
  void listenerKeyboard(
    int key,
    int modifiers,
    bool isPressed,
    bool isRepeat,
  ) =>
      _hostListenerKeyboard(
        _pointer,
        key,
        modifiers,
        isPressed ? 1 : 0,
        isRepeat ? 1 : 0,
      );

  @override
  void listenerTextInput(String text) =>
      _withUtf8(text, (native) => _hostListenerTextInput(_pointer, native));

  @override
  void listenerFocus(bool isFocus) =>
      _hostListenerFocus(_pointer, isFocus ? 1 : 0);

  @override
  void listenerReportedEvent(double delaySeconds) =>
      _hostListenerReportedEvent(_pointer, delaySeconds);

  @override
  void listenerViewModelChange() => _hostListenerViewModelChange(_pointer);

  @override
  void listenerNone() => _hostListenerNone(_pointer);

  @override
  void listenerGamepad(GamepadWire gamepad) => _withFloats(
        gamepad.buttonValues,
        (buttons, buttonCount) => _withFloats(
          gamepad.axes,
          (axes, axisCount) => _hostListenerGamepad(
            _pointer,
            gamepad.kind,
            gamepad.deviceId,
            gamepad.buttonMask & 0xFFFFFFFF,
            (gamepad.buttonMask >> 32) & 0xFFFFFFFF,
            buttons,
            buttonCount,
            axes,
            axisCount,
            gamepad.mapping,
            gamepad.changeKind,
            gamepad.changeIndex,
            gamepad.changeValue,
          ),
        ),
      );

  @override
  ScriptDataResult dataConvert(
    String method,
    ScriptDataKind kind, {
    double number = 0,
    String text = '',
    bool boolean = false,
    int color = 0,
  }) {
    final resultKind = _withUtf8(
      method,
      (native) => _withUtf8(
        text,
        (nativeText) => _hostDataConvert(
          _pointer,
          native,
          kind.index,
          number,
          nativeText,
          boolean ? 1 : 0,
          color,
        ),
      ),
    );
    return switch (ScriptDataKind.values[resultKind]) {
      ScriptDataKind.number => ScriptDataResult(
          kind: ScriptDataKind.number,
          number: _hostConvertNumber(_pointer),
        ),
      ScriptDataKind.string => ScriptDataResult(
          kind: ScriptDataKind.string,
          string: _hostConvertString(_pointer).toDartString(),
        ),
      ScriptDataKind.boolean => ScriptDataResult(
          kind: ScriptDataKind.boolean,
          boolean: _hostConvertBoolean(_pointer),
        ),
      ScriptDataKind.color => ScriptDataResult(
          kind: ScriptDataKind.color,
          color: _hostConvertColor(_pointer),
        ),
      ScriptDataKind.none => const ScriptDataResult(),
    };
  }

  @override
  RenderPath? pathEffect(
    Factory factory,
    RenderPath source,
    PathEffectPaint paint,
  ) {
    final result = _hostPathEffect(
      _pointer,
      (factory as FFIFactory).pointer,
      (source as FFIRenderPath).pointer,
      paint.isStroke ? 1 : 0,
      paint.cap,
      paint.join,
      paint.blendMode,
      paint.color,
      paint.thickness,
      paint.feather,
    );
    if (result == nullptr) {
      return null;
    }
    return FFIRenderPath.fromPointer(factory, result);
  }

  @override
  double? numberMethod(String name, List<double> args) {
    final out = calloc.allocate<Float>(sizeOf<Float>());
    try {
      final ok = _withUtf8(
        name,
        (native) => _withFloats(
          args,
          (values, count) =>
              _hostNumberMethod(_pointer, native, values, count, out),
        ),
      );
      return ok ? out.value : null;
    } finally {
      calloc.free(out);
    }
  }

  @override
  bool booleanMethod(String name) =>
      _withUtf8(name, (native) => _hostBooleanMethod(_pointer, native));

  @override
  void layoutResize(double width, double height) =>
      _hostLayoutResize(_pointer, width, height);

  @override
  Vec2D? layoutMeasure() {
    final out = calloc.allocate<Float>(2 * sizeOf<Float>());
    try {
      if (!_hostLayoutMeasure(_pointer, out)) {
        return null;
      }
      return Vec2D.fromValues(out[0], out[1]);
    } finally {
      calloc.free(out);
    }
  }
}
