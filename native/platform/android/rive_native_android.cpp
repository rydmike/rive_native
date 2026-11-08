#include "rive_native/external.hpp"
#include "rive_native/rive_binding.hpp"
#include "rive/renderer/rive_renderer.hpp"

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <GLES2/gl2ext.h>

#include "rive/renderer/gl/render_context_gl_impl.hpp"
#include "rive/renderer/gl/render_target_gl.hpp"
#include "rive/renderer/gl/gl_utils.hpp"
#if defined(RIVE_CANVAS) && defined(RIVE_ORE)
#include "rive/renderer/cmd/deferred_session.hpp"
#include "rive_native/deferred_consumer.hpp"
#include "rive_native/deferred_host.hpp"
#endif

#include <android/hardware_buffer.h>
#include <android/log.h>
#include <android/native_window_jni.h>
#include <dlfcn.h>
#include <errno.h>
#include <poll.h>
#include <pthread.h>
#include <unistd.h>
#include <sys/system_properties.h>
#include <unordered_map>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <deque>
#include <functional>
#include <iterator>
#include <memory>
#include <future>
#include <mutex>
#include <string.h>
#include <thread>
#include <vector>

#include <jni.h>

#define LOG_TAG "RiveNative"
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, LOG_TAG, __VA_ARGS__)
#define LOGD(...) __android_log_print(ANDROID_LOG_DEBUG, LOG_TAG, __VA_ARGS__)
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)

std::mutex flutterMutex;

// Present threads shared by every render texture. Two is enough to keep a
// screenful of small textures at the display rate on the devices measured;
// each costs an EGL context and a 1x1 pbuffer.
constexpr int kPresentThreads = 2;

// EGL fence syncs, resolved once. EGL_KHR_fence_sync is universal on the
// Android versions this runtime supports; a missing entry point degrades to
// presenting without the wait.
static PFNEGLCREATESYNCKHRPROC egl_createSync()
{
  static auto fn = reinterpret_cast<PFNEGLCREATESYNCKHRPROC>(
      eglGetProcAddress("eglCreateSyncKHR"));
  return fn;
}
static PFNEGLCLIENTWAITSYNCKHRPROC egl_clientWaitSync()
{
  static auto fn = reinterpret_cast<PFNEGLCLIENTWAITSYNCKHRPROC>(
      eglGetProcAddress("eglClientWaitSyncKHR"));
  return fn;
}
static PFNEGLDESTROYSYNCKHRPROC egl_destroySync()
{
  static auto fn = reinterpret_cast<PFNEGLDESTROYSYNCKHRPROC>(
      eglGetProcAddress("eglDestroySyncKHR"));
  return fn;
}

// Testing switches, read once when the GL context is created and documented
// in DIAGNOSTICS.md: `adb shell setprop debug.rive.<name> 0|1`, then restart
// the app. Unset means the shipping behavior.
// A testing switch's raw state: 1, 0, or -1 when unset.
static int debugSwitchState(const char* name)
{
  char key[PROP_NAME_MAX];
  snprintf(key, sizeof(key), "debug.rive.%s", name);
  char value[PROP_VALUE_MAX] = {};
  if (__system_property_get(key, value) <= 0 || value[0] == '\0')
  {
    return -1;
  }
  return value[0] == '1' ? 1 : 0;
}

static bool debugSwitch(const char* name, bool unsetValue)
{
  char key[PROP_NAME_MAX];
  snprintf(key, sizeof(key), "debug.rive.%s", name);
  char value[PROP_VALUE_MAX] = {};
  if (__system_property_get(key, value) <= 0)
  {
    return unsetValue;
  }
  return value[0] == '1';
}

// Hardware buffer present. Entry points are resolved at runtime: minSdk is
// 21 and AHardwareBuffer's JNI bridge is API 26, so a link-time reference
// would keep the library from loading on older devices.
static JavaVM* g_javaVM = nullptr;
static jmethodID g_acquireBufferMethod = nullptr;
static jmethodID g_frameReadyMethod = nullptr;
static jmethodID g_frameSignaledMethod = nullptr;
static jmethodID g_hardwareBufferCloseMethod = nullptr;

// Set by the job threads below; the VM attaches a thread under this name.
static thread_local const char* t_threadName = nullptr;

// The calling thread's JNIEnv. Only the render and push threads (which
// live for the process, so are never detached) may attach; any other
// thread gets its env only if the VM already knows it, and nullptr
// otherwise. The producer thread in particular must not attach: with
// Flutter's UI thread unmerged it is an engine thread that exits at engine
// destruction, and ART aborts a thread that exits attached.
static JNIEnv* jniEnv()
{
  thread_local JNIEnv* env = nullptr;
  if (env == nullptr && g_javaVM != nullptr)
  {
    if (g_javaVM->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6) !=
        JNI_OK)
    {
      env = nullptr;
      if (t_threadName == nullptr)
      {
        return nullptr;
      }
      // Attach under the thread's own name: the VM renames an
      // unnamed attachment "Thread-N", which hides it in traces.
      JavaVMAttachArgs args = {JNI_VERSION_1_6, t_threadName, nullptr};
      g_javaVM->AttachCurrentThreadAsDaemon(&env, &args);
    }
  }
  return env;
}

struct HardwareBufferProcs
{
  AHardwareBuffer* (*fromHardwareBuffer)(JNIEnv*, jobject) = nullptr;
  void (*acquire)(AHardwareBuffer*) = nullptr;
  void (*release)(AHardwareBuffer*) = nullptr;
  void (*describe)(const AHardwareBuffer*, AHardwareBuffer_Desc*) = nullptr;
  // For the import probe only: a buffer of the kind the writer will
  // dequeue, imported once to prove the driver takes it.
  int (*allocate)(const AHardwareBuffer_Desc*, AHardwareBuffer**) = nullptr;
  PFNEGLGETNATIVECLIENTBUFFERANDROIDPROC getNativeClientBuffer = nullptr;
  PFNEGLCREATEIMAGEKHRPROC createImage = nullptr;
  PFNEGLDESTROYIMAGEKHRPROC destroyImage = nullptr;
  PFNGLEGLIMAGETARGETTEXTURE2DOESPROC imageTargetTexture2D = nullptr;
  // Optional: a native fence fd can be waited with poll(), which sleeps
  // in the kernel, where eglClientWaitSyncKHR spins on some drivers.
  PFNEGLDUPNATIVEFENCEFDANDROIDPROC dupNativeFenceFD = nullptr;

  bool valid() const
  {
    return fromHardwareBuffer && acquire && release && getNativeClientBuffer &&
           createImage && destroyImage && imageTargetTexture2D;
  }
};

static const HardwareBufferProcs& hardwareBufferProcs()
{
  static const HardwareBufferProcs procs = [] {
    HardwareBufferProcs p;
    p.fromHardwareBuffer = reinterpret_cast<decltype(p.fromHardwareBuffer)>(
        dlsym(RTLD_DEFAULT, "AHardwareBuffer_fromHardwareBuffer"));
    p.acquire = reinterpret_cast<decltype(p.acquire)>(
        dlsym(RTLD_DEFAULT, "AHardwareBuffer_acquire"));
    p.release = reinterpret_cast<decltype(p.release)>(
        dlsym(RTLD_DEFAULT, "AHardwareBuffer_release"));
    p.describe = reinterpret_cast<decltype(p.describe)>(
        dlsym(RTLD_DEFAULT, "AHardwareBuffer_describe"));
    p.allocate = reinterpret_cast<decltype(p.allocate)>(
        dlsym(RTLD_DEFAULT, "AHardwareBuffer_allocate"));
    p.getNativeClientBuffer = reinterpret_cast<
        PFNEGLGETNATIVECLIENTBUFFERANDROIDPROC>(
        eglGetProcAddress("eglGetNativeClientBufferANDROID"));
    p.createImage = reinterpret_cast<PFNEGLCREATEIMAGEKHRPROC>(
        eglGetProcAddress("eglCreateImageKHR"));
    p.destroyImage = reinterpret_cast<PFNEGLDESTROYIMAGEKHRPROC>(
        eglGetProcAddress("eglDestroyImageKHR"));
    p.imageTargetTexture2D = reinterpret_cast<
        PFNGLEGLIMAGETARGETTEXTURE2DOESPROC>(
        eglGetProcAddress("glEGLImageTargetTexture2DOES"));
    p.dupNativeFenceFD = reinterpret_cast<PFNEGLDUPNATIVEFENCEFDANDROIDPROC>(
        eglGetProcAddress("eglDupNativeFenceFDANDROID"));
    return p;
  }();
  return procs;
}

#define EGL_ERR_CHECK() _check_egl_error(__FILE__, __LINE__)

void _check_egl_error(const char* file, int line)
{
  EGLenum err(eglGetError());

  while (true)
  {
    std::string error;

    switch (err)
    {
      case EGL_SUCCESS:
        return;
      case EGL_NOT_INITIALIZED:
        error = "EGL_NOT_INITIALIZED";
        break;
      case EGL_BAD_ACCESS:
        error = "EGL_BAD_ACCESS";
        break;
      case EGL_BAD_ALLOC:
        error = "EGL_BAD_ALLOC";
        break;
      case EGL_BAD_ATTRIBUTE:
        error = "EGL_BAD_ATTRIBUTE";
        break;
      case EGL_BAD_CONTEXT:
        error = "EGL_BAD_CONTEXT";
        break;
      case EGL_BAD_CONFIG:
        error = "EGL_BAD_CONFIG";
        break;
      case EGL_BAD_CURRENT_SURFACE:
        error = "EGL_BAD_CURRENT_SURFACE";
        break;
      case EGL_BAD_DISPLAY:
        error = "EGL_BAD_DISPLAY";
        break;
      case EGL_BAD_SURFACE:
        error = "EGL_BAD_SURFACE";
        break;
      case EGL_BAD_MATCH:
        error = "EGL_BAD_MATCH";
        break;
      case EGL_BAD_PARAMETER:
        error = "EGL_BAD_PARAMETER";
        break;
      case EGL_BAD_NATIVE_PIXMAP:
        error = "EGL_BAD_NATIVE_PIXMAP";
        break;
      case EGL_BAD_NATIVE_WINDOW:
        error = "EGL_BAD_NATIVE_WINDOW";
        break;
      case EGL_CONTEXT_LOST:
        error = "EGL_CONTEXT_LOST";
        break;
      default:
        LOGE("(%d) %s - %s:%d", err, "Unknown", file, line);
        return;
    }
    LOGE("(%d) %s - %s:%d", err, error.c_str(), file, line);
    err = eglGetError();
  }
}

static bool config_has_attribute(
    EGLDisplay display,
    EGLConfig config,
    EGLint attribute,
    EGLint value)
{
  EGLint outValue = 0;
  EGLBoolean result = eglGetConfigAttrib(display, config, attribute, &outValue);
  EGL_ERR_CHECK();
  return result && (outValue == value);
}

