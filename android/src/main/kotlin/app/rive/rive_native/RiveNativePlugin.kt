package app.rive.rive_native

import android.graphics.PixelFormat
import android.hardware.HardwareBuffer
import android.media.Image
import android.media.ImageReader
import android.media.ImageWriter
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.Trace
import android.view.Surface
import androidx.annotation.Keep
import androidx.annotation.RequiresApi
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.view.TextureRegistry
import android.util.Log

external fun createRiveRenderer(
    surface: Surface,
    width: Int,
    height: Int,
): Long

external fun destroyRiveRenderer(renderer: Long)
external fun markDestroyedRiveRenderer(renderer: Long)

// Hardware buffer present: the renderer draws straight into buffers this
// side owns and hands them to Flutter as Images.
internal external fun createRiveImageRenderer(
    texture: RiveImageTexture,
    width: Int,
    height: Int,
): Long

// The slot's buffer is no longer read by Flutter. With replaced, Flutter
// closed the Image (a dropped frame) and the slot needs a new buffer.
external fun riveImageSlotReleased(renderer: Long, slot: Int, replaced: Boolean)

// Pushes the oldest waiting frame if the producer's ticks have not taken
// it in time (the ticker stopped and it is the last frame). Returns the
// milliseconds until the next check is due, 0 when nothing is waiting.
// Main thread.
external fun riveImageLatePush(renderer: Long): Int
// Whether a texture created now should hand Flutter hardware buffers: the
// app's opt-in, unless the testing property debug.rive.gl_ahb forces it
// either way, and only where the GL context can do it.
external fun riveHardwareBufferPresentEnabled(appOptIn: Boolean): Boolean

class RiveNativePlugin :
    FlutterPlugin,
    MethodCallHandler {
    companion object {
        init {
            System.loadLibrary("rive_native")
        }
    }

    private lateinit var channel: MethodChannel
    private lateinit var textureRegistry: TextureRegistry
    private val renderTextures = mutableMapOf<Long, RiveRenderTexture>()
    private val imageTextures = mutableMapOf<Long, RiveImageTexture>()

    // Released buffer rings, reused by the next texture of the same size.
    private val ringPool =
        RingPool<BufferRing>(
            RiveImageTexture.POOL_BYTES,
            RiveImageTexture.POOL_ENTRIES,
            { it.bytes },
            { it.close() },
        )

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(flutterPluginBinding.binaryMessenger, "rive_native")
        channel.setMethodCallHandler(this)
        textureRegistry = flutterPluginBinding.textureRegistry
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        // Clean up all remaining textures
        renderTextures.values.forEach { it.release() }
        renderTextures.clear()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            imageTextures.values.forEach { it.release() }
            imageTextures.clear()
            ringPool.clear()
        }
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(
        call: MethodCall,
        result: Result,
    ) {
        when (call.method) {
            "createTexture" -> {
                val width = call.argument<Int>("width")
                val height = call.argument<Int>("height")

                if (width == null || height == null) {
                    result.error(
                        "CreateTexture Error",
                        "Width and height are required",
                        null,
                    )
                    return
                }

                val hardwareBuffers = call.argument<Boolean>("hardwareBuffers") == true
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
                    riveHardwareBufferPresentEnabled(hardwareBuffers)
                ) {
                    val imageTexture =
                        RiveImageTexture(
                            textureRegistry.createImageTexture(),
                            width,
                            height,
                            ringPool,
                        )
                    if (imageTexture.riveRenderer == 0L) {
                        // The native side could not bind to this class (a
                        // plugin/library mismatch); it never draws, so the
                        // texture takes the Surface path below instead.
                        Log.w("RiveNativePlugin", "hardware buffer renderer unavailable, using a Surface")
                        imageTexture.release()
                    } else {
                        imageTextures[imageTexture.id] = imageTexture
                        result.success(
                            mapOf(
                                "textureId" to imageTexture.id,
                                "renderer" to imageTexture.riveRenderer.toString(16),
                            ),
                        )
                        return
                    }
                }

                val surfaceProducer = textureRegistry.createSurfaceProducer()
                val riveTexture = RiveRenderTexture(surfaceProducer, width, height)
                renderTextures[surfaceProducer.id()] = riveTexture


                result.success(
                    mapOf(
                        "textureId" to surfaceProducer.id(),
                        "renderer" to riveTexture.riveRenderer.toString(16),
                    ),
                )
            }

            "getRenderContext" -> {
                result.success(
                    mapOf(
                        "rendererContext" to "android",
                    ),
                )
            }

            "removeTexture" -> {
                val textureId = call.argument<Int>("id")?.toLong()
                if (textureId == null) {
                    result.error(
                        "removeTexture Error",
                        "Texture ID is required",
                        null,
                    )
                    return
                }

                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    imageTextures.remove(textureId)?.let { texture ->
                        texture.release()
                        // The last texture out gives back its pooled rings, as
                        // the render context gives back its drawing memory.
                        // Churn never empties the map: a texture is removed a
                        // second after its replacement exists.
                        if (imageTextures.isEmpty()) {
                            ringPool.clear()
                        }
                        result.success(null)
                        return
                    }
                }

                renderTextures[textureId]?.let { texture ->
                    texture.release()
                    renderTextures.remove(textureId)
                    result.success(null)
                } ?: run {
                    Log.e("RiveNativePlugin", "removeTexture: texture $textureId not found")
                    result.error(
                        "removeTexture Error",
                        "Texture not found",
                        null,
                    )
                }
            }

            else -> result.notImplemented()
        }
    }
}

