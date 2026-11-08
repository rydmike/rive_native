package app.rive.rive_native

/**
 * What Flutter's ImageTextureEntry tells us about the buffers we push to it.
 *
 * The entry holds one Image and never closes one it consumed, so the only
 * signal is at the next push: the previously pushed Image is either still
 * open (Flutter took it, and from the next raster on draws the new one, so
 * its slot is free) or closed (Flutter replaced it unconsumed, its buffer
 * went back to the writer, and the slot needs a fresh one). Pure, so the
 * contract is tested without a GPU.
 */
internal class ImageSlotState {
    sealed interface Outcome {
        /** Flutter consumed the slot's last frame; the slot may be drawn into again. */
        data class Consumed(val slot: Int) : Outcome

        /** Flutter closed the slot's Image unconsumed; the slot needs a new buffer. */
        data class Dropped(val slot: Int) : Outcome
    }

    /** The last pushed slot, not yet known to be consumed or dropped. */
    var pending = -1
        private set

    /**
     * Records that [slot] was pushed and settles the previous push.
     *
     * @param stillOpen Whether the previously pushed slot's Image is still open.
     * @return What happened to the previous push, or null when there was none.
     */
    fun pushed(slot: Int, stillOpen: (Int) -> Boolean): Outcome? {
        val previous = pending
        pending = slot
        if (previous == -1 || previous == slot) {
            return null
        }
        return if (stillOpen(previous)) Outcome.Consumed(previous) else Outcome.Dropped(previous)
    }
}

/**
 * Keeps released buffer rings for textures of the same size, oldest out
 * first, bounded by bytes and by count so churn cannot pile up memory or
 * reader/writer pairs. A widget whose scale animates under the default
 * render resolution drops and recreates its texture every frame;
 * allocating a reader, a writer and their buffers each time costs more
 * than keeping a few rings around.
 */
internal class RingPool<T>(
    private val maxBytes: Long,
    private val maxEntries: Int,
    private val bytesOf: (T) -> Long,
    private val evict: (T) -> Unit,
) {
    private data class Entry<T>(val width: Int, val height: Int, val ring: T)

    private val entries = ArrayDeque<Entry<T>>()

    val size: Int get() = entries.size

    fun take(width: Int, height: Int): T? {
        val index = entries.indexOfFirst { it.width == width && it.height == height }
        if (index < 0) {
            return null
        }
        return entries.removeAt(index).ring
    }

    /** Stores [ring], evicting the oldest rings past either bound, this one included. */
    fun recycle(width: Int, height: Int, ring: T) {
        entries.addLast(Entry(width, height, ring))
        var bytes = entries.sumOf { bytesOf(it.ring) }
        while ((bytes > maxBytes || entries.size > maxEntries) && entries.isNotEmpty()) {
            val oldest = entries.removeFirst()
            bytes -= bytesOf(oldest.ring)
            evict(oldest.ring)
        }
    }

    fun clear() {
        while (entries.isNotEmpty()) {
            evict(entries.removeFirst().ring)
        }
    }
}