class EGLThreadState
{
public:
  EGLThreadState()
  {
    m_display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (m_display == EGL_NO_DISPLAY)
    {
      EGL_ERR_CHECK();
      LOGE("eglGetDisplay() failed.");
      return;
    }
    if (!eglInitialize(m_display, 0, 0))
    {
      EGL_ERR_CHECK();
      LOGE("eglInitialize() failed.");
      return;
    }

    // The renderer's baseline is GLES 3.0 and the present threads blit
    // with ES 3 entry points, so select an ES 3 config and ask for an
    // ES 3 context below. A driver whose config list predates that bit
    // falls back to ES 2, where offscreen present is unavailable.
    EGLint configAttributes[] = {
        EGL_RENDERABLE_TYPE,
        EGL_OPENGL_ES3_BIT,
        EGL_BLUE_SIZE,
        8,
        EGL_GREEN_SIZE,
        8,
        EGL_RED_SIZE,
        8,
        EGL_DEPTH_SIZE,
        0,
        EGL_STENCIL_SIZE,
        8,
        EGL_ALPHA_SIZE,
        8,
        EGL_NONE};

    // Choose a config, either a match if possible or the first config
    // otherwise
    const auto configMatches = [&](EGLConfig config) {
      if (!config_has_attribute(m_display, config, EGL_RED_SIZE, 8))
        return false;
      if (!config_has_attribute(m_display, config, EGL_GREEN_SIZE, 8))
        return false;
      if (!config_has_attribute(m_display, config, EGL_BLUE_SIZE, 8))
        return false;
      if (!config_has_attribute(m_display, config, EGL_STENCIL_SIZE, 8))
        return false;
      return config_has_attribute(m_display, config, EGL_DEPTH_SIZE, 0);
    };

    // Selection runs again if an ES 3 context turns out to be
    // unavailable: EGL only allows a context of a version the config's
    // EGL_RENDERABLE_TYPE carries, and an ES 3 config need not carry the
    // ES 2 bit.
    const auto selectConfig = [&](EGLint renderableType) {
      configAttributes[1] = renderableType;
      EGLint num_configs = 0;
      if (!eglChooseConfig(
              m_display,
              configAttributes,
              nullptr,
              0,
              &num_configs) ||
          num_configs == 0)
      {
        EGL_ERR_CHECK();
        return false;
      }
      std::vector<EGLConfig> supportedConfigs(static_cast<size_t>(num_configs));
      eglChooseConfig(
          m_display,
          configAttributes,
          supportedConfigs.data(),
          num_configs,
          &num_configs);
      EGL_ERR_CHECK();
      const auto configIter = std::find_if(
          supportedConfigs.cbegin(),
          supportedConfigs.cend(),
          configMatches);
      m_config = (configIter != supportedConfigs.cend()) ? *configIter
                                                         : supportedConfigs[0];
      return true;
    };

    m_isES3 = selectConfig(EGL_OPENGL_ES3_BIT);
    if (!m_isES3)
    {
      LOGW("No OpenGL ES 3 config, asking for ES 2");
      if (!selectConfig(EGL_OPENGL_ES2_BIT))
      {
        LOGE("eglChooseConfig() didn't find any");
        return;
      }
    }

    // The app's own rendering must win GPU scheduling over Rive's
    // offscreen content: request low context priority where the driver
    // supports it (EGL_IMG_context_priority; SurfaceFlinger uses the
    // same mechanism for high). At the default equal priority, heavy
    // Rive content queues ahead of the app's raster work and stalls the
    // whole app's frame pipeline on the GPU.
    const char* extensions = eglQueryString(m_display, EGL_EXTENSIONS);
    const bool hasContextPriority = extensions != nullptr &&
                                    strstr(
                                        extensions,
                                        "EGL_IMG_context_priority") != nullptr;
    // Without the extension the list terminates at the first EGL_NONE.
    EGLint contextAttributes[] = {
        EGL_CONTEXT_CLIENT_VERSION,
        m_isES3 ? 3 : 2,
        hasContextPriority ? EGL_CONTEXT_PRIORITY_LEVEL_IMG : EGL_NONE,
        EGL_CONTEXT_PRIORITY_LOW_IMG,
        EGL_NONE};

    m_context = eglCreateContext(
        m_display,
        m_config,
        nullptr,
        contextAttributes);
    if (m_context == EGL_NO_CONTEXT && m_isES3)
    {
      // The config advertised ES 3 and the driver still refused the
      // context; carry on as ES 2 rather than lose rendering. The ES 3
      // config need not accept an ES 2 context, so reselect first.
      LOGW("eglCreateContext(ES 3) failed, asking for ES 2");
      EGL_ERR_CHECK();
      m_isES3 = false;
      contextAttributes[1] = 2;
      if (selectConfig(EGL_OPENGL_ES2_BIT))
      {
        m_context = eglCreateContext(
            m_display,
            m_config,
            nullptr,
            contextAttributes);
      }
    }
    if (m_context == EGL_NO_CONTEXT)
    {
      LOGE("eglCreateContext() failed.");
      EGL_ERR_CHECK();
    }
    else if (hasContextPriority)
    {
      // Drivers may clamp the request; log what was granted.
      EGLint granted = EGL_CONTEXT_PRIORITY_MEDIUM_IMG;
      eglQueryContext(
          m_display,
          m_context,
          EGL_CONTEXT_PRIORITY_LEVEL_IMG,
          &granted);
      LOGI(
          "Rive GL context priority: %s",
          granted == EGL_CONTEXT_PRIORITY_LOW_IMG      ? "low"
          : granted == EGL_CONTEXT_PRIORITY_MEDIUM_IMG ? "medium"
                                                       : "other");
    }
    else
    {
      LOGI("Rive GL context priority: default (extension unavailable)");
    }

    // Offscreen present: a second context in the share group owns the
    // window surfaces and only blits and swaps, on its own thread. A
    // swap's consumer fence covers every command submitted on the
    // swapping context (observed on Mali and PowerVR), so swapping from
    // the render context would make each buffer wait on every texture's
    // in-flight work. Default priority: its blits gate the fence Flutter
    // waits on.
    const EGLint presentContextAttributes[] = {
        EGL_CONTEXT_CLIENT_VERSION,
        m_isES3 ? 3 : 2,
        EGL_NONE};
    for (EGLContext& context : m_presentContext)
    {
      context = eglCreateContext(
          m_display,
          m_config,
          m_context,
          presentContextAttributes);
      if (context == EGL_NO_CONTEXT)
      {
        LOGW("eglCreateContext(present) failed, presenting from the "
             "render context");
        EGL_ERR_CHECK();
        break;
      }
    }

    // PLS
    // Create a 1x1 Pbuffer surface that we can use to guarantee m_context
    // is
    // always current on this thread.
    const EGLint PbufferAttrs[] = {
        EGL_WIDTH,
        1,
        EGL_HEIGHT,
        1,
        EGL_NONE,
    };
    m_backgroundSurface = eglCreatePbufferSurface(
        m_display,
        m_config,
        PbufferAttrs);
    EGL_ERR_CHECK();
    if (m_backgroundSurface == EGL_NO_SURFACE)
    {
      LOGE("Failed to create a 1x1 background Pbuffer surface for PLS");
    }
    for (int i = 0; i < kPresentThreads; i++)
    {
      if (m_presentContext[i] == EGL_NO_CONTEXT)
      {
        break;
      }
      // Each present thread needs its own pbuffer: a surface can be
      // current on one thread only, and the render thread holds the one
      // above.
      m_presentSurface[i] = eglCreatePbufferSurface(
          m_display,
          m_config,
          PbufferAttrs);
      EGL_ERR_CHECK();
    }

    eglMakeCurrent(
        m_display,
        m_backgroundSurface,
        m_backgroundSurface,
        m_context);
    m_currentSurface = m_backgroundSurface;

    rive::gpu::RenderContextGLImpl::ContextOptions contextOptions;
    // Testing only: the renderer picks PLS vs MSAA per GPU.
    contextOptions.disablePixelLocalStorage = debugSwitch("gl_msaa", false);
    m_renderContext = rive::gpu::RenderContextGLImpl::MakeContext(
        contextOptions);

    // Offscreen present needs the present context, ES 3 (texture
    // storage, framebuffer blit) and fence syncs: the present context
    // reads what the render context wrote, and only a fence orders that.
    bool presentSurfacesReady = true;
    for (EGLSurface surface : m_presentSurface)
    {
      presentSurfacesReady = presentSurfacesReady && surface != EGL_NO_SURFACE;
    }
    // A multisampled window config cannot be the destination of a
    // glBlitFramebuffer from the present context, and the offscreen path
    // has no other way to reach the surface.
    EGLint configSamples = 0;
    eglGetConfigAttrib(m_display, m_config, EGL_SAMPLES, &configSamples);
    const auto* glImpl = m_renderContext != nullptr
                             ? m_renderContext->static_impl_cast<
                                   rive::gpu::RenderContextGLImpl>()
                             : nullptr;
    // GL provided by ANGLE (Samsung's Xclipse GPUs run GL over Vulkan)
    // has no context-wide swap fence to work around, so the offscreen
    // path's context switches and blits are pure cost there. Measured
    // slower than the direct present on every ANGLE device tried; see
    // ANDROID_DEVICE_TESTING.md.
    const bool isANGLE = glImpl != nullptr &&
                         glImpl->capabilities().isANGLESystemDriver;
    m_offscreenPresent = glImpl != nullptr && m_isES3 && presentSurfacesReady &&
                         configSamples == 0 && egl_createSync() != nullptr &&
                         egl_clientWaitSync() != nullptr &&
                         egl_destroySync() != nullptr &&
                         glImpl->capabilities().contextVersionMajor >= 3 &&
                         !isANGLE && debugSwitch("gl_fbo", true);
    LOGI(
        "Rive GL present: %s%s%s",
        m_offscreenPresent ? "offscreen" : "direct",
        isANGLE ? " (ANGLE)" : "",
        contextOptions.disablePixelLocalStorage ? " (msaa forced)" : "");

    // Hardware buffer present needs the same render-side pieces as the
    // offscreen path (an ES 3 texture render target and fence syncs) plus
    // the EGLImage extensions; the present context is not involved. The
    // extensions are checked by name: eglGetProcAddress returns an entry
    // point for every extension libEGL knows, advertised or not.
    const char* glExtensions = reinterpret_cast<const char*>(
        glGetString(GL_EXTENSIONS));
    const bool
        hasImageExtensions = extensions != nullptr && glExtensions != nullptr &&
                             strstr(
                                 extensions,
                                 "EGL_ANDROID_image_native_buffer") !=
                                 nullptr &&
                             strstr(
                                 extensions,
                                 "EGL_ANDROID_get_native_client_buffer") !=
                                 nullptr &&
                             strstr(glExtensions, "GL_OES_EGL_image") !=
                                 nullptr;
    // Frames prefer a native fence, whose fd the push thread waits with
    // poll(); without the extension they use a plain sync.
    m_nativeFenceSync = extensions != nullptr &&
                        strstr(extensions, "EGL_ANDROID_native_fence_sync") !=
                            nullptr &&
                        hardwareBufferProcs().dupNativeFenceFD != nullptr;
    m_hardwareBufferPresent = m_renderContext != nullptr && m_isES3 &&
                              hasImageExtensions &&
                              egl_createSync() != nullptr &&
                              egl_clientWaitSync() != nullptr &&
                              egl_destroySync() != nullptr &&
                              hardwareBufferProcs().valid() &&
                              m_renderContext
                                      ->static_impl_cast<
                                          rive::gpu::RenderContextGLImpl>()
                                      ->capabilities()
                                      .contextVersionMajor >= 3 &&
                              probeHardwareBufferImport();
    LOGI(
        "Rive hardware buffer present: %s",
        m_hardwareBufferPresent ? "available" : "unavailable");
  }

