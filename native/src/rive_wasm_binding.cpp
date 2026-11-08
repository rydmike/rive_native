// Editor bindings for the wasm scripting backend: the flavor twin of
// rive_luau_binding.cpp. Dart drives stage scripted objects through a native
// host that speaks the runtime's ScriptBackend seam, so the editor stage and
// the runtime file run the same module the same way.
#ifdef WITH_RIVE_SCRIPTING_WASM
#include "rive_native/external.hpp"
#include "rive_native/rive_binding.hpp"
#include "gamepad_invocation.hpp"
#include "scripted_path_queries.hpp"
#include "rive/animation/listener_invocation.hpp"
#include "rive/assets/script_asset.hpp"
#include "rive/async/work_pool.hpp"
#include "rive/core/binary_writer.hpp"
#include "rive/core/vector_binary_stream.hpp"
#include "rive/data_bind/data_context.hpp"
#include "rive/data_bind/data_values/data_value_boolean.hpp"
#include "rive/data_bind/data_values/data_value_color.hpp"
#include "rive/data_bind/data_values/data_value_number.hpp"
#include "rive/data_bind/data_values/data_value_string.hpp"
#include "rive/factory.hpp"
#include "rive/file.hpp"
#include "rive/math/raw_path.hpp"
#include "rive/renderer.hpp"
#include "rive/scripted/scripted_object.hpp"
#include "rive/wasm/module_tier_ladder.hpp"
#include "rive/wasm/path_effect_wire.hpp"
#include "rive/wasm/wasm_scripting_vm.hpp"
#ifdef __EMSCRIPTEN__
#include "rive/wasm/browser_scripting_vm.hpp"
#endif

#include <memory>
#include <string>
#include <unordered_map>

#ifdef __EMSCRIPTEN__
#include <emscripten.h>
#include <emscripten/bind.h>
#include <emscripten/val.h>
using WasmConsoleCallback = emscripten::val;
using emscripten::val;
#else
typedef void (*WasmConsoleCallback)();
#endif

using namespace rive;

const rive::RawPath& renderPathToRawPath(
    rive::Factory* factory,
    rive::RenderPath* renderPath);
const rive::FillRule renderPathFillRule(
    rive::Factory* factory,
    rive::RenderPath* renderPath);

namespace
{
// Module prints and host call failures, in the console wire the Luau lane
// writes so the editor reads both through one decoder.
struct WasmConsole
{
  VectorBinaryStream buffer;
  std::string pending;
  std::string reportedTrap;
  WasmConsoleCallback hasData;
  bool notified = false;
  bool detached = false;

  void writeEntry(uint8_t type, const std::string& text)
  {
    if (detached)
    {
      return;
    }
    BinaryWriter writer(&buffer);
    writer.write(type);
    writer.write(std::string());
    writer.writeVarUint((uint32_t)0);
    writer.writeVarUint((uint64_t)text.size());
    writer.write((const uint8_t*)text.data(), text.size());
    writer.writeVarUint((uint32_t)0);
    if (!notified && CALLBACK_VALID(hasData))
    {
      notified = true;
      hasData();
    }
  }

  void print(const char* text, size_t length)
  {
    pending.append(text, length);
    size_t newline;
    while ((newline = pending.find('\n')) != std::string::npos)
    {
      writeEntry(0, pending.substr(0, newline));
      pending.erase(0, newline + 1);
    }
  }

  void error(const std::string& message) { writeEntry(1, message); }

  void clear()
  {
    buffer.clear();
    notified = false;
  }

  // Dart closes its callback when it lets go, but an adopted VM can still
  // print until its file dies.
  void detach()
  {
    detached = true;
    RESET_CALLBACK(hasData);
    clear();
  }
};

// The VM's print sink shares ownership, so the console outlives the entry.
std::unordered_map<WasmScriptingVM*, std::shared_ptr<WasmConsole>> s_consoles;
std::string s_bootError;

WasmConsole* consoleFor(WasmScriptingVM* vm)
{
  auto itr = s_consoles.find(vm);
  return itr == s_consoles.end() ? nullptr : itr->second.get();
}

// A stage scripted object: the editor's Dart core object owns it and
// forwards every protocol call here, where the runtime's ScriptedObject
// machinery runs it on the file's wasm VM.
class EditorScriptedHost : public ScriptedObject
{
public:
  EditorScriptedHost(File* file, ScriptProtocol protocol)
      : m_file(file)
      , m_protocol(protocol)
  {}

