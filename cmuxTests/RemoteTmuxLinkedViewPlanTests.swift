import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Tests the composed linked-view planner: view lifecycle (create/stale-kill),
/// reconcile actions, and workspace grouping in one decision.
@Suite struct RemoteTmuxLinkedViewPlanTests {
    private typealias P = RemoteTmuxLinkedViewPlan
    private typealias SRow = RemoteTmuxViewSession.SessionRow
    private typealias WRow = RemoteTmuxLinkedWorkspaceModel.WindowRow
    private let view = RemoteTmuxViewSession(ownerId: "o1")  // name: cmux-view-o1

    @Test func firstRunCreatesViewLinksEverythingAndGroups() {
        // No view yet; two real sessions A,B exist.
        let snap = P.Snapshot(
            sessions: [
                SRow(name: "A", isView: false, owner: "", version: nil),
                SRow(name: "B", isView: false, owner: "", version: nil),
            ],
            windows: [
                WRow(sessionName: "A", windowId: "@1", windowIndex: 0),
                WRow(sessionName: "A", windowId: "@2", windowIndex: 1),
                WRow(sessionName: "B", windowId: "@3", windowIndex: 0),
            ],
            cmuxOwnedWindowIds: [],
            placeholderWindowId: nil)
        let plan = P.plan(view: view, snapshot: snap)
        #expect(plan.needsViewCreate)
        #expect(plan.staleViewsToKill.isEmpty)
        #expect(plan.reconcileActions == [
            .link(windowId: "@1"), .link(windowId: "@2"), .link(windowId: "@3"),
        ])
        #expect(plan.workspaces == [
            .init(sessionName: "A", windowIds: ["@1", "@2"]),
            .init(sessionName: "B", windowIds: ["@3"]),
        ])
    }

    @Test func steadyStateNoActionsWhenAllLinked() {
        let snap = P.Snapshot(
            sessions: [
                SRow(name: "cmux-view-o1", isView: true, owner: "o1", version: 1),
                SRow(name: "A", isView: false, owner: "", version: nil),
            ],
            windows: [
                WRow(sessionName: "A", windowId: "@1", windowIndex: 0),
                WRow(sessionName: "cmux-view-o1", windowId: "@0", windowIndex: 0),
                WRow(sessionName: "cmux-view-o1", windowId: "@1", windowIndex: 1),
            ],
            cmuxOwnedWindowIds: ["@1"],
            placeholderWindowId: "@0")
        let plan = P.plan(view: view, snapshot: snap)
        #expect(!plan.needsViewCreate)
        #expect(plan.reconcileActions.isEmpty)
        #expect(plan.workspaces == [.init(sessionName: "A", windowIds: ["@1"])])
    }

    @Test func newWorkspaceAddsLinkForNewSessionWindow() {
        // A new-session W2 (@9) appeared; it should be linked, becoming a workspace.
        let snap = P.Snapshot(
            sessions: [SRow(name: "cmux-view-o1", isView: true, owner: "o1", version: 1)],
            windows: [
                WRow(sessionName: "A", windowId: "@1", windowIndex: 0),
                WRow(sessionName: "W2", windowId: "@9", windowIndex: 0),
                WRow(sessionName: "cmux-view-o1", windowId: "@0", windowIndex: 0),
                WRow(sessionName: "cmux-view-o1", windowId: "@1", windowIndex: 1),
            ],
            cmuxOwnedWindowIds: ["@1"],
            placeholderWindowId: "@0")
        let plan = P.plan(view: view, snapshot: snap)
        #expect(plan.reconcileActions == [.link(windowId: "@9")])
        #expect(plan.workspaces.map(\.sessionName) == ["A", "W2"])
    }

    @Test func closedSessionUnlinksOwnedWindow() {
        // B's window @3 is in the view + owned, but B no longer has a home row → unlink.
        let snap = P.Snapshot(
            sessions: [SRow(name: "cmux-view-o1", isView: true, owner: "o1", version: 1)],
            windows: [
                WRow(sessionName: "A", windowId: "@1", windowIndex: 0),
                WRow(sessionName: "cmux-view-o1", windowId: "@0", windowIndex: 0),
                WRow(sessionName: "cmux-view-o1", windowId: "@1", windowIndex: 1),
                WRow(sessionName: "cmux-view-o1", windowId: "@3", windowIndex: 2), // orphan in view
            ],
            cmuxOwnedWindowIds: ["@1", "@3"],
            placeholderWindowId: "@0")
        let plan = P.plan(view: view, snapshot: snap)
        #expect(plan.reconcileActions == [.unlinkFromView(windowId: "@3")])
        #expect(plan.workspaces == [.init(sessionName: "A", windowIds: ["@1"])])
    }

    @Test func staleOwnViewIsCollectedButForeignViewUntouched() {
        let snap = P.Snapshot(
            sessions: [
                SRow(name: "cmux-view-o1", isView: true, owner: "o1", version: 1),     // current
                SRow(name: "cmux-view-o1-old", isView: true, owner: "o1", version: 0), // our stale
                SRow(name: "cmux-view-o2", isView: true, owner: "o2", version: 1),     // foreign
            ],
            windows: [WRow(sessionName: "cmux-view-o1", windowId: "@0", windowIndex: 0)],
            cmuxOwnedWindowIds: [],
            placeholderWindowId: "@0")
        let plan = P.plan(view: view, snapshot: snap)
        #expect(plan.staleViewsToKill == ["cmux-view-o1-old"])
        #expect(!plan.needsViewCreate)
    }
}
