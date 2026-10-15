import CoreGraphics
import Testing
@testable import CnxTerminal

/// termqa round 6, VERIFY-round5 V2-3 (eviction) and V5-2.
///
/// At the scrollback cap Ghostty prunes its oldest rows a page at a time:
/// the total drops by hundreds of rows, and a viewport in the scrollback
/// keeps its rows, so its reported top drops by the same count. The phone
/// kept every absolute row it held (the reading anchor, the presented and
/// requested viewport tops, the scroll offset) in the old numbering. A
/// reset then read the mark at the old row number, about 900 rows lower in
/// the text (`reading mark restored row 15047 -> 15047 of 17493`), and a
/// fling over the shorter document ran into its end and followed (V5-2).
@Suite struct TerminalHistoryPruneTests {
    @Test func aPruneUnderAViewportInTheScrollbackIsCounted() {
        // 887 rows pruned, 20 new rows appended meanwhile.
        let rows = TerminalHistoryPrune.prunedRows(previousTotal: 17322, previousOffset: 15000,
                                                   total: 17322 - 887 + 20, offset: 15000 - 887,
                                                   requestedTop: 15000, rows: 150)
        #expect(rows == 887)
    }

    @Test func aRequestOrAClearIsNotAPrune() {
        // Our own request moved the viewport up: the total grew.
        #expect(TerminalHistoryPrune.prunedRows(previousTotal: 17000, previousOffset: 15000, total: 17010, offset: 14900,
                                                requestedTop: 14900, rows: 150) == nil)
        // A request was still in flight (the old report was not the one asked for).
        #expect(TerminalHistoryPrune.prunedRows(previousTotal: 17322, previousOffset: 15000, total: 16455, offset: 14113,
                                                requestedTop: 14200, rows: 150) == nil)
        // `clear` (ESC [3J): the scrollback is gone, nothing to keep.
        #expect(TerminalHistoryPrune.prunedRows(previousTotal: 17322, previousOffset: 15000, total: 150, offset: 0,
                                                requestedTop: 15000, rows: 150) == nil)
        // The viewport fell by more than the history shrank plus nothing: not one count.
        #expect(TerminalHistoryPrune.prunedRows(previousTotal: 17322, previousOffset: 15000, total: 17300, offset: 14000,
                                                requestedTop: 15000, rows: 150) == nil)
    }

    @Test func theReadingAnchorMovesWithThePrune() {
        var model = TerminalScrollModel()
        model.restoreReading(.init(row: 15047, delta: 3))
        model.shiftRows(by: -887)
        #expect(model.state == .reading(.init(row: 14160, delta: 3)))
        var following = TerminalScrollModel()
        following.shiftRows(by: -887)
        #expect(following.isFollowing)
    }

    /// V5-2: a fling up from the live bottom that rests a few rows above it
    /// reads; it is not "a fling into the bottom" (the gesture began there).
    @Test func anUpwardFlingFromTheBottomDoesNotFollow() {
        let cell: CGFloat = 16
        let layout = TerminalDocumentLayout(originRow: 0, endRow: 2000)
        let bottom: CGFloat = 1900 * cell
        var model = TerminalScrollModel()
        model.began()
        model.scrolled(offsetY: bottom, bottomOffsetY: bottom)
        model.scrolled(offsetY: bottom - 2 * cell, bottomOffsetY: bottom)
        model.scrolled(offsetY: bottom - 5 * cell, bottomOffsetY: bottom)
        model.settled(offsetY: bottom - 5 * cell, bottomOffsetY: bottom, layout: layout, rowHeight: cell)
        #expect(model.state == .reading(.init(row: 1895, delta: 0)))
    }

    /// A fling down into the bottom while output streams ends a few rows
    /// short of the newest end: it still follows (the touched-bottom slack).
    @Test func aDownwardFlingIntoTheBottomFollows() {
        let cell: CGFloat = 16
        let layout = TerminalDocumentLayout(originRow: 0, endRow: 2000)
        let bottom: CGFloat = 1900 * cell
        var model = TerminalScrollModel()
        model.restoreReading(.init(row: 1000, delta: 0))
        model.began()
        model.scrolled(offsetY: 1500 * cell, bottomOffsetY: bottom)
        model.scrolled(offsetY: bottom, bottomOffsetY: bottom)
        // The bounce back and the output that grew the end meanwhile.
        model.scrolled(offsetY: bottom + 4, bottomOffsetY: bottom + 6 * cell)
        model.settled(offsetY: bottom, bottomOffsetY: bottom + 6 * cell, layout: layout, rowHeight: cell)
        #expect(model.isFollowing)
    }
}
