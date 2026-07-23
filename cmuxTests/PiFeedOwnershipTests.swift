import CMUXAgentLaunch
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Pi Feed ownership", .serialized)
struct PiFeedOwnershipTests {
    @MainActor
    @Test
    func acknowledgedInsertionRehomesSurfaceToItsLiveWorkspace() throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        AppDelegate.shared = appDelegate
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        appDelegate.tabManager = tabManager

        let staleWorkspace = tabManager.addWorkspace(select: false)
        let liveWorkspace = tabManager.addWorkspace(select: true)
        let surfaceId = try #require(liveWorkspace.focusedPanelId)
        defer {
            for workspace in [staleWorkspace, liveWorkspace]
                where tabManager.tabs.contains(where: { $0.id == workspace.id }) {
                tabManager.closeWorkspace(workspace)
            }
            appDelegate.tabManager = nil
            AppDelegate.shared = previousAppDelegate
        }

        var insertedEvent: WorkstreamEvent?
        let store = WorkstreamStore(
            ringCapacity: 10,
            titleProvider: { event in
                insertedEvent = event
                return nil
            }
        )
        FeedCoordinator.shared.install(store: store)

        let event = WorkstreamEvent(
            sessionId: "pi-live-ownership-test",
            hookEventName: .postToolUse,
            source: "pi",
            workspaceId: staleWorkspace.id.uuidString,
            surfaceId: surfaceId.uuidString,
            toolName: "Bash",
            requestId: "pi-live-ownership-request"
        )
        guard case .acknowledged(let itemId?) = FeedCoordinator.shared.ingestAcknowledged(event) else {
            Issue.record("expected authoritative Pi Feed insertion")
            return
        }

        #expect(store.items.contains(where: { $0.id == itemId }))
        #expect(insertedEvent?.workspaceId == liveWorkspace.id.uuidString)
        #expect(insertedEvent?.surfaceId == surfaceId.uuidString)
    }
}
