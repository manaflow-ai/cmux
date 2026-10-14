import CoreGraphics
import Testing
@testable import CnxTerminal

/// design/terminal R1-1: one PTY resize after the keyboard settles, for TUIs.
@Suite struct TerminalTUISizingTests {
    let resting: CGFloat = 676, top: CGFloat = 62, cell: CGFloat = 16.4

    @Test func keyboardDownGivesTheRestingRows() {
        let sizing = TerminalTUISizing()
        #expect(sizing.rows(isTUI: true, restingStackTop: resting, chromeTop: top, cellHeight: cell) == 37)
    }

    @Test func aTUIShrinksOnceTheKeyboardSettlesAndGrowsBack() {
        var sizing = TerminalTUISizing()
        // Mid-animation nothing settled: the rows do not follow the frames.
        #expect(sizing.rows(isTUI: true, restingStackTop: resting, chromeTop: top, cellHeight: cell) == 37)
        sizing.keyboardSettled(stackTop: 400, restingStackTop: resting)
        // top's header row fits above the composer: (400 - 62) / 16.4 = 20 rows.
        #expect(sizing.rows(isTUI: true, restingStackTop: resting, chromeTop: top, cellHeight: cell) == 20)
        sizing.keyboardSettled(stackTop: resting, restingStackTop: resting)
        #expect(sizing.rows(isTUI: true, restingStackTop: resting, chromeTop: top, cellHeight: cell) == 37)
    }

    @Test func aShellKeepsItsRowsWithTheKeyboardUp() {
        var sizing = TerminalTUISizing()
        sizing.keyboardSettled(stackTop: 400, restingStackTop: resting)
        #expect(sizing.rows(isTUI: false, restingStackTop: resting, chromeTop: top, cellHeight: cell) == 37)
    }
}
