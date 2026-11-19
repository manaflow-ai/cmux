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
    /// Waits, bounded by `timeout`, for the monitor's coalesced bump, which
    /// lands on a later main-queue turn.
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

    @Test func workspaceRenameBumpsRevision() async throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let monitor = manager.customSidebarDataChangeMonitor
        monitor.retain()
        defer { monitor.release() }
        let before = monitor.revision

        workspace.setCustomTitle("Renamed for #46725")

        #expect(await waitForRevision(after: before, of: monitor))
    }

    @Test func newWorkspaceIsObserved() async throws {
        let manager = TabManager()
        let monitor = manager.customSidebarDataChangeMonitor
        monitor.retain()
        defer { monitor.release() }
        let added = manager.addWorkspace(select: false)
        #expect(await waitForRevision(after: 0, of: monitor))

        let before = monitor.revision
        added.setCustomTitle("Added for #46725")

        #expect(await waitForRevision(after: before, of: monitor))
    }

    @Test func agentRuntimeChangeBumpsRevisionWithoutTakingTheRowReplay() async throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let monitor = manager.customSidebarDataChangeMonitor
        monitor.retain()
        defer { monitor.release() }
        let runtime = workspace.sidebarAgentRuntimeObservation
        let before = monitor.revision

        runtime.setAgentPIDs(["claude:46725": 46725])

        #expect(await waitForRevision(after: before, of: monitor))
        // A row that subscribes after the change still gets its replay: the
        // monitor's passive listener must not count as an observer.
        let replayed = await withTaskGroup(of: Bool.self) { group in
            group.addTask { @MainActor in
                var iterator = runtime.changes().makeAsyncIterator()
                return await iterator.next() != nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        #expect(replayed)
    }

    @Test func releasedMonitorTearsDownEverySubscription() async throws {
        let manager = TabManager()
        let monitor = manager.customSidebarDataChangeMonitor
        monitor.retain()
        #expect(!monitor.cancellables.isEmpty)
        #expect(!monitor.workspaceCancellables.isEmpty)
        #expect(!monitor.workspaceTasks.isEmpty)
        monitor.retain()
        monitor.release()
        #expect(!monitor.cancellables.isEmpty, "one holder remains")

        let tasks = monitor.workspaceTasks + monitor.globalTasks

        monitor.release()

        #expect(!monitor.isObserving)
        // Emptying the collections alone wouldn't stop the tasks; each one
        // must have been cancelled, and must then finish.
        #expect(tasks.allSatisfy(\.isCancelled))
        for task in tasks {
            await task.value
        }
        #expect(monitor.cancellables.isEmpty)
        #expect(monitor.workspaceCancellables.isEmpty)
        #expect(monitor.workspaceTasks.isEmpty)
        #expect(monitor.globalTasks.isEmpty)
    }

    @Test func monitorIsSharedPerTabManager() {
        let manager = TabManager()
        #expect(manager.customSidebarDataChangeMonitor === manager.customSidebarDataChangeMonitor)
        #expect(TabManager().customSidebarDataChangeMonitor !== manager.customSidebarDataChangeMonitor)
    }
}