  bool addScriptedDirt(ComponentDirt, bool) override
  {
    m_needsUpdate = true;
    return true;
  }
  uint32_t assetId() override { return 0; }
  ScriptProtocol scriptProtocol() override { return m_protocol; }
  Component* component() override { return nullptr; }
  void displayScaleChanged() override { m_displayScaleChanged = true; }

  bool instantiate(const std::string& moduleName)
  {
    scriptDispose();
    auto asset = m_file->scriptAsset(moduleName);
    if (asset == nullptr)
    {
      return false;
    }
    setAsset(ref_rcp(asset));
    // The editor's detection is fresher than the bits the asset serialized.
    int methods = implementedMethods();
    bool ok = asset->initScriptedObject(this);
    implementedMethods(methods);
    return ok;
  }

  bool userInit()
  {
    if (backend() == nullptr || self() == 0)
    {
      return false;
    }
    return hydrateScriptInputs();
  }

  bool active() const
  {
    return m_vm != nullptr && m_vm->valid() && m_self != 0;
  }

  void runUpdate()
  {
    setInUpdatePhase(true);
    scriptUpdate();
    setInUpdatePhase(false);
  }

  WasmScriptingVM* vm() const { return static_cast<WasmScriptingVM*>(m_vm); }

  bool takeNeedsUpdate()
  {
    bool value = m_needsUpdate;
    m_needsUpdate = false;
    return value;
  }
  bool takeDisplayScaleChanged()
  {
    bool value = m_displayScaleChanged;
    m_displayScaleChanged = false;
    return value;
  }

  // A trap stays in the VM after its call, so each message is sent once.
  void reportTrap()
  {
    auto fileVM = m_file->wasmScriptingVM();
    auto console = consoleFor(fileVM);
    if (console == nullptr)
    {
      return;
    }
    const std::string& message = fileVM->lastTrap().message;
    if (message.empty() || message == console->reportedTrap)
    {
      return;
    }
    console->reportedTrap = message;
    console->error(message);
  }

  ScriptBackend::ScriptDataResult convertResult;

private:
  File* m_file;
  ScriptProtocol m_protocol;
  bool m_needsUpdate = false;
  bool m_displayScaleChanged = false;
};

// Reports a trap the export it is declared in leaves behind.
struct TrapReport
{
  EditorScriptedHost* host;
  ~TrapReport() { host->reportTrap(); }
};

WasmScriptingVM* bootVM(
    const uint8_t* bytes,
    size_t length,
    Factory* factory,
    WasmConsoleCallback hasData)
{
  auto console = std::make_shared<WasmConsole>();
  console->hasData = hasData;
  s_bootError.clear();
  auto print = [console](const char* text, size_t size) {
    console->print(text, size);
  };
#ifdef __EMSCRIPTEN__
  // The module runs on the browser's wasm engine. This boot is
  // synchronous, so it instantiates inline rather than through the page's
  // asynchronous prepare step.
  auto vm = BrowserScriptingVM::make(
      Span<const uint8_t>(bytes, length),
      factory);
  if (vm == nullptr)
  {
    s_bootError = "the page has not installed the rive script runner";
    return nullptr;
  }
  vm->onPrint(print);
  if (vm->start() != BrowserScriptingVM::Start::started)
  {
    s_bootError = vm->lastError();
    return nullptr;
  }
#else
  auto vm = WasmScriptingVM::make(
      Span<const uint8_t>(bytes, length),
      factory,
      s_bootError,
      print);
  if (vm == nullptr)
  {
    return nullptr;
  }
#endif
  s_consoles[vm.get()] = std::move(console);
  return vm.release();
}
} // namespace