  ~EGLThreadState()
  {
    LOGD("EGLThreadState getting destroyed! 🧨");
    clearTexturePool();

    if (m_context != EGL_NO_CONTEXT)
    {
      eglDestroyContext(m_display, m_context);
      EGL_ERR_CHECK();
    }
    for (EGLContext context : m_presentContext)
    {
      if (context != EGL_NO_CONTEXT)
      {
        eglDestroyContext(m_display, context);
        EGL_ERR_CHECK();
      }
    }

    eglReleaseThread();
    EGL_ERR_CHECK();

    if (m_display != EGL_NO_DISPLAY)
    {
      eglTerminate(m_display);
      EGL_ERR_CHECK();
    }
  }

  EGLSurface createEGLSurface(ANativeWindow* window)
  {
    if (!window)
    {
      return EGL_NO_SURFACE;
    }

    auto res = eglCreateWindowSurface(m_display, m_config, window, nullptr);
    EGL_ERR_CHECK();
    return res;
  }

  void destroySurface(EGLSurface eglSurface)
  {
    if (eglSurface == EGL_NO_SURFACE)
    {
      return;
    }

    assert(eglSurface != m_backgroundSurface);
    if (m_currentSurface == eglSurface)
    {
      // Make sure m_context always stays current.
      makeCurrent(m_backgroundSurface);
    }

    eglDestroySurface(m_display, eglSurface);
    EGL_ERR_CHECK();
  }

  bool makeCurrent(EGLSurface eglSurface)
  {
    if (eglSurface == m_currentSurface)
    {
      // return;
    }

    if (eglSurface == EGL_NO_SURFACE)
    {
      LOGE("Cannot make EGL_NO_SURFACE current");
      return false;
    }

    if (!eglMakeCurrent(m_display, eglSurface, eglSurface, m_context))
    {
      // m_currentSurface deliberately keeps its old value; callers
      // must not swap, or they would present whichever surface was
      // last current - possibly another texture's.
      LOGE("eglMakeCurrent failed");
      EGL_ERR_CHECK();
      return false;
    }

    m_currentSurface = eglSurface;
    return true;
  }

  void swapBuffers()
  {
    eglSwapBuffers(m_display, m_currentSurface);
    EGL_ERR_CHECK();
  }

  // Whether textures render offscreen and present through the present
  // thread; fixed for the context's lifetime.
  bool offscreenPresent() const { return m_offscreenPresent; }

  // Whether a texture can render into hardware buffers handed to Flutter.
  bool hardwareBufferPresent() const { return m_hardwareBufferPresent; }

  // Render thread, context current. Imports one buffer of the kind the
  // writer will dequeue and attaches it to a framebuffer: a driver that
  // advertises the extensions but refuses this format or usage is found
  // here, before any texture commits to image mode, rather than by every
  // frame of a texture that can then only drop.
  bool probeHardwareBufferImport()
  {
    const HardwareBufferProcs& procs = hardwareBufferProcs();
    if (procs.allocate == nullptr)
    {
      return false;
    }
    AHardwareBuffer_Desc desc = {};
    desc.width = 4;
    desc.height = 4;
    desc.layers = 1;
    desc.format = AHARDWAREBUFFER_FORMAT_R8G8B8A8_UNORM;
    desc.usage = AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE |
                 AHARDWAREBUFFER_USAGE_GPU_COLOR_OUTPUT;
    AHardwareBuffer* buffer = nullptr;
    if (procs.allocate(&desc, &buffer) != 0 || buffer == nullptr)
    {
      LOGW("Rive hardware buffer probe: allocation failed");
      return false;
    }
    bool ok = false;
    EGLImageKHR image = procs.createImage(
        m_display,
        EGL_NO_CONTEXT,
        EGL_NATIVE_BUFFER_ANDROID,
        procs.getNativeClientBuffer(buffer),
        nullptr);
    if (image != EGL_NO_IMAGE_KHR)
    {
      GLuint texture = 0, fbo = 0;
      glGenTextures(1, &texture);
      glBindTexture(GL_TEXTURE_2D, texture);
      procs.imageTargetTexture2D(GL_TEXTURE_2D, image);
      glBindTexture(GL_TEXTURE_2D, 0);
      glGenFramebuffers(1, &fbo);
      glBindFramebuffer(GL_FRAMEBUFFER, fbo);
      glFramebufferTexture2D(
          GL_FRAMEBUFFER,
          GL_COLOR_ATTACHMENT0,
          GL_TEXTURE_2D,
          texture,
          0);
      ok = glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE;
      glBindFramebuffer(GL_FRAMEBUFFER, 0);
      glDeleteFramebuffers(1, &fbo);
      glDeleteTextures(1, &texture);
      procs.destroyImage(m_display, image);
      // Any GL error the probe raised must not reach the renderer.
      while (glGetError() != GL_NO_ERROR)
      {
      }
    }
    else
    {
      EGL_ERR_CHECK();
    }
    procs.release(buffer);
    if (!ok)
    {
      LOGW("Rive hardware buffer probe: import or attach failed, "
           "Surface present instead");
    }
    return ok;
  }
  bool nativeFenceSync() const { return m_nativeFenceSync; }

  // The render context on its pbuffer, where offscreen rendering happens.
  bool makeCurrentRender() { return makeCurrent(m_backgroundSurface); }

  // Present thread only. Binds the present context to a window surface,
  // or with EGL_NO_SURFACE to its own pbuffer, which lets go of every
  // window surface.
  bool makeCurrentPresent(int thread, EGLSurface eglSurface)
  {
    if (eglSurface == EGL_NO_SURFACE)
    {
      eglSurface = m_presentSurface[thread];
    }
    if (eglSurface == m_presentCurrentSurface[thread])
    {
      return true;
    }
    if (!eglMakeCurrent(
            m_display,
            eglSurface,
            eglSurface,
            m_presentContext[thread]))
    {
      LOGE("eglMakeCurrent(present) failed");
      EGL_ERR_CHECK();
      m_presentCurrentSurface[thread] = EGL_NO_SURFACE;
      return false;
    }
    m_presentCurrentSurface[thread] = eglSurface;
    return true;
  }

  // Render thread. Offscreen slot textures outlive the texture they were
  // made for: a widget that resizes drops its render texture every frame
  // (an animating scale does this), and reallocating its slots each time
  // costs more than keeping a few around. Bounded, so an app that churns
  // sizes does not accumulate them.
  GLuint takePooledTexture(uint32_t width, uint32_t height)
  {
    for (auto it = m_texturePool.begin(); it != m_texturePool.end(); ++it)
    {
      if (it->width == width && it->height == height)
      {
        GLuint id = it->id;
        m_texturePool.erase(it);
        return id;
      }
    }
    return 0;
  }

  void recycleTexture(GLuint id, uint32_t width, uint32_t height)
  {
    if (id == 0)
    {
      return;
    }
    // Bounded by bytes rather than count: a pool of full-screen
    // textures must not sit on tens of megabytes.
    constexpr size_t kMaxPooledBytes = 12 << 20;
    m_texturePool.push_back({id, width, height});
    size_t pooledBytes = 0;
    for (const auto& pooled : m_texturePool)
    {
      pooledBytes += size_t{pooled.width} * pooled.height * 4;
    }
    // Evict down to the bound even if that empties the pool: one
    // full screen texture on a dense display can exceed it by itself.
    while (pooledBytes > kMaxPooledBytes && !m_texturePool.empty())
    {
      const auto& oldest = m_texturePool.front();
      pooledBytes -= size_t{oldest.width} * oldest.height * 4;
      glDeleteTextures(1, &oldest.id);
      m_texturePool.erase(m_texturePool.begin());
    }
  }

  void clearTexturePool()
  {
    for (const auto& pooled : m_texturePool)
    {
      glDeleteTextures(1, &pooled.id);
    }
    m_texturePool.clear();
  }

  // Present thread only.
  void swapPresent(EGLSurface eglSurface)
  {
    eglSwapBuffers(m_display, eglSurface);
    EGL_ERR_CHECK();
  }

  rive::gpu::RenderContext* renderContext() const
  {
    return m_renderContext.get();
  }

  EGLDisplay display() const { return m_display; }

protected:
  EGLSurface m_currentSurface = EGL_NO_SURFACE;
  EGLDisplay m_display = EGL_NO_DISPLAY;
  EGLContext m_context = EGL_NO_CONTEXT;
  EGLConfig m_config = static_cast<EGLConfig>(0);

  std::unique_ptr<rive::gpu::RenderContext> m_renderContext;

  // 1x1 Pbuffer surface that allows us to make the GL context current without
  // a window surface.
  EGLSurface m_backgroundSurface;

  EGLContext m_presentContext[kPresentThreads] = {};
  EGLSurface m_presentSurface[kPresentThreads] = {};
  // Written only by the thread that owns the index.
  EGLSurface m_presentCurrentSurface[kPresentThreads] = {};
  bool m_offscreenPresent = false;
  bool m_hardwareBufferPresent = false;
  bool m_nativeFenceSync = false;
  // Cleared when the ES 3 config or context is unavailable.
  bool m_isES3 = true;

  struct PooledTexture
  {
    GLuint id;
    uint32_t width;
    uint32_t height;
  };
  std::vector<PooledTexture> m_texturePool;
};

// Render thread that owns the EGL context and all GL work. GLES contexts are
// thread affine, so replay runs here and the FFI thread only records.
class GLThread
{
public:
  static GLThread& instance()
  {
    static GLThread inst("RiveRender");
    return inst;
  }

  // Offscreen present: fence waits, blits and swaps run here on a present
  // context, so they never occupy the render thread. Textures are spread
  // across these: a present costs a couple of milliseconds of CPU, most of
  // it binding the window surface, which caps one thread at a few hundred
  // presents a second.
  static GLThread& presentInstance(int thread)
  {
    static_assert(kPresentThreads == 2, "name each present thread");
    static GLThread instances[kPresentThreads] = {
        GLThread("RivePresent0"),
        GLThread("RivePresent1")};
    return instances[thread];
  }

  // Hardware buffer present: waits each frame's fence and hands the buffer
  // to Flutter. No GL context; a fence wait needs only the display.
  static GLThread& pushInstance()
  {
    static GLThread inst("RivePush");
    return inst;
  }

  // Run fn on the render thread and block for its result.
  template <typename Fn> auto invoke(Fn&& fn) -> decltype(fn())
  {
    std::packaged_task<decltype(fn())()> task(std::forward<Fn>(fn));
    auto fut = task.get_future();
    {
      std::lock_guard<std::mutex> lock(m_mutex);
      m_jobs.push_back([&task] { task(); });
      m_cv.notify_one();
    }
    return fut.get();
  }

  // Post fn to run on the render thread asynchronously, in order.
  void post(std::function<void()> fn)
  {
    std::lock_guard<std::mutex> lock(m_mutex);
    m_pending.fetch_add(1, std::memory_order_relaxed);
    m_jobs.push_back([this, fn = std::move(fn)] {
      fn();
      m_pending.fetch_sub(1, std::memory_order_release);
    });
    m_cv.notify_one();
  }

