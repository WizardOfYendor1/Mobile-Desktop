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
            hasDpadKeys = true,
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
        val traits = traits(
            isExternal = true,
            hasGamepadSource = true,
            hasAllFaceButtons = true,
        )

        assertEquals(NativeInputDeviceClass.GAMEPAD, NativeInputDeviceClassifier.classify(traits))
    }

    @Test
    fun `the virtual-search pseudo device is not a gamepad`() {
        // Observed on a Shield: this internal device declares a generic key
        // layout including the face buttons, classified as a GAMEPAD and took
        // Player 3. Requiring all four face buttons was not enough on its own;
        // isExternal is what excludes it.
        val traits = traits(
            isExternal = false,
            hasGamepadSource = true,
            hasKeyboardSource = true,
            hasDpadSource = true,
            hasAllFaceButtons = true,
            hasDpadKeys = true,
        )

        assertNull(NativeInputDeviceClassifier.classify(traits))
    }

    @Test
    fun `a gpio key block is not offered as a remote`() {
        // Observed on a Shield listed as "Menu & navigation - gpio-keys". It is
        // a board-level power/volume key block: keyboard source, but it cannot
        // navigate anything.
        val traits = traits(
            isExternal = false,
            hasKeyboardSource = true,
            hasDpadKeys = false,
        )

        assertNull(NativeInputDeviceClassifier.classify(traits))
    }

    @Test
    fun `an external device that cannot navigate is not a remote`() {
        val traits = traits(
            isExternal = true,
            hasKeyboardSource = true,
            hasDpadKeys = false,
        )

        assertNull(NativeInputDeviceClassifier.classify(traits))
    }

    @Test
    fun `an internal pad with real sticks is still a gamepad`() {
        // The joystick-axis rule runs before the external check, so a built-in
        // pad with analog sticks or hat axes is unaffected by that guard.
        val traits = traits(
            isExternal = false,
            hasGamepadSource = true,
            hasJoystickAxis = true,
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
        val traits = traits(
            isExternal = true,
            hasKeyboardSource = true,
            hasDpadKeys = true,
            isAlphabeticKeyboard = false,
        )

        assertEquals(NativeInputDeviceClass.REMOTE, NativeInputDeviceClassifier.classify(traits))
    }

    @Test
    fun `a touch navigation surface is a remote`() {
        val traits = traits(
            isExternal = true,
            hasTouchNavigationSource = true,
            hasDpadKeys = true,
        )

        assertEquals(NativeInputDeviceClass.REMOTE, NativeInputDeviceClassifier.classify(traits))
    }

    @Test
    fun `a keyboard that also reports every face button is treated as a gamepad`() {
        // Order matters: the gamepad rules run before the keyboard rule, so a
        // pad exposing a keyboard source cannot be demoted to KEYBOARD and lose
        // its automatic port.
        val traits = traits(
            isExternal = true,
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
        hasDpadKeys: Boolean = false,
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
        hasDpadKeys = hasDpadKeys,
        isAlphabeticKeyboard = isAlphabeticKeyboard,
    )
}
