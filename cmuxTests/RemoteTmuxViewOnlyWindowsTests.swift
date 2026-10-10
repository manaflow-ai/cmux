import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A command that names a mirrored window only by its id (`tmux new-window -a -t @12`) lands in
/// whichever session holding that window was used last, and the hidden view session is used every
/// few seconds. Measured on tmux 3.7b. The new window then sits in the view and nowhere else, so it
/// never becomes a tab. It belongs in the real session of the window it was created next to.
@Suite struct RemoteTmuxViewOnlyWindowsTests {
    private typealias Row = RemoteTmuxLinkedWorkspaceModel.WindowRow
    private let view = "cmux-view-v1-owner-hash"

    /// `main` holds @1 @2 @3 at 0 1 2; the view holds its placeholder @0 and links all three.
    private var baseRows: [Row] {
        [
            Row(sessionName: "main", windowId: "@1", windowIndex: 0),
            Row(sessionName: "main", windowId: "@2", windowIndex: 1),
            Row(sessionName: "main", windowId: "@3", windowIndex: 2),
            Row(sessionName: view, windowId: "@0", windowIndex: 0),
            Row(sessionName: view, windowId: "@1", windowIndex: 1),
            Row(sessionName: view, windowId: "@2", windowIndex: 2),
            Row(sessionName: view, windowId: "@3", windowIndex: 3),
        ]
    }

    private func adoptions(_ rows: [Row], owned: Set<String> = ["@1", "@2", "@3"]) -> [RemoteTmuxViewOnlyWindows.Adoption] {
        RemoteTmuxViewOnlyWindows.adoptions(
            rows: rows, viewSessionName: view, excludedSessions: [view],
            placeholderWindowId: "@0", cmuxOwnedWindowIds: owned)
    }

    @Test func aWindowCreatedNextToAMirroredWindowJoinsThatWindowsSession() {
        // `new-window -a -t @2` resolved to the view: the new @9 sits right after @2 there only.
        var rows = baseRows.filter { $0.sessionName != view || $0.windowIndex < 3 }
        rows.append(Row(sessionName: view, windowId: "@9", windowIndex: 3))
        rows.append(Row(sessionName: view, windowId: "@3", windowIndex: 4))
        #expect(adoptions(rows) == [.init(windowId: "@9", sessionName: "main", afterWindowIndex: 1)])
    }

    @Test func aWindowCmuxLinkedWhoseSessionIsGoneIsNotAdopted() {
        // @3's home session was killed; the view's copy is cmux's own and gets cleaned up instead.
        let rows = baseRows.filter { !($0.sessionName == "main" && $0.windowId == "@3") }
        #expect(adoptions(rows).isEmpty)
    }

    @Test func thePlaceholderIsNeverAdopted() {
        #expect(adoptions(baseRows).isEmpty)
    }

    @Test func aWindowWithNoMirroredWindowBeforeItStaysWhereItIs() {
        var rows = baseRows.map { row -> Row in
            row.sessionName == view && row.windowIndex > 0
                ? Row(sessionName: view, windowId: row.windowId, windowIndex: row.windowIndex + 1)
                : row
        }
        rows.append(Row(sessionName: view, windowId: "@9", windowIndex: 1))
        #expect(adoptions(rows).isEmpty, "there is no neighbour to say which session it belongs to")
    }

    @Test func aWindowAlreadyInARealSessionIsLeftAlone() {
        var rows = baseRows
        rows.append(Row(sessionName: "other", windowId: "@9", windowIndex: 0))
        rows.append(Row(sessionName: view, windowId: "@9", windowIndex: 4))
        #expect(adoptions(rows, owned: ["@1", "@2", "@3", "@9"]).isEmpty)
    }

    @Test func viewOnlyNeighboursAreSkippedToTheNearestMirroredWindow() {
        var rows = baseRows
        rows.append(Row(sessionName: view, windowId: "@8", windowIndex: 4))
        rows.append(Row(sessionName: view, windowId: "@9", windowIndex: 5))
        #expect(adoptions(rows) == [
            .init(windowId: "@8", sessionName: "main", afterWindowIndex: 2),
            .init(windowId: "@9", sessionName: "main", afterWindowIndex: 2),
        ])
    }
}
