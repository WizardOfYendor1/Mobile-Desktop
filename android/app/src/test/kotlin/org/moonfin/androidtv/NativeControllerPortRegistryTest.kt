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
    fun `a vacated port is held open rather than given to a waiting pad`() {
        val registry = NativeControllerPortRegistry()
        registry.activate((1..5).map { candidate(it, "p$it") })

        registry.remove(2)

        // A wireless pad going to sleep must not surrender its player number to
        // a spare pad that is merely present.
        assertNull(registry.snapshot().single { it.profileId == "p5" }.port)
        assertTrue(registry.snapshot().none { it.port == 1 })
    }

    @Test
    fun `a sleeping pad reclaims its own port on reconnect`() {
        val registry = NativeControllerPortRegistry()
        registry.activate((1..5).map { candidate(it, "p$it") })
        registry.remove(1)

        val returned = registry.addOrUpdate(candidate(1, "p1"))

        assertEquals(0, returned.port)
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

    @Test
    fun `pins place devices on their chosen ports regardless of discovery order`() {
        val registry = NativeControllerPortRegistry()
        registry.setPins(mapOf("eightbitdo" to 0, "xbox" to 1))

        val connections = registry.activate(
            listOf(
                candidate(9, "xbox", controllerNumber = 1),
                candidate(3, "eightbitdo", controllerNumber = 2),
            ),
        )

        assertEquals(0, connections.single { it.profileId == "eightbitdo" }.port)
        assertEquals(1, connections.single { it.profileId == "xbox" }.port)
        assertTrue(connections.all { it.pinned })
    }

    @Test
    fun `a lone pinned player two pad is promoted into player one at session start`() {
        val registry = NativeControllerPortRegistry()
        registry.setPins(mapOf("eightbitdo" to 0, "xbox" to 1))

        val connections = registry.activate(listOf(candidate(9, "xbox")))

        // Promotion is session-only, so the borrowed slot must not read as pinned.
        assertEquals(0, connections.single().port)
        assertFalse(connections.single().pinned)
    }

    @Test
    fun `a pin is honoured again once its device returns`() {
        val registry = NativeControllerPortRegistry()
        registry.setPins(mapOf("eightbitdo" to 0, "xbox" to 1))
        registry.activate(listOf(candidate(9, "xbox")))

        val connections = registry.activate(
            listOf(candidate(9, "xbox"), candidate(3, "eightbitdo")),
        )

        assertEquals(0, connections.single { it.profileId == "eightbitdo" }.port)
        assertEquals(1, connections.single { it.profileId == "xbox" }.port)
    }

    @Test
    fun `identical pinned profiles resolve to the lowest device id`() {
        val registry = NativeControllerPortRegistry()
        registry.setPins(mapOf("shared" to 1))

        val connections = registry.activate(listOf(candidate(8, "shared"), candidate(4, "shared")))

        assertEquals(1, connections.single { it.deviceId == 4 }.port)
        assertEquals(0, connections.single { it.deviceId == 8 }.port)
    }

    @Test
    fun `hot plug fills a vacancy without moving an assigned device`() {
        val registry = NativeControllerPortRegistry()
        registry.activate(listOf(candidate(1, "p1"), candidate(2, "p2")))

        val added = registry.addOrUpdate(candidate(3, "p3"))

        assertEquals(2, added.port)
        assertEquals(0, registry.connection(1)?.port)
        assertEquals(1, registry.connection(2)?.port)
    }

    @Test
    fun `a pinned device arriving mid session does not displace a live player`() {
        val registry = NativeControllerPortRegistry()
        registry.setPins(mapOf("eightbitdo" to 0))
        registry.activate(listOf(candidate(9, "xbox")))

        val late = registry.addOrUpdate(candidate(3, "eightbitdo"))

        assertEquals(0, registry.connection(9)?.port)
        assertEquals(1, late.port)
    }

    @Test
    fun `an unpinned keyboard never takes a port but a pinned one does`() {
        val registry = NativeControllerPortRegistry()

        val unpinned = registry.activate(
            listOf(candidate(1, "pad"), candidate(2, "kbd", NativeInputDeviceClass.KEYBOARD)),
        )
        assertNull(unpinned.single { it.profileId == "kbd" }.port)

        registry.setPins(mapOf("kbd" to 1))
        val pinned = registry.activate(
            listOf(candidate(1, "pad"), candidate(2, "kbd", NativeInputDeviceClass.KEYBOARD)),
        )
        assertEquals(1, pinned.single { it.profileId == "kbd" }.port)
    }

    @Test
    fun `a remote is listed and assignable is false`() {
        val registry = NativeControllerPortRegistry()

        val connections = registry.activate(
            listOf(candidate(1, "pad"), candidate(2, "remote", NativeInputDeviceClass.REMOTE)),
        )

        val remote = connections.single { it.profileId == "remote" }
        assertNull(remote.port)
        assertFalse(remote.assignable)
        assertTrue(connections.single { it.profileId == "pad" }.assignable)
    }

    @Test
    fun `editing pins mid session reassigns immediately`() {
        val registry = NativeControllerPortRegistry()
        registry.activate(listOf(candidate(1, "a"), candidate(2, "b")))

        val connections = registry.setPins(mapOf("b" to 0, "a" to 1))

        assertEquals(0, connections.single { it.profileId == "b" }.port)
        assertEquals(1, connections.single { it.profileId == "a" }.port)
    }

    private fun candidate(
        deviceId: Int,
        profileId: String,
        deviceClass: NativeInputDeviceClass = NativeInputDeviceClass.GAMEPAD,
        controllerNumber: Int = 0,
    ) = NativeControllerCandidate(deviceId, profileId, profileId, controllerNumber, deviceClass)
}
