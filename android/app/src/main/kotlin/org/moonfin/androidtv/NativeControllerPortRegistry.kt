package org.moonfin.androidtv

/**
 * Session-local ownership of the four libretro controller ports. This class is
 * deliberately Android-free so its ordering and reconnect behaviour can be
 * unit tested without an emulator. Device discovery remains outside the input
 * dispatch path; [NativePadInput] turns Android InputDevices into candidates
 * only when the device list changes or a native session starts.
 *
 * libretro port N is in-core player N + 1. Ports stay the vocabulary here and
 * in C; only Dart and the UI speak in player numbers.
 *
 * The governing invariant: **a device that holds a port never changes port
 * except by user action.** Ports are computed fresh only in [activate].
 * Mid-session, a connect fills a vacancy; it never rearranges anyone.
 */
internal data class NativeControllerCandidate(
    val deviceId: Int,
    val profileId: String,
    val name: String,
    val controllerNumber: Int,
    val deviceClass: NativeInputDeviceClass,
)

internal data class NativeControllerConnection(
    val deviceId: Int,
    val profileId: String,
    val name: String,
    val port: Int?,
    internal val controllerNumber: Int,
    val deviceClass: NativeInputDeviceClass,
    val pinned: Boolean = false,
) {
    val connectionId: String get() = "android-connection-$deviceId"
    val supported: Boolean get() = port != null
    val isGamepad: Boolean get() = deviceClass == NativeInputDeviceClass.GAMEPAD

    /**
     * Whether the user may give this device a player slot. A keyboard is
     * assignable but is never auto-assigned; a remote is neither.
     */
    val assignable: Boolean get() = deviceClass != NativeInputDeviceClass.REMOTE

    fun channelPayload(): Map<String, Any?> = mapOf(
        "id" to profileId,
        "connectionId" to connectionId,
        "name" to name,
        "port" to port,
        "supported" to supported,
        "deviceClass" to deviceClass.name.lowercase(),
        "assignable" to assignable,
        "pinned" to pinned,
    )
}

internal class NativeControllerPortRegistry {
    private val connections = LinkedHashMap<Int, NativeControllerConnection>()

    /** Session-local reconnect memory for *unpinned* pads only. */
    private val profilePortHints = HashMap<String, Int>()

    /** Durable user assignment: profile id -> port. Supplied from Dart. */
    private var pins: Map<String, Int> = emptyMap()

    private var sessionActive = false

    /**
     * Applies the user's durable player assignment. Mid-session this reallocates
     * immediately, which is deliberate: the only way to reach it is an explicit
     * edit in the assignment UI, and displacement is what the user asked for.
     */
    fun setPins(next: Map<String, Int>): List<NativeControllerConnection> {
        pins = next.filterValues { it in 0 until MAX_PORTS }
        if (!sessionActive) return snapshot()
        return allocate(connections.values.map { it.toCandidate() })
    }

