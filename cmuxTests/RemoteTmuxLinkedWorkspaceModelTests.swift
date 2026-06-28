import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Tests regrouping the linked-view's flat window set back into per-session
/// workspaces: all view sessions excluded, deterministic single home, stable tab
/// order, robust parsing.
@Suite struct RemoteTmuxLinkedWorkspaceModelTests {
    private typealias M = RemoteTmuxLinkedWorkspaceModel
    private typealias Row = RemoteTmuxLinkedWorkspaceModel.WindowRow

    private let view = "cmux-view-o1"
    private lazy var rows: [Row] = [
        Row(sessionName: "A", windowId: "@1", windowIndex: 0),
        Row(sessionName: "A", windowId: "@2", windowIndex: 1),
        Row(sessionName: "B", windowId: "@3", windowIndex: 0),
        Row(sessionName: view, windowId: "@0", windowIndex: 0), // placeholder
        Row(sessionName: view, windowId: "@1", windowIndex: 1),
        Row(sessionName: view, windowId: "@2", windowIndex: 2),
        Row(sessionName: view, windowId: "@3", windowIndex: 3),
    ]

    @Test func parsesRows() {
        // format is window_id : window_index : session_name
        let out = "@1:0:A\n@3:0:B"
        #expect(M.parseRows(out) == [
            Row(sessionName: "A", windowId: "@1", windowIndex: 0),
            Row(sessionName: "B", windowId: "@3", windowIndex: 0),
        ])
    }

    @Test func parsingKeepsSessionNamesContainingDelimiter() {
        // A `:` in the (free-text, last) name must not drop or corrupt the row.
        let out = "@5:2:we:ird:name"
        #expect(M.parseRows(out) == [Row(sessionName: "we:ird:name", windowId: "@5", windowIndex: 2)])
    }

    @Test func usesPrintableDelimiterNotControlByte() {
        #expect(!M.listFormat.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) })
        #expect(M.listFormat.contains(":"))
    }

    @Test mutating func groupsByHomeSessionExcludingView() {
        let ws = M.workspaces(rows: rows, excludedSessions: [view])
        #expect(ws == [
            .init(sessionName: "A", windowIds: ["@1", "@2"]),
            .init(sessionName: "B", windowIds: ["@3"]),
        ])
        #expect(!ws.flatMap(\.windowIds).contains("@0"))   // placeholder excluded
    }

    @Test func excludesForeignViewSessionsToo() {
        // A foreign cmux install's view must be excluded as well — never a workspace.
        let r = [
            Row(sessionName: "A", windowId: "@1", windowIndex: 0),
            Row(sessionName: "cmux-view-bob", windowId: "@8", windowIndex: 0),
        ]
        let ws = M.workspaces(rows: r, excludedSessions: ["cmux-view-o1", "cmux-view-bob"])
        #expect(ws == [.init(sessionName: "A", windowIds: ["@1"])])
        #expect(!M.desiredLinkedWindowIds(rows: r, excludedSessions: ["cmux-view-o1", "cmux-view-bob"]).contains("@8"))
    }

    @Test func windowInMultipleSessionsHasDeterministicSingleHome() {
        // @12 is linked into both B and A (a user cross-link). It must land in
        // exactly one workspace, the lexicographically smallest home (A).
        let r = [
            Row(sessionName: "B", windowId: "@12", windowIndex: 0),
            Row(sessionName: "A", windowId: "@12", windowIndex: 5),
        ]
        let ws = M.workspaces(rows: r, excludedSessions: [])
        let appearances = ws.flatMap(\.windowIds).filter { $0 == "@12" }
        #expect(appearances == ["@12"])                                   // exactly once
        #expect(M.homeSession(forWindowId: "@12", rows: r, excludedSessions: []) == "A")
        #expect(ws.first { $0.sessionName == "A" }?.windowIds == ["@12"])  // in A, not B
        // B's only window is homed to A, so B has no exclusively-owned window and
        // does not appear as a workspace (a tmux session always has >=1 window, so
        // this only arises from a manual cross-link).
        #expect(ws.first { $0.sessionName == "B" } == nil)
    }

    @Test func tabOrderFollowsWindowIndex() {
        let r = [
            Row(sessionName: "A", windowId: "@7", windowIndex: 5),
            Row(sessionName: "A", windowId: "@4", windowIndex: 1),
            Row(sessionName: "A", windowId: "@9", windowIndex: 3),
        ]
        #expect(M.workspaces(rows: r, excludedSessions: []) == [.init(sessionName: "A", windowIds: ["@4", "@9", "@7"])])
    }

    @Test mutating func desiredLinkedWindowsAreAllNonViewWindows() {
        #expect(M.desiredLinkedWindowIds(rows: rows, excludedSessions: [view]) == ["@1", "@2", "@3"])
    }

    @Test mutating func homeSessionRoutesOutputToWorkspace() {
        #expect(M.homeSession(forWindowId: "@2", rows: rows, excludedSessions: [view]) == "A")
        #expect(M.homeSession(forWindowId: "@3", rows: rows, excludedSessions: [view]) == "B")
        #expect(M.homeSession(forWindowId: "@0", rows: rows, excludedSessions: [view]) == nil)
    }

    @Test func emptyWhenOnlyViewExists() {
        let r = [Row(sessionName: "cmux-view-o1", windowId: "@0", windowIndex: 0)]
        #expect(M.workspaces(rows: r, excludedSessions: ["cmux-view-o1"]).isEmpty)
        #expect(M.desiredLinkedWindowIds(rows: r, excludedSessions: ["cmux-view-o1"]).isEmpty)
    }
}
