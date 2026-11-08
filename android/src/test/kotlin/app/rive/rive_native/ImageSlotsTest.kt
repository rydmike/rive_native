package app.rive.rive_native

import app.rive.rive_native.ImageSlotState.Outcome
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ImageSlotStateTest {
    @Test
    fun firstPushSettlesNothing() {
        val state = ImageSlotState()
        assertNull(state.pushed(0) { true })
        assertEquals(0, state.pending)
    }

    @Test
    fun previousStillOpenMeansConsumed() {
        val state = ImageSlotState()
        state.pushed(0) { true }
        assertEquals(Outcome.Consumed(0), state.pushed(1) { true })
        assertEquals(1, state.pending)
    }

    @Test
    fun previousClosedMeansDropped() {
        val state = ImageSlotState()
        state.pushed(0) { true }
        assertEquals(Outcome.Dropped(0), state.pushed(1) { slot -> slot != 0 })
        assertEquals(1, state.pending)
    }

    @Test
    fun repushingTheSameSlotSettlesNothing() {
        val state = ImageSlotState()
        state.pushed(2) { true }
        assertNull(state.pushed(2) { true })
        assertEquals(2, state.pending)
    }

    @Test
    fun settlesOnlyTheImmediatelyPreviousPush() {
        val state = ImageSlotState()
        state.pushed(0) { true }
        state.pushed(1) { true }
        val asked = mutableListOf<Int>()
        assertEquals(Outcome.Consumed(1), state.pushed(2) { asked.add(it); true })
        assertEquals(listOf(1), asked)
    }
}

class RingPoolTest {
    private val evicted = mutableListOf<String>()
    private fun pool(maxBytes: Long, maxEntries: Int = 100) =
        RingPool<String>(maxBytes, maxEntries, { it.length.toLong() }, { evicted.add(it) })

    @Test
    fun takesOnlyAMatchingSize() {
        val pool = pool(100)
        pool.recycle(4, 4, "ring")
        assertNull(pool.take(8, 8))
        assertEquals("ring", pool.take(4, 4))
        assertNull(pool.take(4, 4))
        assertEquals(0, pool.size)
    }

    @Test
    fun evictsOldestPastTheByteBound() {
        val pool = pool(10)
        pool.recycle(1, 1, "aaaa")
        pool.recycle(2, 2, "bbbb")
        pool.recycle(3, 3, "cccc")
        assertEquals(listOf("aaaa"), evicted)
        assertEquals(2, pool.size)
        assertNull(pool.take(1, 1))
        assertEquals("bbbb", pool.take(2, 2))
    }

    @Test
    fun aRingLargerThanTheBoundIsEvictedAtOnce() {
        val pool = pool(3)
        pool.recycle(9, 9, "toolarge")
        assertEquals(listOf("toolarge"), evicted)
        assertEquals(0, pool.size)
    }

    @Test
    fun evictsOldestPastTheEntryBound() {
        val pool = pool(1000, maxEntries = 2)
        pool.recycle(1, 1, "a")
        pool.recycle(2, 2, "b")
        pool.recycle(3, 3, "c")
        assertEquals(listOf("a"), evicted)
        assertEquals(2, pool.size)
    }

    @Test
    fun clearEvictsEverything() {
        val pool = pool(100)
        pool.recycle(1, 1, "a")
        pool.recycle(2, 2, "b")
        pool.clear()
        assertEquals(listOf("a", "b"), evicted)
        assertEquals(0, pool.size)
    }
}
