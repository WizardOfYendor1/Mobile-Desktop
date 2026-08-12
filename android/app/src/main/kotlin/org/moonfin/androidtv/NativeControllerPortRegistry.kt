package org.moonfin.androidtv

/**
 * Session-local ownership of the four libretro controller ports. This class is
 * deliberately Android-free so its ordering and reconnect behaviour can be
 * unit tested without an emulator. Device discovery remains outside the input
 * dispatch path; [NativePadInput] turns Android InputDevices into candidates
 * only when the device list changes or a native session starts.
 */
internal data class NativeControllerCandidate(
    val deviceId: Int,
    val profileId: String,
    val name: String,
    val controllerNumber: Int,
)

internal data class NativeControllerConnection(
    val deviceId: Int,
    val profileId: String,
    val name: String,
    val port: Int?,
    internal val controllerNumber: Int,
) {
    val connectionId: String get() = "android-connection-$deviceId"
    val supported: Boolean get() = port != null

    fun channelPayload(): Map<String, Any?> = mapOf(
        "id" to profileId,
        "connectionId" to connectionId,
        "name" to name,
        "port" to port,
        "supported" to supported,
    )
}

internal class NativeControllerPortRegistry {
    private val connections = LinkedHashMap<Int, NativeControllerConnection>()
    private val profilePortHints = HashMap<String, Int>()

    private var sessionActive = false

    fun activate(candidates: Collection<NativeControllerCandidate>): List<NativeControllerConnection> {
        sessionActive = true
        connections.clear()
        profilePortHints.clear()
        val ordered = candidates.sortedWith(
            compareBy<NativeControllerCandidate>(
                { if (it.controllerNumber > 0) 0 else 1 },
                { if (it.controllerNumber > 0) it.controllerNumber else Int.MAX_VALUE },
                { it.deviceId },
            ),
        )
        for ((index, candidate) in ordered.withIndex()) {
            val port = index.takeIf { it < MAX_PORTS }
            connections[candidate.deviceId] = candidate.toConnection(port)
            if (port != null) profilePortHints[candidate.profileId] = port
        }
        return snapshot()
    }

    fun deactivate(candidates: Collection<NativeControllerCandidate>): List<NativeControllerConnection> {
        sessionActive = false
        connections.clear()
        profilePortHints.clear()
        for (candidate in candidates) {
            connections[candidate.deviceId] = candidate.toConnection(null)
        }
        return snapshot()
    }

    /** Replaces the inactive discovery snapshot without assigning gameplay ports. */
    fun refreshInactive(candidates: Collection<NativeControllerCandidate>): List<NativeControllerConnection> {
        if (sessionActive) return snapshot()
        connections.clear()
        for (candidate in candidates) {
            connections[candidate.deviceId] = candidate.toConnection(null)
        }
        return snapshot()
    }

    /**
     * Updates one live connection without reassigning existing players. A
     * reconnect first takes its non-exclusive remembered port when free, then
     * the first free port; a fifth device remains present but unsupported.
     */
    fun addOrUpdate(candidate: NativeControllerCandidate): NativeControllerConnection {
        val existing = connections[candidate.deviceId]
        if (existing != null) {
            val updated = candidate.toConnection(existing.port)
            connections[candidate.deviceId] = updated
            updated.port?.let { profilePortHints[candidate.profileId] = it }
            return updated
        }

        val port = if (sessionActive) allocatePort(candidate.profileId) else null
        val connection = candidate.toConnection(port)
        connections[candidate.deviceId] = connection
        if (port != null) profilePortHints[candidate.profileId] = port
        return connection
    }

    fun remove(deviceId: Int): NativeControllerConnection? {
        val removed = connections.remove(deviceId) ?: return null
        val freedPort = removed.port ?: return removed
        if (!sessionActive) return removed
        val promoted = connections.values
            .asSequence()
            .filter { !it.supported }
            .sortedWith(
                compareBy<NativeControllerConnection>(
                    { if (it.controllerNumber > 0) 0 else 1 },
                    { if (it.controllerNumber > 0) it.controllerNumber else Int.MAX_VALUE },
                    { it.deviceId },
                ),
            )
            .firstOrNull()
            ?: return removed
        connections[promoted.deviceId] = promoted.copy(port = freedPort)
        profilePortHints[promoted.profileId] = freedPort
        return removed
    }

    fun connection(deviceId: Int): NativeControllerConnection? = connections[deviceId]

    fun snapshot(): List<NativeControllerConnection> = connections.values.sortedWith(
        compareBy<NativeControllerConnection>({ it.port ?: Int.MAX_VALUE }, { it.name }, { it.deviceId }),
    )

    fun assignedCount(): Int = connections.values.count { it.supported }

    private fun allocatePort(profileId: String): Int? {
        val used = BooleanArray(MAX_PORTS)
        for (connection in connections.values) connection.port?.let { used[it] = true }
        val hint = profilePortHints[profileId]
        if (hint != null && !used[hint]) return hint
        return (0 until MAX_PORTS).firstOrNull { !used[it] }
    }

    private fun NativeControllerCandidate.toConnection(port: Int?): NativeControllerConnection =
        NativeControllerConnection(deviceId, profileId, name, port, controllerNumber)

    companion object {
        const val MAX_PORTS = 4
    }
}

/** Fixed, allocation-free composition of one physical source per port plus P1 keyboard/remote input. */
internal class NativePortMaskComposer {
    private val controllerMasks = IntArray(NativeControllerPortRegistry.MAX_PORTS)
    private var keyboardMask = 0

    fun setController(port: Int, mask: Int): Int {
        require(port in controllerMasks.indices)
        controllerMasks[port] = mask
        return combined(port)
    }

    fun setKeyboard(mask: Int): Int {
        keyboardMask = mask
        return combined(0)
    }

    fun combined(port: Int): Int {
        require(port in controllerMasks.indices)
        return controllerMasks[port] or if (port == 0) keyboardMask else 0
    }

    fun reset() {
        controllerMasks.fill(0)
        keyboardMask = 0
    }
}
