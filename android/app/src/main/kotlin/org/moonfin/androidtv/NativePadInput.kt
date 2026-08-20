package org.moonfin.androidtv

import android.content.Context
import android.hardware.input.InputManager
import android.os.Handler
import android.os.SystemClock
import android.util.SparseArray
import android.view.InputDevice
import android.view.KeyEvent
import android.view.MotionEvent
import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.roundToInt
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
        fun onControllerDiagnosticsAxes(payload: Map<String, Any?>)
        fun onControllerDiagnosticsButton(payload: Map<String, Any?>)
    }

    private val inputManager = context.getSystemService(Context.INPUT_SERVICE) as? InputManager
    private val registry = NativeControllerPortRegistry()
    private val padStates = SparseArray<PadState>()
    private val maskComposer = NativePortMaskComposer()
    // Which axis constants carry trigger pressure, resolved once per device
    // id. See triggerAxesFor and TriggerAxisResolver below.
    private val triggerAxisCache = SparseArray<TriggerAxes>()
    // Remotes/keyboards aren't controller connections but feed P1's D-pad/Enter
    // state; kept independent so it composes with, not replaces, P1's pad.
    private val keyboardState = PadState(KEYBOARD_DEVICE_ID, "", 0, DEFAULT_TABLE)

    private var customMappings: Map<String, Map<Int, Int>> = emptyMap()
    private var captureActive = false
    private var captureConnectionId: String? = null
    private var diagnosticsActive = false
    private var diagnosticsConnectionId: String? = null
    // Throttles axis emissions to ~30Hz (design's "Cost" section); button
    // transitions are rare and always sent immediately.
    private var lastDiagnosticsAxisEmitUptimeMs = 0L

    // Counts publishPadState calls across every port; every ANALOG_POLL_INTERVAL
    // of them, one JNI call re-reads which ports the core has queried
    // RETRO_DEVICE_ANALOG on. Tied to actual analog activity rather than a
    // wall-clock tick: a Handler timer would keep firing (and need explicit
    // start/stop bookkeeping around setActive/dispose) even while no stick is
    // moving, whereas this piggybacks on a call site that already only runs
    // while a pad is live.
    private var analogPollCounter = 0

    /** True while a native session is loaded; checked first in dispatch. */
    @Volatile var active = false
        private set

    // Retained so [dispose] can unregister it. InputManager is process-wide and
    // outlives the Activity, so an unregistered listener keeps this object, the
    // bridge, the callbacks and the Activity reachable for the life of the
    // process -- and the orphan goes on receiving device callbacks.
    private val deviceListener = object : InputManager.InputDeviceListener {
        // Drop the classifier's cache on every device list change.
        override fun onInputDeviceAdded(deviceId: Int) {
            NativeInputDeviceClassifier.invalidate()
            onDeviceAdded(deviceId)
        }

        override fun onInputDeviceRemoved(deviceId: Int) {
            NativeInputDeviceClassifier.invalidate()
            onDeviceRemoved(deviceId)
        }

        override fun onInputDeviceChanged(deviceId: Int) {
            NativeInputDeviceClassifier.invalidate()
            onDeviceChanged(deviceId)
        }
    }

    init {
        inputManager?.registerInputDeviceListener(deviceListener, null)
        refreshInactiveSnapshot()
    }

    /** Releases the process-wide listener. Safe to call more than once. */
    fun dispose() {
        inputManager?.unregisterInputDeviceListener(deviceListener)
        clearPadStates(publish = false)
        triggerAxisCache.clear()
        NativeInputDeviceClassifier.invalidate()
    }

    /**
     * Marks whether the core has queried RETRO_DEVICE_ANALOG on [port] since
     * the last game load. Per the digital/analog rule, this is what gates the
     * stick->d-pad conversion in onMotion off once a core wants the raw
     * axes; the hat keeps feeding digital either way. Defaults to false, so
     * behaviour is unchanged until something calls this.
     */
    fun setCoreReadsAnalog(port: Int, reads: Boolean) {
        for (index in 0 until padStates.size()) {
            val state = padStates.valueAt(index)
            if (state.port != port || state.coreReadsAnalog == reads) continue
            state.coreReadsAnalog = reads
            // The stick stops driving the d-pad from here, so its latched
            // direction must go with it. stickDirX/Y are no longer updated once
            // this is on, so a direction held at the moment of the flip would
            // otherwise stay frozen and keep feeding the hat fallback for ever
            // -- pinning a direction the user cannot clear with the stick, and
            // fighting every new input. Clear the bits it asserted too: a held
            // d-pad re-asserts them on its next event, but nothing else would.
            state.stickDirX = 0
            state.stickDirY = 0
            applyMotionBit(state, RETRO_LEFT, false)
            applyMotionBit(state, RETRO_RIGHT, false)
            applyMotionBit(state, RETRO_UP, false)
            applyMotionBit(state, RETRO_DOWN, false)
            publishMask(state)
        }
    }

    /**
     * Polls [LibretroBridge.analogDescriptorPorts] once and applies its
     * bitmask to every live [PadState] via [setCoreReadsAnalog]. Called from
     * [setActive] shortly after activation and periodically from
     * [publishPadState] (see [analogPollCounter]) rather than per event,
     * since this crosses JNI and the digital/analog rule only needs to react
     * within a handful of frames, not on every single one.
     *
     * The signal is the core's published RETRO_ENVIRONMENT_SET_INPUT_DESCRIPTORS
     * for the current game, not "did the core query RETRO_DEVICE_ANALOG" --
     * that older signal was accurate about what it measured but answered the
     * wrong question, and using it as an analog/digital gate made real games
     * worse:
     *
     *  - FBNeo queries analog for every game, including 4-way ones. BurgerTime
     *    became unplayable: our old digital path ignored sideways drift below
     *    0.40, but FBNeo's own analog->digital conversion uses a far lower
     *    threshold, so a slight lean while climbing produced a diagonal a 4-way
     *    game cannot act on, and the character stopped.
     *  - Stella queries analog for Breakout, where the control is an absolute
     *    paddle; feeding it stick position made it wild.
     *
     * Input descriptors are per-game and authoritative instead: BurgerTime
     * publishes 64 descriptors, all device=JOYPAD, zero analog; Capcom
     * Bowling publishes 48 device=JOYPAD entries plus 8 device=ANALOG entries
     * ('Trackball X'/'Trackball Y'). A port only leaves the d-pad-conversion
     * path when the current game itself describes analog controls for it.
     *
     * Descriptors can arrive a few ms after [LibretroBridge] finishes loading
     * (FBNeo sends them late), which is why [setActive] schedules a delayed
     * refresh instead of relying solely on the periodic one.
     */
    private fun refreshAnalogPorts() {
        val mask = bridge.analogDescriptorPorts()
        for (port in 0 until NativeControllerPortRegistry.MAX_PORTS) {
            setCoreReadsAnalog(port, (mask shr port) and 1 != 0)
        }
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
        analogPollCounter = 0
        if (value) {
            val connections = registry.activate(discoverCandidates(logDiagnostics = true))
            for (connection in connections) addPadState(connection)
            // Input descriptors can arrive a few ms after load returns (FBNeo
            // sends them late), so a single refresh shortly after activation
            // catches them instead of waiting for ANALOG_POLL_INTERVAL
            // publishes, which may not happen for a while if nobody is
            // touching a stick yet.
            handler.postDelayed({ if (active) refreshAnalogPorts() }, ANALOG_POLL_ACTIVATE_DELAY_MS)
        } else {
            registry.deactivate(discoverCandidates())
        }
        bridge.setControllerCount(if (value) registry.assignedCount() else 0)
    }

    /**
     * Applies the user's durable Player 1-4 assignment. Pad state and masks
     * reset first so a held button can't strand a bit on the port it left.
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

    /**
     * Monitor mode for the controller test panel: observation only, never
     * consumes or binds anything. See the design doc's "Placement and
     * lifecycle" invariants -- mirrors [setCapture]'s shape exactly, but
     * [onKey]/[onMotion] fall through to normal handling either way instead
     * of returning early.
     */
    fun setDiagnostics(active: Boolean, connectionId: String?) {
        diagnosticsActive = active
        diagnosticsConnectionId = connectionId.takeIf { active }
        lastDiagnosticsAxisEmitUptimeMs = 0L
    }

    /** Returns true when this key was consumed by the native pad path. */
    fun onKey(event: KeyEvent): Boolean {
        val keyCode = event.keyCode
        if (keyCode == KeyEvent.KEYCODE_BACK || isVolumeKey(keyCode)) return false
        if (event.repeatCount != 0) return true

        val connection = registry.connection(event.deviceId)
        // Observation only: computed before any consuming branch below and
        // never gates a return, so it can never bind or swallow anything.
        emitDiagnosticsButtonIfMatching(connection, event)
        if (keyCode == KeyEvent.KEYCODE_MENU ||
            keyCode == KeyEvent.KEYCODE_BUTTON_MODE ||
            keyCode == KeyEvent.KEYCODE_ESCAPE
        ) {
            // A remote/keyboard keeps its menu gesture (navigation source, no
            // port); an overflow gamepad past the fourth does not.
            if (event.action == KeyEvent.ACTION_DOWN &&
                (connection == null || connection.supported || !connection.isGamepad)
            ) {
                bridge.onMenu(connection?.port ?: 0)
            }
            return true
        }

        // Capture wins over Start/normal dispatch so a physical Start key can
        // be rebound without opening the pause menu; an unassigned fifth
        // device can still be captured since it's profile work, not gameplay.
        if (connection != null && captureActive && event.action == KeyEvent.ACTION_DOWN &&
            matchesCapture(connection)
        ) {
            captureActive = false
            captureConnectionId = null
            callbacks.onControllerMappingKey(event.keyCode, connection.channelPayload())
            return true
        }

        // A device holding a port drives that port. A remote/unpinned keyboard
        // has no port but must still feed Player 1 navigation, not be swallowed
        // as unsupported. A gamepad past the fourth is consumed and goes nowhere.
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
        // Consume an overflow pad's sticks; let remote touch-nav motion fall
        // through to Flutter's normal focus handling.
        if (!connection.supported) return connection.isGamepad
        val state = padStates.get(event.deviceId) ?: return true

        // Every axis is read exactly once: getAxisValue is a native call, and
        // this runs on the UI thread for every motion event of every pad.
        val rawLx = event.getAxisValue(MotionEvent.AXIS_X)
        val rawLy = event.getAxisValue(MotionEvent.AXIS_Y)
        val rawRx = event.getAxisValue(MotionEvent.AXIS_Z)
        val rawRy = event.getAxisValue(MotionEvent.AXIS_RZ)

        // The digital/analog rule: the stick keeps feeding the d-pad
        // conversion only until the core has queried analog on this port;
        // the hat always feeds digital, unconditionally, below.
        if (!state.coreReadsAnalog) {
            state.stickDirX = stickAxisDirection(rawLx, state.stickDirX)
            state.stickDirY = stickAxisDirection(rawLy, state.stickDirY)
        }
        // The hat wins while it is held; the stick supplies the direction the
        // rest of the time (when it is still allowed to, see above).
        val rawHatX = event.getAxisValue(MotionEvent.AXIS_HAT_X)
        val rawHatY = event.getAxisValue(MotionEvent.AXIS_HAT_Y)
        val hatX = hatFallback(direction(rawHatX), state.stickDirX, state.coreReadsAnalog)
        val hatY = hatFallback(direction(rawHatY), state.stickDirY, state.coreReadsAnalog)
        applyMotionBit(state, RETRO_LEFT, hatX == -1)
        applyMotionBit(state, RETRO_RIGHT, hatX == 1)
        applyMotionBit(state, RETRO_UP, hatY == -1)
        applyMotionBit(state, RETRO_DOWN, hatY == 1)

        val triggerAxes = triggerAxesFor(event.deviceId, event.device)
        val leftTrigger = event.getAxisValue(triggerAxes.left)
        val rightTrigger = event.getAxisValue(triggerAxes.right)

        // Triggers arrive as axes, not key events, so without this they could
        // never be bound: arming capture and squeezing one produced nothing.
        // Report a crossing as a synthetic code the mapping layer can store
        // like any other, so a trigger can drive whatever the user chooses.
        if (captureActive && matchesCapture(connection)) {
            val crossed = when {
                leftTrigger >= AXIS_THRESHOLD -> SYNTHETIC_KEYCODE_L2
                rightTrigger >= AXIS_THRESHOLD -> SYNTHETIC_KEYCODE_R2
                else -> null
            }
            if (crossed != null) {
                captureActive = false
                captureConnectionId = null
                callbacks.onControllerMappingKey(crossed, connection!!.channelPayload())
                return true
            }
        }
        applyMotionBit(state, RETRO_L2, leftTrigger >= AXIS_THRESHOLD)
        applyMotionBit(state, RETRO_R2, rightTrigger >= AXIS_THRESHOLD)

        // Packed into a Long rather than a Pair: this is per motion event on
        // every pad, and a Pair would be a heap allocation each time.
        val left = analogAxisPair(rawLx, rawLy)
        val right = analogAxisPair(rawRx, rawRy)
        publishPadState(
            state,
            axisX(left), axisY(left),
            axisX(right), axisY(right),
            analogTrigger(leftTrigger), analogTrigger(rightTrigger),
        )
        // Observation only, after every binding decision above: never gates
        // the `return true` gameplay path takes regardless.
        emitDiagnosticsAxesIfMatching(
            connection, rawLx, rawLy, rawRx, rawRy, rawHatX, rawHatY, leftTrigger, rightTrigger,
        )
        return true
    }

    /**
     * Whether [connection] is the one the test panel is currently watching.
     * Mirrors capture's own connectionId-or-profileId match.
     */
    private fun matchesDiagnostics(connection: NativeControllerConnection?): Boolean =
        connection != null &&
            (connection.connectionId == diagnosticsConnectionId || connection.profileId == diagnosticsConnectionId)

    /**
     * Emits a button transition for the test panel. Invariant 1 (never
     * consumes/binds): called from a point in [onKey] that never gates a
     * return, so this is a pure side effect. Invariant 2 (mutual exclusion
     * with capture): `captureActive` short-circuits this regardless of
     * whether the event actually matched capture's own connection.
     */
    private fun emitDiagnosticsButtonIfMatching(connection: NativeControllerConnection?, event: KeyEvent) {
        if (!diagnosticsActive || captureActive) return
        if (event.action != KeyEvent.ACTION_DOWN && event.action != KeyEvent.ACTION_UP) return
        if (!matchesDiagnostics(connection)) return
        callbacks.onControllerDiagnosticsButton(
            mapOf(
                "connectionId" to connection!!.connectionId,
                "port" to connection.port,
                "keyCode" to event.keyCode,
                "keyName" to KeyEvent.keyCodeToString(event.keyCode),
                "pressed" to (event.action == KeyEvent.ACTION_DOWN),
                // Resolved here rather than in Dart: this table already carries
                // the device's custom binding when it has one and the default
                // layout otherwise, and duplicating that map in Dart would let
                // the two drift.
                "retroPadIndex" to retroPadIndexFor(connection, event.keyCode),
            ),
        )
    }

    /** The RetroPad index [keyCode] maps to for this device, or null. */
    /** Whether [connection] is the device capture is currently armed for. */
    private fun matchesCapture(connection: NativeControllerConnection?): Boolean =
        connection != null &&
            (connection.connectionId == captureConnectionId ||
                connection.profileId == captureConnectionId)

    private fun retroPadIndexFor(connection: NativeControllerConnection, keyCode: Int): Int? {
        val table = padStates.get(connection.deviceId)?.table ?: tableFor(connection.profileId)
        val index = indexFor(table, keyCode)
        return if (index == NONE || index == SWALLOW) null else index
    }

    /**
     * Emits a raw axis snapshot for the test panel, throttled to
     * [DIAGNOSTICS_AXIS_THROTTLE_MS] (~30Hz, per the design's "Cost"
     * section). Values are pre-dead-zone/pre-calibration: the panel shows
     * what the pad reports, not what the core receives. See
     * [emitDiagnosticsButtonIfMatching] for the two invariants, upheld the
     * same way here.
     */
    private fun emitDiagnosticsAxesIfMatching(
        connection: NativeControllerConnection,
        rawLx: Float,
        rawLy: Float,
        rawRx: Float,
        rawRy: Float,
        hatX: Float,
        hatY: Float,
        l2: Float,
        r2: Float,
    ) {
        if (!diagnosticsActive || captureActive) return
        if (!matchesDiagnostics(connection)) return
        val now = SystemClock.uptimeMillis()
        if (now - lastDiagnosticsAxisEmitUptimeMs < DIAGNOSTICS_AXIS_THROTTLE_MS) return
        lastDiagnosticsAxisEmitUptimeMs = now
        callbacks.onControllerDiagnosticsAxes(
            mapOf(
                "connectionId" to connection.connectionId,
                "port" to connection.port,
                "lx" to rawLx.toDouble(),
                "ly" to rawLy.toDouble(),
                "rx" to rawRx.toDouble(),
                "ry" to rawRy.toDouble(),
                "hatX" to hatX.toDouble(),
                "hatY" to hatY.toDouble(),
                "l2" to l2.toDouble(),
                "r2" to r2.toDouble(),
            ),
        )
    }

    /**
     * Resolves and caches, once per device, which axis constants actually
     * carry left/right trigger pressure. Cleared on device removal/change so
     * a replacement device under the same id is re-probed rather than
     * inheriting a stale resolution.
     */
    private fun triggerAxesFor(deviceId: Int, device: InputDevice?): TriggerAxes {
        triggerAxisCache.get(deviceId)?.let { return it }
        val resolved = if (device != null) {
            TriggerAxisResolver.resolve { axis ->
                device.getMotionRange(axis, InputDevice.SOURCE_JOYSTICK) != null
            }
        } else {
            TriggerAxes(MotionEvent.AXIS_LTRIGGER, MotionEvent.AXIS_RTRIGGER)
        }
        triggerAxisCache.put(deviceId, resolved)
        return resolved
    }

    // A pad returning under a new id leaves the old id's bits latched if its
    // removal callback lands after this one. Releases input only; the registry
    // keeps the vacated port for the pad to reclaim.
    private fun releaseVanishedPadStates() {
        for (index in 0 until padStates.size()) {
            val state = padStates.valueAt(index)
            if (InputDevice.getDevice(state.deviceId) == null) clearPadState(state, publish = active)
        }
    }

    private fun onDeviceAdded(deviceId: Int) {
        releaseVanishedPadStates()
        val candidate = candidateFor(deviceId) ?: return
        val connection = registry.addOrUpdate(candidate)
        if (active && connection.supported && padStates.get(deviceId) == null) addPadState(connection)
        if (active) bridge.setControllerCount(registry.assignedCount(), force = true)
    }

    private fun onDeviceRemoved(deviceId: Int) {
        val connection = registry.remove(deviceId) ?: return
        padStates.get(deviceId)?.let { clearPadState(it, publish = active) }
        padStates.remove(deviceId)
        triggerAxisCache.remove(deviceId)
        // No promotion pass here: reallocating would move live players.
        if (captureConnectionId == connection.connectionId) setCapture(false, null)
        if (diagnosticsConnectionId == connection.connectionId) setDiagnostics(false, null)
        if (active) bridge.setControllerCount(registry.assignedCount(), force = true)
    }

    private fun onDeviceChanged(deviceId: Int) {
        val candidate = candidateFor(deviceId) ?: run {
            onDeviceRemoved(deviceId)
            return
        }
        val previous = registry.connection(deviceId)
        val connection = registry.addOrUpdate(candidate)
        // A device can re-enumerate with a different HID descriptor under the
        // same id; re-probe trigger axes rather than trusting a stale cache.
        triggerAxisCache.remove(deviceId)
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
     * Every routable device becomes a candidate, not only gamepads, so a
     * remote/keyboard reaches the assignment UI. Port eligibility is the
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
        state.stickDirX = 0
        state.stickDirY = 0
        state.analogLx = 0
        state.analogLy = 0
        state.analogRx = 0
        state.analogRy = 0
        state.trigL = 0
        state.trigR = 0
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

    /**
     * Analog counterpart of [publishMask]: sends through
     * [LibretroBridge.onPadState] instead of the mask-only path, but only
     * when the mask changed or an analog value moved by more than
     * [ANALOG_SEND_EPSILON], so a resting stick does not cross JNI on every
     * motion event.
     */
    private fun publishPadState(
        state: PadState,
        rawLx: Int,
        rawLy: Int,
        rx: Int,
        ry: Int,
        trigL: Int,
        trigR: Int,
    ) {
        // One physical stick drives one domain, never both. While it is feeding
        // the d-pad, the analog axes it would otherwise report stay centred --
        // otherwise a core that reads both (FBNeo reads analog unconditionally)
        // sees the same lean twice and the two disagree.
        val lx = if (state.coreReadsAnalog) rawLx else 0
        val ly = if (state.coreReadsAnalog) rawLy else 0
        val desiredMask = state.keyMask or state.motionMask or state.pulseMask
        val maskChanged = desiredMask != state.sentMask
        val analogChanged = analogMoved(lx, state.analogLx) || analogMoved(ly, state.analogLy) ||
            analogMoved(rx, state.analogRx) || analogMoved(ry, state.analogRy) ||
            analogMoved(trigL, state.trigL) || analogMoved(trigR, state.trigR)
        state.analogLx = lx
        state.analogLy = ly
        state.analogRx = rx
        state.analogRy = ry
        state.trigL = trigL
        state.trigR = trigR
        if (!maskChanged && !analogChanged) return
        val combined = if (maskChanged) {
            state.sentMask = desiredMask
            updateComposedMask(state)
        } else {
            maskComposer.combined(state.port)
        }
        bridge.onPadState(state.port, combined, lx, ly, rx, ry, trigL, trigR)

        analogPollCounter++
        if (analogPollCounter >= ANALOG_POLL_INTERVAL) {
            analogPollCounter = 0
            refreshAnalogPorts()
        }
    }

    private fun analogMoved(new: Int, old: Int): Boolean = abs(new - old) > ANALOG_SEND_EPSILON

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
        // Latched stick direction, kept per axis so the hysteresis below has a
        // previous value to hold on to. Hat axes are stateless.
        var stickDirX: Int = 0,
        var stickDirY: Int = 0,
        // Last-sent analog state, int16 range (-32768..32767 for axes,
        // 0..0x7fff for triggers). Used both as the value forwarded to
        // lh_set_pad_state and as the baseline analogMoved diffs against.
        var analogLx: Int = 0,
        var analogLy: Int = 0,
        var analogRx: Int = 0,
        var analogRy: Int = 0,
        var trigL: Int = 0,
        var trigR: Int = 0,
        // Set once the host reports the running core queried RETRO_DEVICE_ANALOG
        // on this port; see setCoreReadsAnalog. Resets to false whenever a new
        // PadState is constructed, i.e. every game load.
        var coreReadsAnalog: Boolean = false,
    )

    private companion object {
        const val AXIS_THRESHOLD = 0.5f
        // Well clear of any real Android keycode (KEYCODE_* tops out in the
        // low hundreds), so a stored binding can never collide with one.
        const val SYNTHETIC_KEYCODE_L2 = 0x10012
        const val SYNTHETIC_KEYCODE_R2 = 0x10013
        // ~1/255 in int16 terms (32767/255 ≈ 128): the finest step the pads
        // actually report, per the design doc's measured 8-bit resolution.
        // A resting stick's rounding noise stays under this, a real move does
        // not, so this is what gates crossing JNI on every motion event.
        const val ANALOG_SEND_EPSILON = 128
        // Every 64th publishPadState call re-reads analogDescriptorPorts. Chosen
        // to be cheap even at Gauntlet's measured ~56 ANALOG queries/frame
        // (an unrelated, much hotter path) while still reacting within a
        // fraction of a second of real stick movement.
        const val ANALOG_POLL_INTERVAL = 64
        // Delay before the one-shot refresh in setActive(true); the design
        // doc measured descriptors landing within a comfortable margin of
        // content load, so this just needs to be comfortably after that, not
        // tuned tightly.
        const val ANALOG_POLL_ACTIVATE_DELAY_MS = 500L
        // ~30Hz, per the design's "Cost" section; button transitions bypass
        // this and are always sent immediately since they are rare.
        const val DIAGNOSTICS_AXIS_THROTTLE_MS = 33L
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
 * Converts 1-based players (what the user sees) to 0-based ports here only;
 * the rest of the Kotlin and C code thinks purely in ports.
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
                    // One profile can't hold two players; keep the lowest rather
                    // than let iteration order decide.
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
                // `bindings` supports the structured dev format; shipping
                // payloads stay flat so older clients still work.
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

/**
 * A hat is a switch reporting exactly -1/0/+1, so one trip point suits it. A
 * stick sweeps, so it gets a Schmitt trigger: [STICK_ENGAGE] is low enough that
 * the first half of the travel is not dead, and the direction then holds until
 * the axis falls back past [STICK_RELEASE], so a hand resting near the trip
 * point cannot chatter it on and off.
 *
 * [previous] is this axis's last result; pass 0 when nothing is held.
 */
internal fun stickAxisDirection(value: Float, previous: Int): Int = when {
    value >= STICK_ENGAGE -> 1
    value <= -STICK_ENGAGE -> -1
    previous == 1 && value >= STICK_RELEASE -> 1
    previous == -1 && value <= -STICK_RELEASE -> -1
    else -> 0
}

internal const val STICK_ENGAGE = 0.40f
internal const val STICK_RELEASE = 0.20f

/** Analog dead zone, deliberately minimal: ~5 steps of the 1/255 the pads
 *  actually report, vs the 0.125 they declare. See the design doc. */
internal const val ANALOG_DEAD_ZONE = 0.02f

/**
 * Radial dead zone plus rescale: values inside the dead zone are exactly
 * centre, and everything outside is rescaled so full deflection still reaches
 * the rails instead of clipping short. Returns the pair as packed ints in
 * -32767..32767.
 */
internal fun analogAxisPair(rawX: Float, rawY: Float): Long {
    val magnitude = hypot(rawX, rawY)
    if (magnitude <= ANALOG_DEAD_ZONE || magnitude == 0f) return packAxes(0, 0)
    val scale = ((magnitude - ANALOG_DEAD_ZONE) / (1f - ANALOG_DEAD_ZONE)) / magnitude
    val x = (rawX * scale).coerceIn(-1f, 1f)
    val y = (rawY * scale).coerceIn(-1f, 1f)
    return packAxes((x * 32767f).roundToInt(), (y * 32767f).roundToInt())
}

/**
 * X and Y packed into one Long so the conversion stays allocation-free on the
 * per-motion-event path. A Pair would be a heap object per event per pad, which
 * is real GC pressure on the low-end boxes this runs on.
 */
internal fun packAxes(x: Int, y: Int): Long = (x.toLong() shl 32) or (y.toLong() and 0xffffffffL)
internal fun axisX(packed: Long): Int = (packed shr 32).toInt()
internal fun axisY(packed: Long): Int = packed.toInt()

/** Trigger pressure 0..1 -> 0..0x7fff, with the same dead zone applied. */
internal fun analogTrigger(raw: Float): Int {
    if (raw <= ANALOG_DEAD_ZONE) return 0
    val scale = ((raw - ANALOG_DEAD_ZONE) / (1f - ANALOG_DEAD_ZONE)).coerceIn(0f, 1f)
    return (scale * 0x7fff).roundToInt()
}

/** Which axis constants carry left/right trigger pressure for a device. */
internal data class TriggerAxes(val left: Int, val right: Int)

/**
 * Discovers which axis a device actually carries trigger pressure on, rather
 * than assuming AXIS_LTRIGGER/AXIS_RTRIGGER. Measured 2026-08-20: a Logitech
 * F710 and F310 both *declare* those two axes but never send a changing
 * value on them -- the live values arrive on AXIS_BRAKE/AXIS_GAS instead. See
 * the design doc's "Platform layer" section.
 *
 * [declared] answers "does the device advertise this axis" (backed by
 * `InputDevice.getMotionRange(axis, SOURCE_JOYSTICK) != null` in production);
 * a fake is used in tests. AXIS_Z/AXIS_RZ are included as a last-resort
 * fallback per the design but are excluded here since onMotion always binds
 * them to the right stick.
 */
internal object TriggerAxisResolver {
    private val LEFT_CANDIDATES = intArrayOf(
        MotionEvent.AXIS_LTRIGGER, MotionEvent.AXIS_BRAKE, MotionEvent.AXIS_Z)
    private val RIGHT_CANDIDATES = intArrayOf(
        MotionEvent.AXIS_RTRIGGER, MotionEvent.AXIS_GAS, MotionEvent.AXIS_RZ)
    private val STICK_AXES =
        setOf(MotionEvent.AXIS_X, MotionEvent.AXIS_Y, MotionEvent.AXIS_Z, MotionEvent.AXIS_RZ)

    fun resolve(declared: (Int) -> Boolean): TriggerAxes {
        val left = LEFT_CANDIDATES.firstOrNull { declared(it) && it !in STICK_AXES }
            ?: MotionEvent.AXIS_LTRIGGER
        val right = RIGHT_CANDIDATES.firstOrNull { declared(it) && it !in STICK_AXES }
            ?: MotionEvent.AXIS_RTRIGGER
        return TriggerAxes(left, right)
    }
}

/**
 * The digital direction for one axis: the hat wins whenever it is held, and the
 * stick supplies the direction the rest of the time -- but only while the stick
 * is still allowed to drive digital.
 *
 * Once the core reads analog the stick's latched direction must not leak
 * through here. It stops being updated at that point, so returning it would pin
 * whatever direction was held at the moment the rule engaged, permanently.
 */
internal fun hatFallback(hatDirection: Int, stickDirection: Int, coreReadsAnalog: Boolean): Int =
    when {
        hatDirection != 0 -> hatDirection
        coreReadsAnalog -> 0
        else -> stickDirection
    }
