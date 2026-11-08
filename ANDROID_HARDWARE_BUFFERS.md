# Android hardware buffer present

How a Rive texture reaches Flutter on Android when an app opts in with `RiveNative.init(androidHardwareBuffers: true)`. Written for reviewers of the code in `native/platform/android/rive_native_android.cpp` (the image mode of `AndroidRenderTexture`) and `android/src/main/kotlin/app/rive/rive_native/` (`RiveImageTexture`, `BufferRing`, `RingPool`, `ImageSlotState`). Measurements and the testing switch are in `ANDROID_DEVICE_TESTING.md` and `DIAGNOSTICS.md`.

## The problem it solves

The Surface path (still the default, and the fallback) gives each texture a window surface from Flutter's `SurfaceProducer`. Rive renders offscreen, and a present thread with its own EGL context blits the frame into that surface and swaps it; Android's buffer queue then carries the buffer to Flutter's `ImageReader`. On Mali that costs about one CPU core continuously at 8 to 16 widgets, more than the drawing itself, in `eglMakeCurrent` per surface and the blit. The hardware buffer path removes the surface, the swap and the blit: Rive draws into a buffer the plugin owns, and Flutter samples that buffer.

## What Flutter provides, and what it does not

`TextureRegistry.createImageTexture()` returns an `ImageTextureEntry`: public API since Flutter 3.13, built for compositing Flutter's own Android platform views (`ImageReaderPlatformViewRenderTarget` in the engine) and still one of its two API 29+ backends for them, behind the `SurfaceProducer` one. The plugin calls `pushImage(Image)`; Flutter's raster thread wraps the Image's `HardwareBuffer` as an EGLImage (Impeller GL, Skia) or a `VkImage` (Impeller Vulkan), cached by buffer id, and draws it. Both that entry and the `SurfaceProducer` behind the Surface path implement `TextureRegistry.ImageConsumer`, and the engine's raster thread imports the buffer through that one interface, so nothing new runs on Flutter's side for our buffers.

Three engine facts shape everything below (Flutter 3.47, `FlutterRenderer.java` `ImageTextureRegistryEntry`, `image_external_texture*.cc`):

1. The entry holds one Image. A push while the previous one is unconsumed closes the previous one ("Dropping PlatformView Frame").
2. Flutter never closes an Image it consumed. It keeps drawing the last consumed buffer on every raster frame until it acquires a newer one.
3. On API 33+ the raster thread CPU-waits the Image's fence; below 33 it ignores the fence. The public SDK gives an app no way to attach a fence to an Image (every `SyncFence` factory is hidden).

So the plugin owns the buffers, infers consumption from fact 1, and always hands Flutter a finished frame so fact 3 never matters.

## Buffers

`BufferRing`, one per texture size. An `ImageReader` exists only to host a buffer queue; an `ImageWriter` on its Surface dequeues one Image per slot, four slots, and never queues them. Each Image's `HardwareBuffer` is wrapped once on the render thread as an EGLImage bound to a `GL_TEXTURE_2D`, which `TextureRenderTargetGL` renders into top-down (a buffer has no window-system flip). Below API 33 the reader's consumer usage supplies the GPU render and sample bits (measured 0x330 with the pre-33 constructors); the Builder on 33+ asks for them directly.

Rings released by a texture go to `RingPool`, keyed by size, bounded by bytes (16 MB) and count (16), oldest out. A widget that recreates its texture every frame (an animating scale under the default render resolution) reuses them instead of allocating. The pool is emptied when the last texture is removed, as the render context releases its drawing memory then; a recreated texture never empties it, since the old texture is removed a second after the new one exists.

## Ownership: who may draw into a slot

A slot is busy from the moment its frame is queued for pushing until Flutter is known to have let go of it. Flutter says nothing, so `ImageSlotState` infers it at the next push: after `pushImage(S')`, if the previously pushed Image S is still open, Flutter consumed S and from the next raster on draws S', so S's slot is released; if S is closed, Flutter dropped it (fact 1), its buffer went back to the writer, and the slot is marked stale and dequeues a fresh buffer before its next use.

The render thread reuses released slots oldest first, so the slot just released, which Flutter's raster of the previous frame may still be sampling, stays out of use for two more frames unless it is the only free one. That window is the same one Flutter's ImageReader path has (it returns a buffer to the producer without a release fence); it is accepted rather than paid for with a fifth buffer per texture. The pacing gate (`canAcceptDeferredFrame`) refuses a tick when the in-flight replays plus busy slots would exceed four.

## Push timing

