import 'dart:js_interop' as js;
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:rive_native/rive_luau.dart' show ConsoleEntry;
import 'package:rive_native/rive_native.dart';
import 'package:rive_native/rive_wasm_scripting.dart';
import 'package:rive_native/src/console_reader.dart';
import 'package:rive_native/src/rive_native_web.dart';
import 'package:rive_native/src/web/rive_renderer_web.dart';
import 'package:rive_native/src/web/rive_web.dart';
import 'package:rive_native/utilities.dart';

/// Raw exports of the wasm scripting binding; linked only when the module
/// carries them, so a Luau flavored module links fine without.
class WasmScriptingWeb {
  static late js.JSFunction vmBoot;
  static late js.JSFunction vmBootError;
  // Tools builds only.
  static js.JSFunction? vmRegisterShaderRstb;
  static js.JSFunction? vmHasShaderRstb;
  static late js.JSFunction vmDelete;
  static late js.JSFunction vmReleaseConsole;
  static late js.JSFunction vmConsoleData;
  static late js.JSFunction vmConsoleSize;
  static late js.JSFunction vmConsoleClear;
  static late js.JSFunction vmLastError;
  static late js.JSFunction vmDisplayScale;
  static late js.JSFunction vmSetExecutionTimeout;
  static js.JSFunction? setDefaultExecutionTimeout;
  static late js.JSFunction requireBounds;
  static late js.JSFunction vmSetPlaying;
  static late js.JSFunction pollAsyncWork;
  static late js.JSFunction fileAdoptWasmScriptingVM;
  static late js.JSFunction fileWasmScriptingVM;
  static late js.JSFunction fileRegisterWasmScript;
  static late js.JSFunction hostCreate;
  static late js.JSFunction hostDelete;
  static late js.JSFunction hostSetDataContext;
  static late js.JSFunction hostSetImplementedMethods;
  static late js.JSFunction hostInstantiate;
  static late js.JSFunction hostUserInit;
  static late js.JSFunction hostActive;
  static late js.JSFunction hostTakeNeedsUpdate;
  static late js.JSFunction hostTakeDisplayScaleChanged;
  static late js.JSFunction hostAdvance;
  static late js.JSFunction hostUpdate;
  static late js.JSFunction hostTrigger;
  static late js.JSFunction hostSetNumberInput;
  static late js.JSFunction hostSetIntegerInput;
  static late js.JSFunction hostSetBooleanInput;
  static late js.JSFunction hostSetStringInput;
  static late js.JSFunction hostSetViewModelInput;
  static late js.JSFunction hostSetArtboardInput;
  static late js.JSFunction hostDraw;
  static late js.JSFunction hostPointerEvent;
  static late js.JSFunction hostKeyboardEvent;
  static late js.JSFunction hostTextEvent;
  static late js.JSFunction hostGamepadEvent;
  static late js.JSFunction hostListenerPointer;
  static late js.JSFunction hostListenerKeyboard;
  static late js.JSFunction hostListenerTextInput;
  static late js.JSFunction hostListenerFocus;
  static late js.JSFunction hostListenerReportedEvent;
  static late js.JSFunction hostListenerViewModelChange;
  static late js.JSFunction hostListenerNone;
  static late js.JSFunction hostListenerGamepad;
  static late js.JSFunction hostDataConvert;
  static late js.JSFunction hostConvertNumber;
  static late js.JSFunction hostConvertString;
  static late js.JSFunction hostConvertBoolean;
  static late js.JSFunction hostConvertColor;
  static late js.JSFunction hostPathEffect;
  static late js.JSFunction hostNumberMethod;
  static late js.JSFunction hostBooleanMethod;
  static late js.JSFunction hostLayoutResize;
  static late js.JSFunction hostLayoutMeasure;

  static bool linked = false;