class RiveRenderTexture(
    surfaceProducer: TextureRegistry.SurfaceProducer,
    width: Int,
    height: Int,
) : TextureRegistry.SurfaceProducer.Callback {
    private val producer: TextureRegistry.SurfaceProducer = surfaceProducer
    private var surface: Surface
    var riveRenderer: Long = 0

    init {
        producer.setSize(width, height)
        producer.setCallback(
            this,
        )

        surface = producer.surface
        riveRenderer =
            createRiveRenderer(
                surface,
                width,
                height,
            )
    }

    // Called when coming back from backgrounding.
    override fun onSurfaceAvailable() {
        // This should only happen when returning from backgrounding.
        markRendererDestroyed()
        // Make a new surface for Flutter to use, but we're going to build a new
        // texture shortly...
        surface = producer.getSurface()
    }

    override fun onSurfaceCleanup() {
        // Do surface cleanup here, and stop drawing frames.
        markRendererDestroyed()
    }

    private fun markRendererDestroyed() {
        synchronized(this) {
            if (riveRenderer != 0L) {
                markDestroyedRiveRenderer(riveRenderer)
            }
        }
    }

    fun release() {
        synchronized(this) {
            if (riveRenderer != 0L) {
                destroyRiveRenderer(riveRenderer)
                riveRenderer = 0
            }
            try {
                surface.release()
                producer.release()
            } catch (e: Exception) {
                Log.w("RiveNativePlugin", "release: error releasing surface: $e")
                // Surface may already be released, ignore
            }
        }
    }
}

/**
 * The buffers behind one texture size: an ImageWriter whose dequeued Images
 * are rendered into repeatedly and never queued, and the ImageReader that
 * exists only to host its buffer queue. Outlives the texture it was made
 * for through the plugin's pool.
 */
@RequiresApi(Build.VERSION_CODES.Q)
internal class BufferRing(val width: Int, val height: Int) {
    // The reader's usage merges into the buffers the writer dequeues, which
    // is the only way to ask for GPU usage before API 33: the writer's own
    // usage is Builder-only. Measured on API 33 and 36, the pre-33
    // constructors yield GPU_COLOR_OUTPUT | GPU_SAMPLED_IMAGE plus the
    // writer's default CPU_WRITE_OFTEN, at the same rate.
    private val legacy = Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU
    private val usage = HardwareBuffer.USAGE_GPU_COLOR_OUTPUT or HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE
    private val reader: ImageReader =
        if (legacy) {
            ImageReader.newInstance(width, height, PixelFormat.RGBA_8888, 1, usage)
        } else {
            ImageReader.Builder(width, height)
                .setImageFormat(PixelFormat.RGBA_8888)
                .setMaxImages(1)
                .setUsage(usage)
                .build()
        }
    private val writer: ImageWriter =
        if (legacy) {
            ImageWriter.newInstance(reader.surface, RiveImageTexture.SLOTS, PixelFormat.RGBA_8888)
        } else {
            ImageWriter.Builder(reader.surface)
                .setImageFormat(PixelFormat.RGBA_8888)
                .setMaxImages(RiveImageTexture.SLOTS)
                .setUsage(usage)
                .build()
        }
    val images = arrayOfNulls<Image>(RiveImageTexture.SLOTS)

