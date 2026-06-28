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
    private let view = RemoteTmuxViewSession(ownerId: "o1")
    private var vname: String { view.sessionName }
    private func ownView() -> SRow { SRow(name: vname, isView: true, owner: "o1", version: 1) }

    @Test func firstRunCreatesViewLinksEverythingAndGroups() {
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
            sessions: [ownView(), SRow(name: "A", isView: false, owner: "", version: nil)],
            windows: [
                WRow(sessionName: "A", windowId: "@1", windowIndex: 0),
                WRow(sessionName: vname, windowId: "@0", windowIndex: 0),
                WRow(sessionName: vname, windowId: "@1", windowIndex: 1),
            ],
            cmuxOwnedWindowIds: ["@1"],
            placeholderWindowId: "@0")
        let plan = P.plan(view: view, snapshot: snap)
        #expect(!plan.needsViewCreate)
        #expect(plan.reconcileActions.isEmpty)
        #expect(plan.workspaces == [.init(sessionName: "A", windowIds: ["@1"])])
    }

    @Test func newWorkspaceAddsLinkForNewSessionWindow() {
        let snap = P.Snapshot(
            sessions: [ownView()],
            windows: [
                WRow(sessionName: "A", windowId: "@1", windowIndex: 0),
                WRow(sessionName: "W2", windowId: "@9", windowIndex: 0),
                WRow(sessionName: vname, windowId: "@0", windowIndex: 0),
                WRow(sessionName: vname, windowId: "@1", windowIndex: 1),
            ],
            cmuxOwnedWindowIds: ["@1"],
            placeholderWindowId: "@0")
        let plan = P.plan(view: view, snapshot: snap)
        #expect(plan.reconcileActions == [.link(windowId: "@9")])
        #expect(plan.workspaces.map(\.sessionName) == ["A", "W2"])
    }

    @Test func closedSessionUnlinksOwnedWindow() {
        let snap = P.Snapshot(
            sessions: [ownView()],
            windows: [
                WRow(sessionName: "A", windowId: "@1", windowIndex: 0),
                WRow(sessionName: vname, windowId: "@0", windowIndex: 0),
                WRow(sessionName: vname, windowId: "@1", windowIndex: 1),
                WRow(sessionName: vname, windowId: "@3", windowIndex: 2), // orphan in view
            ],
            cmuxOwnedWindowIds: ["@1", "@3"],
            placeholderWindowId: "@0")
        let plan = P.plan(view: view, snapshot: snap)
        #expect(plan.reconcileActions == [.unlinkFromView(windowId: "@3")])
        #expect(plan.workspaces == [.init(sessionName: "A", windowIds: ["@1"])])
    }

    @Test func staleOwnViewCollectedForeignViewNeverTouchedNorSurfaced() {
        let snap = P.Snapshot(
            sessions: [
                ownView(),
                SRow(name: "cmux-view-o1-old", isView: true, owner: "o1", version: 0), // our stale
                SRow(name: "cmux-view-bob", isView: true, owner: "bob", version: 1),    // foreign
            ],
            windows: [
                WRow(sessionName: vname, windowId: "@0", windowIndex: 0),
                WRow(sessionName: "cmux-view-bob", windowId: "@8", windowIndex: 0),     // foreign window
            ],
            cmuxOwnedWindowIds: [],
            placeholderWindowId: "@0")
        let plan = P.plan(view: view, snapshot: snap)
        #expect(plan.staleViewsToKill == ["cmux-view-o1-old"])  // never includes foreign
        #expect(!plan.needsViewCreate)
        // foreign view's window @8 must NOT be linked, and the foreign view is not a workspace
        #expect(!plan.reconcileActions.contains(.link(windowId: "@8")))
        #expect(plan.workspaces.isEmpty)
    }
}