  // Posted jobs not yet finished, invoke jobs are not counted.
  int pending() const { return m_pending.load(std::memory_order_acquire); }

  // Block until every queued job has run.
  void drain()
  {
    invoke([] {});
  }

private:
  // Named so per-thread CPU shows up by role in a trace.
  explicit GLThread(const char* name)
      : m_thread([this, name] {
        pthread_setname_np(pthread_self(), name);
        t_threadName = name;
        loop();
      })
  {}
  ~GLThread() = default; // process lifetime, never joined

  void loop()
  {
    for (;;)
    {
      std::function<void()> job;
      {
        std::unique_lock<std::mutex> lock(m_mutex);
        m_cv.wait(lock, [this] { return !m_jobs.empty(); });
        job = std::move(m_jobs.front());
        m_jobs.pop_front();
      }
      job();
    }
  }

  std::thread m_thread;
  std::mutex m_mutex;
  std::condition_variable m_cv;
  std::deque<std::function<void()>> m_jobs;
  std::atomic<int> m_pending{0};
};

class AndroidRenderTexture
#if defined(RIVE_CANVAS) && defined(RIVE_ORE)
    : public rive_native::DeferredTextureHost
#endif
{
public:
  AndroidRenderTexture(
      ANativeWindow* surfaceWindow,
      uint32_t width,
      uint32_t height)
      : m_surfaceWindow(surfaceWindow)
      , m_width(width)
      , m_height(height)
  {
    ANativeWindow_acquire(surfaceWindow);
    s_liveTextures.fetch_add(1, std::memory_order_relaxed);
  }

  // Hardware buffer present: imageTexture is a global ref to the Kotlin
  // RiveImageTexture that owns the buffers and the Flutter entry.
  AndroidRenderTexture(jobject imageTexture, uint32_t width, uint32_t height)
      : m_surfaceWindow(nullptr)
      , m_width(width)
      , m_height(height)
      , m_imageTexture(imageTexture)
  {
    s_liveTextures.fetch_add(1, std::memory_order_relaxed);
  }

  ~AndroidRenderTexture()
  {
    const bool wasLast = s_liveTextures.fetch_sub(
                             1,
                             std::memory_order_relaxed) == 1;
    // GL resources must be released on the render thread that owns them.
    GLThread::instance().invoke([this, wasLast] {
      releaseOffscreenResources();
      m_plsRenderer.reset();
      m_renderTarget = nullptr;
      if (threadState && m_eglSurface != EGL_NO_SURFACE)
      {
        threadState->destroySurface(m_eglSurface);
        m_eglSurface = EGL_NO_SURFACE;
      }
      // With no Rive view left, give back what the context grew for
      // drawing and keep the context itself, as Rive Android does.
      // Queued behind every posted frame, so none is mid flush. A
      // texture made meanwhile keeps them.
      if (wasLast && threadState &&
          s_liveTextures.load(std::memory_order_relaxed) == 0)
      {
        threadState->clearTexturePool();
        if (auto* renderContext = threadState->renderContext())
        {
          renderContext->releaseResources();
        }
      }
    });

    if (m_surfaceWindow)
    {
      ANativeWindow_release(m_surfaceWindow);
      m_surfaceWindow = nullptr;
    }
    if (m_imageTexture != nullptr)
    {
      if (JNIEnv* env = jniEnv())
      {
        env->DeleteGlobalRef(m_imageTexture);
      }
      m_imageTexture = nullptr;
    }
  }

  bool beginFrame(bool clear, uint32_t color)
  {
    if (m_scheduledDestruction)
    {
      LOGW("Rive AndroidRenderTexture beginFrame called on destroyed "
           "texture");
      return false;
    }
    if (!threadState)
    {
      LOGD("Rive AndroidRenderTexture creating EGLThreadState");
      threadState = std::make_unique<EGLThreadState>();
    }

    if (!m_renderTarget && imageMode())
    {
      // Hardware buffers are ordinary GL textures once bound through
      // an EGLImage, so this is the offscreen path minus the window
      // surface: the slots are hardware buffers, allocated on demand in
      // acquireRenderSlot(), and endFrame() pushes them to Flutter.
      if (!threadState->hardwareBufferPresent())
      {
        LOGE("Rive hardware buffer present unavailable on this "
             "device");
        return false;
      }
      if (!threadState->makeCurrentRender())
      {
        return false;
      }
      auto renderContext = threadState->renderContext();
      m_offscreen = true;
      auto textureTarget = rive::make_rcp<rive::gpu::TextureRenderTargetGL>(
          m_width,
          m_height);
      // Flutter samples the buffer with row 0 at the top. A window
      // surface flips GL's bottom-up rows on the way to the screen;
      // nothing does that for a buffer, so render top-down instead.
      textureTarget->setBottomUp(false);
      m_textureTarget = textureTarget.get();
      m_renderTarget = std::move(textureTarget);
      m_plsRenderer = std::make_unique<rive::RiveRenderer>(renderContext);
    }
    else if (!m_renderTarget)
    {
      m_eglSurface = threadState->createEGLSurface(m_surfaceWindow);
      if (m_eglSurface == EGL_NO_SURFACE)
      {
        LOGE("AndroidRenderTexture failed to create EGL surface");
        return false;
      }

      m_offscreen = threadState->offscreenPresent();
      if (!(m_offscreen ? threadState->makeCurrentRender()
                        : threadState->makeCurrent(m_eglSurface)))
      {
        // Drop the surface just created: the next frame comes back
        // here, and would otherwise leak one surface per attempt.
        threadState->destroySurface(m_eglSurface);
        m_eglSurface = EGL_NO_SURFACE;
        return false;
      }
      auto renderContext = threadState->renderContext();
      if (renderContext == nullptr)
      {
        LOGW("Rive AndroidRenderTexture Rive Renderer (PLS) not "
             "supported");
        return true; // PLS was not supported.
      }
      int width = ANativeWindow_getWidth(m_surfaceWindow);
      int height = ANativeWindow_getHeight(m_surfaceWindow);
      assert(width == m_width);
      assert(height == m_height);

      if (m_offscreen)
      {
        // The slots themselves are allocated on demand, in
        // acquireRenderSlot().
        auto textureTarget = rive::make_rcp<rive::gpu::TextureRenderTargetGL>(
            width,
            height);
        m_textureTarget = textureTarget.get();
        m_renderTarget = std::move(textureTarget);
      }
      else
      {
        GLint sampleCount;
        glBindFramebuffer(GL_FRAMEBUFFER, 0);
        glGetIntegerv(GL_SAMPLES, &sampleCount);
        m_renderTarget = rive::make_rcp<rive::gpu::FramebufferRenderTargetGL>(
            width,
            height,
            0,
            sampleCount);
      }
      m_plsRenderer = std::make_unique<rive::RiveRenderer>(renderContext);
    }

    // Nothing has been rendered into this texture yet, so there is
    // nothing to preserve: an offscreen texture straight from the pool
    // still holds the last frame of whichever texture released it, and a
    // freshly allocated one holds undefined content.
    bool clearFrame = clear;
    if (m_offscreen)
    {
      m_renderSlot = acquireRenderSlot();
      if (m_renderSlot == kNoSlot || m_offscreenTex[m_renderSlot] == 0)
      {
        // Image mode: no slot, or its buffer could not be acquired
        // or wrapped. The frame is dropped.
        m_renderSlot = 0;
        return false;
      }
      // After acquireRenderSlot(): in image mode it clears
      // m_hasOffscreenFrame when the last frame's buffer went back to
      // the writer with a dropped frame.
      clearFrame = clear || !m_hasOffscreenFrame;
      if (!clearFrame && m_lastRenderedSlot != m_renderSlot)
      {
        // Preserve means "draw over the last frame", which lives in
        // whichever slot rendered it.
        copyOffscreenSlot(m_lastRenderedSlot, m_renderSlot);
      }
      m_textureTarget->setTargetTexture(m_offscreenTex[m_renderSlot]);
    }

    threadState->renderContext()->beginFrame({
        .renderTargetWidth = m_width,
        .renderTargetHeight = m_height,
        .loadAction = clearFrame ? rive::gpu::LoadAction::clear
                                 : rive::gpu::LoadAction::preserveRenderTarget,
        .clearColor = color,
    });
    return true;
  }

  // Flush the frame's GPU work to the current surface without presenting.
  // A texture marked destroyed since beginFrame still flushes: the frame
  // is begun on the render context, and its teardown is queued behind
  // this job.
  bool submitFrame()
  {
    if (!threadState || !m_renderTarget ||
        (!imageMode() && m_eglSurface == EGL_NO_SURFACE))
    {
      LOGE("Rive AndroidRenderTexture submitFrame called with invalid "
           "state");
      return false;
    }

    auto renderContext = threadState->renderContext();
    if (!renderContext)
    {
      LOGE("Rive AndroidRenderTexture renderContext is null");
      return false;
    }

    // beginFrame's slot setup binds textures on whatever unit is active,
    // which can be one of the renderer's own; rebind them before drawing.
    renderContext->static_impl_cast<rive::gpu::RenderContextGLImpl>()
        ->invalidateGLState();

    if (!(m_offscreen ? threadState->makeCurrentRender()
                      : threadState->makeCurrent(m_eglSurface)))
    {
      return false;
    }

    renderContext->flush({.renderTarget = m_renderTarget.get()});
    // Don't unbind the renderer's GL resources here: script canvases
    // flush before the next screen frame and rely on these bindings.
    return true;
  }

  void scheduleDestruction() { m_scheduledDestruction = true; }

  // Hardware buffer present: Flutter no longer reads the slot's buffer. A
  // replaced slot lost its buffer to a dropped frame and gets a new one
  // the next time it is rendered into. Called on the platform thread.
  void imageSlotReleased(int slot, bool replaced)
  {
    if (slot < 0 || slot >= slotCount())
    {
      return;
    }
    if (replaced)
    {
      m_slotStale[slot].store(true, std::memory_order_release);
    }
    m_slotReleaseSeq[slot].store(
        m_releaseCounter.fetch_add(1, std::memory_order_relaxed) + 1,
        std::memory_order_release);
    releaseOffscreenSlot(slot);
  }

#if defined(RIVE_CANVAS) && defined(RIVE_ORE)
  // FFI thread: snapshot the recorded frame and hand it to the render thread.
  bool deferredFlush();
  void drainDeferred() override;

  // Render thread: the replayed frame is complete, get it to the screen.
  void endFrame();

  // Frames THIS texture may run ahead of its replays. The bound must be
  // per texture: textures tick in a stable order, so a shared budget hands
  // the whole render thread to whichever textures tick first and starves
  // the rest - under load some widgets would never draw at all instead of
  // everyone degrading together.
  static constexpr int kMaxInFlightReplays = static_cast<int>(
      rive_native::DeferredConsumer::kMaxQueued);
  bool canAcceptDeferredFrame() const
  {
    // Offscreen: every in-flight replay will claim one of the two slots,
    // and a slot with a queued present is taken, so accept only when a
    // slot is left for this frame too. Otherwise the replay would block
    // the shared render thread waiting for the present thread. Direct
    // presents never queue, so this reduces to the in-flight bound.
    const int inFlight = m_inFlightReplays.load(std::memory_order_acquire);
    int busySlots = 0;
    for (int i = 0; i < slotCount(); i++)
    {
      busySlots += m_offscreenPending[i].load(std::memory_order_acquire) > 0;
    }
    return inFlight < kMaxInFlightReplays && inFlight + busySlots < slotCount();
  }

  rive::gpu::RenderContext* renderContext() const
  {
    return threadState ? threadState->renderContext() : nullptr;
  }
#endif

private:
  ANativeWindow* m_surfaceWindow;
  uint32_t m_width;
  uint32_t m_height;

  EGLSurface m_eglSurface = nullptr;
  rive::rcp<rive::gpu::RenderTargetGL> m_renderTarget;
  std::unique_ptr<rive::RiveRenderer> m_plsRenderer;
  // Written from the JNI/platform thread (scheduleDestruction), read on
  // the render thread (beginFrame/present) - atomic so the cross-thread
  // flag check is not a data race.
  std::atomic<bool> m_scheduledDestruction{false};
  // Offscreen present. Two textures alternate: the render thread draws the
  // next frame into one while the present thread shows the other.
  // m_offscreenPending counts each slot's queued presents: incremented on
  // the render thread when a present is posted, decremented on the present
  // thread once it has run, read by the pacing gate on the FFI thread. A
  // count rather than a flag, so a bounded slot wait that times out cannot
  // mark a slot free while a second present for it is still queued.
  // m_presentReadFbo belongs to the present thread; everything else here
  // to the render thread.
  bool m_offscreen = false;
  // Offscreen textures per Flutter texture. Three, so a frame that takes
  // longer than a vsync to record and replay can still record while one
  // slot replays and one presents; with two, long frames (full-screen
  // content, a RivePanel) ran well below the display rate.
  static constexpr int kOffscreenSlots = 3;
  // Image mode: one slot is the frame Flutter holds, a frame whose fence
  // has not signaled by the next tick holds one more, and one is being
  // recorded into; the fourth lets a frame record while another replays.
  // More did not help on any device measured (5 and 6 were tried).
  static constexpr int kImageSlots = 4;
  static constexpr int kSlots = kImageSlots;
  static_assert(
      kImageSlots >= kOffscreenSlots,
      "the slot arrays are sized for image mode");
  int slotCount() const { return imageMode() ? kImageSlots : kOffscreenSlots; }
  GLuint m_offscreenTex[kSlots] = {};
  std::atomic<int> m_offscreenPending[kSlots] = {};
  std::mutex m_offscreenMutex;
  std::condition_variable m_offscreenCv;
  bool m_hasOffscreenFrame = false;
  int m_renderSlot = 0;
  int m_lastRenderedSlot = 0;
  // Which present thread shows this texture's frames. Fixed for its
  // lifetime, so its frames always reach the screen in order.
  const int m_presentThread = s_nextPresentThread.fetch_add(
                                  1,
                                  std::memory_order_relaxed) %
                              kPresentThreads;
  static std::atomic<int> s_nextPresentThread;
  GLuint m_presentReadFbo[kSlots] = {};
  GLuint m_copyFbo[2] = {0, 0};
  rive::gpu::TextureRenderTargetGL* m_textureTarget = nullptr;

  // Hardware buffer present. Non-null selects image mode: each slot's
  // texture is an EGLImage over a hardware buffer the Kotlin side dequeued
  // for it. A stale slot's buffer went back to the writer (Flutter dropped
  // the frame) and is freed and re-acquired on the render thread.
  jobject m_imageTexture = nullptr;
  AHardwareBuffer* m_slotBuffer[kSlots] = {};
  EGLImageKHR m_slotImage[kSlots] = {};
  std::atomic<bool> m_slotStale[kSlots] = {};
  // When each slot was last released; acquireRenderSlot() takes the
  // oldest. A slot is released when the push after it lands, i.e. while
  // Flutter's raster of its frame may still be sampling it; taking the
  // oldest release keeps that slot out of use for two more frames unless
  // it is the only free one, which under load it can be. That is the
  // same window Flutter's own ImageReader path has (it releases a buffer
  // to the producer without a release fence), accepted rather than paid
  // for with a fifth buffer per texture.
  std::atomic<uint64_t> m_slotReleaseSeq[kSlots] = {};
  std::atomic<uint64_t> m_releaseCounter{0};
  bool imageMode() const { return m_imageTexture != nullptr; }

  // Rendered frames not yet pushed, in order. A frame is pushed from the
  // producer's next tick if its fence has signaled by then (so the push
  // lands before that frame's raster acquires it, never racing it), or
  // else by the push thread once the fence signals. The sync is shared so
  // whichever side drops it last destroys it, never under another's wait.
  struct SyncHolder
  {
    EGLDisplay display;
    EGLSyncKHR sync;
    // Set by the push thread once the fence has signaled. The producer
    // thread reads this rather than asking EGL: it has no context, and
    // a zero-timeout eglClientWaitSyncKHR there never reported
    // completion on the devices tried.
    std::atomic<bool> signaled{false};
    std::chrono::steady_clock::time_point signaledAt;
    // The sync's native fence, or -1: waited with poll() when present.
    int fenceFd = -1;
    ~SyncHolder()
    {
      if (fenceFd >= 0)
      {
        close(fenceFd);
      }
      if (sync != EGL_NO_SYNC_KHR)
      {
        egl_destroySync()(display, sync);
      }
    }
  };
  struct ReadyFrame
  {
    int slot = -1;
    std::shared_ptr<SyncHolder> sync;
    // The texture's first frame: nothing is on screen to displace, so
    // it is pushed as soon as the fence signals instead of at a tick.
    // A widget that recreates its texture every frame (an animating
    // scale) never ticks a texture twice, and waiting would cap it
    // near 25 fps.
    bool first = false;
  };
  std::mutex m_readyMutex;
  std::deque<ReadyFrame> m_readyFrames;
  // The push thread is shared by every texture, so a texture being
  // destroyed cancels its own jobs and waits for just those rather than
  // draining the thread behind every other texture's fence wait.
  std::atomic<bool> m_pushCancelled{false};
  std::atomic<int> m_pushJobs{0};
  std::condition_variable m_pushJobsCv;
  // One push per tick: the gate check pushes, and the flush that follows
  // it in the same tick must not push a second frame, which Flutter would
  // take as a replacement for the first. Producer thread only.
  bool m_pushedSinceFlush = false;
  // Render thread: whether a frame of this texture has been queued for
  // pushing before (the first one is pushed without waiting for a tick).
  bool m_pushedOnce = false;

  // acquireRenderSlot() result when image mode has no slot to draw into.
  static constexpr int kNoSlot = -1;
  int acquireRenderSlot();
  int allocateOffscreenSlot(int slot);
  int allocateImageSlot(int slot);
  void freeImageSlot(int slot);
  void presentOffscreenSlot(int slot, EGLSyncKHR sync);
  void pushImageSlot();
  void frameSignaled();
  // frameReady's second argument: kTickPush for a frame pushed from the
  // producer's tick, kLatePush for one the push thread had to deliver
  // itself (traced separately by the Kotlin side).
  static constexpr int kTickPush = 0;
  static constexpr int kLatePush = 1;
  static constexpr int kFirstPush = 2;
  void frameReady(int slot, int how);

public:
  // Producer (FFI) thread: push the oldest frame whose GPU work has
  // finished, at most one per call.
  void pushReadyFrames();
  void markPushedSinceFlush() { m_pushedSinceFlush = true; }
  // Platform thread. Pushes the oldest frame if its fence signaled
  // kLatePushMs ago and no tick has taken it, i.e. the ticker stopped and
  // this is the last frame. Returns the milliseconds until the next
  // check is due, or 0 when nothing is waiting.
  static constexpr int kLatePushMs = 40;
  int latePush();

private:
  void releaseOffscreenSlot(int slot);
  void blitFullFrame();
  void copyOffscreenSlot(int from, int to);
  void releaseOffscreenResources();
#if defined(RIVE_CANVAS) && defined(RIVE_ORE)
  // Incremented on the FFI thread at post, decremented on the render
  // thread when the replay job finishes.
  std::atomic<int> m_inFlightReplays{0};
#endif

  // Textures alive in the process, so the last one out can release.
  static std::atomic<int> s_liveTextures;

public:
  static std::unique_ptr<EGLThreadState> threadState;

  rive::Renderer* renderer() { return m_plsRenderer.get(); }
};