  static void link(js.JSObject module) {
    js.JSFunction raw(String name) => module['_$name'] as js.JSFunction;
    js.JSFunction? optional(String name) => module['_$name'] as js.JSFunction?;
    vmBoot = module['riveWasmVMBoot'] as js.JSFunction;
    vmBootError = raw('riveWasmVMBootError');
    vmRegisterShaderRstb = optional('riveWasmVMRegisterShaderRstb');
    vmHasShaderRstb = optional('riveWasmVMHasShaderRstb');
    vmDelete = raw('riveWasmVMDelete');
    vmReleaseConsole = raw('riveWasmVMReleaseConsole');
    vmConsoleData = raw('riveWasmVMConsoleData');
    vmConsoleSize = raw('riveWasmVMConsoleSize');
    vmConsoleClear = raw('riveWasmVMConsoleClear');
    vmLastError = raw('riveWasmVMLastError');
    vmDisplayScale = raw('riveWasmVMDisplayScale');
    vmSetExecutionTimeout = raw('riveWasmVMSetExecutionTimeout');
    setDefaultExecutionTimeout = optional('riveWasmSetDefaultExecutionTimeout');
    requireBounds = raw('riveWasmRequireBounds');
    vmSetPlaying = raw('riveWasmVMSetPlaying');
    pollAsyncWork = raw('riveWasmPollAsyncWork');
    fileAdoptWasmScriptingVM = raw('riveFileAdoptWasmScriptingVM');
    fileWasmScriptingVM = raw('riveFileWasmScriptingVM');
    fileRegisterWasmScript = raw('riveFileRegisterWasmScript');
    hostCreate = raw('riveScriptedHostCreate');
    hostDelete = raw('riveScriptedHostDelete');
    hostSetDataContext = raw('riveScriptedHostSetDataContext');
    hostSetImplementedMethods = raw('riveScriptedHostSetImplementedMethods');
    hostInstantiate = raw('riveScriptedHostInstantiate');
    hostUserInit = raw('riveScriptedHostUserInit');
    hostActive = raw('riveScriptedHostActive');
    hostTakeNeedsUpdate = raw('riveScriptedHostTakeNeedsUpdate');
    hostTakeDisplayScaleChanged = raw(
      'riveScriptedHostTakeDisplayScaleChanged',
    );
    hostAdvance = raw('riveScriptedHostAdvance');
    hostUpdate = raw('riveScriptedHostUpdate');
    hostTrigger = raw('riveScriptedHostTrigger');
    hostSetNumberInput = raw('riveScriptedHostSetNumberInput');
    hostSetIntegerInput = raw('riveScriptedHostSetIntegerInput');
    hostSetBooleanInput = raw('riveScriptedHostSetBooleanInput');
    hostSetStringInput = raw('riveScriptedHostSetStringInput');
    hostSetViewModelInput = raw('riveScriptedHostSetViewModelInput');
    hostSetArtboardInput = raw('riveScriptedHostSetArtboardInput');
    hostDraw = raw('riveScriptedHostDraw');
    hostPointerEvent = raw('riveScriptedHostPointerEvent');
    hostKeyboardEvent = raw('riveScriptedHostKeyboardEvent');
    hostTextEvent = raw('riveScriptedHostTextEvent');
    hostGamepadEvent = raw('riveScriptedHostGamepadEvent');
    hostListenerPointer = raw('riveScriptedHostListenerPointer');
    hostListenerKeyboard = raw('riveScriptedHostListenerKeyboard');
    hostListenerTextInput = raw('riveScriptedHostListenerTextInput');
    hostListenerFocus = raw('riveScriptedHostListenerFocus');
    hostListenerReportedEvent = raw('riveScriptedHostListenerReportedEvent');
    hostListenerViewModelChange = raw(
      'riveScriptedHostListenerViewModelChange',
    );
    hostListenerNone = raw('riveScriptedHostListenerNone');
    hostListenerGamepad = raw('riveScriptedHostListenerGamepad');
    hostDataConvert = raw('riveScriptedHostDataConvert');
    hostConvertNumber = raw('riveScriptedHostConvertNumber');
    hostConvertString = raw('riveScriptedHostConvertString');
    hostConvertBoolean = raw('riveScriptedHostConvertBoolean');
    hostConvertColor = raw('riveScriptedHostConvertColor');
    hostPathEffect = raw('riveScriptedHostPathEffect');
    hostNumberMethod = raw('riveScriptedHostNumberMethod');
    hostBooleanMethod = raw('riveScriptedHostBooleanMethod');
    hostLayoutResize = raw('riveScriptedHostLayoutResize');
    hostLayoutMeasure = raw('riveScriptedHostLayoutMeasure');
    linked = true;
  }
}

int _int(js.JSAny? value) => (value as js.JSNumber).toDartInt;
double _double(js.JSAny? value) => (value as js.JSNumber).toDartDouble;
bool _bool(js.JSAny? value) => _int(value) != 0;

T _withUtf8<T>(String value, T Function(js.JSAny pointer) body) {
  final buffer = value.toWasmUtf8();
  try {
    return body(buffer.pointer);
  } finally {
    buffer.dispose();
  }
}

