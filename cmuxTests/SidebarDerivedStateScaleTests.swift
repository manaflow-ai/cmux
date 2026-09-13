import AppKit
import Bonsplit
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
    @Test(arguments: [20, 50, 100])
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

    @Test(arguments: [20, 50, 100])
    func workspaceEventKeepsDerivedWorkScoped(workspaceCount: Int) async throws {
        let harness = try await SidebarLazyLayoutScaleTests.mountSidebar(
            workspaceCount: workspaceCount, includeGroups: false
        )
        defer { harness.tearDown() }
        #expect(harness.tabManager.tabs.count == workspaceCount)
        let beforeBuilds = harness.counter.workspaceSnapshotBuilds
        for _ in 0..<32 where harness.counter.workspaceSnapshotBuilds == beforeBuilds {
            SidebarLazyLayoutScaleTests.turnMainRunLoopOnce(layingOut: harness.window)
            await Task.yield()
        }
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

    /// Drain accepted publisher emissions. The measured condition is a counter
    /// crossing, not an elapsed wall-clock quiet interval.
    private func settle(_ harness: SidebarLazyLayoutScaleTests.Harness, minimumSnapshotBuilds: Int = 1) async {
        if minimumSnapshotBuilds > 0 {
            for _ in 0..<64 where harness.counter.workspaceSnapshotBuilds < minimumSnapshotBuilds {
                SidebarLazyLayoutScaleTests.turnMainRunLoopOnce(layingOut: harness.window)
                await Task.yield()
            }
        } else {
            SidebarLazyLayoutScaleTests.turnMainRunLoopOnce(layingOut: harness.window)
            await Task.yield()
        }
        SidebarLazyLayoutScaleTests.turnMainRunLoopOnce(layingOut: harness.window)
        await Task.yield()
    }
}
