import CoreGraphics
import Testing
@testable import CnxTerminal

/// verify/terminal-scroll-model.md: one owner of the scroll position.
@Suite struct TerminalScrollModelTests {
    let cell: CGFloat = 16

    func bottom(_ layout: TerminalDocumentLayout) -> CGFloat {
        TerminalDocumentLayout.bottomOffset(contentHeight: layout.contentHeight(cellHeight: cell), viewportHeight: 874, topInset: 62, bottomInset: 140)
    }

    @Test func followingRidesTheBottomAsOutputAppends() {
        let model = TerminalScrollModel()
        let a = TerminalDocumentLayout(originRow: 0, endRow: 300)
        let b = TerminalDocumentLayout(originRow: 0, endRow: 320)
        #expect(model.target(layout: a, rowHeight: cell, topInset: 62, bottomOffsetY: bottom(a)) == bottom(a))
        #expect(model.target(layout: b, rowHeight: cell, topInset: 62, bottomOffsetY: bottom(b)) == bottom(b))
    }

    @Test func aReaderStaysOnTheSameRowsWhateverTheDocumentDoes() {
        var model = TerminalScrollModel()
        let a = TerminalDocumentLayout(originRow: 0, endRow: 600)
        model.began()
        #expect(model.target(layout: a, rowHeight: cell, topInset: 62, bottomOffsetY: bottom(a)) == nil)
        // Released mid-history: row 200 at the top, 5 pt into it.
        model.settled(offsetY: 200 * cell + 5, bottomOffsetY: bottom(a), layout: a, rowHeight: cell)
        #expect(model.state == .reading(.init(row: 200, delta: 5)))
        // Output appends, the TUI's redraw shrinks the end, the top is found lower:
        for layout in [TerminalDocumentLayout(originRow: 0, endRow: 640), TerminalDocumentLayout(originRow: 0, endRow: 560),
                       TerminalDocumentLayout(originRow: 40, endRow: 660)] {
            let y = model.target(layout: layout, rowHeight: cell, topInset: 62, bottomOffsetY: bottom(layout))!
            // The same row stays at the same place on screen.
            #expect(layout.row(atContentY: y, cellHeight: cell) == 200)
            #expect(y - layout.contentY(ofRow: 200, cellHeight: cell) == 5)
        }
    }

    @Test func releasingNearTheBottomFollows() {
        var model = TerminalScrollModel()
        let a = TerminalDocumentLayout(originRow: 0, endRow: 600)
        model.began()
        model.settled(offsetY: bottom(a) - 20, bottomOffsetY: bottom(a), layout: a, rowHeight: cell)
        #expect(model.isFollowing)
    }

    /// A fling into the bottom while output streams ends a few rows short of
    /// the newest end: it follows.
    @Test func aFlingThatReachedTheBottomFollows() {
        var model = TerminalScrollModel()
        let a = TerminalDocumentLayout(originRow: 0, endRow: 600)
        model.began()
        model.scrolled(offsetY: bottom(a), bottomOffsetY: bottom(a))
        let grown = TerminalDocumentLayout(originRow: 0, endRow: 605)
        model.settled(offsetY: bottom(a), bottomOffsetY: bottom(grown), layout: grown, rowHeight: cell)
        #expect(model.isFollowing)
    }

    @Test func onlyInputJumpOrAResetFollowAgain() {
        var model = TerminalScrollModel()
        let a = TerminalDocumentLayout(originRow: 0, endRow: 600)
        model.began()
        model.settled(offsetY: 100 * cell, bottomOffsetY: bottom(a), layout: a, rowHeight: cell)
        #expect(!model.isFollowing)
        var typed = model; typed.input(); #expect(typed.isFollowing)
        var jumped = model; jumped.jumpToBottom(); #expect(jumped.isFollowing)
        var reset = model; reset.reset(); #expect(reset.isFollowing)
    }

    @Test func aDragThatBeganFollowingRemembersIt() {
        var model = TerminalScrollModel()
        model.began()
        #expect(model.state == .interacting(startedFollowing: true))
        model.keyboardDragPinned()
        #expect(model.isInteracting)
    }
}