    // The most Images dequeued at once. A closed Image's buffer goes back
    // to the writer's queue, which keeps it allocated for the next dequeue,
    // so this is what the ring holds in graphics memory, not the count of
    // open Images.
    private var allocated = 0

    /**
     * Memory the pool accounts for. A ring that never dequeued still costs
     * its reader and writer and will allocate a buffer on first use, so it
     * counts as one slot rather than nothing.
     */
    val bytes: Long get() = 4L * maxOf(allocated, 1) * width * height

    /** The slot's Image, dequeuing one if it has none; null when the writer has no buffer left. */
    fun image(slot: Int): Image? {
        images[slot]?.let { return it }
        val image =
            try {
                writer.dequeueInputImage()
            } catch (e: IllegalStateException) {
                Log.e("RiveImageTexture", "dequeueInputImage failed: $e")
                return null
            }
        images[slot] = image
        allocated = maxOf(allocated, images.count { it != null })
        return image
    }

    fun close() {
        // Closes every Image still dequeued.
        writer.close()
        reader.close()
    }
}

/**
 * A Flutter texture fed with finished hardware buffers instead of a Surface.
 *
 * Each slot's Image is dequeued once and rendered into repeatedly. Flutter
 * reads the buffer behind an Image pushed to its ImageTextureEntry and never
 * closes a consumed Image, so this side decides when a slot may be drawn into
 * again (see ImageSlotState). A push that arrives before the previous Image
 * was consumed makes Flutter close that Image (a dropped frame); the buffer
 * then belongs to the writer again and the slot is dequeued afresh.
 */
