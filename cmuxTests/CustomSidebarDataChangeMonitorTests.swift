import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Issue #46725: custom sidebars that don't read `clock` rebuild only when
/// their data changes, driven by this monitor instead of a 1 s tick.
@MainActor
@Suite(.serialized) struct CustomSidebarDataChangeMonitorTests {
    /// Waits for the monitor's coalesced bump (delivered on the main queue,
    /// at most once per `coalesceInterval`).
    private func waitForRevision(
        after revision: UInt64,
        of monitor: CustomSidebarDataChangeMonitor,
        timeout: Duration = .seconds(5)
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if monitor.revision != revision { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return monitor.revision != revision
    }

    /// Lets the subscribe-time replays (current-value publishers) land.
    private func settle(_ monitor: CustomSidebarDataChangeMonitor) async -> UInt64 {
        var last = monitor.revision
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1_200))
            if monitor.revision == last { return last }
            last = monitor.revision
        }
        return last
    }

    @Test func workspaceRenameBumpsRevision() async throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let monitor = manager.customSidebarDataChangeMonitor
        monitor.retain()
        defer { monitor.release() }
        let before = await settle(monitor)
        let changedAtBefore = monitor.changedAt

        workspace.setCustomTitle("Renamed for #46725")

        #expect(await waitForRevision(after: before, of: monitor))
        #expect(monitor.changedAt > changedAtBefore)
    }

    @Test func newWorkspaceBumpsRevisionAndIsObserved() async throws {
        let manager = TabManager()
        let monitor = manager.customSidebarDataChangeMonitor
        monitor.retain()
        defer { monitor.release() }
        let before = await settle(monitor)

        let added = manager.addWorkspace(select: false)
        #expect(await waitForRevision(after: before, of: monitor))

        // The new workspace's own changes are observed too.
        let afterAdd = await settle(monitor)
        added.setCustomTitle("Added for #46725")
        #expect(await waitForRevision(after: afterAdd, of: monitor))
    }

    @Test func releasedMonitorStopsObserving() async throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let monitor = manager.customSidebarDataChangeMonitor
        monitor.retain()
        _ = await settle(monitor)
        monitor.release()
        #expect(!monitor.isObserving)
        let before = monitor.revision

        workspace.setCustomTitle("Not observed")

        #expect(!(await waitForRevision(after: before, of: monitor, timeout: .milliseconds(1_500))))
    }

    @Test func monitorIsSharedPerTabManager() {
        let manager = TabManager()
        #expect(manager.customSidebarDataChangeMonitor === manager.customSidebarDataChangeMonitor)
        #expect(TabManager().customSidebarDataChangeMonitor !== manager.customSidebarDataChangeMonitor)
    }
}
