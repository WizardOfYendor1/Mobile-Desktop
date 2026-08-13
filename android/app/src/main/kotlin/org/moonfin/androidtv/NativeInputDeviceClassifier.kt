package org.moonfin.androidtv

import android.util.Log
import android.view.InputDevice
import android.view.KeyEvent

/**
 * What kind of input device Android has handed us.
 *
 * Android exposes no "is this a remote" API -- `InputDevice` has no `isRemote()`,
 * no `SOURCE_REMOTE`, and never uses the word. Classification is therefore an
 * inference from advertised capabilities, anchored on two platform facts:
 *
 *  - [InputDevice.isFullKeyboard] (hidden, so reimplemented here) is defined by
 *    the platform as SOURCE_KEYBOARD plus KEYBOARD_TYPE_ALPHABETIC.
 *  - SOURCE_TOUCH_NAVIGATION is documented as a surface whose swipes act as
 *    D-pad traversal, which in practice means a TV remote touchpad.
 */
internal enum class NativeInputDeviceClass { GAMEPAD, KEYBOARD, REMOTE }

/**
 * The capability snapshot [NativeInputDeviceClassifier] decides from. Kept free
 * of Android types so classification is unit testable without an emulator.
 */
internal data class NativeInputDeviceTraits(
    val isVirtual: Boolean,
    val isExternal: Boolean,
    val hasGamepadSource: Boolean,
    val hasJoystickSource: Boolean,
    val hasKeyboardSource: Boolean,
    val hasDpadSource: Boolean,
    val hasTouchNavigationSource: Boolean,
    val hasJoystickAxis: Boolean,
    val hasAllFaceButtons: Boolean,
    val isAlphabeticKeyboard: Boolean,
)

internal object NativeInputDeviceClassifier {
    /** Null means the device is not an input source this app should route at all. */
    fun classify(traits: NativeInputDeviceTraits): NativeInputDeviceClass? = when {
        traits.isVirtual -> null
        traits.hasJoystickAxis -> NativeInputDeviceClass.GAMEPAD
        // All four face buttons, not any of them. A TV remote commonly reports
        // BUTTON_A for its select key, which is what made the previous
        // `hasKeys(...).any { it }` accept the onn 4K remote as a gamepad.
        // `isExternal` was guarding that over-match and is not needed once the
        // full set is required; keeping it would only reject a real internal pad.
        (traits.hasGamepadSource || traits.hasJoystickSource) && traits.hasAllFaceButtons ->
            NativeInputDeviceClass.GAMEPAD
        traits.hasKeyboardSource && traits.isAlphabeticKeyboard -> NativeInputDeviceClass.KEYBOARD
        // A positive description of a remote -- delivers navigation keys, is
        // neither a confirmed pad nor a full keyboard -- rather than a bucket
        // for whatever fell through. A device claiming only a gamepad source
        // with no axes, no full face-button set and no navigation keys is
        // unidentifiable, so it reaches the null below and is ignored.
        traits.hasTouchNavigationSource || traits.hasDpadSource || traits.hasKeyboardSource ->
            NativeInputDeviceClass.REMOTE
        else -> null
    }

    fun classify(device: InputDevice): NativeInputDeviceClass? = classify(traitsOf(device))

    fun traitsOf(device: InputDevice): NativeInputDeviceTraits {
        val hasJoystickAxis = device.motionRanges.any { range ->
            range.source and InputDevice.SOURCE_JOYSTICK == InputDevice.SOURCE_JOYSTICK
        }
        return NativeInputDeviceTraits(
            isVirtual = device.isVirtual,
            isExternal = device.isExternal,
            hasGamepadSource = device.supportsSource(InputDevice.SOURCE_GAMEPAD),
            hasJoystickSource = device.supportsSource(InputDevice.SOURCE_JOYSTICK),
            hasKeyboardSource = device.supportsSource(InputDevice.SOURCE_KEYBOARD),
            hasDpadSource = device.supportsSource(InputDevice.SOURCE_DPAD),
            hasTouchNavigationSource = device.supportsSource(InputDevice.SOURCE_TOUCH_NAVIGATION),
            hasJoystickAxis = hasJoystickAxis,
            // hasKeys() is a synchronous binder call to system_server. Rule 2
            // already settles the result when an axis is present, so skip the
            // IPC in that case; the value cannot change the outcome.
            hasAllFaceButtons = if (hasJoystickAxis) false else hasAllFaceButtons(device),
            isAlphabeticKeyboard = device.keyboardType == InputDevice.KEYBOARD_TYPE_ALPHABETIC,
        )
    }

    private fun hasAllFaceButtons(device: InputDevice): Boolean = device.hasKeys(
        KeyEvent.KEYCODE_BUTTON_A,
        KeyEvent.KEYCODE_BUTTON_B,
        KeyEvent.KEYCODE_BUTTON_X,
        KeyEvent.KEYCODE_BUTTON_Y,
    ).all { it }

    /**
     * One line per device at session start. The onn 4K remote is believed to be
     * caught by the face-button rule rather than by advertising a joystick axis,
     * but that has not been confirmed on hardware; this makes the answer a
     * single logcat grep instead of a guess.
     *
     * Microphone and Bluetooth address are logged for identification only and
     * never classify -- some gamepads report microphones.
     */
    fun logDiagnostics(device: InputDevice, traits: NativeInputDeviceTraits) {
        val deviceClass = classify(traits)?.name ?: "IGNORED"
        val faceButtons = if (traits.hasJoystickAxis) "skipped" else traits.hasAllFaceButtons.toString()
        Log.i(
            TAG,
            "device=${device.name} vendor=${device.vendorId} product=${device.productId} " +
                "sources=0x${Integer.toHexString(device.sources)} keyboardType=${device.keyboardType} " +
                "gamepad=${traits.hasGamepadSource} joystick=${traits.hasJoystickSource} " +
                "keyboard=${traits.hasKeyboardSource} dpad=${traits.hasDpadSource} " +
                "touchNav=${traits.hasTouchNavigationSource} joystickAxis=${traits.hasJoystickAxis} " +
                "allFaceButtons=$faceButtons alphabetic=${traits.isAlphabeticKeyboard} " +
                "external=${traits.isExternal} mic=${device.hasMicrophone()} -> $deviceClass",
        )
    }

    private const val TAG = "moonfin_input"
}