T _withFloats<T>(List<double> values, T Function(js.JSAny pointer) body) {
  final buffer = WasmBuffer((values.isEmpty ? 1 : values.length) * 4);
  try {
    final data = buffer.data;
    Float32List.view(
      data.buffer,
      data.offsetInBytes,
      values.length,
    ).setAll(0, values);
    return body(buffer.pointer);
  } finally {
    buffer.dispose();
  }
}

bool get wasmScriptingAvailableNative => WasmScriptingWeb.linked;

WasmVMBoot bootWasmScriptingVM(Uint8List module, Factory riveFactory) {
  if (!WasmScriptingWeb.linked) {
    return WasmVMBoot(error: 'the wasm module carries no wasm scripting VM');
  }
  final bytes = WasmBuffer.fromBytes(module);
  final vm = WasmScriptingVMWasm._();
  final pointer = _int(
    WasmScriptingWeb.vmBoot.callAsFunction(
      null,
      bytes.pointer,
      module.length.toJS,
      (riveFactory as WebFactory).pointer,
      vm.notifyConsoleHasData.toJS,
    ),
  );
  bytes.dispose();
  if (pointer == 0) {
    return WasmVMBoot(
      error: RiveWasm.toDartString(
        _int(WasmScriptingWeb.vmBootError.callAsFunction(null)),
      ),
    );
  }
  vm._pointer = pointer;
  return WasmVMBoot(vm: vm);
}

// The browser compiles modules itself; there is no wamrc to point at.
void configureWasmAotNative(String wamrcPath, String cacheDir) {}

void pollWasmAsyncWorkNative() {
  if (WasmScriptingWeb.linked) {
    WasmScriptingWeb.pollAsyncWork.callAsFunction(null);
  }
}

void setDefaultWasmExecutionTimeoutNative(int timeoutMs) {
  if (WasmScriptingWeb.linked) {
    WasmScriptingWeb.setDefaultExecutionTimeout?.callAsFunction(
      null,
      timeoutMs.toJS,
    );
  }
}

void requireWasmBoundsNative(bool on) {
  if (WasmScriptingWeb.linked) {
    WasmScriptingWeb.requireBounds.callAsFunction(null, (on ? 1 : 0).toJS);
  }
}

class WasmScriptingVMWasm extends WasmScriptingVM {
  int _pointer = 0;
  bool _adopted = false;
  final _bufferedEntries = <ConsoleEntry>[];

  WasmScriptingVMWasm._();

  @js.JSExport()
  // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
  void notifyConsoleHasData() => consoleHasData.notifyListeners();

  int get pointer => _pointer;

  @override
  bool get isDisposed => _pointer == 0;

  void markAdopted() => _adopted = true;

  bool _readNativeConsole(List<ConsoleEntry> entries) {
    if (isDisposed) {
      return false;
    }
    final size = _int(
      WasmScriptingWeb.vmConsoleSize.callAsFunction(null, _pointer.toJS),
    );
    if (size == 0) {
      return false;
    }
    final data = _int(
      WasmScriptingWeb.vmConsoleData.callAsFunction(null, _pointer.toJS),
    );
    final reader = BinaryReader.fromList(
      Uint8List.fromList(RiveWasm.heap(data, size)),
    );
    WasmScriptingWeb.vmConsoleClear.callAsFunction(null, _pointer.toJS);
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
    notifyConsoleHasData();
  }

  @override
  String get lastError => isDisposed
      ? ''
      : RiveWasm.toDartString(
          _int(
            WasmScriptingWeb.vmLastError.callAsFunction(null, _pointer.toJS),
          ),
        );

  @override
  void displayScale(double scale) {
    if (!isDisposed) {
      WasmScriptingWeb.vmDisplayScale.callAsFunction(
        null,
        _pointer.toJS,
        scale.toJS,
      );
    }
  }

  @override
  WasmExecutionTier get executionTier => WasmExecutionTier.browser;

  @override
  void registerShaderRstb(String name, Uint8List bytes) {
    final register = WasmScriptingWeb.vmRegisterShaderRstb;
    if (isDisposed || register == null) {
      return;
    }
    final buffer = WasmBuffer.fromBytes(bytes);
    _withUtf8(
      name,
      (native) => register.callAsFunctionEx(
        null,
        _pointer.toJS,
        native,
        buffer.pointer,
        bytes.length.toJS,
      ),
    );
    buffer.dispose();
  }