std::unique_ptr<EGLThreadState> AndroidRenderTexture::threadState;
std::atomic<int> AndroidRenderTexture::s_nextPresentThread{0};
std::atomic<int> AndroidRenderTexture::s_liveTextures{0};

// Runs on the render thread that owns the context, GL is thread affine.
static void ensureThreadStateOnGLThread()
{
  if (!AndroidRenderTexture::threadState)
  {
    AndroidRenderTexture::threadState = std::make_unique<EGLThreadState>();
  }
}

// Route GL touching deferred setup onto the render thread. Pacing is per
// texture (riveTextureCanAcceptDeferredFrame).
static void ensureRenderThreadRunner()
{
#if defined(RIVE_CANVAS) && defined(RIVE_ORE)
  static std::once_flag once;
  std::call_once(once, [] {
    rive_native::setRenderThreadRunner([](const std::function<void()>& fn) {
      GLThread::instance().invoke([&] { fn(); });
    });
  });
#endif
}

EXPORT rive::Factory* riveFactory()
{
  std::unique_lock<std::mutex> lock(flutterMutex);
  ensureRenderThreadRunner();
  return GLThread::instance().invoke([]() -> rive::Factory* {
    ensureThreadStateOnGLThread();
    return AndroidRenderTexture::threadState
               ? AndroidRenderTexture::threadState->renderContext()
               : nullptr;
  });
}

EXPORT jlong Java_app_rive_rive_1native_RiveNativePluginKt_createRiveRenderer(
    JNIEnv* env,
    jclass clazz,
    jobject surface,
    jint width,
    jint height)
{
  ANativeWindow* surfaceWindow = ANativeWindow_fromSurface(env, surface);

  AndroidRenderTexture* renderTexture = new AndroidRenderTexture(
      surfaceWindow,
      (uint32_t)width,
      (uint32_t)height);
  return reinterpret_cast<jlong>(renderTexture);
}

EXPORT jlong
Java_app_rive_rive_1native_RiveNativePluginKt_createRiveImageRenderer(
    JNIEnv* env,
    jclass clazz,
    jobject imageTexture,
    jint width,
    jint height)
{
  if (g_javaVM == nullptr)
  {
    env->GetJavaVM(&g_javaVM);
  }
  if (g_acquireBufferMethod == nullptr)
  {
    jclass textureClass = env->GetObjectClass(imageTexture);
    g_acquireBufferMethod = env->GetMethodID(
        textureClass,
        "acquireBuffer",
        "(I)Landroid/hardware/HardwareBuffer;");
    g_frameReadyMethod = env->GetMethodID(textureClass, "frameReady", "(II)V");
    g_frameSignaledMethod = env->GetMethodID(
        textureClass,
        "frameSignaled",
        "()V");
    env->DeleteLocalRef(textureClass);
    // A lookup that failed has thrown; a further JNI call with that
    // pending is itself a JNI error, so check here and again below.
    if (!env->ExceptionCheck())
    {
      jclass bufferClass = env->FindClass("android/hardware/HardwareBuffer");
      g_hardwareBufferCloseMethod = env->GetMethodID(
          bufferClass,
          "close",
          "()V");
      env->DeleteLocalRef(bufferClass);
    }
    if (env->ExceptionCheck())
    {
      // A missing method is a plugin/library mismatch; fail this
      // texture rather than leave the exception for a later call.
      env->ExceptionDescribe();
      env->ExceptionClear();
      g_acquireBufferMethod = nullptr;
      return 0;
    }
  }
  AndroidRenderTexture* renderTexture = new AndroidRenderTexture(
      env->NewGlobalRef(imageTexture),
      (uint32_t)width,
      (uint32_t)height);
  return reinterpret_cast<jlong>(renderTexture);
}

