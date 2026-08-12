package org.moonfin.androidtv

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class NativeControllerPortRegistryTest {
    @Test
    fun `activation orders positive controller numbers before device id`() {
        val registry = NativeControllerPortRegistry()

        val connections = registry.activate(
            listOf(
                candidate(12, "late", controllerNumber = 2),
                candidate(2, "no-number", controllerNumber = 0),
                candidate(7, "first", controllerNumber = 1),
            ),
        )

        assertEquals(listOf("first", "late", "no-number"), connections.map { it.profileId })
        assertEquals(listOf(0, 1, 2), connections.map { it.port })
    }

    @Test
    fun `removed port is reused by a reconnecting profile`() {
        val registry = NativeControllerPortRegistry()
        registry.activate(listOf(candidate(1, "p1"), candidate(2, "p2")))

        val removed = registry.remove(2)
        val reconnect = registry.addOrUpdate(candidate(20, "p2"))

        assertEquals(1, removed?.port)
        assertEquals(1, reconnect.port)
    }

    @Test
    fun `fifth connection remains visible but unsupported`() {
        val registry = NativeControllerPortRegistry()
        val connections = registry.activate((1..5).map { candidate(it, "p$it") })

        assertEquals(4, registry.assignedCount())
        assertNull(connections.single { it.profileId == "p5" }.port)
        assertFalse(connections.single { it.profileId == "p5" }.supported)
    }

    @Test
    fun `unsupported connection claims a port when its owner disconnects`() {
        val registry = NativeControllerPortRegistry()
        registry.activate((1..5).map { candidate(it, "p$it") })

        registry.remove(2)

        val promoted = registry.snapshot().single { it.profileId == "p5" }
        assertEquals(1, promoted.port)
        assertTrue(promoted.supported)
    }

    @Test
    fun `identical profiles retain distinct runtime connections`() {
        val registry = NativeControllerPortRegistry()
        val connections = registry.activate(listOf(candidate(3, "shared"), candidate(4, "shared")))

        assertEquals(listOf("shared", "shared"), connections.map { it.profileId })
        assertEquals(listOf(0, 1), connections.map { it.port })
        assertEquals(2, connections.map { it.connectionId }.toSet().size)
        assertTrue(connections.all { it.supported })
    }

    @Test
    fun `inactive snapshot exposes profiles without gameplay ports`() {
        val registry = NativeControllerPortRegistry()
        val snapshot = registry.refreshInactive(listOf(candidate(5, "profile")))

        assertNull(snapshot.single().port)
        assertFalse(snapshot.single().supported)
    }

    private fun candidate(deviceId: Int, profileId: String, controllerNumber: Int = 0) =
        NativeControllerCandidate(deviceId, profileId, profileId, controllerNumber)
}
