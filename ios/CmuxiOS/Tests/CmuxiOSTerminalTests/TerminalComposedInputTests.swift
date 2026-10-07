import CmuxiOSTerminal
import Testing

/// E4: a composed prompt is one paste (bracketed by Ghostty when the
/// program asked for it) and one Return press and release.
@Suite struct TerminalComposedInputTests {
    @Test func sendIsPasteThenReturn() {
        let actions = TerminalComposedInput(text: "line one\nline two", submits: true).actions
        #expect(actions.count == 3)
        #expect(actions.first == .paste("line one\nline two"))
        guard case .key(let press) = actions[1], case .key(let release) = actions[2] else {
            Issue.record("expected Return press and release")
            return
        }
        #expect(press.keyCode == TerminalHIDUsage.ghosttyKeyCode(TerminalHIDUsage.enter))
        #expect(press.isPress && press.mods.isEmpty)
        #expect(release == press.released)
    }

    @Test func insertOnlyPastes() {
        #expect(TerminalComposedInput(text: "ls", submits: false).actions == [.paste("ls")])
    }
}
