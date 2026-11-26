import AppKit
import Carbon.HIToolbox
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

/// Regression coverage for https://github.com/manaflow-ai/cmux/issues/5993:
/// cmux ignored `macos-option-as-alt` left/right and captured Option before
/// character composition.
///
/// libghostty applies `macos-option-as-alt = left|right` (both in
/// `ghostty_surface_key_translation_mods` and in the key encoder's
/// Alt-prefix rules) from the `GHOSTTY_MODS_*_RIGHT` side bits of the mods
/// cmux sends. If cmux maps both physical Option keys to the same generic
/// `GHOSTTY_MODS_ALT`, every Option key looks like the left one: with
/// `= left` the right Option can never compose characters (`…`, `@`, `ą`,
/// `/`), and with `= right` the right Option is never treated as Alt.
@MainActor
@Suite struct GhosttyOptionAsAltModsTests {
    // MARK: NSEvent flags -> libghostty mods side bits

    @Test func rightOptionCarriesAltAndAltRightSideBit() {
        let raw = NSEvent.ModifierFlags.option.rawValue | UInt(NX_DEVICERALTKEYMASK)
        let mods = cmuxGhosttyModsFromFlags(modifierFlagsRawValue: raw)
        #expect(mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0)
        #expect(
            mods.rawValue & GHOSTTY_MODS_ALT_RIGHT.rawValue != 0,
            "right Option must set GHOSTTY_MODS_ALT_RIGHT so macos-option-as-alt = left|right can distinguish sides"
        )
    }

    @Test func leftOptionCarriesAltWithoutAltRightSideBit() {
        let raw = NSEvent.ModifierFlags.option.rawValue | UInt(NX_DEVICELALTKEYMASK)
        let mods = cmuxGhosttyModsFromFlags(modifierFlagsRawValue: raw)
        #expect(mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0)
        #expect(mods.rawValue & GHOSTTY_MODS_ALT_RIGHT.rawValue == 0)
    }

    @Test func rightShiftCarriesShiftRightSideBit() {
        let raw = NSEvent.ModifierFlags.shift.rawValue | UInt(NX_DEVICERSHIFTKEYMASK)
        let mods = cmuxGhosttyModsFromFlags(modifierFlagsRawValue: raw)
        #expect(mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0)
        #expect(mods.rawValue & GHOSTTY_MODS_SHIFT_RIGHT.rawValue != 0)
    }

    @Test func rightControlCarriesCtrlRightSideBit() {
        let raw = NSEvent.ModifierFlags.control.rawValue | UInt(NX_DEVICERCTLKEYMASK)
        let mods = cmuxGhosttyModsFromFlags(modifierFlagsRawValue: raw)
        #expect(mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0)
        #expect(mods.rawValue & GHOSTTY_MODS_CTRL_RIGHT.rawValue != 0)
    }

    @Test func rightCommandCarriesSuperRightSideBit() {
        let raw = NSEvent.ModifierFlags.command.rawValue | UInt(NX_DEVICERCMDKEYMASK)
        let mods = cmuxGhosttyModsFromFlags(modifierFlagsRawValue: raw)
        #expect(mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0)
        #expect(mods.rawValue & GHOSTTY_MODS_SUPER_RIGHT.rawValue != 0)
    }

    @Test func genericModifiersMapWithoutSideBits() {
        let raw = NSEvent.ModifierFlags.shift.rawValue
            | NSEvent.ModifierFlags.control.rawValue
            | NSEvent.ModifierFlags.option.rawValue
            | NSEvent.ModifierFlags.command.rawValue
        let mods = cmuxGhosttyModsFromFlags(modifierFlagsRawValue: raw)
        #expect(mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0)
        #expect(mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0)
        #expect(mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0)
        #expect(mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0)
        #expect(mods.rawValue & GHOSTTY_MODS_SHIFT_RIGHT.rawValue == 0)
        #expect(mods.rawValue & GHOSTTY_MODS_CTRL_RIGHT.rawValue == 0)
        #expect(mods.rawValue & GHOSTTY_MODS_ALT_RIGHT.rawValue == 0)
        #expect(mods.rawValue & GHOSTTY_MODS_SUPER_RIGHT.rawValue == 0)
    }

    @Test func mouseModsNeverCarrySideBits() {
        // libghostty stores only binding modifiers for mouse/link state and
        // compares incoming mods against that stored value; side bits on the
        // mouse path would make every event with a held right-side modifier
        // look like a modifier change and re-dirty the screen.
        let raw = NSEvent.ModifierFlags.option.rawValue
            | NSEvent.ModifierFlags.shift.rawValue
            | UInt(NX_DEVICERALTKEYMASK)
            | UInt(NX_DEVICERSHIFTKEYMASK)
        let mods = cmuxGhosttyMouseModsFromFlags(modifierFlagsRawValue: raw)
        #expect(mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0)
        #expect(mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0)
        #expect(mods.rawValue & GHOSTTY_MODS_ALT_RIGHT.rawValue == 0)
        #expect(mods.rawValue & GHOSTTY_MODS_SHIFT_RIGHT.rawValue == 0)
    }

    @Test func mouseOverLinkActionDecodesURLAndClearsEmptyHover() {
        var bytes = Array("https://example.com/path?q=cmux".utf8CString)
        let decoded = bytes.withUnsafeBufferPointer { buffer in
            GhosttySurfaceScrollView.linkHoverURL(from: ghostty_action_mouse_over_link_s(
                url: buffer.baseAddress,
                len: bytes.count - 1
            ))
        }
        #expect(decoded == "https://example.com/path?q=cmux")
        #expect(GhosttySurfaceScrollView.linkHoverURL(from: ghostty_action_mouse_over_link_s(url: nil, len: 0)) == nil)
    }

    // MARK: libghostty translation mods -> AppKit translation flags

    @Test func translationFlagsDropOptionWhenGhosttyStripsAlt() {
        // macos-option-as-alt stripped Alt for this side: the AppKit
        // character translation must not apply Option (Alt/Meta encoding).
        let translated = cmuxTranslationModifierFlags(
            original: [.option],
            ghosttyTranslationMods: GHOSTTY_MODS_NONE
        )
        #expect(!translated.contains(.option))
    }

    @Test func translationFlagsKeepOptionWhenGhosttyKeepsAlt() {
        // Option on the composing side must stay available to AppKit so
        // Option-composed characters keep working.
        let translated = cmuxTranslationModifierFlags(
            original: [.option, .shift],
            ghosttyTranslationMods: ghostty_input_mods_e(
                rawValue: GHOSTTY_MODS_ALT.rawValue | GHOSTTY_MODS_SHIFT.rawValue
            )
        )
        #expect(translated.contains(.option))
        #expect(translated.contains(.shift))
    }

    @Test func translationFlagsPreserveFlagsGhosttyDoesNotModel() {
        let translated = cmuxTranslationModifierFlags(
            original: [.option, .function, .numericPad],
            ghosttyTranslationMods: GHOSTTY_MODS_NONE
        )
        #expect(translated.contains(.function))
        #expect(translated.contains(.numericPad))
        #expect(!translated.contains(.option))
    }

    // MARK: Option composition per keyboard layout (issue #5993 acceptance)

    @Test func usLayoutOptionSemicolonComposesEllipsis() throws {
        try expectOptionComposes(
            layoutID: "com.apple.keylayout.US",
            keyCode: UInt16(kVK_ANSI_Semicolon),
            expected: "…"
        )
    }

    @Test func germanLayoutOptionLComposesAtSign() throws {
        try expectOptionComposes(
            layoutID: "com.apple.keylayout.German",
            keyCode: UInt16(kVK_ANSI_L),
            expected: "@"
        )
    }

    @Test func polishProLayoutOptionAComposesAOgonek() throws {
        try expectOptionComposes(
            layoutID: "com.apple.keylayout.PolishPro",
            keyCode: UInt16(kVK_ANSI_A),
            expected: "ą"
        )
    }

    @Test func canadianCSALayoutOptionComposesSlash() throws {
        // On Canadian-CSA the key at the ANSI-slash position types "é";
        // Option/AltGr must still produce "/" (issue #5025).
        try expectOptionComposes(
            layoutID: "com.apple.keylayout.Canadian-CSA",
            keyCode: UInt16(kVK_ANSI_Slash),
            expected: "/"
        )
    }

    private func expectOptionComposes(
        layoutID: String,
        keyCode: UInt16,
        expected: String
    ) throws {
        let composed = try #require(
            KeyboardLayout.textInputCharacter(
                forKeyCode: keyCode,
                modifierFlags: .option,
                inputSourceID: layoutID
            ),
            Comment(rawValue: "input source \(layoutID) unavailable or produced no character")
        )
        #expect(
            composed == expected,
            Comment(rawValue: "Option translation on \(layoutID) produced \(composed) instead of \(expected)")
        )
    }
}