#ifndef __EMSCRIPTEN__
EXPORT WasmScriptingVM* riveWasmVMBoot(
    const uint8_t* bytes,
    SizeType length,
    Factory* factory,
    WasmConsoleCallback hasData)
{
  return bootVM(bytes, (size_t)length, factory, hasData);
}
#endif

EXPORT const char* riveWasmVMBootError() { return s_bootError.c_str(); }

#ifndef __EMSCRIPTEN__
// An empty wamrc path falls back to RIVE_WAMRC.
EXPORT void riveWasmConfigureAot(const char* wamrcPath, const char* cacheDir)
{
  ModuleTierLadder::instance().configure(
      wamrcPath == nullptr ? "" : wamrcPath,
      cacheDir == nullptr ? "" : cacheDir);
}
#endif

EXPORT uint8_t riveWasmVMExecutionTier(WasmScriptingVM* vm)
{
  return vm == nullptr ? 0 : (uint8_t)vm->executionTier();
}

// The file destroys an adopted VM with itself; Dart drops the console
// then, before the pointer goes stale.
EXPORT void riveWasmVMReleaseConsole(WasmScriptingVM* vm)
{
  auto itr = s_consoles.find(vm);
  if (itr != s_consoles.end())
  {
    itr->second->detach();
    s_consoles.erase(itr);
  }
}

// For VMs that never get adopted by a file; adopted ones die with the file.
EXPORT void riveWasmVMDelete(WasmScriptingVM* vm)
{
  riveWasmVMReleaseConsole(vm);
  delete vm;
}

EXPORT const uint8_t* riveWasmVMConsoleData(WasmScriptingVM* vm)
{
  auto console = consoleFor(vm);
  return console == nullptr ? nullptr : console->buffer.memory().data();
}

EXPORT SizeType riveWasmVMConsoleSize(WasmScriptingVM* vm)
{
  auto console = consoleFor(vm);
  return console == nullptr ? 0 : CAST_SIZE console->buffer.memory().size();
}

EXPORT void riveWasmVMConsoleClear(WasmScriptingVM* vm)
{
  auto console = consoleFor(vm);
  if (console != nullptr)
  {
    console->clear();
  }
}

EXPORT const char* riveWasmVMLastError(WasmScriptingVM* vm)
{
  return vm == nullptr ? "" : vm->lastError().c_str();
}

EXPORT void riveWasmVMDisplayScale(WasmScriptingVM* vm, float scale)
{
  if (vm != nullptr)
  {
    vm->displayScale(scale);
  }
}

#ifdef WITH_RIVE_TOOLS
// A shader the workspace compiled for this bake; the booted file carries
// none of its own.
EXPORT void riveWasmVMRegisterShaderRstb(
    WasmScriptingVM* vm,
    const char* name,
    const uint8_t* bytes,
    SizeType length)
{
  if (vm != nullptr)
  {
    vm->registerShaderRstb(name, std::vector<uint8_t>(bytes, bytes + length));
  }
}

EXPORT bool riveWasmVMHasShaderRstb(WasmScriptingVM* vm, const char* name)
{
  return vm != nullptr && vm->findShaderRstb(name) != nullptr;
}
#endif

EXPORT void riveWasmVMSetExecutionTimeout(WasmScriptingVM* vm, int timeoutMs)
{
  if (vm != nullptr)
  {
    vm->setTimeoutMs(timeoutMs);
  }
}

// A module's top level runs as it boots, before a host can set its VM's own.
EXPORT void riveWasmSetDefaultExecutionTimeout(int timeoutMs)
{
  WasmScriptingVM::defaultTimeoutMs(timeoutMs);
}

EXPORT void riveWasmRequireBounds(uint8_t on)
{
  WasmScriptingVM::requireBounds(on != 0);
}

EXPORT void riveWasmVMSetPlaying(WasmScriptingVM* vm, uint8_t playing)
{
#ifdef WITH_RIVE_TOOLS
  if (vm != nullptr)
  {
    vm->isPlaying(playing != 0);
  }
#endif
}