  @override
  bool hasShaderRstb(String name) {
    final has = WasmScriptingWeb.vmHasShaderRstb;
    return !isDisposed &&
        has != null &&
        _withUtf8(
              name,
              (native) =>
                  _int(has.callAsFunctionEx(null, _pointer.toJS, native)),
            ) !=
            0;
  }

  @override
  void setExecutionTimeout(int timeoutMs) {
    if (!isDisposed) {
      WasmScriptingWeb.vmSetExecutionTimeout.callAsFunction(
        null,
        _pointer.toJS,
        timeoutMs.toJS,
      );
    }
  }

  @override
  void setPlaying(bool playing) {
    if (!isDisposed) {
      WasmScriptingWeb.vmSetPlaying.callAsFunction(
        null,
        _pointer.toJS,
        (playing ? 1 : 0).toJS,
      );
    }
  }

  @override
  void dispose() {
    if (isDisposed) {
      return;
    }
    if (_adopted) {
      WasmScriptingWeb.vmReleaseConsole.callAsFunction(null, _pointer.toJS);
    } else {
      WasmScriptingWeb.vmDelete.callAsFunction(null, _pointer.toJS);
    }
    _pointer = 0;
  }
}

ScriptedHost? makeScriptedHost(File file, int protocol) {
  if (!WasmScriptingWeb.linked) {
    return null;
  }
  final pointer = _int(
    WasmScriptingWeb.hostCreate.callAsFunction(
      null,
      (file as WebRiveFile).pointer.toJS,
      protocol.toJS,
    ),
  );
  return pointer == 0 ? null : ScriptedHostWasm._(pointer);
}

class ScriptedHostWasm extends ScriptedHost {
  int _pointer;
  ScriptedHostWasm._(this._pointer);

  js.JSAny get _ptr => _pointer.toJS;

  @override
  void dispose() {
    if (_pointer == 0) {
      return;
    }
    WasmScriptingWeb.hostDelete.callAsFunction(null, _ptr);
    _pointer = 0;
  }

  @override
  void setDataContext(InternalDataContext? dataContext) =>
      WasmScriptingWeb.hostSetDataContext.callAsFunction(
        null,
        _ptr,
        (dataContext == null ? 0 : (dataContext as WebRiveDataContext).pointer)
            .toJS,
      );

  @override
  void setImplementedMethods(int bits) =>
      WasmScriptingWeb.hostSetImplementedMethods
          .callAsFunction(null, _ptr, bits.toJS);

  @override
  bool instantiate(String moduleName) => _withUtf8(
        moduleName,
        (name) => _bool(
          WasmScriptingWeb.hostInstantiate.callAsFunction(null, _ptr, name),
        ),
      );

  @override
  bool userInit() =>
      _bool(WasmScriptingWeb.hostUserInit.callAsFunction(null, _ptr));

  @override
  bool get isActive =>
      _pointer != 0 &&
      _bool(WasmScriptingWeb.hostActive.callAsFunction(null, _ptr));

  @override
  bool takeNeedsUpdate() =>
      _bool(WasmScriptingWeb.hostTakeNeedsUpdate.callAsFunction(null, _ptr));

  @override
  bool takeDisplayScaleChanged() => _bool(
        WasmScriptingWeb.hostTakeDisplayScaleChanged.callAsFunction(null, _ptr),
      );

  @override
  bool advance(double elapsedSeconds) => _bool(
        WasmScriptingWeb.hostAdvance.callAsFunction(
          null,
          _ptr,
          elapsedSeconds.toJS,
        ),
      );

  @override
  void update() => WasmScriptingWeb.hostUpdate.callAsFunction(null, _ptr);

  @override
  void trigger(String name) => _withUtf8(
        name,
        (native) =>
            WasmScriptingWeb.hostTrigger.callAsFunction(null, _ptr, native),
      );

  @override
  void setNumberInput(String name, double value) => _withUtf8(
        name,
        (native) => WasmScriptingWeb.hostSetNumberInput.callAsFunction(
          null,
          _ptr,
          native,
          value.toJS,
        ),
      );

  @override
  void setIntegerInput(String name, int value) => _withUtf8(
        name,
        (native) => WasmScriptingWeb.hostSetIntegerInput.callAsFunction(
          null,
          _ptr,
          native,
          value.toJS,
        ),
      );

  @override
  void setBooleanInput(String name, bool value) => _withUtf8(
        name,
        (native) => WasmScriptingWeb.hostSetBooleanInput.callAsFunction(
          null,
          _ptr,
          native,
          (value ? 1 : 0).toJS,
        ),
      );

