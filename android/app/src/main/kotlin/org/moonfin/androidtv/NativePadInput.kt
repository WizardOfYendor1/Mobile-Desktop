package org.moonfin.androidtv

import android.content.Context
import android.hardware.input.InputManager
import android.os.Handler
import android.util.SparseArray
import android.view.InputDevice
import android.view.KeyEvent
import android.view.MotionEvent
import org.json.JSONObject

/**
 * Android's direct native-libretro input path. Every assigned connection owns
 * an independent whole-state mask and writes it straight to its libretro port;
 * no event crosses Dart and no controller worker/queue is introduced.
 */
internal class NativePadInput(
    private val bridge: LibretroBridge,
    private val handler: Handler,
    context: Context,
    private val callbacks: Callbacks,
) {
    internal interface Callbacks {
        fun onControllerMappingKey(keyCode: Int, device: Map<String, Any?>)
    }

    private val inputManager = context.getSystemService(Context.INPUT_SERVICE) as? InputManager
    private val registry = NativeControllerPortRegistry()
    private val padStates = SparseArray<PadState>()
    private val maskComposer = NativePortMaskComposer()
    // Android TV remotes and USB keyboards are not controller connections,
    // but historically contributed their D-pad/Enter state to P1. Keep that
    // source independent so it composes with (rather than replaces) P1's pad.
    private val keyboardState = PadState(KEYBOARD_DEVICE_ID, "", 0, DEFAULT_TABLE)

    private var customMappings: Map<String, Map<Int, Int>> = emptyMap()
    private var captureActive = false
    private var captureConnectionId: String? = null

    /** True while a native session is loaded; checked first in dispatch. */
    @Volatile var active = false
        private set

    init {
        inputManager?.registerInputDeviceListener(
            object : InputManager.InputDeviceListener {
                override fun onInputDeviceAdded(deviceId: Int) = onDeviceAdded(deviceId)

                override fun onInputDeviceRemoved(deviceId: Int) = onDeviceRemoved(deviceId)

                override fun onInputDeviceChanged(deviceId: Int) = onDeviceChanged(deviceId)
            },
            null,
        )
        refreshInactiveSnapshot()
    }

    /** Available before gameplay so Dart can load all profile mappings first. */
    fun nativeGamepadDevices(): List<Map<String, Any?>> {
        if (!active) refreshInactiveSnapshot()
        return registry.snapshot().map(NativeControllerConnection::channelPayload)
    }

    fun setActive(value: Boolean) {
        if (active == value) return
        active = value
        clearPadStates(publish = false)
        bridge.resetPadMasks()
        if (value) {
            val connections = registry.activate(discoverCandidates(logDiagnostics = true))
            for (connection in connections) addPadState(connection)
        } else {
            registry.deactivate(discoverCandidates())
        }
        bridge.setControllerCount(if (value) registry.assignedCount() else 0)
    }

    /**
     * Applies the user's durable Player 1-4 assignment. Ports are rebuilt from
     * scratch, so pad state is dropped and masks reset first: a button held
     * across a reassignment must not strand a bit set on the port it left.
     */
    fun setControllerAssignments(json: String) {
        val pins = NativeControllerAssignmentParser.parse(json)
        clearPadStates(publish = active)
        bridge.resetPadMasks()
        val connections = registry.setPins(pins)
        if (!active) return
        for (connection in connections) addPadState(connection)
        bridge.setControllerCount(registry.assignedCount(), force = true)
    }

    fun setControllerMappings(json: String) {
    customMappings = NativeControllerMappingParser.parse(json)
        for (index in 0 until padStates.size()) {
            val state = padStates.valueAt(index)
            state.table = tableFor(state.profileId)
        }
    }

    fun setCapture(active: Boolean, connectionId: String?) {
        captureActive = active
        captureConnectionId = connectionId.takeIf { active }
    }

    /** Returns true when this key was consumed by the native pad path. */
    fun onKey(event: KeyEvent): Boolean {
        val keyCode = event.keyCode
        if (keyCode == KeyEvent.KEYCODE_BACK || isVolumeKey(keyCode)) return false
        if (event.repeatCount != 0) return true

        val connection = registry.connection(event.deviceId)
        // Android TV remotes retain their menu gesture independently of a
        // physical gamepad. An unsupported fifth controller is consumed, but
        // cannot control the running session or overlay.
        if (keyCode == KeyEvent.KEYCODE_MENU ||
            keyCode == KeyEvent.KEYCODE_BUTTON_MODE ||
            keyCode == KeyEvent.KEYCODE_ESCAPE
        ) {
            // A remote or keyboard keeps its menu gesture: it is a navigation
            // source that holds no port, not an overflow pad being ignored.
            if (event.action == KeyEvent.ACTION_DOWN &&
                (connection == null || connection.supported || !connection.isGamepad)
            ) {
                bridge.onMenu(connection?.port ?: 0)
            }
            return true
        }

        // Capture wins over Start and normal dispatch so a physical Start key
        // can be rebound without opening the pause menu. Capture remains
        // available to an unassigned fifth device because it is profile work,
        // not gameplay routing; its normal gameplay events are still consumed.
        if (connection != null && captureActive && event.action == KeyEvent.ACTION_DOWN &&
            (connection.connectionId == captureConnectionId || connection.profileId == captureConnectionId)
        ) {
            captureActive = false
            captureConnectionId = null
            callbacks.onControllerMappingKey(event.keyCode, connection.channelPayload())
            return true
        }

        // Three routes. A device holding a port drives that port. A remote or an
        // unpinned keyboard has no port and keeps feeding the composed Player 1
        // navigation state, which is why it must not be swallowed as "not
        // supported". A gamepad past the fourth is consumed and goes nowhere.
        val state = when {
            connection == null -> keyboardState
            connection.supported -> padStates.get(event.deviceId) ?: return true
            connection.isGamepad -> return true
            else -> keyboardState
        }

        if (keyCode == KeyEvent.KEYCODE_BUTTON_START) {
            handleStart(state, event.action == KeyEvent.ACTION_DOWN)
            return true
        }
        if (event.action != KeyEvent.ACTION_DOWN && event.action != KeyEvent.ACTION_UP) return true

        val index = indexFor(state.table, keyCode)
        when (index) {
            NONE -> return false
            SWALLOW -> return true
            else -> {
                val bit = 1 shl index
                if (event.action == KeyEvent.ACTION_DOWN) {
                    releaseLostHolds(state, index, bit)
                    state.keyMask = state.keyMask or bit
                } else {
                    state.keyMask = state.keyMask and bit.inv()
                }
                publishMask(state)
            }
        }
        return true
    }

    /** Returns true when this motion event was gameplay-shaped and consumed. */
    fun onMotion(event: MotionEvent): Boolean {
        if (event.source and InputDevice.SOURCE_JOYSTICK != InputDevice.SOURCE_JOYSTICK ||
            event.action != MotionEvent.ACTION_MOVE
        ) return false

        val connection = registry.connection(event.deviceId) ?: return false
        // Consume an overflow pad's sticks; let a remote's touch-navigation
        // motion fall through to Flutter's normal focus handling.
        if (!connection.supported) return connection.isGamepad
        val state = padStates.get(event.deviceId) ?: return true
        val hatX = axisDirection(event, MotionEvent.AXIS_HAT_X, MotionEvent.AXIS_X)
        val hatY = axisDirection(event, MotionEvent.AXIS_HAT_Y, MotionEvent.AXIS_Y)
        applyMotionBit(state, RETRO_LEFT, hatX == -1)
        applyMotionBit(state, RETRO_RIGHT, hatX == 1)
        applyMotionBit(state, RETRO_UP, hatY == -1)
        applyMotionBit(state, RETRO_DOWN, hatY == 1)
        applyMotionBit(state, RETRO_L2, event.getAxisValue(MotionEvent.AXIS_LTRIGGER) >= AXIS_THRESHOLD)
        applyMotionBit(state, RETRO_R2, event.getAxisValue(MotionEvent.AXIS_RTRIGGER) >= AXIS_THRESHOLD)
        publishMask(state)
        return true
    }

    private fun onDeviceAdded(deviceId: Int) {
        val candidate = candidateFor(deviceId) ?: return
        val connection = registry.addOrUpdate(candidate)
        if (active && connection.supported && padStates.get(deviceId) == null) addPadState(connection)
        if (active) bridge.setControllerCount(registry.assignedCount(), force = true)
    }

    private fun onDeviceRemoved(deviceId: Int) {
        val connection = registry.remove(deviceId) ?: return
        padStates.get(deviceId)?.let { clearPadState(it, publish = active) }
        padStates.remove(deviceId)
        // No promotion pass here: the registry holds the vacated port open so a
        // sleeping or briefly disconnected pad reclaims it, rather than a spare
        // pad silently inheriting its player number.
        if (captureConnectionId == connection.connectionId) setCapture(false, null)
        if (active) bridge.setControllerCount(registry.assignedCount(), force = true)
    }

    private fun onDeviceChanged(deviceId: Int) {
        val candidate = candidateFor(deviceId) ?: run {
            onDeviceRemoved(deviceId)
            return
        }
        val previous = registry.connection(deviceId)
        val connection = registry.addOrUpdate(candidate)
        if (previous?.profileId != connection.profileId) {
            padStates.get(deviceId)?.let { clearPadState(it, publish = active) }
            padStates.remove(deviceId)
            if (active && connection.supported) addPadState(connection)
        } else {
            padStates.get(deviceId)?.let { state -> state.table = tableFor(connection.profileId) }
        }
        if (active) bridge.setControllerCount(registry.assignedCount(), force = true)
    }

    private fun refreshInactiveSnapshot() {
        registry.refreshInactive(discoverCandidates())
    }

    private fun discoverCandidates(logDiagnostics: Boolean = false): List<NativeControllerCandidate> =
        buildList {
            for (deviceId in InputDevice.getDeviceIds()) {
                candidateFor(deviceId, logDiagnostics)?.let(::add)
            }
        }

    private fun candidateFor(deviceId: Int): NativeControllerCandidate? =
        candidateFor(deviceId, logDiagnostics = false)

    /**
     * Every routable device becomes a candidate, not only gamepads: a remote or
     * keyboard has to reach the snapshot so the assignment UI can show what it
     * is and why it drives Player 1. Eligibility for an actual port is the
     * registry's decision, not this one's.
     */
    private fun candidateFor(deviceId: Int, logDiagnostics: Boolean): NativeControllerCandidate? {
        val device = InputDevice.getDevice(deviceId) ?: return null
        val traits = NativeInputDeviceClassifier.traitsOf(device)
        if (logDiagnostics) NativeInputDeviceClassifier.logDiagnostics(device, traits)
        val deviceClass = NativeInputDeviceClassifier.classify(traits) ?: return null
        val identity = AndroidGamepadIdentity.of(device)
        return NativeControllerCandidate(
            deviceId = deviceId,
            profileId = identity.getValue("id"),
            name = identity.getValue("name"),
            controllerNumber = device.controllerNumber,
            deviceClass = deviceClass,
        )
    }

    private fun addPadState(connection: NativeControllerConnection) {
        val port = connection.port ?: return
        val state = PadState(connection.deviceId, connection.profileId, port, tableFor(connection.profileId))
        padStates.put(connection.deviceId, state)
    }

    private fun clearPadStates(publish: Boolean) {
        for (index in 0 until padStates.size()) clearPadState(padStates.valueAt(index), publish)
        padStates.clear()
        clearPadState(keyboardState, publish)
        maskComposer.reset()
    }

    private fun clearPadState(state: PadState, publish: Boolean) {
        state.startTimer?.let(handler::removeCallbacks)
        state.pulseTimer?.let(handler::removeCallbacks)
        state.startTimer = null
        state.pulseTimer = null
        state.keyMask = 0
        state.motionMask = 0
        state.pulseMask = 0
        state.sentMask = 0
        val combined = updateComposedMask(state)
        if (publish) bridge.onPad(state.port, combined)
    }

    private fun releaseLostHolds(state: PadState, index: Int, bit: Int) {
        val opposite = if (index in OPPOSITE.indices) OPPOSITE[index] else NONE
        if (opposite != NONE) state.keyMask = state.keyMask and (1 shl opposite).inv()
        if (state.keyMask and bit != 0) state.keyMask = state.keyMask and bit.inv()
    }

    private fun applyMotionBit(state: PadState, index: Int, pressed: Boolean) {
        val bit = 1 shl index
        val was = state.motionMask and bit != 0
        if (was != pressed) {
            state.motionMask = if (pressed) state.motionMask or bit else state.motionMask and bit.inv()
        }
    }

    /** One whole-mask JNI write at most for this port when its state changed. */
    private fun publishMask(state: PadState) {
        val desired = state.keyMask or state.motionMask or state.pulseMask
        if (desired == state.sentMask) return
        state.sentMask = desired
        bridge.onPad(state.port, updateComposedMask(state))
    }

    private fun updateComposedMask(state: PadState): Int =
        if (state === keyboardState) maskComposer.setKeyboard(state.sentMask)
        else maskComposer.setController(state.port, state.sentMask)

    private fun handleStart(state: PadState, pressed: Boolean) {
        if (pressed) {
            if (bridge.overlayOpen) {
                state.startConsumed = true
                bridge.onMenu(state.port)
                return
            }
            state.startConsumed = false
            state.startTimer?.let(handler::removeCallbacks)
            val timer = Runnable {
                if (padStates.get(state.deviceId) !== state || !active) return@Runnable
                state.startTimer = null
                state.startConsumed = true
                bridge.onMenu(state.port)
            }
            state.startTimer = timer
            handler.postDelayed(timer, START_HOLD_MS)
            return
        }

        state.startTimer?.let(handler::removeCallbacks)
        state.startTimer = null
        val consumed = state.startConsumed
        state.startConsumed = false
        if (!consumed) pulseStart(state)
    }

    private fun pulseStart(state: PadState) {
        val mapping = indexFor(state.table, KeyEvent.KEYCODE_BUTTON_START)
        val index = mapping.takeIf { it >= 0 } ?: RETRO_START
        val bit = 1 shl index
        state.pulseTimer?.let(handler::removeCallbacks)
        state.pulseMask = state.pulseMask or bit
        publishMask(state)
        val timer = Runnable {
            if (padStates.get(state.deviceId) !== state || !active) return@Runnable
            state.pulseTimer = null
            state.pulseMask = state.pulseMask and bit.inv()
            publishMask(state)
        }
        state.pulseTimer = timer
        handler.postDelayed(timer, START_PULSE_MS)
    }

    private fun tableFor(profileId: String): IntArray {
        val overrides = customMappings[profileId] ?: return DEFAULT_TABLE
        val table = DEFAULT_TABLE.copyOf()
        for ((keyCode, index) in overrides) {
            if (keyCode in 0 until TABLE_SIZE && index in 0..15) table[keyCode] = index
        }
        return table
    }

    private fun indexFor(table: IntArray, keyCode: Int): Int =
        if (keyCode in 0 until TABLE_SIZE) table[keyCode] else NONE

    private fun isVolumeKey(keyCode: Int): Boolean = keyCode == KeyEvent.KEYCODE_VOLUME_UP ||
        keyCode == KeyEvent.KEYCODE_VOLUME_DOWN || keyCode == KeyEvent.KEYCODE_VOLUME_MUTE

    private fun axisDirection(event: MotionEvent, hatAxis: Int, stickAxis: Int): Int =
        direction(event.getAxisValue(hatAxis)).takeIf { it != 0 }
            ?: direction(event.getAxisValue(stickAxis))

    private fun direction(value: Float): Int = when {
        value <= -AXIS_THRESHOLD -> -1
        value >= AXIS_THRESHOLD -> 1
        else -> 0
    }

    private class PadState(
        val deviceId: Int,
        val profileId: String,
        val port: Int,
        var table: IntArray,
        var keyMask: Int = 0,
        var motionMask: Int = 0,
        var pulseMask: Int = 0,
        var sentMask: Int = 0,
        var startTimer: Runnable? = null,
        var pulseTimer: Runnable? = null,
        var startConsumed: Boolean = false,
    )

    private companion object {
        const val AXIS_THRESHOLD = 0.5f
        const val START_HOLD_MS = 1500L
        const val START_PULSE_MS = 34L
        const val KEYBOARD_DEVICE_ID = -1
        const val TABLE_SIZE = 256
        const val NONE = -1
        const val SWALLOW = -2

        const val RETRO_A = 0
        const val RETRO_X = 1
        const val RETRO_SELECT = 2
        const val RETRO_START = 3
        const val RETRO_UP = 4
        const val RETRO_DOWN = 5
        const val RETRO_LEFT = 6
        const val RETRO_RIGHT = 7
        const val RETRO_B = 8
        const val RETRO_Y = 9
        const val RETRO_L1 = 10
        const val RETRO_R1 = 11
        const val RETRO_L2 = 12
        const val RETRO_R2 = 13
        const val RETRO_L3 = 14
        const val RETRO_R3 = 15

        val OPPOSITE = IntArray(16) { NONE }.apply {
            this[RETRO_UP] = RETRO_DOWN
            this[RETRO_DOWN] = RETRO_UP
            this[RETRO_LEFT] = RETRO_RIGHT
            this[RETRO_RIGHT] = RETRO_LEFT
        }

        val SWALLOWED_KEYCODES = intArrayOf(
            KeyEvent.KEYCODE_BUTTON_C, KeyEvent.KEYCODE_BUTTON_Z,
            KeyEvent.KEYCODE_BUTTON_1, KeyEvent.KEYCODE_BUTTON_2,
            KeyEvent.KEYCODE_BUTTON_3, KeyEvent.KEYCODE_BUTTON_4,
            KeyEvent.KEYCODE_BUTTON_5, KeyEvent.KEYCODE_BUTTON_6,
            KeyEvent.KEYCODE_BUTTON_7, KeyEvent.KEYCODE_BUTTON_8,
            KeyEvent.KEYCODE_BUTTON_9, KeyEvent.KEYCODE_BUTTON_10,
            KeyEvent.KEYCODE_BUTTON_11, KeyEvent.KEYCODE_BUTTON_12,
            KeyEvent.KEYCODE_BUTTON_13, KeyEvent.KEYCODE_BUTTON_14,
            KeyEvent.KEYCODE_BUTTON_15, KeyEvent.KEYCODE_BUTTON_16,
        )

        val DEFAULT_TABLE: IntArray = IntArray(TABLE_SIZE) { NONE }.also { table ->
            for (keyCode in SWALLOWED_KEYCODES) if (keyCode in 0 until TABLE_SIZE) table[keyCode] = SWALLOW
            table[KeyEvent.KEYCODE_DPAD_UP] = RETRO_UP
            table[KeyEvent.KEYCODE_DPAD_DOWN] = RETRO_DOWN
            table[KeyEvent.KEYCODE_DPAD_LEFT] = RETRO_LEFT
            table[KeyEvent.KEYCODE_DPAD_RIGHT] = RETRO_RIGHT
            table[KeyEvent.KEYCODE_DPAD_CENTER] = RETRO_A
            table[KeyEvent.KEYCODE_ENTER] = RETRO_A
            table[KeyEvent.KEYCODE_BUTTON_A] = RETRO_A
            table[KeyEvent.KEYCODE_BUTTON_B] = RETRO_B
            table[KeyEvent.KEYCODE_BUTTON_X] = RETRO_X
            table[KeyEvent.KEYCODE_BUTTON_Y] = RETRO_Y
            table[KeyEvent.KEYCODE_BUTTON_SELECT] = RETRO_SELECT
            table[KeyEvent.KEYCODE_BUTTON_L1] = RETRO_L1
            table[KeyEvent.KEYCODE_BUTTON_R1] = RETRO_R1
            table[KeyEvent.KEYCODE_BUTTON_L2] = RETRO_L2
            table[KeyEvent.KEYCODE_BUTTON_R2] = RETRO_R2
            table[KeyEvent.KEYCODE_BUTTON_THUMBL] = RETRO_L3
            table[KeyEvent.KEYCODE_BUTTON_THUMBR] = RETRO_R3
        }
    }
}

