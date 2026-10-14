import CoreGraphics
import Testing
@testable import CnxTerminal

/// design/terminal R1-1: one PTY resize after the keyboard settles, for TUIs.
@Suite struct TerminalTUISizingTests {
    let resting: CGFloat = 676, top: CGFloat = 62, cell: CGFloat = 16.4

    private func rows(_ sizing: TerminalTUISizing) -> Int {
        sizing.rows(restingStackTop: resting, chromeTop: top, cellHeight: cell)
    }

    @Test func keyboardDownGivesTheRestingRows() {
        #expect(rows(TerminalTUISizing()) == 37)
    }

    @Test func aTUIShrinksOnceTheKeyboardSettlesAndGrowsBack() {
        var sizing = TerminalTUISizing()
        sizing.tuiStarted()
        // Mid-animation nothing settled: the rows do not follow the frames.
        #expect(rows(sizing) == 37)
        sizing.keyboardSettled(stackTop: 400, restingStackTop: resting, isTUI: true)
        // top's header fits above the composer: (400 - 62) / 16.4 = 20 rows.
        #expect(rows(sizing) == 20)
        sizing.keyboardSettled(stackTop: resting, restingStackTop: resting, isTUI: true)
        #expect(rows(sizing) == 37)
    }

    @Test func aShellKeepsItsRowsWithTheKeyboardUp() {
        var sizing = TerminalTUISizing()
        sizing.keyboardSettled(stackTop: 400, restingStackTop: resting, isTUI: false)
        #expect(rows(sizing) == 37)
        // A TUI started with the keyboard up gets the rows above the composer.
        sizing.tuiStarted()
        #expect(rows(sizing) == 20)
    }

    @Test func theMirrorResetAfterAResizeDoesNotResizeAgain() {
        var sizing = TerminalTUISizing()
        sizing.tuiStarted()
        sizing.keyboardSettled(stackTop: 400, restingStackTop: resting, isTUI: true)
        // The Mac resets the mirror: the alternate screen goes off, then on.
        // Nothing here changes on "off", so the rows stay put (no ping-pong).
        #expect(rows(sizing) == 20)
        sizing.tuiStarted()
        #expect(rows(sizing) == 20)
    }
}