  @override
  void setStringInput(String name, String value) => _withUtf8(
        name,
        (native) => _withUtf8(
          value,
          (text) => WasmScriptingWeb.hostSetStringInput.callAsFunction(
            null,
            _ptr,
            native,
            text,
          ),
        ),
      );

  @override
  void setViewModelInput(String name, InternalViewModelInstanceValue value) =>
      _withUtf8(
        name,
        (native) => WasmScriptingWeb.hostSetViewModelInput.callAsFunction(
          null,
          _ptr,
          native,
          value.instancePointerAddress.toJS,
        ),
      );

  @override
  void setArtboardInput(String name, Artboard artboard) => _withUtf8(
        name,
        (native) => WasmScriptingWeb.hostSetArtboardInput.callAsFunction(
          null,
          _ptr,
          native,
          (artboard as WebRiveArtboard).pointer.toJS,
        ),
      );

  @override
  void draw(Renderer renderer) => WasmScriptingWeb.hostDraw.callAsFunction(
        null,
        _ptr,
        (renderer as WebRiveRenderer).jsRendererPtr,
      );

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
      (native) => _int(
        WasmScriptingWeb.hostPointerEvent.callAsFunctionEx(
          null,
          _ptr,
          native,
          pointerId.toJS,
          localPosition.x.toJS,
          localPosition.y.toJS,
          hitType.toJS,
          timeStamp.toJS,
        ),
      ),
    );
    return result == 0 ? null : HitResult.values[result - 1];
  }

  @override
  bool keyboardEvent(int key, int modifiers, bool isPressed, bool isRepeat) =>
      _bool(
        WasmScriptingWeb.hostKeyboardEvent.callAsFunctionEx(
          null,
          _ptr,
          key.toJS,
          modifiers.toJS,
          (isPressed ? 1 : 0).toJS,
          (isRepeat ? 1 : 0).toJS,
        ),
      );

  @override
  bool textEvent(String text) => _withUtf8(
        text,
        (native) => _bool(
          WasmScriptingWeb.hostTextEvent.callAsFunction(null, _ptr, native),
        ),
      );

  @override
  bool gamepadEvent(String method, GamepadWire gamepad) => _withUtf8(
        method,
        (native) => _withFloats(
          gamepad.buttonValues,
          (buttons) => _withFloats(
            gamepad.axes,
            (axes) => _bool(
              WasmScriptingWeb.hostGamepadEvent.callAsFunctionEx(
                null,
                _ptr,
                native,
                gamepad.kind.toJS,
                gamepad.deviceId.toJS,
                (gamepad.buttonMask & 0xFFFFFFFF).toJS,
                ((gamepad.buttonMask >> 32) & 0xFFFFFFFF).toJS,
                buttons,
                gamepad.buttonValues.length.toJS,
                axes,
                gamepad.axes.length.toJS,
                gamepad.mapping.toJS,
                gamepad.changeKind.toJS,
                gamepad.changeIndex.toJS,
                gamepad.changeValue.toJS,
              ),
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
      WasmScriptingWeb.hostListenerPointer.callAsFunctionEx(
        null,
        _ptr,
        pointerId.toJS,
        position.x.toJS,
        position.y.toJS,
        previousPosition.x.toJS,
        previousPosition.y.toJS,
        hitType.toJS,
        timeStamp.toJS,
      );

  @override
  void listenerKeyboard(
    int key,
    int modifiers,
    bool isPressed,
    bool isRepeat,
  ) =>
      WasmScriptingWeb.hostListenerKeyboard.callAsFunctionEx(
        null,
        _ptr,
        key.toJS,
        modifiers.toJS,
        (isPressed ? 1 : 0).toJS,
        (isRepeat ? 1 : 0).toJS,
      );

  @override
  void listenerTextInput(String text) => _withUtf8(
        text,
        (native) => WasmScriptingWeb.hostListenerTextInput.callAsFunction(
          null,
          _ptr,
          native,
        ),
      );

  @override
  void listenerFocus(bool isFocus) => WasmScriptingWeb.hostListenerFocus
      .callAsFunction(null, _ptr, (isFocus ? 1 : 0).toJS);

  @override
  void listenerReportedEvent(double delaySeconds) =>
      WasmScriptingWeb.hostListenerReportedEvent
          .callAsFunction(null, _ptr, delaySeconds.toJS);

  @override
  void listenerViewModelChange() =>
      WasmScriptingWeb.hostListenerViewModelChange.callAsFunction(null, _ptr);

  @override
  void listenerNone() =>
      WasmScriptingWeb.hostListenerNone.callAsFunction(null, _ptr);

  @override
  void listenerGamepad(GamepadWire gamepad) => _withFloats(
        gamepad.buttonValues,
        (buttons) => _withFloats(
          gamepad.axes,
          (axes) => WasmScriptingWeb.hostListenerGamepad.callAsFunctionEx(
            null,
            _ptr,
            gamepad.kind.toJS,
            gamepad.deviceId.toJS,
            (gamepad.buttonMask & 0xFFFFFFFF).toJS,
            ((gamepad.buttonMask >> 32) & 0xFFFFFFFF).toJS,
            buttons,
            gamepad.buttonValues.length.toJS,
            axes,
            gamepad.axes.length.toJS,
            gamepad.mapping.toJS,
            gamepad.changeKind.toJS,
            gamepad.changeIndex.toJS,
            gamepad.changeValue.toJS,
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
        (nativeText) => _int(
          WasmScriptingWeb.hostDataConvert.callAsFunctionEx(
            null,
            _ptr,
            native,
            kind.index.toJS,
            number.toJS,
            nativeText,
            (boolean ? 1 : 0).toJS,
            color.toJS,
          ),
        ),
      ),
    );
    return switch (ScriptDataKind.values[resultKind]) {
      ScriptDataKind.number => ScriptDataResult(
          kind: ScriptDataKind.number,
          number: _double(
            WasmScriptingWeb.hostConvertNumber.callAsFunction(null, _ptr),
          ),
        ),
      ScriptDataKind.string => ScriptDataResult(
          kind: ScriptDataKind.string,
          string: RiveWasm.toDartString(
            _int(WasmScriptingWeb.hostConvertString.callAsFunction(null, _ptr)),
          ),
        ),
      ScriptDataKind.boolean => ScriptDataResult(
          kind: ScriptDataKind.boolean,
          boolean: _bool(
            WasmScriptingWeb.hostConvertBoolean.callAsFunction(null, _ptr),
          ),
        ),
      ScriptDataKind.color => ScriptDataResult(
          kind: ScriptDataKind.color,
          color: _int(
            WasmScriptingWeb.hostConvertColor.callAsFunction(null, _ptr),
          ),
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
    final result = WasmScriptingWeb.hostPathEffect.callAsFunctionEx(
      null,
      _ptr,
      (factory as WebFactory).pointer,
      (source as WebRenderPath).pointer,
      (paint.isStroke ? 1 : 0).toJS,
      paint.cap.toJS,
      paint.join.toJS,
      paint.blendMode.toJS,
      paint.color.toJS,
      paint.thickness.toJS,
      paint.feather.toJS,
    );
    if (_int(result) == 0) {
      return null;
    }
    return WebRenderPath.fromPointer(factory, result);
  }

  @override
  double? numberMethod(String name, List<double> args) {
    final out = WasmBuffer(4);
    try {
      final ok = _withUtf8(
        name,
        (native) => _withFloats(
          args,
          (values) => _bool(
            WasmScriptingWeb.hostNumberMethod.callAsFunctionEx(
              null,
              _ptr,
              native,
              values,
              args.length.toJS,
              out.pointer,
            ),
          ),
        ),
      );
      if (!ok) {
        return null;
      }
      final data = out.data;
      return Float32List.view(data.buffer, data.offsetInBytes, 1)[0];
    } finally {
      out.dispose();
    }
  }

  @override
  bool booleanMethod(String name) => _withUtf8(
        name,
        (native) => _bool(
          WasmScriptingWeb.hostBooleanMethod.callAsFunction(null, _ptr, native),
        ),
      );

  @override
  void layoutResize(double width, double height) =>
      WasmScriptingWeb.hostLayoutResize
          .callAsFunction(null, _ptr, width.toJS, height.toJS);

  @override
  Vec2D? layoutMeasure() {
    final out = WasmBuffer(8);
    try {
      if (!_bool(
        WasmScriptingWeb.hostLayoutMeasure.callAsFunction(
          null,
          _ptr,
          out.pointer,
        ),
      )) {
        return null;
      }
      final data = out.data;
      final floats = Float32List.view(data.buffer, data.offsetInBytes, 2);
      return Vec2D.fromValues(floats[0], floats[1]);
    } finally {
      out.dispose();
    }
  }
}
