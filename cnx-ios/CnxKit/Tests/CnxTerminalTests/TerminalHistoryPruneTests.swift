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

    /// VERIFY-round8 claim 1b (T-FOLLOW-04): following at the cap, Ghostty
    /// pruned 886 rows (17739 -> 16853 + new rows) with its viewport on the
    /// active area before and after. No prune was counted, so the frame on
    /// screen kept its top in the old numbering while the document shrank
    /// under it: the page showed rows the frame did not cover, one black frame.
    /// The rows the frame on screen moves up by are the total's shrink.
    @Test func aPruneUnderTheFollowedBottomIsCounted() {
        let rows = 151
        // 886 rows pruned, 12 appended meanwhile; the request is stale (following).
        let total = 17739 - 886 + 12
        #expect(TerminalHistoryPrune.prunedRows(previousTotal: 17739, previousOffset: 17739 - rows,
                                                total: total, offset: total - rows,
                                                requestedTop: 17500, rows: rows) == 874)
        // Following, output only: the total grew.
        #expect(TerminalHistoryPrune.prunedRows(previousTotal: 17739, previousOffset: 17739 - rows,
                                                total: 17750, offset: 17750 - rows, requestedTop: 17500, rows: rows) == nil)
        // Following, `clear`: the history is gone, nothing to keep.
        #expect(TerminalHistoryPrune.prunedRows(previousTotal: 17739, previousOffset: 17739 - rows,
                                                total: rows, offset: 0, requestedTop: 17500, rows: rows) == nil)
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

/// VERIFY-round5 V5-1 (Jump to bottom tap): the offset moved to the live end
/// at once, while the surface still showed the scrollback rows it had: the
/// page was black for a frame until Ghostty presented the end. A move whose
/// visible rows the presented frame does not cover now waits for the frame
/// that does (like following output).
@Suite struct TerminalFrameCoverTests {
    @Test func aJumpOutsideThePresentedRowsWaitsForItsFrame() {
        // Presented rows 1000..<1150; the end's visible rows 16950..<17000.
        #expect(!TerminalFrameCover(presentedTop: 1000, surfaceRows: 150).covers(visibleTop: 16950, visibleBottom: 17000))
        #expect(TerminalFrameCover(presentedTop: 16860, surfaceRows: 150).covers(visibleTop: 16950, visibleBottom: 17000))
        // One row short at the bottom: not covered.
        #expect(!TerminalFrameCover(presentedTop: 16849, surfaceRows: 150).covers(visibleTop: 16950, visibleBottom: 17000))
    }
}

extension TerminalFrameCoverTests {
    @Test func followingAStepIsNotAJump() {
        let cover = TerminalFrameCover(presentedTop: 16850, surfaceRows: 150)
        #expect(!cover.isDisjoint(visibleTop: 16955, visibleBottom: 17003))
        #expect(cover.isDisjoint(visibleTop: 17000, visibleBottom: 17050))
        #expect(TerminalFrameCover(presentedTop: 1000, surfaceRows: 150).isDisjoint(visibleTop: 16950, visibleBottom: 17000))
    }
}