/**
 * Reads the durable player assignment payload, `{"players":{"1":"<profileId>"}}`.
 *
 * The wire format counts players from 1 because that is what the user sees;
 * ports count from 0. The conversion happens here and nowhere else, so the rest
 * of the Kotlin and C code keeps thinking purely in ports.
 */
internal object NativeControllerAssignmentParser {
    fun parse(json: String): Map<String, Int> = try {
        val players = JSONObject(json).optJSONObject("players")
        if (players == null) {
            emptyMap()
        } else {
            buildMap {
                val keys = players.keys()
                while (keys.hasNext()) {
                    val key = keys.next()
                    val player = key.toIntOrNull() ?: continue
                    if (player !in 1..NativeControllerPortRegistry.MAX_PORTS) continue
                    val profileId = players.optString(key).takeIf { it.isNotBlank() } ?: continue
                    // One profile cannot hold two players. A payload that says
                    // otherwise is malformed; keep the lowest player rather than
                    // letting iteration order decide.
                    val port = player - 1
                    val existing = this[profileId]
                    if (existing == null || port < existing) put(profileId, port)
                }
            }
        }
    } catch (_: Exception) {
        emptyMap()
    }
}

/** Reads both the legacy flat profile map and the structured mapping payload.
 * Controller-type preferences are deliberately ignored here: they are sent to
 * the libretro bridge separately and must never become gameplay key bindings.
 */