EXPORT void Java_app_rive_rive_1native_RiveNativePluginKt_riveImageSlotReleased(
    JNIEnv* env,
    jclass clazz,
    jlong renderer,
    jint slot,
    jboolean replaced)
{
  if (renderer != 0)
  {
    reinterpret_cast<AndroidRenderTexture*>(renderer)->imageSlotReleased(
        slot,
        replaced == JNI_TRUE);
  }
}

// Whether textures should be created in image mode: the app opted in
// (RiveNative.init(androidHardwareBuffers: true)) unless the testing switch
// debug.rive.gl_ahb forces it on (1) or off (0), and the GL context can do
// it (checked on the render thread, creating the context on first use the
// way riveFactory() does). A false here makes the Kotlin side create a
// Surface texture instead, so a device that cannot import hardware buffers
// never gets a texture that can only fail.
EXPORT jboolean
Java_app_rive_rive_1native_RiveNativePluginKt_riveHardwareBufferPresentEnabled(
    JNIEnv* env,
    jclass clazz,
    jboolean appOptIn)
{
  const int forced = debugSwitchState("gl_ahb");
  const bool wanted = forced < 0 ? appOptIn == JNI_TRUE : forced == 1;
  if (!wanted)
  {
    return JNI_FALSE;
  }
  // Fixed for the context's lifetime, so the render-thread round trip
  // happens once: a widget that recreates its texture every frame would
  // otherwise queue behind the replays each time.
  static const bool available = [] {
    std::unique_lock<std::mutex> lock(flutterMutex);
    return GLThread::instance().invoke([] {
      ensureThreadStateOnGLThread();
      return AndroidRenderTexture::threadState != nullptr &&
             AndroidRenderTexture::threadState->hardwareBufferPresent();
    });
  }();
  return available ? JNI_TRUE : JNI_FALSE;
}

EXPORT jint Java_app_rive_rive_1native_RiveNativePluginKt_riveImageLatePush(
    JNIEnv* env,
    jclass clazz,
    jlong renderer)
{
  if (renderer == 0)
  {
    return 0;
  }
  return reinterpret_cast<AndroidRenderTexture*>(renderer)->latePush();
}

EXPORT void Java_app_rive_rive_1native_RiveNativePluginKt_destroyRiveRenderer(
    JNIEnv* env,
    jclass clazz,
    jlong renderer)
{
  std::unique_lock<std::mutex> lock(flutterMutex);
  if (renderer != 0)
  {
    AndroidRenderTexture*
        renderTexture = reinterpret_cast<AndroidRenderTexture*>(renderer);
#if defined(RIVE_CANVAS) && defined(RIVE_ORE)
    // Finish any in flight replay before the renderer dies.
    renderTexture->drainDeferred();
#endif
    delete renderTexture;
  }
  else
  {
    LOGW("JNI: Rive destroyRiveRenderer called with null pointer");
  }
}

EXPORT void
Java_app_rive_rive_1native_RiveNativePluginKt_markDestroyedRiveRenderer(
    JNIEnv* env,
    jclass clazz,
    jlong renderer)
{
  std::unique_lock<std::mutex> lock(flutterMutex);
  if (renderer != 0)
  {
    AndroidRenderTexture*
        renderTexture = reinterpret_cast<AndroidRenderTexture*>(renderer);
    renderTexture->scheduleDestruction();
  }
  else
  {
    LOGW("JNI: Rive markDestroyedRiveRenderer called with null pointer");
  }
}

EXPORT bool clear(
    AndroidRenderTexture* renderTexture,
    bool clear,
    uint32_t color)
{
  if (renderTexture == nullptr)
  {
    return false;
  }
  std::unique_lock<std::mutex> lock(flutterMutex);
#if defined(RIVE_CANVAS) && defined(RIVE_ORE)
  if (renderTexture->deferredSession() != nullptr)
  {
    // No GPU work in deferred mode, stash the clear for replay.
    renderTexture->deferredClear(clear, color);
    return true;
  }
  rive_native::warnNoDeferredSession();
#endif
  return false;
}

EXPORT bool flush(AndroidRenderTexture* renderTexture, float devicePixelRatio)
{
  if (renderTexture == nullptr)
  {
    return false;
  }

  std::unique_lock<std::mutex> lock(flutterMutex);
#if defined(RIVE_CANVAS) && defined(RIVE_ORE)
  if (renderTexture->deferredSession() != nullptr)
  {
    return renderTexture->deferredFlush();
  }
#endif
  return false;
}

// Deferred only: a texture with no session attached has nothing to draw with.
EXPORT rive::Renderer* makeRenderer(AndroidRenderTexture* renderTexture)
{
  if (renderTexture == nullptr)
  {
    return nullptr;
  }
  std::unique_lock<std::mutex> lock(flutterMutex);
#if defined(RIVE_CANVAS) && defined(RIVE_ORE)
  return renderTexture->deferredScreenRenderer();
#else
  return nullptr;
#endif
}

// Present thread: wait for the slot's GPU work, blit it to the window, wait
// for the blit and swap. The buffer reaches Flutter's ImageReader with a
// consumer fence that covers only the finished blit, so the platform thread
// never blocks on it at acquire.
void AndroidRenderTexture::presentOffscreenSlot(int slot, EGLSyncKHR sync)
{
  EGLDisplay display = threadState->display();
  if (sync != EGL_NO_SYNC_KHR)
  {
    // Bounded, so a wedged GPU degrades to a late present rather than a
    // hung present thread.
    constexpr EGLTimeKHR kMaxFenceWaitNs = 100000000; // 100ms
    EGLint waited = egl_clientWaitSync()(display, sync, 0, kMaxFenceWaitNs);
    egl_destroySync()(display, sync);
    if (waited != EGL_CONDITION_SATISFIED_KHR)
    {
      // Blitting anyway can tear, and is still better than freezing
      // the texture. EGL_FALSE means the wait never ran, which needs
      // a driver bug to reach; log once so it is diagnosable.
      static std::atomic<bool> logged{false};
      if (!logged.exchange(true, std::memory_order_relaxed))
      {
        LOGW(
            "Rive present fence wait returned 0x%x, presenting "
            "without it",
            waited);
      }
    }
  }
  if (m_scheduledDestruction || m_eglSurface == EGL_NO_SURFACE ||
      !threadState->makeCurrentPresent(m_presentThread, m_eglSurface))
  {
    releaseOffscreenSlot(slot);
    return;
  }
  if (m_presentReadFbo[slot] == 0)
  {
    glGenFramebuffers(1, &m_presentReadFbo[slot]);
    glBindFramebuffer(GL_READ_FRAMEBUFFER, m_presentReadFbo[slot]);
    glFramebufferTexture2D(
        GL_READ_FRAMEBUFFER,
        GL_COLOR_ATTACHMENT0,
        GL_TEXTURE_2D,
        m_offscreenTex[slot],
        0);
  }
  glBindFramebuffer(GL_READ_FRAMEBUFFER, m_presentReadFbo[slot]);
  // Re-bind the texture every present: in a share group, another context's
  // writes to it are only guaranteed visible after a re-bind.
  glBindTexture(GL_TEXTURE_2D, m_offscreenTex[slot]);
  glBindTexture(GL_TEXTURE_2D, 0);
  glBindFramebuffer(GL_DRAW_FRAMEBUFFER, 0);
  blitFullFrame();
  // The entry points are guaranteed: the offscreen path is gated on them.
  EGLSyncKHR blitSync = egl_createSync()(display, EGL_SYNC_FENCE_KHR, nullptr);
  if (blitSync != EGL_NO_SYNC_KHR)
  {
    constexpr EGLTimeKHR kMaxBlitWaitNs = 50000000; // 50ms
    egl_clientWaitSync()(
        display,
        blitSync,
        EGL_SYNC_FLUSH_COMMANDS_BIT_KHR,
        kMaxBlitWaitNs);
    egl_destroySync()(display, blitSync);
  }
  else
  {
    // No fence for this blit, so finish it here instead. Releasing the
    // slot with the blit still reading it would let the render thread
    // overwrite what the present context is sampling.
    glFinish();
  }
  threadState->swapPresent(m_eglSurface);
  releaseOffscreenSlot(slot);
}

// Present thread: the slot has been shown (or skipped); the render thread
// may draw into it again.
void AndroidRenderTexture::releaseOffscreenSlot(int slot)
{
  {
    std::lock_guard<std::mutex> lock(m_offscreenMutex);
    m_offscreenPending[slot].fetch_sub(1, std::memory_order_release);
  }
  m_offscreenCv.notify_all();
}

// Render thread: pick the slot to render the next frame into.
//
// Window mode allocates slots on demand and reuses them as soon as their
// frame has been presented, so a texture only grows a second or third slot
// while its frames take longer to replay and present than the display
// interval. Image mode allocates a fresh slot before reusing a released one
// (the just-released slot may still be on screen), so every image-mode
// texture holds all four buffers after its first four frames.
int AndroidRenderTexture::acquireRenderSlot()
{
  if (imageMode())
  {
    // A slot Flutter dropped a frame from lost its buffer to the writer
    // and gets a fresh one; of the rest, take the one released longest
    // ago, since the one just displaced may still be on screen until
    // the next raster acquires its successor.
    if (m_slotStale[m_lastRenderedSlot].load(std::memory_order_acquire))
    {
      // The last frame went back to the writer with its buffer, and
      // may come back as any slot's next buffer: a preserve has
      // nothing to draw over, whichever slot is chosen below.
      m_hasOffscreenFrame = false;
    }
    int best = -1;
    uint64_t bestSeq = 0;
    for (int i = 0; i < slotCount(); i++)
    {
      if (m_offscreenPending[i].load(std::memory_order_acquire) != 0)
      {
        continue;
      }
      if (m_slotStale[i].load(std::memory_order_acquire))
      {
        freeImageSlot(i);
      }
      if (m_offscreenTex[i] == 0)
      {
        return allocateImageSlot(i);
      }
      uint64_t seq = m_slotReleaseSeq[i].load(std::memory_order_acquire);
      if (best < 0 || seq < bestSeq)
      {
        best = i;
        bestSeq = seq;
      }
    }
    if (best >= 0)
    {
      return best;
    }
    // Every slot is waiting on Flutter. The pacing gate normally
    // prevents this; wait for one, bounded, and take it, or drop the
    // frame rather than draw into a slot Flutter still holds.
    {
      std::unique_lock<std::mutex> lock(m_offscreenMutex);
      m_offscreenCv.wait_for(lock, std::chrono::milliseconds(200), [&] {
        for (int i = 0; i < slotCount(); i++)
        {
          if (m_offscreenPending[i].load(std::memory_order_acquire) == 0)
          {
            return true;
          }
        }
        return false;
      });
    }
    for (int i = 0; i < slotCount(); i++)
    {
      if (m_offscreenPending[i].load(std::memory_order_acquire) != 0)
      {
        continue;
      }
      if (m_slotStale[i].load(std::memory_order_acquire))
      {
        freeImageSlot(i);
      }
      return m_offscreenTex[i] == 0 ? allocateImageSlot(i) : i;
    }
    return kNoSlot;
  }
  for (int i = 0; i < slotCount(); i++)
  {
    if (m_offscreenTex[i] != 0 &&
        m_offscreenPending[i].load(std::memory_order_acquire) == 0)
    {
      return i;
    }
  }
  for (int i = 0; i < slotCount(); i++)
  {
    if (m_offscreenTex[i] == 0)
    {
      return imageMode() ? allocateImageSlot(i) : allocateOffscreenSlot(i);
    }
  }
  // Every slot is waiting on the present thread. The pacing gate normally
  // prevents this; wait for the oldest, bounded so a stalled present cannot
  // hang the render thread, then take it either way (its pending count
  // keeps the bookkeeping right).
  {
    std::unique_lock<std::mutex> lock(m_offscreenMutex);
    m_offscreenCv.wait_for(lock, std::chrono::milliseconds(200), [&] {
      for (int i = 0; i < slotCount(); i++)
      {
        if (m_offscreenPending[i].load(std::memory_order_acquire) == 0)
        {
          return true;
        }
      }
      return false;
    });
  }
  for (int i = 0; i < slotCount(); i++)
  {
    if (m_offscreenPending[i].load(std::memory_order_acquire) == 0)
    {
      return i;
    }
  }
  return (m_lastRenderedSlot + 1) % slotCount();
}