// Image decodes and other work tasks complete through the shared pool; the
// stage polls it once per frame, as artboard advance does for runtime files.
EXPORT void riveWasmPollAsyncWork() { rive_pollAsyncWork(); }

EXPORT void riveFileAdoptWasmScriptingVM(File* file, WasmScriptingVM* vm)
{
  if (file == nullptr || vm == nullptr)
  {
    return;
  }
  file->adoptWasmScriptingVM(std::unique_ptr<WasmScriptingVM>(vm));
}

EXPORT WasmScriptingVM* riveFileWasmScriptingVM(File* file)
{
  return file == nullptr ? nullptr : file->wasmScriptingVM();
}

EXPORT bool riveFileRegisterWasmScript(
    File* file,
    const char* moduleName,
    const char* registryName)
{
  if (file == nullptr || moduleName == nullptr || registryName == nullptr)
  {
    return false;
  }
  return file->registerWasmScript(moduleName, registryName);
}

EXPORT EditorScriptedHost* riveScriptedHostCreate(File* file, uint8_t protocol)
{
  if (file == nullptr)
  {
    return nullptr;
  }
  return new EditorScriptedHost(file, (ScriptProtocol)protocol);
}

EXPORT void riveScriptedHostDelete(EditorScriptedHost* host) { delete host; }

EXPORT void riveScriptedHostSetDataContext(
    EditorScriptedHost* host,
    DataContext* dataContext)
{
  if (host != nullptr)
  {
    host->dataContext(ref_rcp(dataContext));
  }
}

EXPORT void riveScriptedHostSetImplementedMethods(
    EditorScriptedHost* host,
    int bits)
{
  if (host != nullptr)
  {
    host->implementedMethods(bits);
  }
}

EXPORT bool riveScriptedHostInstantiate(
    EditorScriptedHost* host,
    const char* moduleName)
{
  if (host == nullptr || moduleName == nullptr)
  {
    return false;
  }
  TrapReport report{host};
  return host->instantiate(moduleName);
}

EXPORT bool riveScriptedHostUserInit(EditorScriptedHost* host)
{
  if (host == nullptr)
  {
    return false;
  }
  TrapReport report{host};
  return host->userInit();
}

EXPORT bool riveScriptedHostActive(EditorScriptedHost* host)
{
  return host != nullptr && host->active();
}

EXPORT bool riveScriptedHostTakeNeedsUpdate(EditorScriptedHost* host)
{
  return host != nullptr && host->takeNeedsUpdate();
}

EXPORT bool riveScriptedHostTakeDisplayScaleChanged(EditorScriptedHost* host)
{
  return host != nullptr && host->takeDisplayScaleChanged();
}

EXPORT bool riveScriptedHostAdvance(
    EditorScriptedHost* host,
    float elapsedSeconds)
{
  if (host == nullptr || !host->active())
  {
    return false;
  }
  TrapReport report{host};
  return host->scriptAdvance(elapsedSeconds);
}

EXPORT void riveScriptedHostUpdate(EditorScriptedHost* host)
{
  if (host != nullptr && host->active())
  {
    TrapReport report{host};
    host->runUpdate();
  }
}

EXPORT void riveScriptedHostTrigger(EditorScriptedHost* host, const char* name)
{
  if (host != nullptr && host->active() && name != nullptr)
  {
    TrapReport report{host};
    host->trigger(name);
  }
}

EXPORT void riveScriptedHostSetNumberInput(
    EditorScriptedHost* host,
    const char* name,
    float value)
{
  if (host != nullptr && host->active() && name != nullptr)
  {
    TrapReport report{host};
    host->setNumberInput(name, value);
  }
}

EXPORT void riveScriptedHostSetIntegerInput(
    EditorScriptedHost* host,
    const char* name,
    int value)
{
  if (host != nullptr && host->active() && name != nullptr)
  {
    TrapReport report{host};
    host->setIntegerInput(name, value);
  }
}

EXPORT void riveScriptedHostSetBooleanInput(
    EditorScriptedHost* host,
    const char* name,
    uint8_t value)
{
  if (host != nullptr && host->active() && name != nullptr)
  {
    TrapReport report{host};
    host->setBooleanInput(name, value != 0);
  }
}

