import CoreGraphics

/// Where the terminal's scrollable document starts and ends in Ghostty's
/// absolute rows (0 = the oldest scrollback row), and how its rows map to the
/// scroll view's content coordinates. Portable rules of
/// `TerminalViewController`, unit tested (verify/design/terminal/SPEC.md B1).
///
/// The phone mirrors the Mac's screen at the bottom of a taller local grid
/// (`TerminalRowShift`), so a short session has rows above the Mac's row 0
/// that nothing ever wrote. They are not part of the document: its top is
/// the first row with text (or the cursor's row, if that is higher), so a
/// short session draws row 0 at the top inset like Terminal.app, there is
/// nothing above it to scroll into, and `clear` puts the prompt back at the
/// top. Blank space is only ever below the cursor.
public struct TerminalDocumentLayout: Equatable, Sendable {
    /// First absolute row of the document.
    public var originRow: Int
    /// One past the last absolute row of the document: the cursor's row or
    /// the last row with text below it, whichever is lower (+ 1), or the
    /// scrollback total when the cursor is unknown.
    public var endRow: Int

    public init(originRow: Int, endRow: Int) {
        self.originRow = max(0, originRow)
        self.endRow = max(self.originRow + 1, endRow)
    }

    /// Rows in the document (at least one).
    public var rowCount: Int { endRow - originRow }

    /// The document for Ghostty's scrollback `total`, the cursor's absolute
    /// row (nil: unknown) and the blank rows at the top of the screen (nil:
    /// not read; 0 for a local session with no mirror offset).
    public static func make(totalRows: Int, cursorRow: Int?, leadingBlankRows: Int?,
                            lastContentRow: Int? = nil) -> TerminalDocumentLayout {
        let total = max(1, totalRows)
        // An inline TUI (Codex CLI) keeps the cursor in its input box and
        // draws rows below it (hints, status): they are part of the document,
        // or the last of them would rest under the composer (user report,
        // 2026-10-14).
        let lastRow = max(cursorRow ?? -1, lastContentRow ?? -1)
        let end = lastRow >= 0 ? min(total, lastRow + 1) : total
        var origin = leadingBlankRows ?? 0
        // Never start below the cursor: the prompt row is always in the document.
        if let cursorRow { origin = min(origin, cursorRow) }
        origin = min(origin, end - 1)
        return TerminalDocumentLayout(originRow: origin, endRow: end)
    }

    /// While the reader is scrolled up, the document's end does not move up
    /// (Codex QA F2). An inline TUI clears and redraws its live area below
    /// the cursor as it commits streamed lines; read as a shorter document,
    /// that put the reader past its end, and following resumed: the view
    /// held for a moment, then jumped. A cleared scrollback (the total
    /// shrank) still shortens it.
    public func keepingEnd(of previous: TerminalDocumentLayout?, following: Bool, totalRows: Int,
                           previousTotal: Int) -> TerminalDocumentLayout {
        guard !following, let previous, totalRows >= previousTotal, endRow < previous.endRow,
              originRow == previous.originRow else { return self }
        return TerminalDocumentLayout(originRow: originRow, endRow: min(max(1, totalRows), previous.endRow))
    }

    /// Content y of absolute `row`'s top edge.
    public func contentY(ofRow row: Int, cellHeight: CGFloat) -> CGFloat {
        CGFloat(row - originRow) * cellHeight
    }

    /// Absolute row at content y (rows above the origin clamp to it).
    public func row(atContentY y: CGFloat, cellHeight: CGFloat) -> Int {
        guard cellHeight > 0 else { return originRow }
        return originRow + Int(floor(max(0, y) / cellHeight))
    }

    /// Content height of the document.
    public func contentHeight(cellHeight: CGFloat) -> CGFloat {
        CGFloat(rowCount) * cellHeight
    }

    /// The offset that shows the document's end: the last row just above the
    /// bottom inset (the composer), or the first row at the top inset when the
    /// document is shorter than the space between them (a short session never
    /// floats to the bottom; it moves up only as far as the cursor needs).
    public static func bottomOffset(contentHeight: CGFloat, viewportHeight: CGFloat, topInset: CGFloat,
                                    bottomInset: CGFloat) -> CGFloat {
        max(-topInset, contentHeight + bottomInset - viewportHeight)
    }

    /// Whether the blank rows at the top must be read again: the origin is
    /// unknown, the scrollback shrank (`clear`, a reset), or the document's
    /// top is still on the active screen (where an erase can blank it).
    /// Once the top is in the scrollback above the screen it cannot change
    /// without the total shrinking, so a flood never pays for the read.
    public static func needsOriginScan(previous: TerminalDocumentLayout?, previousTotal: Int, totalRows: Int,
                                       screenRows: Int) -> Bool {
        guard let previous else { return true }
        if totalRows < previousTotal { return true }
        let activeTop = max(0, totalRows - screenRows)
        return previous.originRow >= activeTop
    }

    /// Leading newlines of Ghostty's plain text (one per blank row before
    /// the first row with text), at most `limit`. Text with no newline
    /// before its first character starts at row 0.
    public static func leadingNewlines(in bytes: UnsafeRawBufferPointer, limit: Int) -> Int {
        var count = 0
        for byte in bytes {
            if byte == 0x0A {
                count += 1
                if count >= limit { return limit }
            } else if byte == 0x0D || byte == 0x20 {
                continue
            } else {
                return count
            }
        }
        // Only newlines and spaces: everything read is blank.
        return limit
    }
}