// Render thread, with the render context current.
int AndroidRenderTexture::allocateOffscreenSlot(int slot)
{
  m_offscreenTex[slot] = threadState->takePooledTexture(m_width, m_height);
  if (m_offscreenTex[slot] == 0)
  {
    LOGD("Rive offscreen slot %d for %ux%u", slot, m_width, m_height);
    glGenTextures(1, &m_offscreenTex[slot]);
    glBindTexture(GL_TEXTURE_2D, m_offscreenTex[slot]);
    glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, m_width, m_height);
    glutils::SetTexture2DSamplingParams(GL_NEAREST, GL_NEAREST);
    glBindTexture(GL_TEXTURE_2D, 0);
  }
  return slot;
}

// Render thread, with the render context current. Wraps the slot's hardware
// buffer, dequeued by the Kotlin side, as a GL texture: the render target
// then draws into the buffer itself, and Flutter samples the same memory.
int AndroidRenderTexture::allocateImageSlot(int slot)
{
  JNIEnv* env = jniEnv();
  if (env == nullptr)
  {
    return slot;
  }
  const HardwareBufferProcs& procs = hardwareBufferProcs();
  jobject hardwareBuffer = env->CallObjectMethod(
      m_imageTexture,
      g_acquireBufferMethod,
      slot);
  if (env->ExceptionCheck())
  {
    env->ExceptionDescribe();
    env->ExceptionClear();
    hardwareBuffer = nullptr;
  }
  if (hardwareBuffer == nullptr)
  {
    // Normal on a texture being released (the Kotlin side answers
    // null), a writer with no buffer left otherwise; the frame is
    // dropped either way.
    return slot;
  }
  AHardwareBuffer* buffer = procs.fromHardwareBuffer(env, hardwareBuffer);
  procs.acquire(buffer);
  // The Java object's own reference is not needed past this point; the
  // Image and the acquire above keep the buffer alive.
  env->CallVoidMethod(hardwareBuffer, g_hardwareBufferCloseMethod);
  env->DeleteLocalRef(hardwareBuffer);

  EGLClientBuffer clientBuffer = procs.getNativeClientBuffer(buffer);
  EGLImageKHR image = procs.createImage(
      threadState->display(),
      EGL_NO_CONTEXT,
      EGL_NATIVE_BUFFER_ANDROID,
      clientBuffer,
      nullptr);
  if (image == EGL_NO_IMAGE_KHR)
  {
    LOGE("Rive hardware buffer slot %d: eglCreateImageKHR failed", slot);
    EGL_ERR_CHECK();
    procs.release(buffer);
    return slot;
  }
  if (procs.describe != nullptr)
  {
    // The usage the allocator granted: GPU_COLOR_OUTPUT (0x200) must be
    // in it for the render target, GPU_SAMPLED_IMAGE (0x100) for
    // Flutter. Below API 33 the writer cannot ask for either itself.
    AHardwareBuffer_Desc desc = {};
    procs.describe(buffer, &desc);
    LOGD(
        "Rive hardware buffer slot %d for %ux%u, format %u, usage 0x%llx",
        slot,
        m_width,
        m_height,
        desc.format,
        static_cast<unsigned long long>(desc.usage));
  }
  GLuint texture = 0;
  glGenTextures(1, &texture);
  glBindTexture(GL_TEXTURE_2D, texture);
  procs.imageTargetTexture2D(GL_TEXTURE_2D, image);
  glutils::SetTexture2DSamplingParams(GL_NEAREST, GL_NEAREST);
  glBindTexture(GL_TEXTURE_2D, 0);

  m_slotBuffer[slot] = buffer;
  m_slotImage[slot] = image;
  m_offscreenTex[slot] = texture;
  m_slotStale[slot].store(false, std::memory_order_relaxed);
  return slot;
}

// Render thread, with the render context current.
void AndroidRenderTexture::freeImageSlot(int slot)
{
  const HardwareBufferProcs& procs = hardwareBufferProcs();
  if (m_offscreenTex[slot] != 0)
  {
    glDeleteTextures(1, &m_offscreenTex[slot]);
    m_offscreenTex[slot] = 0;
  }
  if (m_slotImage[slot] != EGL_NO_IMAGE_KHR)
  {
    procs.destroyImage(threadState->display(), m_slotImage[slot]);
    m_slotImage[slot] = EGL_NO_IMAGE_KHR;
  }
  if (m_slotBuffer[slot] != nullptr)
  {
    procs.release(m_slotBuffer[slot]);
    m_slotBuffer[slot] = nullptr;
  }
  m_slotStale[slot].store(false, std::memory_order_relaxed);
}

// Push thread: wait for the oldest unwaited frame's GPU work and mark it
// signaled for the producer's next tick to push. Never blocks on anything
// but the fence: every texture's frames share this thread, and waiting here
// for one texture's tick would leave the others' fences unmarked when their
// ticks come. Nothing here touches GL; the buffer reaches Flutter complete,
// so its raster thread has nothing to wait on.
void AndroidRenderTexture::pushImageSlot()
{
  if (m_pushCancelled.load(std::memory_order_acquire))
  {
    return;
  }
  ReadyFrame frame;
  {
    std::lock_guard<std::mutex> lock(m_readyMutex);
    // Jobs and frames are queued in the same order; skip frames the
    // producer already took.
    auto it = std::find_if(
        m_readyFrames.begin(),
        m_readyFrames.end(),
        [](const ReadyFrame& f) {
          return !f.sync->signaled.load(std::memory_order_acquire);
        });
    if (it == m_readyFrames.end())
    {
      return;
    }
    frame = *it;
  }
  // Wait in 100 ms slices, bounded: a frame on the low-priority context
  // behind every other texture's replay can take longer than a slice on a
  // slow device, and pushing it early would show a torn frame for as long
  // as the next push takes. A GPU wedged past the bound still gets the
  // frame pushed, so the texture and the destroy-time drain never hang.
  constexpr int kFenceWaitSliceMs = 100;
  constexpr int kFenceWaitSlices = 15;
  bool complete = frame.sync->fenceFd < 0 &&
                  frame.sync->sync == EGL_NO_SYNC_KHR; // finished with glFinish
  for (int slice = 0; !complete && slice < kFenceWaitSlices; slice++)
  {
    if (m_pushCancelled.load(std::memory_order_acquire))
    {
      return;
    }
    if (frame.sync->fenceFd >= 0)
    {
      // Any event on a sync fence fd means it is no longer pending
      // (POLLERR is a fence that signaled with an error).
      pollfd pfd = {frame.sync->fenceFd, POLLIN, 0};
      int polled;
      do
      {
        polled = poll(&pfd, 1, kFenceWaitSliceMs);
      } while (polled < 0 && errno == EINTR);
      complete = polled != 0;
    }
    else
    {
      complete = egl_clientWaitSync()(
                     frame.sync->display,
                     frame.sync->sync,
                     0,
                     EGLTimeKHR{kFenceWaitSliceMs} * 1000000) ==
                 EGL_CONDITION_SATISFIED_KHR;
    }
  }
  if (!complete)
  {
    static std::atomic<bool> logged{false};
    if (!logged.exchange(true, std::memory_order_relaxed))
    {
      LOGW(
          "Rive hardware buffer fence not signaled after %d ms, pushing "
          "without it",
          kFenceWaitSliceMs * kFenceWaitSlices);
    }
  }
  frame.sync->signaledAt = std::chrono::steady_clock::now();
  frame.sync->signaled.store(true, std::memory_order_release);
  if (frame.first)
  {
    // Nothing on screen to displace: push now rather than at a tick.
    ReadyFrame front;
    bool deliver = false;
    {
      std::lock_guard<std::mutex> lock(m_readyMutex);
      if (!m_readyFrames.empty() && m_readyFrames.front().sync == frame.sync)
      {
        front = m_readyFrames.front();
        m_readyFrames.pop_front();
        deliver = true;
      }
    }
    if (deliver)
    {
      frameReady(front.slot, kFirstPush);
    }
    return;
  }
  frameSignaled();
}

// Platform thread.
int AndroidRenderTexture::latePush()
{
  ReadyFrame frame;
  {
    std::lock_guard<std::mutex> lock(m_readyMutex);
    if (m_readyFrames.empty())
    {
      return 0;
    }
    const ReadyFrame& front = m_readyFrames.front();
    if (!front.sync->signaled.load(std::memory_order_acquire))
    {
      return kLatePushMs;
    }
    const auto waited = std::chrono::duration_cast<std::chrono::milliseconds>(
                            std::chrono::steady_clock::now() -
                            front.sync->signaledAt)
                            .count();
    if (waited < kLatePushMs)
    {
      return static_cast<int>(kLatePushMs - waited);
    }
    frame = front;
    m_readyFrames.pop_front();
  }
  frameReady(frame.slot, kLatePush);
  return kLatePushMs;
}

// Push thread. Asks the Kotlin side to arm its late-push check, which it
// keeps armed while frames are waiting; from a native thread the push
// itself must go through the platform thread anyway.
void AndroidRenderTexture::frameSignaled()
{
  JNIEnv* env = jniEnv();
  if (env == nullptr)
  {
    return;
  }
  env->CallVoidMethod(m_imageTexture, g_frameSignaledMethod);
  if (env->ExceptionCheck())
  {
    env->ExceptionDescribe();
    env->ExceptionClear();
  }
}