EXPORT void riveScriptedHostSetStringInput(
    EditorScriptedHost* host,
    const char* name,
    const char* value)
{
  if (host != nullptr && host->active() && name != nullptr)
  {
    TrapReport report{host};
    host->setStringInput(name, value == nullptr ? "" : value);
  }
}

EXPORT void riveScriptedHostSetViewModelInput(
    EditorScriptedHost* host,
    const char* name,
    ViewModelInstanceValue* value)
{
  if (host != nullptr && host->active() && name != nullptr)
  {
    TrapReport report{host};
    host->setViewModelInput(name, value);
  }
}

EXPORT void riveScriptedHostSetArtboardInput(
    EditorScriptedHost* host,
    const char* name,
    WrappedArtboard* artboard)
{
  if (host != nullptr && host->active() && name != nullptr &&
      artboard != nullptr)
  {
    TrapReport report{host};
    host->setArtboardInput(name, artboard->artboard());
  }
}

EXPORT void riveScriptedHostDraw(EditorScriptedHost* host, Renderer* renderer)
{
  if (host == nullptr || !host->active() || renderer == nullptr)
  {
    return;
  }
  TrapReport report{host};
  host->backend()->callDraw(host, host->self(), renderer);
}

// 0 when the method is not implemented, else the hit result plus one.
EXPORT uint8_t riveScriptedHostPointerEvent(
    EditorScriptedHost* host,
    const char* method,
    int pointerId,
    float x,
    float y,
    int hitType,
    float timeStamp)
{
  if (host == nullptr || !host->active() || method == nullptr)
  {
    return 0;
  }
  TrapReport report{host};
  HitResult result = HitResult::none;
  if (!host->backend()->callPointerEvent(
          host,
          host->self(),
          method,
          pointerId,
          Vec2D(x, y),
          (ListenerType)hitType,
          timeStamp,
          &result))
  {
    return 0;
  }
  return (uint8_t)result + 1;
}

EXPORT bool riveScriptedHostKeyboardEvent(
    EditorScriptedHost* host,
    uint32_t key,
    uint8_t modifiers,
    uint8_t isPressed,
    uint8_t isRepeat)
{
  if (host == nullptr || !host->active())
  {
    return false;
  }
  TrapReport report{host};
  return host->backend()->callKeyboardEvent(
      host,
      host->self(),
      static_cast<Key>(key),
      static_cast<KeyModifiers>(modifiers),
      isPressed != 0,
      isRepeat != 0);
}

EXPORT bool riveScriptedHostTextEvent(
    EditorScriptedHost* host,
    const char* text)
{
  if (host == nullptr || !host->active())
  {
    return false;
  }
  TrapReport report{host};
  return host->backend()->callTextEvent(
      host,
      host->self(),
      text == nullptr ? "" : text);
}

// The button mask crosses as two words so the web export takes plain numbers.
EXPORT bool riveScriptedHostGamepadEvent(
    EditorScriptedHost* host,
    const char* method,
    uint8_t kind,
    int32_t deviceId,
    uint32_t buttonMaskLo,
    uint32_t buttonMaskHi,
    const float* buttonValues,
    uint32_t buttonCount,
    const float* axes,
    uint32_t axisCount,
    uint8_t mapping,
    uint8_t changeKind,
    uint8_t changeIndex,
    float changeValue)
{
  if (host == nullptr || !host->active() || method == nullptr)
  {
    return false;
  }
  uint64_t buttonMask = ((uint64_t)buttonMaskHi << 32) | buttonMaskLo;
  auto invocation = gamepadListenerInvocation(
      kind,
      deviceId,
      buttonMask,
      buttonValues,
      buttonCount,
      axes,
      axisCount,
      mapping,
      changeKind,
      changeIndex,
      changeValue);
  TrapReport report{host};
  return host->backend()
      ->callGamepadEvent(host, host->self(), method, invocation);
}