internal object NativeControllerMappingParser {
    fun parse(json: String): Map<String, Map<Int, Int>> = try {
        val root = JSONObject(json)
        buildMap {
            val deviceIds = root.keys()
            while (deviceIds.hasNext()) {
                val deviceId = deviceIds.next()
                val profile = try {
                    root.getJSONObject(deviceId)
                } catch (_: Exception) {
                    continue
                }
                // `bindings` supports the short-lived structured format used
                // during development. Shipping payloads remain flat so older
                // clients still see numeric keycodes and ignore the additive
                // `controllerTypes` metadata key.
                val rawMapping = if (profile.has("bindings")) {
                    try {
                        profile.getJSONObject("bindings")
                    } catch (_: Exception) {
                        null
                    }
                } else {
                    profile
                }
                if (rawMapping == null) continue
                val mapping = mutableMapOf<Int, Int>()
                val keycodes = rawMapping.keys()
                while (keycodes.hasNext()) {
                    val keycodeText = keycodes.next()
                    val keycode = keycodeText.toIntOrNull() ?: continue
                    val button = rawMapping.optInt(keycodeText, -1)
                    if (button in 0..15) mapping[keycode] = button
                }
                put(deviceId, mapping)
            }
        }
    } catch (_: Exception) {
        emptyMap()
    }
}
