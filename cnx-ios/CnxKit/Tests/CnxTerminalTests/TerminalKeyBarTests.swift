import CoreGraphics
import Foundation
import Testing
@testable import CnxTerminal

/// SPEC M1: the key bar's ctrl is a real modifier, from the composer too.
@Suite struct TerminalCtrlModifierTests {
    @Test func armedCtrlSendsTheControlKeyAndDisarms() {
        var router = TerminalInputRouter()
        router.tapSticky(.control, at: 10)
        let actions = router.composerKey("c")
        guard case .key(let press)? = actions?.first else {
            Issue.record("ctrl+c from the composer did not become a key event")
            return
        }
        #expect(press.mods.contains(.control))
        #expect(press.text == "c")
        #expect(actions?.count == 2)
        // Armed: one key, then off; the next letter stays in the composer.
        #expect(router.sticky.control == .off)
        #expect(router.composerKey("e") == nil)
    }

    @Test func nothingArmedLeavesTextToTheComposer() {
        var router = TerminalInputRouter()
        #expect(router.composerKey("h") == nil)
    }

    @Test func returnAndPastesStayInTheComposer() {
        var router = TerminalInputRouter()
        router.tapSticky(.control, at: 10)
        #expect(router.composerKey("\n") == nil)
        #expect(router.composerKey("hello") == nil)
        #expect(router.sticky.control != .off)
    }

    @Test func doubleTapLocksUntilTappedAgain() {
        var router = TerminalInputRouter()
        router.tapSticky(.control, at: 10)
        router.tapSticky(.control, at: 10.2)
        #expect(router.sticky.control == .locked)
        _ = router.composerKey("c")
        _ = router.composerKey("d")
        #expect(router.sticky.control == .locked)
        router.tapSticky(.control, at: 12)
        #expect(router.sticky.control == .off)
    }

    @Test func altSendsAnEscapePrefixedKey() {
        var router = TerminalInputRouter()
        router.tapSticky(.alternate, at: 1)
        guard case .key(let press)? = router.composerKey("b")?.first else {
            Issue.record("alt+b did not become a key event")
            return
        }
        #expect(press.mods.contains(.alternate))
        #expect(router.sticky.alternate == .off)
    }
}

/// SPEC B2: ^C is pinned; the scroller fades only where keys continue.
@Suite struct TerminalKeyBarLayoutTests {
    @Test func controlCIsPinnedAndAltScrolls() {
        #expect(KeyBarKey.pinned == [.escape, .control, .chord("c")])
        #expect(!KeyBarKey.middle.contains(.chord("c")))
        #expect(KeyBarKey.middle.contains(.alternate))
        #expect(Array(KeyBarKey.middle.prefix(9)) == [.tab, .shiftTab, .up, .down, .left, .right, .chord("d"), .chord("z"), .chord("l")])
        #expect(KeyBarKey.chord("c").accessibilityLabel == "Control C")
    }

    @Test func leadingEdgeIsHardAtRest() {
        let rest = KeyBarScrollEdges(offset: 0, contentWidth: 900, visibleWidth: 186)
        #expect(!rest.fadesLeading)
        #expect(rest.fadesTrailing)
        let scrolled = KeyBarScrollEdges(offset: 120, contentWidth: 900, visibleWidth: 186)
        #expect(scrolled.fadesLeading)
        #expect(scrolled.fadesTrailing)
        let end = KeyBarScrollEdges(offset: 714, contentWidth: 900, visibleWidth: 186)
        #expect(!end.fadesTrailing)
    }
}
