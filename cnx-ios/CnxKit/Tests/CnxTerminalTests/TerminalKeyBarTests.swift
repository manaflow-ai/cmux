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

@Suite struct JoystickAndComposerGeometryTests {
    @Test func theThumbFollowsTheFingerPastTheCircleUpToACap() {
        let geometry = JoystickGeometry()
        #expect(JoystickGeometry.travel == 48)
        // Inside the cap the thumb is under... beside the finger: no scaling.
        #expect(geometry.thumbOffset(for: CGSize(width: 30, height: 0)) == CGSize(width: 30, height: 0))
        // Beyond it, capped along the same direction.
        let capped = geometry.thumbOffset(for: CGSize(width: 60, height: 80))
        #expect(abs(hypot(capped.width, capped.height) - 48) < 0.001)
        #expect(abs(capped.width / capped.height - 0.75) < 0.001)
    }

    @Test func oneLineIsAsTallAsTheCircles() {
        let metrics = ComposerMetrics()
        // SF body at the default size: 20.3 pt lines -> 7 pt insets, 34.3 + 1.7 rounding.
        let inset = metrics.verticalTextInset(lineHeight: 20.29)
        #expect(inset == 7)
        #expect(20.29 + 2 * inset <= ComposerMetrics.circle)
        // Large type never squeezes the text.
        #expect(metrics.verticalTextInset(lineHeight: 40) == 4)
    }
}

/// Codex QA F5: the joystick repeats like a held key.
@Suite struct JoystickRepeatTests {
    let rule = JoystickRepeat()

    @Test func aFlickSendsExactlyOneArrow() {
        #expect(rule.arrows(holding: 0.15, at: 40) == 1)
        #expect(rule.arrows(holding: 0.39, at: 48) == 1)
        #expect(rule.arrows(holding: 0.3, at: 4) == 0)
    }

    @Test func aHoldRepeatsAfter400msAtAboutTenASecond() {
        #expect(rule.rate(distance: 20) == 10)
        // 1.2 s at 30 pt: 1 + 0.8 s x 11.5 = 10 arrows, not ~40.
        #expect(rule.arrows(holding: 1.2, at: 30) <= 10)
        #expect(rule.interval(distance: 20) == .milliseconds(100))
    }

    @Test func theRateRisesGentlyWithDistanceAndIsCapped() {
        #expect(rule.rate(distance: 36) > rule.rate(distance: 24))
        #expect(rule.rate(distance: 48) == JoystickRepeat.fastestRate)
        #expect(rule.rate(distance: 200) == JoystickRepeat.fastestRate)
        #expect(JoystickRepeat.fastestRate <= 20)
    }
}

/// User report 2026-10-14 (resize loop): the PTY's rows are measured against
/// the composer's one-line card, never its transient rows.
@Suite struct ComposerRestingHeightTests {
    @Test func theRestingCardIsOneLineTall() {
        let metrics = ComposerMetrics()
        #expect(metrics.restingCardHeight(lineHeight: 20.29) == 48)
        // Larger text: taller, but still fixed for that size.
        #expect(metrics.restingCardHeight(lineHeight: 40) == 60)
    }
}
