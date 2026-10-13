import Foundation
import Testing
@testable import CmuxNative

struct TerminalReplayTests {
    private func b64(_ text: String) -> JSONValue { .string(Data(text.utf8).base64EncodedString()) }

    @Test func vtStateUsesDataPlusPending() {
        let payload: JSONValue = ["event": "vt-state", "cols": 60, "rows": 40, "data": b64("hello"), "pending": b64("\u{1B}[")]
        #expect(TerminalReplay.bytes(event: "vt-state", payload: payload) == Data("hello\u{1B}[".utf8))
    }

    @Test func resizedPrefersReplayOverData() {
        let payload: JSONValue = ["cols": 60, "rows": 40, "replay": b64("new"), "data": b64("old")]
        #expect(TerminalReplay.bytes(event: "resized", payload: payload) == Data("new".utf8))
    }

    @Test func resizedFallsBackToProtocol6Data() {
        let payload: JSONValue = ["cols": 60, "rows": 40, "data": b64("v6")]
        #expect(TerminalReplay.bytes(event: "resized", payload: payload) == Data("v6".utf8))
    }

    /// A resize with no replay must not start the surface over: the old code
    /// fed RIS alone and blanked the screen until the program redrew.
    @Test func resizedWithoutReplayKeepsTheScreen() {
        let payload: JSONValue = ["cols": 60, "rows": 40, "surface": 14]
        #expect(TerminalReplay.bytes(event: "resized", payload: payload) == nil)
    }

    @Test func emptyReplayStillResets() {
        let payload: JSONValue = ["cols": 60, "rows": 40, "replay": ""]
        #expect(TerminalReplay.bytes(event: "resized", payload: payload) == Data())
    }
}

struct TerminalViewportMathTests {
    @Test func shortGridSitsOnTheComposer() {
        #expect(TerminalViewportMath.topPad(viewHeight: 956, bottomInset: 100, gridHeight: 672) == 184)
        #expect(TerminalViewportMath.topPad(viewHeight: 956, bottomInset: 100, gridHeight: 2000) == 0)
    }

    // 1000 rows of 16 pt, 45-row grid (720 pt), 874 pt view, 92 pt composer:
    // row 0 sits 62 pt down the content (topPad), the status bar is 62 pt.
    private func row(offset: CGFloat, topPad: CGFloat = 62, lead: CGFloat = 62, total: Int = 1000) -> (row: Int, maxRow: Int) {
        TerminalViewportMath.shellViewportRow(offset: offset, cellHeight: 16, topPad: topPad, lead: lead,
                                              visibleBottom: 874 - 92, totalRows: total, gridRows: 45, viewportRows: 45)
    }

    @Test func pinnedToBottomShowsTheLiveScreen() {
        let result = row(offset: CGFloat(955) * 16)
        #expect(result.maxRow == 955)
        #expect(result.row == 955)
        // Rubber-banding past the bottom stays on the live screen.
        #expect(row(offset: CGFloat(955) * 16 + 40).row == 955)
    }

    @Test func scrolledRowsStartBelowTheStatusBar() {
        // Mid scroll with a 6 pt topPad: the first drawn row starts at or
        // below the 62 pt status bar, so the grid reaches under the composer.
        let offset: CGFloat = 4000
        let result = row(offset: offset, topPad: 6)
        let top = 6 + CGFloat(result.row) * 16 - offset
        #expect(top >= 62 && top < 78)
        // Its bottom still covers the content above the composer.
        #expect(top + 720 >= 874 - 92)
    }

    @Test func neverLeavesTheContentAboveTheComposerUndrawn() {
        // A big topPad (another phone sized the grid smaller) and no lead:
        // the content above the composer decides.
        let offset: CGFloat = 4000
        let result = row(offset: offset, topPad: 62, lead: 0)
        #expect(result.row == 250)
        let top = 62 + CGFloat(result.row) * 16 - offset
        #expect(top + 720 >= 874 - 92)
    }

    @Test func noScrollbackYetIsRowZero() {
        let result = row(offset: -54, total: 45)
        #expect(result.row == 0 && result.maxRow == 0)
    }

