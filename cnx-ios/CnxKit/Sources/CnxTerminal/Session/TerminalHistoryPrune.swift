/// Ghostty prunes its oldest scrollback rows a page at a time once the
/// scrollback is at its cap: the total drops by hundreds of rows, and a
/// viewport in the scrollback keeps its rows, so its reported top drops by
/// the same count. Every absolute row the phone holds (the reading anchor,
/// the presented and requested viewport tops, the document, the scroll
/// offset) must move up by it, or a reset reads the mark at the old row
/// number, rows lower in the text (VERIFY-round5 V2-3), and a fling over the
/// shorter document runs into its end (V5-2).
struct TerminalHistoryPrune {
    /// The rows pruned between two scrollbar reports, or nil when the change
    /// is something else: a request of ours (the old report was not the one
    /// asked for, or the history did not shrink), a `clear` (the history is
    /// gone), a viewport that followed the output, or a viewport that fell
    /// by far more than the history shrank.
    static func prunedRows(previousTotal: Int, previousOffset: Int, total: Int, offset: Int,
                           requestedTop: Int, rows: Int) -> Int? {
        // Following (VERIFY-round8 claim 1b): the viewport is the active area
        // before and after, so it moved with the end, not with the rows. The
        // frame on screen (the old end) is the total's shrink higher in the
        // new numbering: that is how far everything held moves up, so the
        // page shows the same frame at the same place until the next present
        // (the rows appended meanwhile are not in that frame yet).
        if previousOffset == previousTotal - rows, offset == total - rows, total < previousTotal, total > rows {
            return previousTotal - total
        }
        guard previousOffset == requestedTop, total < previousTotal, total > rows,
              previousOffset < previousTotal - rows else { return nil }
        let pruned = previousOffset - offset
        guard pruned > 0 else { return nil }
        // pruned = shrink + rows appended meanwhile: the prune dominates.
        let appended = pruned - (previousTotal - total)
        guard appended >= 0, appended * 2 <= pruned else { return nil }
        return pruned
    }
}

/// The rows of the frame on screen (the surface's viewport, placed at
/// `presentedTop`). A scroll whose visible rows it does not cover would show
/// the page's black background until Ghostty presents a frame for them
/// (VERIFY-round5 V5-1), so it waits for that frame.
struct TerminalFrameCover: Equatable {
    var presentedTop: Int
    var surfaceRows: Int

    func covers(visibleTop: Int, visibleBottom: Int) -> Bool {
        visibleTop >= presentedTop && visibleBottom <= presentedTop + surfaceRows
    }

    /// None of the visible rows are in the frame: a jump, not a step.
    func isDisjoint(visibleTop: Int, visibleBottom: Int) -> Bool {
        visibleBottom <= presentedTop || visibleTop >= presentedTop + surfaceRows
    }
}
