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

    @Test func pinnedToBottomShowsTheLiveScreen() {
        // 1000 rows of 16.8 pt, 40-row grid: the bottom offset lands on the last screen.
        let cell: CGFloat = 16.8
        let maxOffset = CGFloat(1000 - 40) * cell
        let result = TerminalViewportMath.viewportRow(offset: maxOffset, maxOffset: maxOffset, cellHeight: cell,
                                                      totalRows: 1000, gridRows: 40, viewportRows: 40)
        #expect(result.maxRow == 960)
        #expect(result.row == 960)
    }

    @Test func noScrollbackYetIsRowZero() {
        let result = TerminalViewportMath.viewportRow(offset: 0, maxOffset: 0, cellHeight: 16.8, totalRows: 0, gridRows: 40, viewportRows: 0)
        #expect(result.row == 0 && result.maxRow == 0)
    }

    @Test func degenerateCellHeightNeverTraps() {
        let zero = TerminalViewportMath.viewportRow(offset: 500, maxOffset: 900, cellHeight: 0, totalRows: 100, gridRows: 40, viewportRows: 40)
        #expect(zero.row == zero.maxRow)
        let nan = TerminalViewportMath.viewportRow(offset: .nan, maxOffset: 900, cellHeight: 16, totalRows: 100, gridRows: 40, viewportRows: 40)
        #expect(nan.row == nan.maxRow)
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

    @Test func visibleFraction() {
        let visible = CGRect(x: 0, y: 100, width: 440, height: 800)
        #expect(TerminalViewportMath.visibleFraction(of: CGRect(x: 0, y: 200, width: 440, height: 400), in: visible) == 1)
        #expect(TerminalViewportMath.visibleFraction(of: CGRect(x: 0, y: 1000, width: 440, height: 400), in: visible) == 0)
        #expect(TerminalViewportMath.visibleFraction(of: CGRect(x: 0, y: 700, width: 440, height: 400), in: visible) == 0.5)
    }
}