    @Test func degenerateValuesNeverTrap() {
        let zero = TerminalViewportMath.shellViewportRow(offset: 500, cellHeight: 0, topPad: 0, lead: 0, visibleBottom: 700, totalRows: 100, gridRows: 40, viewportRows: 40)
        #expect(zero.row == zero.maxRow)
        let nan = TerminalViewportMath.shellViewportRow(offset: .nan, cellHeight: 16, topPad: 0, lead: 0, visibleBottom: 700, totalRows: 100, gridRows: 40, viewportRows: 40)
        #expect(nan.row == nan.maxRow)
        let huge = TerminalViewportMath.shellViewportRow(offset: 1e30, cellHeight: 16, topPad: 0, lead: 0, visibleBottom: 700, totalRows: 100, gridRows: 40, viewportRows: 40)
        #expect(huge.row == huge.maxRow)
    }

    @Test func gridKeepsASymmetricSideInset() {
        // 402 pt view, 7.2 pt cells: 394 pt fit 54 columns (388.8), 5.2 pt left over.
        #expect(TerminalViewportMath.gridWidth(viewWidth: 402) == 394)
        let x = TerminalViewportMath.gridOriginX(viewWidth: 402, cols: 54, cellWidth: 7.2)
        #expect(x == 6)
        let right = 402 - (x + 54 * 7.2)
        #expect(right >= TerminalViewportMath.sideInset && abs(right - x) < 7.2)
    }

    @Test func gridWiderThanTheViewStaysAtTheInset() {
        // The Mac's grid can be wider than the phone (another client sized it).
        #expect(TerminalViewportMath.gridOriginX(viewWidth: 402, cols: 120, cellWidth: 7.2) == TerminalViewportMath.sideInset)
        #expect(TerminalViewportMath.gridOriginX(viewWidth: 402, cols: 0, cellWidth: 7.2) == TerminalViewportMath.sideInset)
    }

    @Test func shortScreenRestsBelowTheBar() {
        // After `clear`: 40 blank rows, the screen's top row 4 pt below the
        // screen edge, a 116 pt bar: rest 112 pt up so row 0 clears the bar.
        #expect(TerminalViewportMath.bottomShift(screenTopY: 4, topInset: 116, blankRows: 40, cellHeight: 16.8) == 112)
    }

    @Test func fullScreenKeepsItsLastRowOnTheComposer() {
        // Prompt on the last row (or one blank row for the cursor): no shift,
        // older rows sit under the bar.
        #expect(TerminalViewportMath.bottomShift(screenTopY: 4, topInset: 116, blankRows: 0, cellHeight: 16.8) == 0)
        #expect(TerminalViewportMath.bottomShift(screenTopY: 4, topInset: 116, blankRows: 1, cellHeight: 16.8) == 0)
        // Three blank rows: only two slide under the composer.
        #expect(TerminalViewportMath.bottomShift(screenTopY: 4, topInset: 116, blankRows: 3, cellHeight: 16.8) == 33.6)
    }

    @Test func keyboardUpShiftsFurther() {
        // The shell keeps its grid with the keyboard up, so its top is off screen.
        #expect(TerminalViewportMath.bottomShift(screenTopY: -300, topInset: 116, blankRows: 40, cellHeight: 16.8) == 416)
        #expect(TerminalViewportMath.bottomShift(screenTopY: 200, topInset: 116, blankRows: 40, cellHeight: 16.8) == 0)
        #expect(TerminalViewportMath.bottomShift(screenTopY: 4, topInset: 116, blankRows: 40, cellHeight: 0) == 0)
    }

    @Test func visibleFraction() {
        let visible = CGRect(x: 0, y: 100, width: 440, height: 800)
        #expect(TerminalViewportMath.visibleFraction(of: CGRect(x: 0, y: 200, width: 440, height: 400), in: visible) == 1)
        #expect(TerminalViewportMath.visibleFraction(of: CGRect(x: 0, y: 1000, width: 440, height: 400), in: visible) == 0)
        #expect(TerminalViewportMath.visibleFraction(of: CGRect(x: 0, y: 700, width: 440, height: 400), in: visible) == 0.5)
    }
}
