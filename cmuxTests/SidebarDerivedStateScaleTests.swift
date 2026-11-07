import AppKit
import Bonsplit
import CMUXAgentLaunch
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Measures the real sidebar owner, including offscreen workspaces. The Cloud
/// outline fixture separately counts AppKit row configuration and persistence.
@MainActor
@Suite("Sidebar derived state scale", .serialized)
struct SidebarDerivedStateScaleTests {
    // Both invariants below are absolute work counts (zero derived work for
    // bookkeeping; a constant snapshot bound and an O(N) input ceiling for one
    // event), so the smallest and largest mounted lists bracket the claim. The
    // middle 50-workspace case re-ran the same assertions at a scale between
    // two it already held at.
    @Test(arguments: [20, 100])
    func paneRegistryBookkeepingDoesNotInvalidateCachedSidebar(workspaceCount: Int) async throws {
        let harness = try await SidebarLazyLayoutScaleTests.mountSidebar(
            workspaceCount: workspaceCount, includeGroups: false
        )
        defer { harness.tearDown() }
        await settle(harness)
        harness.counter.reset()
        let workspace = try #require(harness.tabManager.tabs.last)
        let inferred = workspace.inferredTaskStatus
        // A surface mapping may arrive before its panel is installed. No live
        // panel, title, PR, branch, or status changes until that installation.
        let provisionalSurface = TabID()
        workspace.bindSurface(provisionalSurface, toPanelId: UUID())
        defer { workspace.paneTree.removeSurfaceMapping(forSurfaceId: provisionalSurface) }
        #expect(workspace.inferredTaskStatus == inferred)
        await settle(harness, minimumSnapshotBuilds: 0)
        print("SIDEBAR_DERIVED_SCALE workspaces=\(workspaceCount) pane_registry_changes=1 snapshot_builds=\(harness.counter.workspaceSnapshotBuilds) row_inputs=\(harness.counter.workspaceRowInputProjections)")
        #expect(harness.counter.workspaceSnapshotBuilds == 0)
        #expect(harness.counter.workspaceRowInputProjections == 0,
                "Cached sidebar rows must not observe pane registry bookkeeping through task-status inference.")
    }

    @Test(arguments: [20, 100])
    func workspaceEventKeepsDerivedWorkScoped(workspaceCount: Int) async throws {
        let harness = try await SidebarLazyLayoutScaleTests.mountSidebar(
            workspaceCount: workspaceCount, includeGroups: false
        )
        defer { harness.tearDown() }
        #expect(harness.tabManager.tabs.count == workspaceCount)
        await settle(harness)
        #expect(harness.counter.workspaceSnapshotBuilds >= workspaceCount)
        harness.counter.reset()

        let workspace = try #require(harness.tabManager.tabs.last)
        let start = ContinuousClock.now
        workspace.setCustomTitle("Scale fixture changed workspace")
        await settle(harness)
        let elapsed = start.duration(to: .now)
        let builds = harness.counter.workspaceSnapshotBuilds
        let inputs = harness.counter.workspaceRowInputProjections
        print("SIDEBAR_DERIVED_SCALE workspaces=\(workspaceCount) changed_workspaces=1 snapshot_builds=\(builds) row_inputs=\(inputs) settled_duration=\(elapsed)")
        #expect(builds > 0, "The workspace change must reach the live snapshot owner.")
        #expect(builds <= 3, "One changed workspace must not rebuild derived snapshots for the whole list.")
        #expect(inputs <= workspaceCount * 4, "One event must not fan out into N parent-list updates.")
        #expect(harness.counter.maxSnapshotBuildsInOneRowBody == 0)
    }

    /// The row's session-priority menu values reach it through its workspace snapshot, which
    /// the workspace's change event refreshes. The sidebar body itself must not read the
    /// `@Observable` state: that would tie it to every workspace and rebuild every row input.
    @Test
    func sessionPriorityValuesReachRowsOnlyThroughTheWorkspaceSnapshot() async throws {
        let workspaceCount = 20
        let harness = try await SidebarLazyLayoutScaleTests.mountSidebar(
            workspaceCount: workspaceCount, includeGroups: false
        )
        defer { harness.tearDown() }
        await settle(harness)

        // Written to the model directly, without the workspace's change event: only a body
        // that observes the state rebuilds now, once per write. Other suites' main-actor work
        // can invalidate the sidebar during a round too, so a few rounds may rebuild anyway.
        let rounds = 8
        var roundsThatRebuilt = 0
        for workspace in harness.tabManager.tabs.prefix(rounds) {
            harness.counter.reset()
            workspace.sessionPriorityState.difficultyOverride = .hard
            workspace.sessionPriorityState.isManual = true
            await settle(harness, minimumSnapshotBuilds: 0)
            if harness.counter.workspaceRowInputProjections > 0 { roundsThatRebuilt += 1 }
        }
        #expect(roundsThatRebuilt <= rounds / 2,
                "The sidebar body must not observe session priority state (\(roundsThatRebuilt) of \(rounds) writes rebuilt it).")

        // Through the workspace, the change event rebuilds that one snapshot, and the new
        // values reach the rows in one parent update.
        for workspace in harness.tabManager.tabs.suffix(3) {
            harness.counter.reset()
            workspace.setClaudeDifficultyOverride(.easy)
            await settle(harness)
            let builds = harness.counter.workspaceSnapshotBuilds
            let inputs = harness.counter.workspaceRowInputProjections
            #expect((1...3).contains(builds), "Only the changed workspace's snapshot rebuilds (\(builds)).")
            #expect(inputs > 0, "The changed snapshot must reach the row inputs.")
            #expect(inputs <= workspaceCount * 4, "One change must not fan out into N parent-list updates (\(inputs)).")
        }
    }

    /// Wait for accepted publisher emissions, then require a quiet interval.
    /// This is a test deadline, not a delay or polling loop in shipped code.
    ///
    /// The quiet window only has to outlast the slowest coalescing stage a
    /// leaked sidebar update would have to cross: the per-workspace
    /// `sidebarImmediateObservationCoalesceInterval` (50 ms), the sidebar
    /// observation debounce (40 ms), and one run-loop turn for
    /// `SidebarWorkspaceSnapshotRefreshCoalescer`. 150 ms is three times the
    /// longest of those, so a late emission still lands inside the window.
    private static let quietWindow = Duration.milliseconds(150)

    private func settle(_ harness: SidebarLazyLayoutScaleTests.Harness, minimumSnapshotBuilds: Int = 1) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        var quietSince = ContinuousClock.now
        var previous = -1
        repeat {
            SidebarLazyLayoutScaleTests.turnMainRunLoopOnce(layingOut: harness.window)
            await Task.yield()
            let count = harness.counter.workspaceSnapshotBuilds + harness.counter.workspaceRowInputProjections
            if previous != count {
                previous = count
                quietSince = .now
            }
            if harness.counter.workspaceSnapshotBuilds >= minimumSnapshotBuilds,
               quietSince.duration(to: .now) >= Self.quietWindow { return }
        } while .now < deadline
        Issue.record("Sidebar derived-state work did not converge within four seconds.")
    }
}
