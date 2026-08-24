package org.moonfin.androidtv

import android.view.KeyEvent
import org.junit.Assert.assertEquals
import org.junit.Test

class NativeMappingTablesTest {
    @Test
    fun `default table maps the d-pad and confirm keys`() {
        val table = NativeMappingTables.DEFAULT
        assertEquals(NativeMappingTables.RETRO_UP, table[KeyEvent.KEYCODE_DPAD_UP])
        assertEquals(NativeMappingTables.RETRO_DOWN, table[KeyEvent.KEYCODE_DPAD_DOWN])
        assertEquals(NativeMappingTables.RETRO_LEFT, table[KeyEvent.KEYCODE_DPAD_LEFT])
        assertEquals(NativeMappingTables.RETRO_RIGHT, table[KeyEvent.KEYCODE_DPAD_RIGHT])
        assertEquals(NativeMappingTables.RETRO_A, table[KeyEvent.KEYCODE_DPAD_CENTER])
        assertEquals(NativeMappingTables.RETRO_A, table[KeyEvent.KEYCODE_ENTER])
    }

    @Test
    fun `back, home and volume keys are never bound or swallowed`() {
        val table = NativeMappingTables.DEFAULT
        assertEquals(NativeMappingTables.NONE, table[KeyEvent.KEYCODE_BACK])
        assertEquals(NativeMappingTables.NONE, table[KeyEvent.KEYCODE_HOME])
        assertEquals(NativeMappingTables.NONE, table[KeyEvent.KEYCODE_VOLUME_UP])
        assertEquals(NativeMappingTables.NONE, table[KeyEvent.KEYCODE_VOLUME_DOWN])
        assertEquals(NativeMappingTables.NONE, table[KeyEvent.KEYCODE_VOLUME_MUTE])
    }

    @Test
    fun `media keys are swallowed by default`() {
        val table = NativeMappingTables.DEFAULT
        assertEquals(NativeMappingTables.SWALLOW, table[KeyEvent.KEYCODE_MEDIA_FAST_FORWARD])
        assertEquals(NativeMappingTables.SWALLOW, table[KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE])
    }

    @Test
    fun `a user binding overrides the swallow entry`() {
        val table = NativeMappingTables.custom(
            mapOf(KeyEvent.KEYCODE_MEDIA_FAST_FORWARD to NativeMappingTables.RETRO_L1),
        )
        assertEquals(NativeMappingTables.RETRO_L1, table[KeyEvent.KEYCODE_MEDIA_FAST_FORWARD])
    }

    @Test
    fun `null overrides return the default table identically`() {
        val table = NativeMappingTables.custom(null)
        assertEquals(NativeMappingTables.DEFAULT.toList(), table.toList())
    }

    @Test
    fun `custom never mutates the default table`() {
        NativeMappingTables.custom(mapOf(KeyEvent.KEYCODE_MEDIA_FAST_FORWARD to NativeMappingTables.RETRO_L1))
        assertEquals(NativeMappingTables.SWALLOW, NativeMappingTables.DEFAULT[KeyEvent.KEYCODE_MEDIA_FAST_FORWARD])

        NativeMappingTables.custom(mapOf(KeyEvent.KEYCODE_DPAD_UP to NativeMappingTables.RETRO_B))
        assertEquals(NativeMappingTables.RETRO_UP, NativeMappingTables.DEFAULT[KeyEvent.KEYCODE_DPAD_UP])
    }

    @Test
    fun `out-of-range keycodes and indices in overrides are ignored`() {
        val table = NativeMappingTables.custom(
            mapOf(
                -1 to NativeMappingTables.RETRO_A,
                NativeMappingTables.TABLE_SIZE to NativeMappingTables.RETRO_A,
                KeyEvent.KEYCODE_DPAD_UP to -1,
                KeyEvent.KEYCODE_DPAD_DOWN to 16,
            ),
        )
        assertEquals(NativeMappingTables.RETRO_UP, table[KeyEvent.KEYCODE_DPAD_UP])
        assertEquals(NativeMappingTables.RETRO_DOWN, table[KeyEvent.KEYCODE_DPAD_DOWN])
    }

    @Test
    fun `indexFor returns NONE outside the table's range`() {
        val table = NativeMappingTables.DEFAULT
        assertEquals(NativeMappingTables.NONE, NativeMappingTables.indexFor(table, NativeMappingTables.TABLE_SIZE))
        assertEquals(NativeMappingTables.NONE, NativeMappingTables.indexFor(table, -1))
    }
}