static void listenerPerform(
    EditorScriptedHost* host,
    const ListenerInvocation& invocation)
{
  if (host == nullptr || !host->active())
  {
    return;
  }
  TrapReport report{host};
  host->backend()->callListenerPerform(host, host->self(), invocation);
}

EXPORT void riveScriptedHostListenerPointer(
    EditorScriptedHost* host,
    uint8_t pointerId,
    float x,
    float y,
    float prevX,
    float prevY,
    int hitType,
    float timeStamp)
{
  listenerPerform(
      host,
      ListenerInvocation::pointer(
          Vec2D(x, y),
          Vec2D(prevX, prevY),
          pointerId,
          (ListenerType)hitType,
          timeStamp));
}

EXPORT void riveScriptedHostListenerKeyboard(
    EditorScriptedHost* host,
    uint32_t key,
    uint8_t modifiers,
    uint8_t isPressed,
    uint8_t isRepeat)
{
  listenerPerform(
      host,
      ListenerInvocation::keyboard(
          static_cast<Key>(key),
          static_cast<KeyModifiers>(modifiers),
          isPressed != 0,
          isRepeat != 0));
}

EXPORT void riveScriptedHostListenerTextInput(
    EditorScriptedHost* host,
    const char* text)
{
  listenerPerform(
      host,
      ListenerInvocation::textInput(text == nullptr ? "" : text));
}

EXPORT void riveScriptedHostListenerFocus(
    EditorScriptedHost* host,
    uint8_t isFocus)
{
  listenerPerform(host, ListenerInvocation::focus(nullptr, isFocus != 0));
}

EXPORT void riveScriptedHostListenerReportedEvent(
    EditorScriptedHost* host,
    float delaySeconds)
{
  listenerPerform(
      host,
      ListenerInvocation::reportedEvent(nullptr, delaySeconds));
}

EXPORT void riveScriptedHostListenerViewModelChange(EditorScriptedHost* host)
{
  listenerPerform(host, ListenerInvocation::viewModelChange(nullptr));
}

EXPORT void riveScriptedHostListenerNone(EditorScriptedHost* host)
{
  listenerPerform(host, ListenerInvocation::none());
}

EXPORT void riveScriptedHostListenerGamepad(
    EditorScriptedHost* host,
    uint8_t kind,
    int32_t deviceId,
    uint32_t buttonMaskLo,
    uint32_t buttonMaskHi,
    const float* buttonValues,
    uint32_t buttonCount,
    const float* axes,
    uint32_t axisCount,
    uint8_t mapping,
    uint8_t changeKind,
    uint8_t changeIndex,
    float changeValue)
{
  uint64_t buttonMask = ((uint64_t)buttonMaskHi << 32) | buttonMaskLo;
  listenerPerform(
      host,
      gamepadListenerInvocation(
          kind,
          deviceId,
          buttonMask,
          buttonValues,
          buttonCount,
          axes,
          axisCount,
          mapping,
          changeKind,
          changeIndex,
          changeValue));
}

// kind: 1 number, 2 string, 3 boolean, 4 color. Returns the result kind (0
// none) and parks the value for the getters below.
EXPORT uint8_t riveScriptedHostDataConvert(
    EditorScriptedHost* host,
    const char* method,
    uint8_t kind,
    float number,
    const char* text,
    uint8_t boolean,
    int color)
{
  if (host == nullptr || !host->active() || method == nullptr)
  {
    return 0;
  }
  auto convert = [&](DataValue&& input) {
    TrapReport report{host};
    host->convertResult = ScriptBackend::ScriptDataResult();
    host->backend()->callDataConvert(
        host,
        host->self(),
        method,
        &input,
        &host->convertResult);
    return (uint8_t)host->convertResult.kind;
  };
  switch (kind)
  {
    case 1:
      return convert(DataValueNumber(number));
    case 2:
      return convert(DataValueString(text == nullptr ? "" : text));
    case 3:
      return convert(DataValueBoolean(boolean != 0));
    case 4:
      return convert(DataValueColor(color));
    default:
      return 0;
  }
}

EXPORT float riveScriptedHostConvertNumber(EditorScriptedHost* host)
{
  return host == nullptr ? 0 : host->convertResult.number;
}

