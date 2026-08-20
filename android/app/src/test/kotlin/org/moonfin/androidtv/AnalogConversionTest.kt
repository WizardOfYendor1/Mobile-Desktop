package org.moonfin.androidtv

import android.view.MotionEvent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class AnalogConversionTest {
    @Test
    fun `centre reports zero`() {
        assertEquals(packAxes(0, 0), analogAxisPair(0f, 0f))
    }

    @Test
    fun `a value inside the dead zone reports zero`() {
        assertEquals(packAxes(0, 0), analogAxisPair(0.01f, 0f))
        assertEquals(packAxes(0, 0), analogAxisPair(0f, -0.015f))
    }

    @Test
    fun `full deflection reaches the rail`() {
        // Proves the rescale: without it, full deflection would clip at
        // (1 - ANALOG_DEAD_ZONE) * 32767 instead of reaching it.
        assertEquals(packAxes(32767, 0), analogAxisPair(1f, 0f))
    }

    @Test
    fun `full negative deflection reaches the negative rail`() {
        val packed = analogAxisPair(-1f, 0f)
        val x = axisX(packed)
        assertEquals(-32767, x)
    }

    @Test
    fun `just outside the dead zone is a small value, not a jump to full scale`() {
        // The dead zone is 0.02; 0.03 is barely past it, so the rescaled
        // result should be a small fraction of the rail, not near it.
        val packed = analogAxisPair(0.03f, 0f)
        val x = axisX(packed)
        assertTrue("expected a small non-zero value, got $x", x in 1..3000)
    }

    @Test
    fun `a diagonal stays diagonal and does not exceed the rails`() {
        val packed = analogAxisPair(0.707f, 0.707f)
        val x = axisX(packed)
        val y = axisY(packed)
        assertTrue(x > 0)
        assertTrue(y > 0)
        // Roughly equal magnitude on both axes (diagonal preserved).
        assertTrue(Math.abs(x - y) < 200)
        assertTrue(x <= 32767)
        assertTrue(y <= 32767)
    }

    @Test
    fun `trigger at rest reports zero`() {
        assertEquals(0, analogTrigger(0f))
    }

    @Test
    fun `trigger fully pressed reaches 0x7fff`() {
        assertEquals(0x7fff, analogTrigger(1f))
    }

    @Test
    fun `trigger inside the dead zone reports zero`() {
        assertEquals(0, analogTrigger(0.01f))
    }

    @Test
    fun `trigger axis resolution picks BRAKE and GAS when LTRIGGER and RTRIGGER are unused`() {
        val declared = setOf(MotionEvent.AXIS_BRAKE, MotionEvent.AXIS_GAS)
        val axes = TriggerAxisResolver.resolve { it in declared }
        assertEquals(MotionEvent.AXIS_BRAKE, axes.left)
        assertEquals(MotionEvent.AXIS_GAS, axes.right)
    }

    @Test
    fun `trigger axis resolution picks LTRIGGER and RTRIGGER when the device declares those`() {
        val declared = setOf(MotionEvent.AXIS_LTRIGGER, MotionEvent.AXIS_RTRIGGER)
        val axes = TriggerAxisResolver.resolve { it in declared }
        assertEquals(MotionEvent.AXIS_LTRIGGER, axes.left)
        assertEquals(MotionEvent.AXIS_RTRIGGER, axes.right)
    }
}