@RequiresApi(Build.VERSION_CODES.Q)
internal class RiveImageTexture(
    private val entry: TextureRegistry.ImageTextureEntry,
    width: Int,
    height: Int,
    private val pool: RingPool<BufferRing>,
) {
    companion object {
        // Must match kImageSlots in rive_native_android.cpp.
        const val SLOTS = 4
        // Rings kept for reuse across all textures, by bytes; a ring of four
        // full-screen buffers exceeds it alone and is not kept.
        const val POOL_BYTES = 16L shl 20
        // Also bounds the reader/writer pairs kept for small textures.
        const val POOL_ENTRIES = 16
        // Must match kLatePushMs in rive_native_android.cpp: a couple of
        // frame intervals, which a running ticker pushes well within.
        const val LATE_PUSH_MS = 40L
        private const val TAG = "RiveImageTexture"
    }

    private val ring: BufferRing = pool.take(width, height) ?: BufferRing(width, height)
    private val mainHandler = Handler(Looper.getMainLooper())
    private val lock = Any()

    // Main thread only.
    private val state = ImageSlotState()
    private var released = false
    var riveRenderer: Long = 0
        private set

    val id: Long get() = entry.id()

    init {
        riveRenderer = createRiveImageRenderer(this, width, height)
    }

    /** Render thread. The slot's buffer, dequeuing an Image for it if it has none. */
    @Keep
    fun acquireBuffer(slot: Int): HardwareBuffer? {
        synchronized(lock) {
            if (released) {
                return null
            }
            return ring.image(slot)?.hardwareBuffer
        }
    }

    /**
     * Native, any thread. The slot holds a finished frame, its GPU work
     * complete. [how] says who pushed it: 0 the producer's tick, 1 the
     * late-push timer because no tick came, 2 the push thread because it
     * is the texture's first frame.
     */
    @Keep
    fun frameReady(slot: Int, how: Int) {
        // From the producer's tick this already runs on the main thread
        // (Flutter merges its UI and platform threads), and pushing now
        // lands before this frame's raster acquires the texture. A push
        // from another thread (the texture's first frame, from the push
        // thread) is queued for the main thread; a tick push that gets
        // there first delivers it before its own, newer frame, so a frame
        // never lands behind a later one.
        if (Looper.myLooper() === Looper.getMainLooper()) {
            drainQueued()
            pushOnMain(slot, how)
        } else {
            synchronized(lock) { queued.addLast(slot to how) }
            mainHandler.post { drainQueued() }
        }
    }

    // Deliveries posted from other threads, oldest first; guarded by lock.
    private val queued = ArrayDeque<Pair<Int, Int>>()

    // Main thread.
    private fun drainQueued() {
        while (true) {
            val next = synchronized(lock) { queued.removeFirstOrNull() } ?: return
            pushOnMain(next.first, next.second)
        }
    }

    // One late-push check at a time; re-armed while frames are waiting.
    private val latePushArmed = java.util.concurrent.atomic.AtomicBoolean(false)
    private val latePushCheck: Runnable =
        object : Runnable {
            override fun run() {
                latePushArmed.set(false)
                val renderer = synchronized(lock) { if (released) 0L else riveRenderer }
                if (renderer == 0L) {
                    return
                }
                val again = riveImageLatePush(renderer)
                if (again > 0 && latePushArmed.compareAndSet(false, true)) {
                    mainHandler.postDelayed(this, again.toLong())
                }
            }
        }

    /**
     * Native push thread. A frame's GPU work finished; the next producer
     * tick pushes it. Arms the check that pushes it late if no tick comes
     * (the ticker stopped), unless one is already armed.
     */
    @Keep
    fun frameSignaled() {
        if (latePushArmed.compareAndSet(false, true)) {
            mainHandler.postDelayed(latePushCheck, LATE_PUSH_MS)
        }
    }

    private fun pushOnMain(slot: Int, how: Int) {
        val image: Image?
        val renderer: Long
        synchronized(lock) {
            if (released || riveRenderer == 0L) {
                return
            }
            image = ring.images[slot]
            renderer = riveRenderer
        }
        if (image == null) {
            // The slot lost its buffer before its frame could be pushed.
            // Release it so its pending count balances; the previous push
            // stays pending and settles at the next real push.
            Log.e(TAG, "frameReady for an empty slot $slot")
            riveImageSlotReleased(renderer, slot, true)
            return
        }
        // Traced so a perfetto capture can count pushes per texture, the
        // way the Surface path's queueBuffer is counted.
        val section =
            when (how) {
                1 -> "RiveImagePushLate:$id"
                2 -> "RiveImagePushFirst:$id"
                else -> "RiveImagePush:$id"
            }
        Trace.beginSection(section)
        try {
            entry.pushImage(image)
        } finally {
            Trace.endSection()
        }

        // pushImage is what closes a dropped previous Image, so its state
        // is read after it, under the monitor the render thread's dequeue
        // uses.
        val previousOpen = synchronized(lock) { state.pending.let { it != -1 && isOpen(ring.images[it]) } }
        when (val outcome = state.pushed(slot) { previousOpen }) {
            // Flutter's raster of the previous frame may still be sampling
            // the released slot; the render thread reuses released slots
            // oldest first, which keeps it out of use for two more frames
            // unless it is the only free one (see m_slotReleaseSeq in
            // rive_native_android.cpp).
            is ImageSlotState.Outcome.Consumed ->
                riveImageSlotReleased(renderer, outcome.slot, false)
            is ImageSlotState.Outcome.Dropped -> {
                Trace.beginSection("RiveImageDrop:$id")
                try {
                    synchronized(lock) { ring.images[outcome.slot] = null }
                    riveImageSlotReleased(renderer, outcome.slot, true)
                } finally {
                    Trace.endSection()
                }
            }
            null -> {}
        }
    }

    private fun isOpen(image: Image?): Boolean {
        if (image == null) {
            return false
        }
        return try {
            image.width
            true
        } catch (e: IllegalStateException) {
            false
        }
    }

    fun release() {
        val renderer: Long
        synchronized(lock) {
            if (released) {
                return
            }
            released = true
            renderer = riveRenderer
            riveRenderer = 0
        }
        // Outside the monitor: destroying drains the render thread, and a
        // replay on it may be inside acquireBuffer() waiting for the lock.
        // With released set it gets null and its frame is dropped.
        if (renderer != 0L) {
            destroyRiveRenderer(renderer)
        }
        // Closes the last pushed Image if Flutter never consumed it, which
        // the next user of the ring must not find in its slot.
        entry.release()
        val pending = state.pending
        if (pending != -1 && !isOpen(ring.images[pending])) {
            ring.images[pending] = null
        }
        pool.recycle(ring.width, ring.height, ring)
    }
}