EXPORT const char* riveScriptedHostConvertString(EditorScriptedHost* host)
{
  return host == nullptr ? "" : host->convertResult.string.c_str();
}

EXPORT bool riveScriptedHostConvertBoolean(EditorScriptedHost* host)
{
  return host != nullptr && host->convertResult.boolean;
}

EXPORT int riveScriptedHostConvertColor(EditorScriptedHost* host)
{
  return host == nullptr ? 0 : host->convertResult.color;
}

// The paint snapshot is what the Luau lane's DartPaint table exposes; the
// returned path is ref'd for Dart, null when the script did not run.
EXPORT RenderPath* riveScriptedHostPathEffect(
    EditorScriptedHost* host,
    Factory* factory,
    RenderPath* source,
    uint32_t isStroke,
    uint32_t cap,
    uint32_t join,
    uint32_t blendMode,
    uint32_t color,
    float thickness,
    float feather)
{
  if (host == nullptr || !host->active() || factory == nullptr ||
      source == nullptr)
  {
    return nullptr;
  }
  PathEffectPaintWire paint;
  paint.style = (uint32_t)(isStroke != 0 ? RenderPaintStyle::stroke
                                         : RenderPaintStyle::fill);
  paint.cap = cap;
  paint.join = join;
  paint.blendMode = blendMode;
  paint.color = color;
  paint.thickness = thickness;
  paint.feather = feather;
  const RawPath& sourcePath = renderPathToRawPath(factory, source);
  RawPath outPath;
  TrapReport report{host};
  if (!host->vm()->callPathEffectUpdate(
          host,
          host->self(),
          sourcePath,
          paint,
          nullptr,
          &outPath))
  {
    return nullptr;
  }
  auto renderPath = factory->makeRenderPath(
      outPath,
      renderPathFillRule(factory, source));
  retainScriptedPathQueries(renderPath.get(), outPath);
  return renderPath.release();
}

EXPORT bool riveScriptedHostNumberMethod(
    EditorScriptedHost* host,
    const char* name,
    const float* args,
    uint32_t argCount,
    float* outResult)
{
  if (host == nullptr || !host->active() || name == nullptr ||
      outResult == nullptr)
  {
    return false;
  }
  TrapReport report{host};
  return host->backend()
      ->callNumberMethod(host, host->self(), name, args, argCount, outResult);
}

EXPORT bool riveScriptedHostBooleanMethod(
    EditorScriptedHost* host,
    const char* name)
{
  if (host == nullptr || !host->active() || name == nullptr)
  {
    return false;
  }
  TrapReport report{host};
  return host->backend()->callBooleanMethod(host, host->self(), name);
}

EXPORT void riveScriptedHostLayoutResize(
    EditorScriptedHost* host,
    float width,
    float height)
{
  if (host == nullptr || !host->active())
  {
    return;
  }
  TrapReport report{host};
  host->backend()->callLayoutResize(host, host->self(), Vec2D(width, height));
}

EXPORT bool riveScriptedHostLayoutMeasure(
    EditorScriptedHost* host,
    float* outSize)
{
  if (host == nullptr || !host->active() || outSize == nullptr)
  {
    return false;
  }
  Vec2D size;
  TrapReport report{host};
  if (!host->backend()->callLayoutMeasure(host, host->self(), &size))
  {
    return false;
  }
  outSize[0] = size.x;
  outSize[1] = size.y;
  return true;
}

#ifdef __EMSCRIPTEN__
EMSCRIPTEN_BINDINGS(RiveWasmBinding)
{
  // Takes a JS callback, so it lives here rather than as a raw export.
  emscripten::function(
      "riveWasmVMBoot",
      emscripten::optional_override(
          [](WasmPtr bytes,
             SizeType length,
             WasmPtr factory,
             emscripten::val hasData) -> WasmPtr {
            return (WasmPtr)bootVM(
                (const uint8_t*)bytes,
                (size_t)length,
                (Factory*)factory,
                hasData);
          }));
}
#endif

#endif // WITH_RIVE_SCRIPTING_WASM
