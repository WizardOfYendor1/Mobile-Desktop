package org.moonfin.androidtv

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class NativeInputDeviceClassifierTest {
    @Test
    fun `an android tv remote reporting a single face button is not a gamepad`() {
        // The onn 4K remote shape, and the regression this classifier exists
        // for: the previous rule accepted any external device reporting *any*
        // of A/B/X/Y, and a TV remote commonly reports BUTTON_A for select.
        val traits = traits(
            isExternal = true,
            hasGamepadSource = true,
            hasKeyboardSource = true,
            hasDpadSource = true,
            hasAllFaceButtons = false,
        )

        assertEquals(NativeInputDeviceClass.REMOTE, NativeInputDeviceClassifier.classify(traits))
    }

    @Test
    fun `a pad with joystick axes is a gamepad`() {
        val traits = traits(
            isExternal = true,
            hasGamepadSource = true,
            hasJoystickSource = true,
            hasJoystickAxis = true,
        )

        assertEquals(NativeInputDeviceClass.GAMEPAD, NativeInputDeviceClassifier.classify(traits))
    }

    @Test
    fun `a pad with no axes qualifies on the full face button set`() {
        val traits = traits(hasGamepadSource = true, hasAllFaceButtons = true)

        assertEquals(NativeInputDeviceClass.GAMEPAD, NativeInputDeviceClassifier.classify(traits))
    }

    @Test
    fun `an internal pad is still a gamepad`() {
        // isExternal was dropped from the face-button rule; requiring all four
        // buttons already prevents the over-match it was guarding against, and
        // keeping it would reject a legitimate built-in pad.
        val traits = traits(
            isExternal = false,
            hasGamepadSource = true,
            hasAllFaceButtons = true,
        )

        assertEquals(NativeInputDeviceClass.GAMEPAD, NativeInputDeviceClassifier.classify(traits))
    }

    @Test
    fun `an alphabetic keyboard is a keyboard`() {
        val traits = traits(
            isExternal = true,
            hasKeyboardSource = true,
            isAlphabeticKeyboard = true,
        )

        assertEquals(NativeInputDeviceClass.KEYBOARD, NativeInputDeviceClassifier.classify(traits))
    }

    @Test
    fun `a non alphabetic keyboard source is a remote`() {
        val traits = traits(hasKeyboardSource = true, isAlphabeticKeyboard = false)

        assertEquals(NativeInputDeviceClass.REMOTE, NativeInputDeviceClassifier.classify(traits))
    }

    @Test
    fun `a touch navigation surface is a remote`() {
        val traits = traits(hasTouchNavigationSource = true)

        assertEquals(NativeInputDeviceClass.REMOTE, NativeInputDeviceClassifier.classify(traits))
    }

    @Test
    fun `a keyboard that also reports every face button is treated as a gamepad`() {
        // Order matters: the gamepad rules run before the keyboard rule, so a
        // pad exposing a keyboard source cannot be demoted to KEYBOARD and lose
        // its automatic port.
        val traits = traits(
            hasGamepadSource = true,
            hasKeyboardSource = true,
            hasAllFaceButtons = true,
            isAlphabeticKeyboard = true,
        )

        assertEquals(NativeInputDeviceClass.GAMEPAD, NativeInputDeviceClassifier.classify(traits))
    }

    @Test
    fun `a virtual device is ignored`() {
        val traits = traits(isVirtual = true, hasJoystickAxis = true, hasGamepadSource = true)

        assertNull(NativeInputDeviceClassifier.classify(traits))
    }

    @Test
    fun `a gamepad source with no other evidence is ignored`() {
        // Claims to be a pad but has no axes, no full face-button set and no
        // navigation keys. Unidentifiable, so it is routed nowhere rather than
        // guessed into a class.
        val traits = traits(hasGamepadSource = true)

        assertNull(NativeInputDeviceClassifier.classify(traits))
    }

    private fun traits(
        isVirtual: Boolean = false,
        isExternal: Boolean = false,
        hasGamepadSource: Boolean = false,
        hasJoystickSource: Boolean = false,
        hasKeyboardSource: Boolean = false,
        hasDpadSource: Boolean = false,
        hasTouchNavigationSource: Boolean = false,
        hasJoystickAxis: Boolean = false,
        hasAllFaceButtons: Boolean = false,
        isAlphabeticKeyboard: Boolean = false,
    ) = NativeInputDeviceTraits(
        isVirtual = isVirtual,
        isExternal = isExternal,
        hasGamepadSource = hasGamepadSource,
        hasJoystickSource = hasJoystickSource,
        hasKeyboardSource = hasKeyboardSource,
        hasDpadSource = hasDpadSource,
        hasTouchNavigationSource = hasTouchNavigationSource,
        hasJoystickAxis = hasJoystickAxis,
        hasAllFaceButtons = hasAllFaceButtons,
        isAlphabeticKeyboard = isAlphabeticKeyboard,
    )
}
