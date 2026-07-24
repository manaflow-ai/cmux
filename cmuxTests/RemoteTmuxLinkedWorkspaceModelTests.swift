import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct RemoteTmuxLinkedWorkspaceModelTests {
    private typealias Model = RemoteTmuxLinkedWorkspaceModel

    @Test func parseRowsReadsAllFieldsIncludingSessionId() {
        let rows = Model.parseRows("$3:@7:2:1:work\n$3:@8:0:0:work\n")
        #expect(rows == [
            .init(sessionName: "work", sessionId: "$3", windowId: "@7", windowIndex: 2, isActive: true),
            .init(sessionName: "work", sessionId: "$3", windowId: "@8", windowIndex: 0, isActive: false),
        ])
    }

    @Test func parseRowsRejoinsColonInSessionNameAndHandlesCRLF() {
        // session_name is the last field; a ':' in it must not shift fields, and
        // CRLF output must split cleanly (no stray '\r' on the name).
        let rows = Model.parseRows("$1:@1:0:1:a:b\r\n")
        #expect(rows == [.init(sessionName: "a:b", sessionId: "$1", windowId: "@1", windowIndex: 0, isActive: true)])
    }

    @Test func parseRowsSkipsShortLines() {
        #expect(Model.parseRows("garbage\n$1:@1:0:1:ok\n").map(\.windowId) == ["@1"])
    }

    @Test func workspacesGroupsByHomeSessionInStableOrder() {
        let rows = [
            Model.WindowRow(sessionName: "b", sessionId: "$2", windowId: "@2", windowIndex: 0, isActive: true),
            Model.WindowRow(sessionName: "a", sessionId: "$1", windowId: "@1", windowIndex: 1, isActive: false),
            Model.WindowRow(sessionName: "a", sessionId: "$1", windowId: "@0", windowIndex: 0, isActive: true),
        ]
        let ws = Model.workspaces(rows: rows, excludedSessions: [])
        #expect(ws.map(\.sessionName) == ["a", "b"])       // sorted by session name
        #expect(ws[0].windowIds == ["@0", "@1"])           // ordered by (windowIndex, windowId)
        #expect(ws[0].activeWindowId == "@0")
        #expect(ws[0].sessionId == 1)                      // "$1" -> 1
        #expect(ws[1].windowIds == ["@2"])
    }

    @Test func workspacesExcludesViewSessions() {
        let rows = [
            Model.WindowRow(sessionName: "cmux-view-XYZ", sessionId: "$9", windowId: "@1", windowIndex: 0),
            Model.WindowRow(sessionName: "real", sessionId: "$1", windowId: "@1", windowIndex: 0, isActive: true),
        ]
        #expect(Model.workspaces(rows: rows, excludedSessions: ["cmux-view-XYZ"]).map(\.sessionName) == ["real"])
    }

    @Test func crossLinkedWindowGetsDeterministicSmallestHome() {
        // @1 is linked into both "a" and "b"; its single home is the
        // lexicographically smallest non-excluded session ("a"), so "b" — which
        // holds only that linked copy — yields no workspace.
        let rows = [
            Model.WindowRow(sessionName: "b", sessionId: "$2", windowId: "@1", windowIndex: 5, isActive: true),
            Model.WindowRow(sessionName: "a", sessionId: "$1", windowId: "@1", windowIndex: 0, isActive: false),
        ]
        let ws = Model.workspaces(rows: rows, excludedSessions: [])
        #expect(ws.map(\.sessionName) == ["a"])
        #expect(ws[0].windowIds == ["@1"])
    }

    @Test func desiredLinkedWindowIdsExcludesViewOnlyWindows() {
        let rows = [
            Model.WindowRow(sessionName: "cmux-view-A", sessionId: "$9", windowId: "@9", windowIndex: 0),
            Model.WindowRow(sessionName: "real", sessionId: "$1", windowId: "@1", windowIndex: 0),
        ]
        #expect(Model.desiredLinkedWindowIds(rows: rows, excludedSessions: ["cmux-view-A"]) == ["@1"])
    }

    @Test func homeSessionIsSmallestNonExcluded() {
        let rows = [
            Model.WindowRow(sessionName: "z", sessionId: "$3", windowId: "@1", windowIndex: 0),
            Model.WindowRow(sessionName: "m", sessionId: "$2", windowId: "@1", windowIndex: 0),
        ]
        #expect(Model.homeSession(forWindowId: "@1", rows: rows, excludedSessions: []) == "m")
        #expect(Model.homeSession(forWindowId: "@1", rows: rows, excludedSessions: ["m"]) == "z")
    }
}
