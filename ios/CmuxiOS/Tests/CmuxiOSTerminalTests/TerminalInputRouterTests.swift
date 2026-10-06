import Testing
@testable import CmuxiOSTerminal

/// The terminal's input routing (plans/cmux-next/ios-keyboard.md T1-T4, KB2).
@Suite struct TerminalInputRouterTests {
    private func key(_ actions: [TerminalInputAction]) -> TerminalKeyEvent? {
        guard case .key(let event)? = actions.first else { return nil }
        return event
    }

    @Test func stickyModifierArmsLocksAndClears() {
        var sticky = TerminalStickyModifiers()
        sticky.tap(.control, at: 10)
        #expect(sticky.isActive(.control))
        #expect(sticky.consume().control)
        #expect(!sticky.isActive(.control), "an armed modifier applies to one key")
        sticky.tap(.control, at: 20)
        sticky.tap(.control, at: 20.2)
        #expect(sticky.state(.control) == .locked)
        _ = sticky.consume()
        #expect(sticky.state(.control) == .locked, "a locked modifier stays")
        sticky.tap(.control, at: 30)
        #expect(sticky.state(.control) == .off)
        sticky.tap(.alternate, at: 40)
        sticky.tap(.alternate, at: 41)
        #expect(sticky.state(.alternate) == .off, "a slow second tap turns it off")
    }

    @Test func hardwareCtrlCGoesToTheEncoderWithThePhysicalKey() {
        var router = TerminalInputRouter()
        guard case .handled(let actions) = router.pressBegan(usage: 0x06, mods: .control, characters: "\u{3}", unmodified: "c")
        else { Issue.record("Ctrl-C was not handled"); return }
        let event = key(actions)
        #expect(event?.keyCode == 0x06, "the HID usage of C goes straight through")
        #expect(event?.mods == .control)
        #expect(event?.text == "c")
        #expect(event?.unshiftedCodepoint == 0x63)
        #expect(router.pressEnded(actions) == [.key(TerminalKeyEvent(keyCode: 0x06, mods: .control, text: nil,
                                                                       unshiftedCodepoint: 0x63, isPress: false))])
    }

    @Test func plainPrintableKeysAndCommandStayWithTheSystem() {
        var router = TerminalInputRouter()
        #expect(router.pressBegan(usage: 0x04, mods: [], characters: "a", unmodified: "a") == .system)
        #expect(router.pressBegan(usage: 0x04, mods: .shift, characters: "A", unmodified: "a") == .system)
        #expect(router.pressBegan(usage: 0x19, mods: .command, characters: "v", unmodified: "v") == .system)
        #expect(router.pressBegan(usage: TerminalHIDUsage.backspace, mods: [], characters: "\u{8}", unmodified: "\u{8}") == .system,
                "plain Backspace repeats through the text system")
    }

    @Test func specialAndAltKeysGoToTheEncoder() {
        var router = TerminalInputRouter()
        guard case .handled(let esc) = router.pressBegan(usage: TerminalHIDUsage.escape, mods: [], characters: "\u{1b}",
                                                         unmodified: "\u{1b}") else { Issue.record("Esc"); return }
        #expect(key(esc) == TerminalKeyEvent(keyCode: 0x29))
        guard case .handled(let alt) = router.pressBegan(usage: 0x1B, mods: .alternate, characters: "≈", unmodified: "x")
        else { Issue.record("Alt-x"); return }
        #expect(key(alt)?.text == "x", "Option as Meta sends the key, not its Option symbol")
        guard case .handled(let f1) = router.pressBegan(usage: 0x3A, mods: [], characters: "", unmodified: "")
        else { Issue.record("F1"); return }
        #expect(key(f1)?.keyCode == 0x3A)
        router.optionAsMeta = false
        #expect(router.pressBegan(usage: 0x1B, mods: .alternate, characters: "≈", unmodified: "x") == .system,
                "without Option as Meta, Option types its symbol")
    }

    @Test func markedTextIsDrawnNeverSentAndCommitsOnce() {
        var router = TerminalInputRouter()
        #expect(router.setMarkedText("にほ") == [.preedit("にほ")])
        #expect(router.pressBegan(usage: 0x28, mods: [], characters: "\r", unmodified: "\r") == .system,
                "keys belong to the input method while it composes")
        #expect(router.setMarkedText("日本") == [.preedit("日本")])
        #expect(router.unmarkText() == [.preedit(""), .text("日本")])
        #expect(router.unmarkText() == [], "a second commit sends nothing")
        #expect(router.setMarkedText(nil) == [.preedit("")])
    }

    @Test func softwareReturnIsEnterAndStickyCtrlAppliesToTheNextKey() {
        var router = TerminalInputRouter()
        #expect(key(router.insertText("\n")) == TerminalKeyEvent(keyCode: 0x28))
        #expect(router.insertText("'") == [.text("'")], "no smart quote: text goes as typed")
        _ = router.keyBar(.control, at: 1)
        let ctrlC = key(router.insertText("c"))
        #expect(ctrlC?.mods == .control)
        #expect(ctrlC?.keyCode == 0x06)
        #expect(ctrlC?.text == "c")
        #expect(router.insertText("c") == [.text("c")], "the sticky Ctrl applied once")
    }

    @Test func keyBarKeys() {
        var router = TerminalInputRouter()
        #expect(key(router.keyBar(.escape, at: 0)) == TerminalKeyEvent(keyCode: 0x29))
        #expect(key(router.keyBar(.up, at: 0)) == TerminalKeyEvent(keyCode: 0x52))
        #expect(router.keyBar(.tilde, at: 0) == [.text("~")])
        _ = router.keyBar(.alternate, at: 5)
        #expect(key(router.keyBar(.left, at: 6))?.mods == .alternate)
        #expect(router.keyBar(.paste, at: 0).isEmpty)
    }

    @Test func keyBarSetting() {
        #expect(TerminalKeyBarKey.keys(fromSetting: nil) == TerminalKeyBarKey.defaultKeys)
        #expect(TerminalKeyBarKey.keys(fromSetting: ["ctrl", "nope", "esc"]) == [.control, .escape])
        #expect(TerminalKeyBarKey.keys(fromSetting: []) == TerminalKeyBarKey.defaultKeys)
    }

    @Test func physicalKeysAreHIDUsages() {
        var router = TerminalInputRouter()
        for usage: UInt16 in [0x04, 0x1D, 0x27, 0x28, 0x29, 0x2C, 0x38, 0x3A, 0x45, 0x4F, 0x52, 0x68] {
            guard case .handled(let actions) = router.pressBegan(usage: usage, mods: .control, characters: "", unmodified: "")
            else { Issue.record("usage \(usage) not handled"); continue }
            #expect(key(actions)?.keyCode == UInt32(usage), "HID usage \(usage) goes straight to Ghostty")
        }
        #expect(TerminalHIDUsage.usage(forASCII: "c") == 0x06)
        #expect(TerminalHIDUsage.usage(forASCII: "0") == 0x27)
        #expect(TerminalHIDUsage.usage(forASCII: "/") == 0x38)
    }
}