A frame is rendered on the render thread (`RiveRender`), which creates an `EGL_ANDROID_native_fence_sync` for it, flushes, and queues a `ReadyFrame` with the fence's fd. From there:

- The push thread (`RivePush`, no GL context, shared by every texture) waits the fence fd with `poll()`, asleep in the kernel (`eglClientWaitSyncKHR` spins on PowerVR), and marks the frame signaled. It never blocks on anything else: waiting there for one texture's tick left the other textures' fences unmarked.
- The producer's next tick (`riveTextureCanAcceptDeferredFrame`, then `deferredFlush`, on Flutter's platform thread when the UI thread is merged with it) pushes the oldest signaled frame, one per tick. The push lands before that frame's raster acquires the texture, so it can never be displaced unconsumed. Pushing when the fence signaled instead, from the push thread, raced the raster acquire and dropped 4 to 7% of frames.
- A frame no tick takes within 40 ms of signaling (the last frame when a ticker stops) is pushed by a timer on the platform thread. A texture's first frame is pushed as soon as it signals: nothing is on screen to displace, and a widget that recreates its texture every frame only ever pushes first frames. That push comes from the push thread and is queued for the platform thread; a tick push that runs first delivers the queued frame before its own, so a frame never lands behind a later one.
- If the producer thread is not a Java thread (Flutter's UI thread unmerged), it does not attach to the VM (an engine thread that exits attached aborts the process); the timer path delivers its frames a frame interval later.

## Threads and locks

| Thread | Does | Locks |
| --- | --- | --- |
| Platform (main) | createTexture/removeTexture, `pushOnMain`, the late-push timer, `release()` | the Kotlin ring monitor, briefly; never across a blocking call |
| Producer (FFI; the platform thread when merged) | the gate check and flush, which push a signaled frame | `flutterMutex` (FFI entry), `m_readyMutex` briefly |
| RiveRender | replay into the slot, `allocateImageSlot` (JNI into the ring monitor), `endFrame` | `m_offscreenMutex`, `m_readyMutex`, the ring monitor through JNI |
| RivePush | fence waits, marks signaled, first-frame push | `m_readyMutex` briefly |

No cycle: the ring monitor is always released before any native mutex is taken; `release()` leaves the monitor before destroying the native texture, whose drain waits for the render thread, whose replay may be inside `acquireBuffer` waiting for that monitor.

## Teardown

`RiveImageTexture.release()` marks itself released (so `acquireBuffer` answers null and in-flight replays drop their frame), destroys the native texture, which cancels this texture's push jobs and waits for just those (not the shared push thread's queue), frees EGLImages, GL textures and buffer refs on the render thread; then `entry.release()` closes the last pushed Image if Flutter never consumed it, and the ring goes to the pool. Flutter's cached EGLImage keeps its own reference to any buffer it still draws.

## Fallbacks

Image mode is offered only when, once per process on the render thread: the GL context is ES 3 with fence syncs; the EGL and GL extension strings name `EGL_ANDROID_image_native_buffer`, `EGL_ANDROID_get_native_client_buffer` and `GL_OES_EGL_image` (`eglGetProcAddress` returns entry points regardless); and a 4x4 probe buffer of the writer's format and usage imports and attaches to a framebuffer. Otherwise, below API 29, without the opt-in, with `debug.rive.gl_ahb=0`, or when the native side cannot bind to the Kotlin texture class (it returns no renderer), the texture is a `SurfaceProducer` and takes the Surface path unchanged. `debug.rive.gl_ahb=1` opts a device in regardless of the app, for testing.

A frame whose fence has not signaled after 1.5 s of retries is pushed anyway with a one-time warning, so a wedged GPU cannot freeze the texture or the destroy-time wait. A slot whose buffer could not be acquired or wrapped drops its frame and releases itself so the slot accounting stays balanced.

## What to review

- `ImageSlotState.pushed` and `RiveImageTexture.pushOnMain`: the ownership rule, and that the previous Image is checked after `pushImage`, which is what closes a dropped one.
- `AndroidRenderTexture::pushReadyFrames`, `pushImageSlot`, `latePush`, `endFrame` (image branch) and `acquireRenderSlot` (image branch): the push protocol and the slot bookkeeping (`m_offscreenPending`, `m_slotStale`, `m_slotReleaseSeq`).
- `releaseOffscreenResources` (image branch) and `RiveImageTexture.release`: teardown ordering.
- `ImageSlotsTest.kt` covers the state machine and the pool; device behavior is measured with the benchmark app (`ANDROID_DEVICE_TESTING.md`).
