import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct KeyboardShortcutPlusKeyFallbackTests {
    // Regression for https://github.com/manaflow-ai/cmux/issues/5981.
    // On Spanish-ISO, Latin American, and German layouts the dedicated "+" key
    // sits at the US "]" position (keyCode 30) and types a bare "+". The Cmd-]
    // shortcuts (Forward / Focus Forward) must not claim that event via the ANSI
    // keyCode fallback, or Cmd-"+" navigates forward instead of zooming in.
    @Test func dedicatedPlusKeyIsNotStolenByBracketShortcutsOnNonUSLayout() {
        let plusKeyArgs: (KeyboardShortcutSettings.Action) -> Bool = { action in
            action.defaultShortcut.matches(
                keyCode: 30, // US kVK_ANSI_RightBracket; the dedicated "+" key on ES/DE.
                modifierFlags: [.command],
                eventCharacter: "+",
                layoutCharacterProvider: { _, _ in "+" }
            )
        }

        #expect(
            !plusKeyArgs(.focusHistoryForward),
            "Cmd-\"+\" must not trigger Focus Forward (Cmd-]) on layouts where \"+\" is keyCode 30"
        )
        #expect(
            !plusKeyArgs(.browserForward),
            "Cmd-\"+\" must not trigger browser Forward (Cmd-]) on layouts where \"+\" is keyCode 30"
        )

        #expect(
            plusKeyArgs(.browserZoomIn),
            "Cmd and the dedicated + key should still zoom the browser in"
        )
    }

    // The keyCode fallback must keep working for layouts whose physical "]" key
    // produces a glyph that is not a base shortcut key, such as French/Italian
    // "$" at keyCode 30. There the user has no other way to reach Cmd-].
    @Test func bracketShortcutsStillMatchByKeyCodeWhenGlyphIsNotABaseKey() {
        let dollarKeyArgs: (KeyboardShortcutSettings.Action) -> Bool = { action in
            action.defaultShortcut.matches(
                keyCode: 30,
                modifierFlags: [.command],
                eventCharacter: "$", // French/Italian keyCode 30.
                layoutCharacterProvider: { _, _ in "$" }
            )
        }

        #expect(
            dollarKeyArgs(.focusHistoryForward),
            "Cmd-] (keyCode 30) should still trigger Focus Forward when the glyph is \"$\""
        )
        #expect(
            dollarKeyArgs(.browserForward),
            "Cmd-] (keyCode 30) should still trigger browser Forward when the glyph is \"$\""
        )

        #expect(
            KeyboardShortcutSettings.Action.browserForward.defaultShortcut.matches(
                keyCode: 30,
                modifierFlags: [.command],
                eventCharacter: "]",
                layoutCharacterProvider: { _, _ in "]" }
            ),
            "US Cmd-] should still trigger browser Forward"
        )
    }

    @Test func recordedPhysicalBracketShortcutStillMatchesDedicatedPlusKeyByStoredKeyCode() {
        let recordedShortcut = StoredShortcut(
            key: "]",
            command: true,
            shift: false,
            option: false,
            control: false,
            keyCode: 30
        )

        #expect(
            recordedShortcut.matches(
                keyCode: 30,
                modifierFlags: [.command],
                eventCharacter: "+",
                layoutCharacterProvider: { _, _ in "+" }
            ),
            "A user-recorded physical keyCode shortcut should survive the non-US + glyph guard"
        )
    }

    @Test func recordedCommandShortcutMatchesStoredKeyCodeBeforePrintableFallbackBlock() {
        let recordedShortcut = StoredShortcut(
            key: "n",
            command: true,
            shift: false,
            option: false,
            control: false,
            keyCode: 45
        )

        #expect(
            recordedShortcut.matches(
                keyCode: 45, // US kVK_ANSI_N.
                modifierFlags: [.command],
                eventCharacter: "b",
                layoutCharacterProvider: { _, _ in "b" }
            ),
            "A user-recorded physical keyCode shortcut should survive a different printable command glyph"
        )
    }

    @Test func controlShortcutStillFallsBackByPhysicalKeyCodeOnAlternateAsciiLayout() {
        let controlN = StoredShortcut(
            key: "n",
            command: false,
            shift: false,
            option: false,
            control: true
        )

        #expect(
            controlN.matches(
                keyCode: 45, // US kVK_ANSI_N.
                modifierFlags: [.control],
                eventCharacter: "b",
                layoutCharacterProvider: { _, _ in "b" }
            ),
            "Control shortcuts should keep the longstanding ANSI keyCode fallback on alternate ASCII layouts"
        )
    }
}
