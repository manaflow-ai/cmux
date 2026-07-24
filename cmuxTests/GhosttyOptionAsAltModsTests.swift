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

    @Test func optionNUsesGhosttyTranslatedEventWhenAltIsEnabled() throws {
        let view = GhosttyNSView(frame: .zero)
        let original = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.option],
            timestamp: 1,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "n",
            isARepeat: false,
            keyCode: UInt16(kVK_ANSI_N)
        ))
        let translated = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: original.timestamp,
            windowNumber: original.windowNumber,
            context: nil,
            characters: "n",
            charactersIgnoringModifiers: "n",
            isARepeat: false,
            keyCode: original.keyCode
        ))

        let interpreted = view.textInputInterpretationEvent(
            original: original,
            translated: translated
        )

        #expect(!interpreted.modifierFlags.contains(.option))
        #expect(interpreted.characters == "n")
    }

    @Test func unshiftedCodepointRecoversASCIIIdentityForC0ControlEvent() throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.control],
            timestamp: 1,
            windowNumber: 0,
            context: nil,
            characters: "\u{001A}",
            charactersIgnoringModifiers: "с",
            isARepeat: false,
            keyCode: UInt16(kVK_ANSI_C)
        ))

        let codepoint = KeyboardLayout.unshiftedCodepoint(
            for: event,
            controlCharacterProvider: { keyCode, modifiers in
                #expect(keyCode == UInt16(kVK_ANSI_C))
                #expect(modifiers.isEmpty)
                return "c"
            }
        )

        #expect(codepoint == UnicodeScalar("c").value)
    }

    @Test func controlTextRecoveryAcceptsAnyPrintableLayoutResult() throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.control, .shift],
            timestamp: 1,
            windowNumber: 0,
            context: nil,
            characters: "\u{001B}",
            charactersIgnoringModifiers: "x",
            isARepeat: false,
            keyCode: UInt16(kVK_ANSI_X)
        ))

        let recovered = KeyboardLayout.recoveredTextForControlCharacterEvent(
            event,
            appKitCharacterProvider: { candidateEvent, modifiers in
                #expect(candidateEvent === event)
                #expect(modifiers == [.shift])
                return "\u{001B}"
            },
            layoutCharacterProvider: { keyCode, modifiers in
                #expect(keyCode == UInt16(kVK_ANSI_X))
                #expect(modifiers == [.shift])
                return "Ж"
            }
        )

        #expect(recovered == "Ж")
    }

    @Test func controlTextRecoveryPrefersAppKitReinterpretation() throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.control],
            timestamp: 1,
            windowNumber: 0,
            context: nil,
            characters: "\u{0001}",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: UInt16(kVK_ANSI_A)
        ))
        var consultedLayout = false

        let recovered = KeyboardLayout.recoveredTextForControlCharacterEvent(
            event,
            appKitCharacterProvider: { _, modifiers in
                #expect(modifiers.isEmpty)
                return "α"
            },
            layoutCharacterProvider: { _, _ in
                consultedLayout = true
                return "a"
            }
        )

        #expect(recovered == "α")
        #expect(!consultedLayout)
    }

    @Test func controlTextRecoveryDoesNotInventTextForEscape() throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 1,
            windowNumber: 0,
            context: nil,
            characters: "\u{001B}",
            charactersIgnoringModifiers: "\u{001B}",
            isARepeat: false,
            keyCode: UInt16(kVK_Escape)
        ))

        let recovered = KeyboardLayout.recoveredTextForControlCharacterEvent(
            event,
            appKitCharacterProvider: { _, _ in "\u{001B}" },
            layoutCharacterProvider: { _, _ in nil }
        )

        #expect(recovered == nil)
    }

    @Test func unshiftedCodepointUsesProductionKeyboardLayoutResolverForC0ControlEvent() throws {
        let expectedText = try #require(
            KeyboardLayout.character(forKeyCode: UInt16(kVK_ANSI_C))
        )
        let expectedScalar = try #require(expectedText.unicodeScalars.first)
        #expect(expectedText.unicodeScalars.count == 1)
        #expect(expectedScalar.value >= 0x20 && expectedScalar.value < 0x7F)

        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.control],
            timestamp: 1,
            windowNumber: 0,
            context: nil,
            characters: "\u{001A}",
            charactersIgnoringModifiers: "\u{001A}",
            isARepeat: false,
            keyCode: UInt16(kVK_ANSI_C)
        ))

        #expect(
            KeyboardLayout.unshiftedCodepoint(for: event) == expectedScalar.value
        )
    }

    @Test func unshiftedCodepointPreservesAlternateASCIIKeyboardLayout() throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.control],
            timestamp: 1,
            windowNumber: 0,
            context: nil,
            characters: "\u{000C}",
            charactersIgnoringModifiers: "q",
            isARepeat: false,
            keyCode: UInt16(kVK_ANSI_Q)
        ))

        let codepoint = KeyboardLayout.unshiftedCodepoint(
            for: event,
            controlCharacterProvider: { _, _ in "'" }
        )

        #expect(codepoint == UnicodeScalar("'").value)
    }

    @Test func unshiftedCodepointPreservesOrdinaryUnicodeLayoutIdentity() throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 1,
            windowNumber: 0,
            context: nil,
            characters: "с",
            charactersIgnoringModifiers: "с",
            isARepeat: false,
            keyCode: UInt16(kVK_ANSI_C)
        ))
        var normalizedShortcutLayout = false

        let codepoint = KeyboardLayout.unshiftedCodepoint(
            for: event,
            controlCharacterProvider: { _, _ in
                normalizedShortcutLayout = true
                return "c"
            },
            eventCharacterProvider: { _ in "с" }
        )

        #expect(!normalizedShortcutLayout)
        #expect(codepoint == UnicodeScalar("с").value)
    }

    @Test func keyIdentityTrackerPreservesCodepointAcrossRepeatAndRelease() {
        var tracker = KeyboardLayoutKeyIdentityTracker()
        let keyCode = UInt16(kVK_ANSI_C)
        let pressCodepoint = UnicodeScalar("c").value
        let changedLayoutCodepoint = UnicodeScalar("с").value

        #expect(
            tracker.codepointForKeyDown(
                keyCode: keyCode,
                resolvedCodepoint: pressCodepoint,
                isRepeat: false
            ) == pressCodepoint
        )
        #expect(
            tracker.codepointForKeyDown(
                keyCode: keyCode,
                resolvedCodepoint: changedLayoutCodepoint,
                isRepeat: true
            ) == pressCodepoint
        )
        #expect(
            tracker.codepointForKeyUp(keyCode: keyCode) == pressCodepoint
        )
        #expect(tracker.codepointForKeyUp(keyCode: keyCode) == nil)
    }

    @Test func keyIdentityTrackerClearsOnFocusLoss() {
        var tracker = KeyboardLayoutKeyIdentityTracker()
        let keyCode = UInt16(kVK_ANSI_C)

        _ = tracker.codepointForKeyDown(
            keyCode: keyCode,
            resolvedCodepoint: UnicodeScalar("c").value,
            isRepeat: false
        )
        tracker.reset()

        #expect(tracker.codepointForKeyUp(keyCode: keyCode) == nil)
    }

}
