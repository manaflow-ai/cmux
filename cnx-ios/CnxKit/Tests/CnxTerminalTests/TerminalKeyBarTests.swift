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

    /// R2-4: at rest only whole keys are drawn; the fade is 12 pt.
    @Test func cutKeysAreNotDrawnAtRest() {
        let visible = CGRect(x: 0, y: 0, width: 151, height: 34)
        #expect(KeyBarClipping().isWhole(CGRect(x: 103, y: 0, width: 40, height: 34), in: visible))
        #expect(!KeyBarClipping().isWhole(CGRect(x: 138, y: 0, width: 40, height: 34), in: visible))
        #expect(!KeyBarClipping().isWhole(CGRect(x: -13, y: 0, width: 40, height: 34), in: visible))
        #expect(KeyBarScrollEdges.trailingFade == 12)
    }

    /// R3-5 (round 5): the scroller is a whole number of equal keys, so a
    /// snapped row has no hole and no stretched gap.
    @Test func theScrollerIsAWholeNumberOfKeys() {
        let layout = KeyBarLayout()
        #expect(layout.visibleKeys(available: 151) == 3)
        #expect(layout.scrollerWidth(available: 151) == CGFloat(3 * 44 + 2 * 6))
        #expect(layout.scrollerWidth(available: 200) == CGFloat(4 * 44 + 3 * 6))
        // Any snapped offset (a multiple of key + gap) ends on a key's edge.
        let width = layout.scrollerWidth(available: 151)
        for index in 0..<10 {
            let offset = CGFloat(index) * (KeyBarLayout.keyWidth + KeyBarLayout.spacing)
            let lastEnd = offset + width
            #expect((lastEnd + KeyBarLayout.spacing).truncatingRemainder(dividingBy: KeyBarLayout.keyWidth + KeyBarLayout.spacing) == 0)
        }
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

/// SPEC M4: one key bar rule.
@Suite struct KeyBarVisibilityTests {
    @Test func hiddenAtRest() {
        #expect(KeyBarVisibility().mode == .hidden)
        var rule = KeyBarVisibility()
        rule.keyboardWillShow(visibleHeight: 336)
        #expect(rule.mode == .hidden)
    }

    @Test func ridesTheSoftKeyboardWhileFocused() {
        var rule = KeyBarVisibility(inputFocused: true)
        rule.keyboardWillShow(visibleHeight: 336)
        #expect(rule.mode == .followsKeyboard)
        // Interactive dismissal: still clipped to the keyboard until it is gone.
        rule.keyboardWillHide()
        #expect(rule.mode == .followsKeyboard)
        rule.inputFocused = false
        rule.keyboardDidHide()
        #expect(rule.mode == .hidden)
    }

    @Test func pinnedWithAHardwareKeyboard() {
        var rule = KeyBarVisibility(inputFocused: true)
        // A hardware keyboard: no soft keyboard, or a 44 pt bar-sized frame.
        #expect(rule.mode == .pinned)
        rule.keyboardWillShow(visibleHeight: 44)
        #expect(rule.mode == .pinned)
        // The soft keyboard went away but focus stayed (keyboard connected).
        rule.keyboardWillShow(visibleHeight: 336)
        rule.keyboardWillHide()
        rule.keyboardDidHide()
        #expect(rule.mode == .pinned)
    }
}
