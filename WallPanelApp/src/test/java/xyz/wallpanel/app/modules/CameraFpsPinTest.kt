package xyz.wallpanel.app.modules

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertNull
import org.junit.Test

class CameraFpsPinTest {

    /**
     * The ranges the Lenovo TB-J616F actually reports, copied from the device log.
     */
    private val lenovoRanges = listOf(
            intArrayOf(10000, 10000),
            intArrayOf(15000, 15000),
            intArrayOf(15000, 20000),
            intArrayOf(20000, 20000),
            intArrayOf(5000, 30000),
            intArrayOf(30000, 30000)
    )

    @Test
    fun `prefers the lowest fixed range over the wide one that matches the floor exactly`() {
        // The whole point of the change: [5000,30000] matches a 5fps floor perfectly but floats up
        // to 30fps in practice, so it must lose to the 10fps hardware floor.
        assertArrayEquals(intArrayOf(10000, 10000), CameraFpsPin.chooseRange(lenovoRanges, 5f))
    }

    @Test
    fun `the shipped default of 10fps lands on this hardware's lowest fixed range`() {
        assertArrayEquals(intArrayOf(10000, 10000), CameraFpsPin.chooseRange(lenovoRanges, 10f))
    }

    @Test
    fun `picks an exact fixed match when the hardware offers one`() {
        assertArrayEquals(intArrayOf(15000, 15000), CameraFpsPin.chooseRange(lenovoRanges, 15f))
        assertArrayEquals(intArrayOf(30000, 30000), CameraFpsPin.chooseRange(lenovoRanges, 30f))
    }

    @Test
    fun `chooses a genuine 5fps range when the hardware has one`() {
        val ranges = listOf(intArrayOf(5000, 5000), intArrayOf(5000, 30000), intArrayOf(30000, 30000))
        assertArrayEquals(intArrayOf(5000, 5000), CameraFpsPin.chooseRange(ranges, 5f))
    }

    @Test
    fun `ceiling outweighs floor when the two disagree`() {
        // [10000,10000] delivers 10fps; [4000,25000] delivers 25fps despite the closer floor.
        val ranges = listOf(intArrayOf(4000, 25000), intArrayOf(10000, 10000))
        assertArrayEquals(intArrayOf(10000, 10000), CameraFpsPin.chooseRange(ranges, 5f))
    }

    @Test
    fun `returns null when the device reports no ranges`() {
        assertNull(CameraFpsPin.chooseRange(emptyList(), 5f))
    }
}