    fun activate(candidates: Collection<NativeControllerCandidate>): List<NativeControllerConnection> {
        sessionActive = true
        profilePortHints.clear()
        return allocate(candidates)
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
     * Updates one live connection without moving any existing player. A new
     * device takes, in order: its pinned port when free, the port it held
     * earlier this session when free, then the lowest free port. A device
     * beyond the fourth stays present but unsupported.
     */
    fun addOrUpdate(candidate: NativeControllerCandidate): NativeControllerConnection {
        val existing = connections[candidate.deviceId]
        if (existing != null) {
            val updated = candidate.toConnection(existing.port)
            connections[candidate.deviceId] = updated
            if (updated.port != null && !updated.pinned) {
                profilePortHints[candidate.profileId] = updated.port
            }
            return updated
        }

        val port = if (sessionActive && isEligible(candidate)) allocatePort(candidate.profileId) else null
        val connection = candidate.toConnection(port)
        connections[candidate.deviceId] = connection
        if (port != null && !connection.pinned) profilePortHints[candidate.profileId] = port
        return connection
    }

    /**
     * Drops a device and **holds its port open**. Handing the port to a waiting
     * fifth pad would mean a controller changed players with no user action --
     * a wireless pad going to sleep would surrender Player 1 and come back as
     * Player 5. The vacancy lets it reclaim its port instead.
     */
    fun remove(deviceId: Int): NativeControllerConnection? = connections.remove(deviceId)

    fun connection(deviceId: Int): NativeControllerConnection? = connections[deviceId]

    fun snapshot(): List<NativeControllerConnection> = connections.values.sortedWith(
        compareBy<NativeControllerConnection>({ it.port ?: Int.MAX_VALUE }, { it.name }, { it.deviceId }),
    )

    fun assignedCount(): Int = connections.values.count { it.supported }

    /**
     * Session-start allocation. Pins first, then fill, then the empty-Player-1
     * guard, then overflow.
     */
    private fun allocate(
        candidates: Collection<NativeControllerCandidate>,
    ): List<NativeControllerConnection> {
        val slots = arrayOfNulls<NativeControllerCandidate>(MAX_PORTS)
        val placed = HashSet<Int>()
        val eligible = candidates.filter(::isEligible)

        // Pass 1 -- pins. Among devices sharing a profile id (identical
        // controllers can report identical descriptors) the lowest deviceId
        // wins: arbitrary, but deterministic and stable for the session.
        for (slot in 0 until MAX_PORTS) {
            val profileId = pins.entries.firstOrNull { it.value == slot }?.key ?: continue
            val match = eligible
                .filter { it.profileId == profileId && it.deviceId !in placed }
                .minByOrNull { it.deviceId }
                ?: continue
            slots[slot] = match
            placed += match.deviceId
        }

        // Pass 2 -- fill the lowest free ports in discovery order.
        for (candidate in eligible.filterNot { it.deviceId in placed }.sortedWith(DISCOVERY_ORDER)) {
            val slot = slots.indexOfFirst { it == null }.takeIf { it >= 0 } ?: break
            slots[slot] = candidate
            placed += candidate.deviceId
        }

        // Pass 3 -- promotion. Every present pad may be pinned past Player 1,
        // leaving port 0 empty; a single-player game reading only port 0 would
        // look dead with no error affordance on a TV. Session-only: the stored
        // pin is untouched, so the pinned pad reclaims Player 1 when it returns.
        if (slots[0] == null) {
            val lowest = (1 until MAX_PORTS).firstOrNull { slots[it] != null }
            if (lowest != null) {
                slots[0] = slots[lowest]
                slots[lowest] = null
            }
        }

        val portByDeviceId = HashMap<Int, Int>()
        for ((slot, candidate) in slots.withIndex()) {
            if (candidate != null) portByDeviceId[candidate.deviceId] = slot
        }

        connections.clear()
        profilePortHints.clear()
        for (candidate in candidates) {
            val port = portByDeviceId[candidate.deviceId]
            val connection = candidate.toConnection(port)
            connections[candidate.deviceId] = connection
            if (port != null && !connection.pinned) profilePortHints[candidate.profileId] = port
        }
        return snapshot()
    }

    /**
     * A gamepad always competes for a port. A keyboard is usually plugged in to
     * type, so it takes one only when the user explicitly pinned it; unpinned,
     * it keeps feeding the composed Player 1 navigation path. A remote never
     * takes one.
     */
    private fun isEligible(candidate: NativeControllerCandidate): Boolean = when (candidate.deviceClass) {
        NativeInputDeviceClass.GAMEPAD -> true
        NativeInputDeviceClass.KEYBOARD -> pins.containsKey(candidate.profileId)
        NativeInputDeviceClass.REMOTE -> false
    }

    private fun allocatePort(profileId: String): Int? {
        val used = BooleanArray(MAX_PORTS)
        for (connection in connections.values) connection.port?.let { used[it] = true }
        val pinned = pins[profileId]
        if (pinned != null && !used[pinned]) return pinned
        val hint = profilePortHints[profileId]
        if (hint != null && !used[hint]) return hint
        return (0 until MAX_PORTS).firstOrNull { !used[it] }
    }

    private fun NativeControllerCandidate.toConnection(port: Int?): NativeControllerConnection =
        NativeControllerConnection(
            deviceId = deviceId,
            profileId = profileId,
            name = name,
            port = port,
            controllerNumber = controllerNumber,
            deviceClass = deviceClass,
            // Pinned means "sitting in the port the user chose", not merely
            // "has a pin somewhere". A pad promoted into Player 1 by pass 3
            // reads as unpinned, so the UI can show the slot as borrowed.
            pinned = port != null && pins[profileId] == port,
        )

    private fun NativeControllerConnection.toCandidate(): NativeControllerCandidate =
        NativeControllerCandidate(deviceId, profileId, name, controllerNumber, deviceClass)

    companion object {
        const val MAX_PORTS = 4

        private val DISCOVERY_ORDER = compareBy<NativeControllerCandidate>(
            { if (it.controllerNumber > 0) 0 else 1 },
            { if (it.controllerNumber > 0) it.controllerNumber else Int.MAX_VALUE },
            { it.deviceId },
        )
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