// Producer thread, at each tick. Pushes the oldest frame if its fence has
// signaled, one per tick: a second push in the same tick would replace the
// first before any raster acquired it. A frame whose fence is still pending
// waits for the next tick, or for the push thread if no tick comes.
void AndroidRenderTexture::pushReadyFrames()
{
  if (jniEnv() == nullptr)
  {
    // The producer thread is not a Java thread (Flutter's UI thread
    // unmerged from the platform thread). The late-push timer delivers
    // the frames instead, one frame interval or two later.
    return;
  }
  ReadyFrame frame;
  {
    std::lock_guard<std::mutex> lock(m_readyMutex);
    if (m_readyFrames.empty() ||
        !m_readyFrames.front().sync->signaled.load(std::memory_order_acquire))
    {
      return;
    }
    frame = m_readyFrames.front();
    m_readyFrames.pop_front();
  }
  frameReady(frame.slot, kTickPush);
}

// Any thread. Tells the Kotlin side the slot's frame may be pushed; from a
// native thread it posts the push to the platform thread, where Flutter
// requires it.
void AndroidRenderTexture::frameReady(int slot, int how)
{
  JNIEnv* env = jniEnv();
  if (env == nullptr)
  {
    return;
  }
  env->CallVoidMethod(m_imageTexture, g_frameReadyMethod, slot, how);
  if (env->ExceptionCheck())
  {
    env->ExceptionDescribe();
    env->ExceptionClear();
  }
}

// Copy the bound read framebuffer's full frame to the bound draw framebuffer.
void AndroidRenderTexture::blitFullFrame()
{
  glDisable(GL_SCISSOR_TEST);
  glutils::BlitFramebuffer(
      {0, 0, (int)m_width, (int)m_height},
      m_height,
      /*bottomUp=*/false);
}

// Render thread: copy one slot's frame into the other.
void AndroidRenderTexture::copyOffscreenSlot(int from, int to)
{
  if (m_copyFbo[0] == 0)
  {
    glGenFramebuffers(2, m_copyFbo);
  }
  glBindFramebuffer(GL_READ_FRAMEBUFFER, m_copyFbo[0]);
  glFramebufferTexture2D(
      GL_READ_FRAMEBUFFER,
      GL_COLOR_ATTACHMENT0,
      GL_TEXTURE_2D,
      m_offscreenTex[from],
      0);
  glBindFramebuffer(GL_DRAW_FRAMEBUFFER, m_copyFbo[1]);
  glFramebufferTexture2D(
      GL_DRAW_FRAMEBUFFER,
      GL_COLOR_ATTACHMENT0,
      GL_TEXTURE_2D,
      m_offscreenTex[to],
      0);
  blitFullFrame();
  glBindFramebuffer(GL_READ_FRAMEBUFFER, 0);
  glBindFramebuffer(GL_DRAW_FRAMEBUFFER, 0);
}

// Render thread, before the window surface and textures go away.
void AndroidRenderTexture::releaseOffscreenResources()
{
  if (!m_offscreen || !threadState)
  {
    return;
  }
  if (imageMode())
  {
    // Drop the frames still waiting to be pushed, cancel this texture's
    // push jobs (a fence wait in progress ends at its current slice)
    // and wait for just those to finish; other textures' jobs on the
    // shared push thread are not waited for.
    m_pushCancelled.store(true, std::memory_order_release);
    {
      std::unique_lock<std::mutex> lock(m_readyMutex);
      m_readyFrames.clear();
      m_pushJobsCv.wait(lock, [&] {
        return m_pushJobs.load(std::memory_order_acquire) == 0;
      });
    }
    m_textureTarget = nullptr;
    threadState->makeCurrentRender();
    if (m_copyFbo[0] != 0)
    {
      glDeleteFramebuffers(2, m_copyFbo);
      m_copyFbo[0] = m_copyFbo[1] = 0;
    }
    for (int i = 0; i < kImageSlots; i++)
    {
      freeImageSlot(i);
    }
    m_renderSlot = m_lastRenderedSlot = 0;
    return;
  }
  // Let every queued present for this texture finish, then drop the
  // present context's objects and its hold on the window surface, on the
  // present thread that owns them.
  GLThread::presentInstance(m_presentThread).invoke([this] {
    threadState->makeCurrentPresent(m_presentThread, EGL_NO_SURFACE);
    // Unused (zero) names are ignored by glDeleteFramebuffers.
    glDeleteFramebuffers(kSlots, m_presentReadFbo);
    std::fill(std::begin(m_presentReadFbo), std::end(m_presentReadFbo), 0);
  });
  m_textureTarget = nullptr;
  threadState->makeCurrentRender();
  if (m_copyFbo[0] != 0)
  {
    glDeleteFramebuffers(2, m_copyFbo);
    m_copyFbo[0] = m_copyFbo[1] = 0;
  }
  for (GLuint& tex : m_offscreenTex)
  {
    threadState->recycleTexture(tex, m_width, m_height);
    tex = 0;
  }
  m_renderSlot = m_lastRenderedSlot = 0;
}

#if defined(RIVE_CANVAS) && defined(RIVE_ORE)
// Replays recorded frames onto the Flutter Surface. Runs on the render thread
// holding the EGL context current.
class AndroidRenderTextureFrameSink : public rive_native::HostFrameSink
{
public:
  AndroidRenderTextureFrameSink(
      AndroidRenderTexture* renderTexture,
      bool clear,
      uint32_t color,
      bool replayOre)
      : HostFrameSink(clear, color, renderTexture->screenTarget(), replayOre)
      , m_renderTexture(renderTexture)
  {}

  rive::gpu::RenderContext* renderContext() override
  {
    return m_renderTexture->renderContext();
  }

  rive::Renderer* beginScreen(uint64_t target, bool clear, uint32_t color)
      override
  {
    // One Surface is one Flutter texture, and the base sink has already
    // refused every target but this Surface's. A frame that could not
    // begin (destroyed texture, no buffer for its slot) is dropped
    // rather than replayed into nothing: without a renderer the replay
    // never presents it.
    (void)target;
    // A refused frame (texture marked destroyed) draws nothing and never
    // presents, so the render context is not left mid-frame.
    return m_renderTexture->beginFrame(clear, color)
               ? m_renderTexture->renderer()
               : nullptr;
  }

private:
  AndroidRenderTexture* m_renderTexture;
};

// Render thread. Offscreen: fence the frame just rendered into its slot and
// queue it for the present thread, then move on to the other slot without
// waiting. Direct (no present context): swap now.
void AndroidRenderTexture::endFrame()
{
  if (imageMode() && m_offscreenTex[m_renderSlot] == 0)
  {
    // The slot has no buffer (beginFrame failed); nothing was drawn.
    return;
  }
  if (!submitFrame())
  {
    return;
  }
  if (!m_offscreen)
  {
    threadState->swapBuffers();
    return;
  }
  // Image mode prefers a native fence: its fd is waited with poll() on
  // the push thread, asleep in the kernel until the GPU signals it.
  bool nativeFence = imageMode() && threadState->nativeFenceSync();
  EGLSyncKHR sync = egl_createSync()(
      threadState->display(),
      nativeFence ? EGL_SYNC_NATIVE_FENCE_ANDROID : EGL_SYNC_FENCE_KHR,
      nullptr);
  if (sync == EGL_NO_SYNC_KHR && nativeFence)
  {
    // A plain sync has no fd to duplicate. Consume the failure's error
    // so it is not misattributed to the next EGL call.
    EGL_ERR_CHECK();
    nativeFence = false;
    sync = egl_createSync()(
        threadState->display(),
        EGL_SYNC_FENCE_KHR,
        nullptr);
  }
  if (sync == EGL_NO_SYNC_KHR)
  {
    // No fence for this frame, so finish the work here instead. The
    // present thread has nothing to wait on and would otherwise blit a
    // half-written texture.
    glFinish();
  }
  else
  {
    // Kick the queued work now so the fence can signal; a fence behind
    // unflushed commands never would.
    glFlush();
  }
  const int slot = m_renderSlot;
  m_offscreenPending[slot].fetch_add(1, std::memory_order_release);
  m_hasOffscreenFrame = true;
  m_lastRenderedSlot = slot;
  if (imageMode())
  {
    {
      std::lock_guard<std::mutex> lock(m_readyMutex);
      auto holder = std::make_shared<SyncHolder>();
      holder->display = threadState->display();
      holder->sync = sync;
      if (nativeFence && sync != EGL_NO_SYNC_KHR)
      {
        // Only valid once the sync's commands are flushed (above).
        holder->fenceFd = hardwareBufferProcs().dupNativeFenceFD(
            threadState->display(),
            sync);
      }
      // Without a sync the work was finished with glFinish above; the
      // push thread still marks the frame so the first-frame and late
      // pushes happen for it too.
      m_readyFrames.push_back({slot, std::move(holder), !m_pushedOnce});
      m_pushedOnce = true;
    }
    m_pushJobs.fetch_add(1, std::memory_order_acq_rel);
    GLThread::pushInstance().post([this] {
      pushImageSlot();
      {
        std::lock_guard<std::mutex> lock(m_readyMutex);
        m_pushJobs.fetch_sub(1, std::memory_order_acq_rel);
      }
      m_pushJobsCv.notify_all();
    });
    return;
  }
  GLThread::presentInstance(m_presentThread).post([this, slot, sync] {
    presentOffscreenSlot(slot, sync);
  });
}

// FFI thread: snapshot the recorded frame so the session can record the next
// one, then hand the snapshot to the render thread.
bool AndroidRenderTexture::deferredFlush()
{
  if (imageMode())
  {
    // The gate check normally pushed already this tick.
    if (!m_pushedSinceFlush)
    {
      pushReadyFrames();
    }
    m_pushedSinceFlush = false;
  }
  rive_native::DeferredFrameJob job;
  if (!snapshotDeferredFrame(job))
  {
    return true;
  }
  m_inFlightReplays.fetch_add(1, std::memory_order_release);
  GLThread::instance().post([this, job] {
    AndroidRenderTextureFrameSink sink(
        this,
        job.doClear,
        job.color,
        job.replayOre);
    rive_native::replayDeferredFrame(job, sink, [&] { endFrame(); });
    m_inFlightReplays.fetch_sub(1, std::memory_order_release);
  });
  return true;
}

// Per-texture pacing gate for the Dart producer. Preferred over the
// session-level riveDeferredCanAccept: the session gate is global, and a
// global budget starves whichever textures tick last (they lose the race to
// the same winners every frame).
EXPORT int riveTextureCanAcceptDeferredFrame(
    AndroidRenderTexture* renderTexture)
{
  if (renderTexture == nullptr)
  {
    return 1;
  }
  // Pushing here frees the slots those frames displaced before the gate
  // counts them (when the producer is the platform thread; otherwise the
  // late-push timer does it and the gate sees the release a tick later).
  renderTexture->pushReadyFrames();
  renderTexture->markPushedSinceFlush();
  return renderTexture->canAcceptDeferredFrame() ? 1 : 0;
}

void AndroidRenderTexture::drainDeferred()
{
  // Wait for any in-flight replay on the render thread to finish.
  GLThread::instance().drain();
}

// Pass null to detach the session.
EXPORT void riveTextureUseDeferredSession(
    AndroidRenderTexture* renderTexture,
    void* sessionPtr)
{
  if (renderTexture == nullptr)
  {
    return;
  }
  renderTexture->useDeferredSession(
      static_cast<rive::cmd::DeferredSession*>(sessionPtr));
}
#endif
