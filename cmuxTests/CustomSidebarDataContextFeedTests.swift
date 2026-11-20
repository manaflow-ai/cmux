import CmuxNotifications
import CmuxSwiftRender
import Foundation
import Observation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Custom sidebars get their workspace data from a change feed, not a
/// one-second rebuild: a change reaches the sidebar without a timer, and a
/// refresh with nothing changed neither rebuilds snapshots nor re-renders.
@MainActor
@Suite
struct CustomSidebarDataContextFeedTests {
    private final class RecordFetchCounter {
        var count = 0
    }

    private func makeFeed(_ manager: TabManager, counter: RecordFetchCounter) -> CustomSidebarDataContextFeed {
        CustomSidebarDataContextFeed(
            tabManager: manager,
            sidebarUnread: SidebarUnreadModel(),
            agentRecords: {
                counter.count += 1
                return []
            }
        )
    }

    /// Lets queued main-queue work (the feed's coalesced refresh) run until
    /// `condition` holds or a bounded number of turns pass.
    private func drainMainQueue(until condition: () -> Bool) async {
        for _ in 0..<20 where !condition() {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    private func title(_ context: [String: SwiftValue], at index: Int) -> SwiftValue? {
        context["workspaces"]?.iterationValues?[index].member("title")
    }

    @Test
    func workspaceRenameReachesTheSidebarWithoutATimer() async throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let feed = makeFeed(manager, counter: RecordFetchCounter())
        feed.activate()
        defer { feed.deactivate() }
        let index = try #require(manager.tabs.firstIndex { $0.id == workspace.id })

        _ = workspace.setCustomTitle("Renamed by test")
        await drainMainQueue { title(feed.dataContext, at: index) == .string("Renamed by test") }

        #expect(title(feed.dataContext, at: index) == .string("Renamed by test"))
    }

    @Test
    func refreshWithNothingChangedDoesNotRebuildOrNotify() throws {
        let manager = TabManager()
        let counter = RecordFetchCounter()
        let feed = makeFeed(manager, counter: counter)
        feed.activate()
        defer { feed.deactivate() }
        let context = feed.dataContext
        let fetchesAfterActivate = counter.count

        var notified = false
        withObservationTracking {
            _ = feed.dataContext
        } onChange: {
            notified = true
        }
        feed.refresh()
        feed.refresh()

        #expect(feed.dataContext == context)
        #expect(counter.count == fetchesAfterActivate, "unchanged workspaces must reuse their snapshots")
        #expect(!notified, "an unchanged context must not re-render the sidebar")
    }

    @Test
    func newWorkspaceAppearsAndOnlyItIsBuilt() async throws {
        let manager = TabManager()
        let feed = makeFeed(manager, counter: RecordFetchCounter())
        feed.activate()
        defer { feed.deactivate() }
        let before = manager.tabs.count

        _ = manager.addWorkspace()
        await drainMainQueue { feed.dataContext["workspaceCount"] == .int(before + 1) }

        #expect(feed.dataContext["workspaceCount"] == .int(before + 1))
    }
}
