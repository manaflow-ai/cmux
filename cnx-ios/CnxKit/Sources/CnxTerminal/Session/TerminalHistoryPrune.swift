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
