import CoreGraphics
import Foundation
import Testing
@testable import CnxTerminal

/// SPEC B1: the document starts at the first row with text, never at the
/// blank mirror rows above the Mac's screen.
@Suite struct TerminalDocumentLayoutTests {
    private func leading(_ text: String, limit: Int = 200) -> Int {
        Array(text.utf8).withUnsafeBytes { TerminalDocumentLayout.leadingNewlines(in: $0, limit: limit) }
    }

    @Test func countsBlankRowsBeforeTheFirstText() {
        #expect(leading("\n\n\nLast login\n% ") == 3)
        #expect(leading("% ") == 0)
        #expect(leading("\n\n   indented") == 2)
        #expect(leading("") == 200)
        #expect(leading("\n\n\n", limit: 2) == 2)
    }

    @Test func shortRemoteSessionStartsAtItsFirstRow() {
        // 148-row mirror, Mac screen of 42 rows at the bottom: 106 blank rows,
        // then 10 lines with the cursor on the 10th.
        let layout = TerminalDocumentLayout.make(totalRows: 148, cursorRow: 115, leadingBlankRows: 106)
        #expect(layout.originRow == 106)
        #expect(layout.rowCount == 10)
        #expect(layout.contentY(ofRow: 106, cellHeight: 16) == 0)
        #expect(layout.row(atContentY: 33, cellHeight: 16) == 108)
        #expect(layout.row(atContentY: -50, cellHeight: 16) == 106)
    }

    @Test func clearPutsThePromptOnTheFirstRow() {
        // After `clear` only the prompt row is left, at the mirror offset.
        let layout = TerminalDocumentLayout.make(totalRows: 148, cursorRow: 106, leadingBlankRows: 148)
        #expect(layout.originRow == 106)
        #expect(layout.rowCount == 1)
    }

    @Test func localSessionHasNoOffset() {
        let layout = TerminalDocumentLayout.make(totalRows: 400, cursorRow: 399, leadingBlankRows: 0)
        #expect(layout.originRow == 0)
        #expect(layout.rowCount == 400)
    }

    /// User report (2026-10-14): Codex CLI's cursor is in its input box with
    /// two hint rows drawn below it; those rows end the document, so the
    /// last one rests above the composer instead of under it.
    @Test func rowsDrawnBelowTheCursorEndTheDocument() {
        let layout = TerminalDocumentLayout.make(totalRows: 400, cursorRow: 396, leadingBlankRows: 0, lastContentRow: 398)
        #expect(layout.endRow == 399)
        // Blank rows below the cursor do not.
        #expect(TerminalDocumentLayout.make(totalRows: 400, cursorRow: 396, leadingBlankRows: 0, lastContentRow: 390).endRow == 397)
    }

    /// Codex QA F2: streaming while the reader is scrolled up. Codex clears
    /// its live area below the cursor as it commits lines, so the measured
    /// end moves up for a moment; the reader's document keeps its end, the
    /// view stays inside it, and following does not resume.
    @Test func aScrolledUpReaderKeepsTheEndWhileATUIRedraws() {
        let before = TerminalDocumentLayout(originRow: 0, endRow: 300)
        let redrawing = TerminalDocumentLayout.make(totalRows: 310, cursorRow: 270, leadingBlankRows: 0, lastContentRow: 270)
        #expect(redrawing.endRow == 271)
        let kept = redrawing.keepingEnd(of: before, following: false, totalRows: 310, previousTotal: 305)
        #expect(kept.endRow == 300)
        // The reader is inside the kept document: nothing resumes following.
        var follow = TerminalFollowPolicy(following: false)
        let maxOffset = TerminalDocumentLayout.bottomOffset(contentHeight: kept.contentHeight(cellHeight: 16), viewportHeight: 874,
                                                            topInset: 62, bottomInset: 140)
        let readerOffset: CGFloat = 46 * 16
        #expect(follow.documentResized(offsetY: readerOffset, maxOffsetY: maxOffset, userIsScrolling: false) == nil)
        #expect(!follow.following)
        // Following, the end follows the program.
        #expect(redrawing.keepingEnd(of: before, following: true, totalRows: 310, previousTotal: 305).endRow == 271)
        // A cleared scrollback shortens it.
        #expect(redrawing.keepingEnd(of: before, following: false, totalRows: 40, previousTotal: 305).endRow == 271)
    }

    @Test func unknownCursorUsesTheTotal() {
        let layout = TerminalDocumentLayout.make(totalRows: 50, cursorRow: nil, leadingBlankRows: 10)
        #expect(layout.originRow == 10)
        #expect(layout.endRow == 50)
    }

    @Test func shortDocumentRestsAtTheTopInset() {
        // 10 rows of 16.4 pt under a 62 pt top inset: never floats to the composer.
        let offset = TerminalDocumentLayout.bottomOffset(contentHeight: 164, viewportHeight: 874, topInset: 62, bottomInset: 140)
        #expect(offset == -62)
        // 1 page: the whole document fits between the insets.
        #expect(164 + 62 + 140 <= 874)
    }

    @Test func keyboardLiftsOnlyAsFarAsTheCursorNeeds() {
        // 30 rows (492 pt) with the keyboard up (bottom inset 424 pt): the
        // last row ends just above the composer, not one point higher.
        let offset = TerminalDocumentLayout.bottomOffset(contentHeight: 492, viewportHeight: 874, topInset: 62, bottomInset: 424)
        #expect(offset == 42)
        #expect(492 - offset == CGFloat(874 - 424))
        // Keyboard down again: back to the top inset.
        #expect(TerminalDocumentLayout.bottomOffset(contentHeight: 492, viewportHeight: 874, topInset: 62, bottomInset: 140) == -62)
    }

    @Test func originIsReadOnlyWhileItCanChange() {
        let onScreen = TerminalDocumentLayout(originRow: 106, endRow: 116)
        #expect(TerminalDocumentLayout.needsOriginScan(previous: nil, previousTotal: 0, totalRows: 148, screenRows: 148))
        #expect(TerminalDocumentLayout.needsOriginScan(previous: onScreen, previousTotal: 148, totalRows: 148, screenRows: 148))
        // Deep in the scrollback (a flood): no read.
        let scrolledAway = TerminalDocumentLayout(originRow: 106, endRow: 5000)
        #expect(!TerminalDocumentLayout.needsOriginScan(previous: scrolledAway, previousTotal: 4990, totalRows: 5000, screenRows: 148))
        // Cleared scrollback: read again.
        #expect(TerminalDocumentLayout.needsOriginScan(previous: scrolledAway, previousTotal: 5000, totalRows: 148, screenRows: 148))
    }
}
