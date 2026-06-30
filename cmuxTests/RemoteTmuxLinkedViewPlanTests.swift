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
        #expect(!plan.needsBootstrapSession)  // real sessions exist → no bootstrap
        #expect(plan.staleViewsToKill.isEmpty)
        #expect(plan.reconcileActions == [
            .link(windowId: "@1"), .link(windowId: "@2"), .link(windowId: "@3"),
        ])
        #expect(plan.workspaces == [
            .init(sessionName: "A", windowIds: ["@1", "@2"]),
            .init(sessionName: "B", windowIds: ["@3"]),
        ])
    }

    // MARK: - Bootstrap (session-less host) + view-classification safety edges
    //
    // Edge cases for the linked-view lifecycle. The planner is the pure policy, so
    // these exercise: bootstrap signalling (create one fresh session when a host has
    // no real session), and the exact "what counts as a hidden view session" safety
    // surface (a view requires BOTH the @cmux_view tag AND the reserved name prefix).
    // Integration cases that need the live coordinator/controller (the bootstrap
    // actually creating + surfacing a session, out-of-band teardown, aggregated-window
    // unbind, multi-server isolation) are exercised against the running app via the
    // ssh-tmux CLI repro; these unit tests lock the policy those paths depend on.

    /// EDGE 1: host has only OUR (current) view, no real session → signal bootstrap,
    /// surface nothing, link nothing. (The empty-mirror-on-reconnect root cause.)
    @Test func sessionLessHostWithOwnViewSignalsBootstrapAndSurfacesNothing() {
        let snap = P.Snapshot(
            sessions: [ownView()],
            windows: [WRow(sessionName: vname, windowId: "@0", windowIndex: 0)],
            cmuxOwnedWindowIds: [],
            placeholderWindowId: "@0")
        let plan = P.plan(view: view, snapshot: snap)
        #expect(plan.needsBootstrapSession)
        #expect(!plan.needsViewCreate)       // our view already exists
        #expect(plan.workspaces.isEmpty)
        #expect(plan.reconcileActions.isEmpty)
    }

    /// EDGE 2: completely empty server (no sessions, no windows) → create the view AND
    /// signal bootstrap so a fresh session is made.
    @Test func emptyServerNeedsViewCreateAndBootstrap() {
        let snap = P.Snapshot(
            sessions: [], windows: [], cmuxOwnedWindowIds: [], placeholderWindowId: nil)
        let plan = P.plan(view: view, snapshot: snap)
        #expect(plan.needsViewCreate)
        #expect(plan.needsBootstrapSession)
        #expect(plan.workspaces.isEmpty)
        #expect(plan.reconcileActions.isEmpty)
        #expect(plan.staleViewsToKill.isEmpty)
    }

    /// EDGE 3: only a FOREIGN cmux install's view is present (no real session, no own
    /// view) → still signal bootstrap, create our own view, and NEVER kill or surface
    /// the foreign view. (localhost shared-machine case that broke discovery.)
    @Test func onlyForeignViewStillBootstrapsAndNeverTouchesForeign() {
        let snap = P.Snapshot(
            sessions: [SRow(name: "cmux-view-bob", isView: true, owner: "bob", version: 1)],
            windows: [WRow(sessionName: "cmux-view-bob", windowId: "@8", windowIndex: 0)],
            cmuxOwnedWindowIds: [],
            placeholderWindowId: nil)
        let plan = P.plan(view: view, snapshot: snap)
        #expect(plan.needsBootstrapSession)
        #expect(plan.needsViewCreate)              // our view doesn't exist yet
        #expect(plan.staleViewsToKill.isEmpty)     // foreign view never collected
        #expect(plan.workspaces.isEmpty)           // foreign view never surfaced
        #expect(!plan.reconcileActions.contains(.link(windowId: "@8")))  // never linked
    }

    /// EDGE 4: a real session present → never signal bootstrap.
    @Test func realSessionDoesNotSignalBootstrap() {
        let snap = P.Snapshot(
            sessions: [ownView(), SRow(name: "A", isView: false, owner: "", version: nil)],
            windows: [
                WRow(sessionName: "A", windowId: "@1", windowIndex: 0),
                WRow(sessionName: vname, windowId: "@0", windowIndex: 0),
            ],
            cmuxOwnedWindowIds: [],
            placeholderWindowId: "@0")
        let plan = P.plan(view: view, snapshot: snap)
        #expect(!plan.needsBootstrapSession)
        #expect(plan.workspaces == [.init(sessionName: "A", windowIds: ["@1"])])
    }

    /// EDGE 5: a session NAMED like a view but NOT tagged (`isView == false`) is a
    /// REAL session — it must be surfaced, not excluded. (Safety: the prefix alone
    /// never excludes; a real session that happens to be named `cmux-view-…` mirrors.)
    @Test func untaggedPrefixedSessionIsTreatedAsRealAndSurfaced() {
        let impostor = SRow(name: "cmux-view-not-really", isView: false, owner: "", version: nil)
        let snap = P.Snapshot(
            sessions: [ownView(), impostor],
            windows: [
                WRow(sessionName: "cmux-view-not-really", windowId: "@5", windowIndex: 0),
                WRow(sessionName: vname, windowId: "@0", windowIndex: 0),
            ],
            cmuxOwnedWindowIds: [],
            placeholderWindowId: "@0")
        let plan = P.plan(view: view, snapshot: snap)
        #expect(!plan.needsBootstrapSession)
        #expect(plan.workspaces == [.init(sessionName: "cmux-view-not-really", windowIds: ["@5"])])
        #expect(plan.reconcileActions == [.link(windowId: "@5")])
    }

    /// EDGE 6: a session TAGGED `@cmux_view` but WITHOUT the reserved name prefix is
    /// NOT a view — it must be surfaced. (Safety: tag alone never excludes; user
    /// options can be copied onto any session.)
    @Test func taggedSessionWithoutPrefixIsTreatedAsReal() {
        let impostor = SRow(name: "myproject", isView: true, owner: "o1", version: 1)
        let snap = P.Snapshot(
            sessions: [ownView(), impostor],
            windows: [
                WRow(sessionName: "myproject", windowId: "@7", windowIndex: 0),
                WRow(sessionName: vname, windowId: "@0", windowIndex: 0),
            ],
            cmuxOwnedWindowIds: [],
            placeholderWindowId: "@0")
        let plan = P.plan(view: view, snapshot: snap)
        #expect(!plan.needsBootstrapSession)
        #expect(plan.workspaces == [.init(sessionName: "myproject", windowIds: ["@7"])])
    }

    /// EDGE 7: a multi-window real session groups ALL its windows into one workspace
    /// in window-index order.
    @Test func multiWindowSessionGroupsWindowsInOrder() {
        let snap = P.Snapshot(
            sessions: [ownView(), SRow(name: "dev", isView: false, owner: "", version: nil)],
            windows: [
                WRow(sessionName: "dev", windowId: "@1", windowIndex: 0),
                WRow(sessionName: "dev", windowId: "@2", windowIndex: 1),
                WRow(sessionName: "dev", windowId: "@3", windowIndex: 2),
                WRow(sessionName: vname, windowId: "@0", windowIndex: 0),
            ],
            cmuxOwnedWindowIds: [],
            placeholderWindowId: "@0")
        let plan = P.plan(view: view, snapshot: snap)
        #expect(plan.workspaces == [.init(sessionName: "dev", windowIds: ["@1", "@2", "@3"])])
        #expect(!plan.needsBootstrapSession)
    }

    /// EDGE 8: the view's placeholder window is never surfaced as a workspace and
    /// never unlinked (it backs the view itself).
    @Test func placeholderWindowNeverSurfacedNorUnlinked() {
        let snap = P.Snapshot(
            sessions: [ownView(), SRow(name: "A", isView: false, owner: "", version: nil)],
            windows: [
                WRow(sessionName: "A", windowId: "@1", windowIndex: 0),
                WRow(sessionName: vname, windowId: "@0", windowIndex: 0),  // placeholder
                WRow(sessionName: vname, windowId: "@1", windowIndex: 1),
            ],
            cmuxOwnedWindowIds: ["@1"],
            placeholderWindowId: "@0")
        let plan = P.plan(view: view, snapshot: snap)
        #expect(!plan.workspaces.contains { $0.windowIds.contains("@0") })
        #expect(!plan.reconcileActions.contains(.unlinkFromView(windowId: "@0")))
    }

    /// EDGE 9: only an OWN STALE view exists (old format, no current view, no real
    /// session) → schedule the stale kill, create the current view, AND bootstrap.
    @Test func onlyOwnStaleViewSchedulesKillCreateAndBootstrap() {
        let snap = P.Snapshot(
            sessions: [SRow(name: "cmux-view-o1-old", isView: true, owner: "o1", version: 0)],
            windows: [WRow(sessionName: "cmux-view-o1-old", windowId: "@0", windowIndex: 0)],
            cmuxOwnedWindowIds: [],
            placeholderWindowId: nil)
        let plan = P.plan(view: view, snapshot: snap)
        #expect(plan.staleViewsToKill == ["cmux-view-o1-old"])
        #expect(plan.needsViewCreate)
        #expect(plan.needsBootstrapSession)
        #expect(plan.workspaces.isEmpty)
    }

    /// EDGE 10: multiple real sessions each surface as their own workspace; no bootstrap.
    @Test func multipleRealSessionsEachSurfaceAsWorkspace() {
        let snap = P.Snapshot(
            sessions: [
                ownView(),
                SRow(name: "alpha", isView: false, owner: "", version: nil),
                SRow(name: "beta", isView: false, owner: "", version: nil),
                SRow(name: "gamma", isView: false, owner: "", version: nil),
            ],
            windows: [
                WRow(sessionName: "alpha", windowId: "@1", windowIndex: 0),
                WRow(sessionName: "beta", windowId: "@2", windowIndex: 0),
                WRow(sessionName: "gamma", windowId: "@3", windowIndex: 0),
                WRow(sessionName: vname, windowId: "@0", windowIndex: 0),
            ],
            cmuxOwnedWindowIds: [],
            placeholderWindowId: "@0")
        let plan = P.plan(view: view, snapshot: snap)
        #expect(!plan.needsBootstrapSession)
        #expect(Set(plan.workspaces.map(\.sessionName)) == ["alpha", "beta", "gamma"])
    }

    /// EDGE 11: own view + foreign view + a real session → surface only the real one,
    /// never the foreign view, and never collect the foreign view.
    @Test func realSessionCoexistsWithForeignViewWhichIsNeverSurfacedOrCollected() {
        let snap = P.Snapshot(
            sessions: [
                ownView(),
                SRow(name: "cmux-view-carol", isView: true, owner: "carol", version: 1),
                SRow(name: "work", isView: false, owner: "", version: nil),
            ],
            windows: [
                WRow(sessionName: "work", windowId: "@1", windowIndex: 0),
                WRow(sessionName: "cmux-view-carol", windowId: "@8", windowIndex: 0),
                WRow(sessionName: vname, windowId: "@0", windowIndex: 0),
            ],
            cmuxOwnedWindowIds: [],
            placeholderWindowId: "@0")
        let plan = P.plan(view: view, snapshot: snap)
        #expect(plan.workspaces == [.init(sessionName: "work", windowIds: ["@1"])])
        #expect(plan.staleViewsToKill.isEmpty)
        #expect(!plan.reconcileActions.contains(.link(windowId: "@8")))
        #expect(!plan.needsBootstrapSession)
    }

    /// EDGE 12: a dead orphan window left in OUR reused view is unlinked while a
    /// still-live real session keeps its workspace; the surviving live session is
    /// exactly why bootstrap is NOT signalled.
    @Test func deadOwnedWindowUnlinkedWhileLiveSessionKeepsWorkspace() {
        let snap = P.Snapshot(
            sessions: [ownView(), SRow(name: "live", isView: false, owner: "", version: nil)],
            windows: [
                WRow(sessionName: "live", windowId: "@1", windowIndex: 0),
                WRow(sessionName: vname, windowId: "@0", windowIndex: 0),
                WRow(sessionName: vname, windowId: "@1", windowIndex: 1),
                WRow(sessionName: vname, windowId: "@9", windowIndex: 2),  // orphan copy
            ],
            cmuxOwnedWindowIds: ["@1", "@9"],
            placeholderWindowId: "@0")
        let plan = P.plan(view: view, snapshot: snap)
        #expect(plan.reconcileActions == [.unlinkFromView(windowId: "@9")])
        #expect(plan.workspaces == [.init(sessionName: "live", windowIds: ["@1"])])
        #expect(!plan.needsBootstrapSession)  // a live real session survives
    }

    /// EDGE 13: a dead orphan window in our reused view with NO surviving real
    /// session → unlink the orphan AND signal bootstrap (no live workspace remains).
    /// This is the only case combining a real unlink with bootstrap.
    @Test func deadOrphanUnlinkedAndBootstrapWhenNoRealSessionRemains() {
        let snap = P.Snapshot(
            sessions: [ownView()],   // only our view; the session that owned @9 is gone
            windows: [
                WRow(sessionName: vname, windowId: "@0", windowIndex: 0),
                WRow(sessionName: vname, windowId: "@9", windowIndex: 1),  // orphan copy
            ],
            cmuxOwnedWindowIds: ["@9"],
            placeholderWindowId: "@0")
        let plan = P.plan(view: view, snapshot: snap)
        #expect(plan.reconcileActions == [.unlinkFromView(windowId: "@9")])
        #expect(plan.workspaces.isEmpty)
        #expect(plan.needsBootstrapSession)
    }

    /// EDGE 14: `needsBootstrapSession` keys off the SESSION list, not the window
    /// grouping — so an inconsistent snapshot (a real session present but its window
    /// rows momentarily missing, e.g. a session dying between the two non-atomic
    /// `list-sessions`/`list-windows` queries) does NOT signal bootstrap. This is what
    /// stops cmux recreating a session the user just closed via a snapshot race.
    @Test func realSessionWithMissingWindowRowsDoesNotSignalBootstrap() {
        let snap = P.Snapshot(
            sessions: [ownView(), SRow(name: "raced", isView: false, owner: "", version: nil)],
            windows: [WRow(sessionName: vname, windowId: "@0", windowIndex: 0)],  // no rows for "raced"
            cmuxOwnedWindowIds: [],
            placeholderWindowId: "@0")
        let plan = P.plan(view: view, snapshot: snap)
        #expect(!plan.needsBootstrapSession)   // session list shows a real session
        #expect(plan.workspaces.isEmpty)       // but grouping is (transiently) empty
    }

    // MARK: - Bootstrap GATE (RemoteTmuxViewConnection.shouldBootstrapEmptyHost)
    //
    // The coordinator's one-shot, never-recreate gate, extracted pure so its two
    // safety invariants are unit-tested without tmux/SSH: (1) bootstrap once on a
    // genuinely session-less host's initial attach; (2) NEVER recreate a session the
    // user just closed. Without these the empty-mirror fix would regress into
    // recreating closed sessions (the dominant review finding).

    /// EDGE 15: genuine initial attach to a session-less host → bootstrap.
    @Test func gateBootstrapsOnInitialAttachToSessionLessHost() {
        #expect(RemoteTmuxViewConnection.shouldBootstrapEmptyHost(
            needsBootstrapSession: true, everSurfacedWorkspace: false, alreadyBootstrapped: false))
    }

    /// EDGE 16: the view surfaced a workspace earlier, then the user closed the last
    /// session → plan needs bootstrap, but the gate must REFUSE (no recreate).
    @Test func gateNeverRecreatesAUserClosedSession() {
        #expect(!RemoteTmuxViewConnection.shouldBootstrapEmptyHost(
            needsBootstrapSession: true, everSurfacedWorkspace: true, alreadyBootstrapped: false))
    }

    /// EDGE 17: already bootstrapped (awaiting the new session to surface) → at most
    /// once, so a still-empty reconcile can't spawn a second session.
    @Test func gateBootstrapsAtMostOnce() {
        #expect(!RemoteTmuxViewConnection.shouldBootstrapEmptyHost(
            needsBootstrapSession: true, everSurfacedWorkspace: false, alreadyBootstrapped: true))
    }

    /// EDGE 18: a real session exists → never bootstrap regardless of the flags.
    @Test func gateSkippedWhenRealSessionExists() {
        #expect(!RemoteTmuxViewConnection.shouldBootstrapEmptyHost(
            needsBootstrapSession: false, everSurfacedWorkspace: false, alreadyBootstrapped: false))
    }

    // MARK: - Re-bootstrap GATE (vanished bootstrap session, server-side flakiness)

    /// EDGE 19: we bootstrapped a session that vanished before surfacing (host still
    /// session-less, never surfaced a workspace) → re-arm, bounded by the attempt cap.
    @Test func reBootstrapWhenCreatedSessionVanishedBeforeSurfacing() {
        #expect(RemoteTmuxViewConnection.shouldReBootstrapVanishedEmptyHost(
            needsBootstrapSession: true, everSurfacedWorkspace: false,
            alreadyBootstrapped: true, attempts: 1, maxAttempts: 3))
    }

    /// EDGE 20: never re-bootstrap once the attempt cap is hit (no `new-session` spin
    /// against a host that keeps killing the session we create).
    @Test func reBootstrapStopsAtAttemptCap() {
        #expect(!RemoteTmuxViewConnection.shouldReBootstrapVanishedEmptyHost(
            needsBootstrapSession: true, everSurfacedWorkspace: false,
            alreadyBootstrapped: true, attempts: 3, maxAttempts: 3))
    }

    /// EDGE 21: never re-bootstrap a session the user surfaced then closed — the sticky
    /// `everSurfacedWorkspace` term guards re-arm exactly as it guards the first shot.
    @Test func reBootstrapNeverResurrectsAUserClosedSession() {
        #expect(!RemoteTmuxViewConnection.shouldReBootstrapVanishedEmptyHost(
            needsBootstrapSession: true, everSurfacedWorkspace: true,
            alreadyBootstrapped: true, attempts: 0, maxAttempts: 3))
    }

    /// EDGE 22: re-arm is only for the ALREADY-bootstrapped case; a never-bootstrapped
    /// host is the first gate's job, not this one.
    @Test func reBootstrapRequiresAPriorBootstrap() {
        #expect(!RemoteTmuxViewConnection.shouldReBootstrapVanishedEmptyHost(
            needsBootstrapSession: true, everSurfacedWorkspace: false,
            alreadyBootstrapped: false, attempts: 0, maxAttempts: 3))
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

    @Test func formatBumpKeepsRelinkingAllWindowsIntoFreshView() {
        // A view with OUR name but an old format version: needsViewCreate is true and
        // the stale same-name view is scheduled for kill+recreate. Its windows must
        // be re-linked into the fresh view — i.e. `actual` is treated as empty so
        // they all appear in reconcileActions (regression: previously they were seen
        // as already-present and never re-linked → empty view after upgrade).
        let staleSameName = SRow(name: vname, isView: true, owner: "o1", version: 0)
        let snap = P.Snapshot(
            sessions: [staleSameName, SRow(name: "A", isView: false, owner: "", version: nil)],
            windows: [
                WRow(sessionName: "A", windowId: "@1", windowIndex: 0),
                WRow(sessionName: "A", windowId: "@2", windowIndex: 1),
                // the old view still lists these linked windows under our name:
                WRow(sessionName: vname, windowId: "@0", windowIndex: 0),
                WRow(sessionName: vname, windowId: "@1", windowIndex: 1),
                WRow(sessionName: vname, windowId: "@2", windowIndex: 2),
            ],
            cmuxOwnedWindowIds: ["@1", "@2"],
            placeholderWindowId: "@0")
        let plan = P.plan(view: view, snapshot: snap)
        #expect(plan.needsViewCreate)
        #expect(plan.staleViewsToKill == [vname])
        // BOTH real windows re-link despite being listed in the (doomed) old view.
        #expect(plan.reconcileActions == [.link(windowId: "@1"), .link(windowId: "@2")])
        #expect(plan.workspaces == [.init(sessionName: "A", windowIds: ["@1", "@2"])])
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
        #expect(plan.needsBootstrapSession)  // no real session → bootstrap one
    }
}
