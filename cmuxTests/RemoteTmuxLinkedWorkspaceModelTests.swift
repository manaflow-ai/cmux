import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Tests regrouping the linked-view's flat window set back into per-session
/// workspaces: view excluded, home-session attribution, stable tab order.
@Suite struct RemoteTmuxLinkedWorkspaceModelTests {
    private typealias M = RemoteTmuxLinkedWorkspaceModel
    private typealias Row = RemoteTmuxLinkedWorkspaceModel.WindowRow

    // A realistic list-windows -a: sessions A (2 windows) and B (1), all also
    // linked into the view session (so each appears under "view" too).
    private let rows: [Row] = [
        Row(sessionName: "A", windowId: "@1", windowIndex: 0),
        Row(sessionName: "A", windowId: "@2", windowIndex: 1),
        Row(sessionName: "B", windowId: "@3", windowIndex: 0),
        Row(sessionName: "cmux-view-o1", windowId: "@0", windowIndex: 0), // placeholder
        Row(sessionName: "cmux-view-o1", windowId: "@1", windowIndex: 1),
        Row(sessionName: "cmux-view-o1", windowId: "@2", windowIndex: 2),
        Row(sessionName: "cmux-view-o1", windowId: "@3", windowIndex: 3),
    ]

    @Test func parsesRows() {
        let out = "A\u{1f}@1\u{1f}0\nB\u{1f}@3\u{1f}0"
        #expect(M.parseRows(out) == [
            Row(sessionName: "A", windowId: "@1", windowIndex: 0),
            Row(sessionName: "B", windowId: "@3", windowIndex: 0),
        ])
    }

    @Test func groupsByHomeSessionExcludingView() {
        let ws = M.workspaces(rows: rows, viewSessionName: "cmux-view-o1")
        #expect(ws == [
            .init(sessionName: "A", windowIds: ["@1", "@2"]),
            .init(sessionName: "B", windowIds: ["@3"]),
        ])
        // the view session is never a workspace, and its placeholder @0 never appears
        #expect(!ws.contains { $0.sessionName.hasPrefix("cmux-view") })
        #expect(!ws.flatMap(\.windowIds).contains("@0"))
    }

    @Test func tabOrderFollowsWindowIndex() {
        // Same session, windows given out of order → sorted by index.
        let r = [
            Row(sessionName: "A", windowId: "@7", windowIndex: 5),
            Row(sessionName: "A", windowId: "@4", windowIndex: 1),
            Row(sessionName: "A", windowId: "@9", windowIndex: 3),
        ]
        let ws = M.workspaces(rows: r, viewSessionName: "view")
        #expect(ws == [.init(sessionName: "A", windowIds: ["@4", "@9", "@7"])])
    }

    @Test func desiredLinkedWindowsAreAllNonViewWindows() {
        #expect(M.desiredLinkedWindowIds(rows: rows, viewSessionName: "cmux-view-o1")
                == ["@1", "@2", "@3"])
    }

    @Test func homeSessionRoutesOutputToWorkspace() {
        #expect(M.homeSession(forWindowId: "@2", rows: rows, viewSessionName: "cmux-view-o1") == "A")
        #expect(M.homeSession(forWindowId: "@3", rows: rows, viewSessionName: "cmux-view-o1") == "B")
        // a window that exists only in the view has no home → nil (not shown)
        #expect(M.homeSession(forWindowId: "@0", rows: rows, viewSessionName: "cmux-view-o1") == nil)
    }

    @Test func emptyWhenOnlyViewExists() {
        let r = [Row(sessionName: "cmux-view-o1", windowId: "@0", windowIndex: 0)]
        #expect(M.workspaces(rows: r, viewSessionName: "cmux-view-o1").isEmpty)
        #expect(M.desiredLinkedWindowIds(rows: r, viewSessionName: "cmux-view-o1").isEmpty)
    }
}
