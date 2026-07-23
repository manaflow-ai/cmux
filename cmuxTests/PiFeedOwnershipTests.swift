import CMUXAgentLaunch
import Foundation
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

    @MainActor
    @Test
    func acknowledgedInsertionRejectsClosedAndMalformedSurfaceClaims() {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        AppDelegate.shared = appDelegate
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        appDelegate.tabManager = tabManager
        defer {
            appDelegate.tabManager = nil
            AppDelegate.shared = previousAppDelegate
        }

        let store = WorkstreamStore(ringCapacity: 10)
        FeedCoordinator.shared.install(store: store)
        let claimedSurfaceIds = [UUID().uuidString, "not-a-surface-id"]
        for (index, surfaceId) in claimedSurfaceIds.enumerated() {
            let event = WorkstreamEvent(
                sessionId: "pi-invalid-ownership-\(index)",
                hookEventName: .postToolUse,
                source: "pi",
                workspaceId: UUID().uuidString,
                surfaceId: surfaceId,
                toolName: "Bash",
                requestId: "pi-invalid-ownership-request-\(index)"
            )
            let result = TerminalController.shared.v2IngestAcknowledgedFeedEvents([event])
            guard case .err(let code, _, _) = result else {
                Issue.record("closed or malformed surface claim received an acknowledgment")
                continue
            }
            #expect(code == "not_found")
        }
        #expect(store.items.isEmpty)
    }

    @MainActor
    @Test
    func acknowledgedBatchUsesOneLiveWorkspaceSnapshotForEveryEvent() throws {
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

        var insertedEvents: [WorkstreamEvent] = []
        let store = WorkstreamStore(
            ringCapacity: 100,
            titleProvider: { event in
                insertedEvents.append(event)
                return nil
            }
        )
        FeedCoordinator.shared.install(store: store)
        let events = (0..<64).map { index in
            WorkstreamEvent(
                sessionId: "pi-live-batch-\(index)",
                hookEventName: .postToolUse,
                source: "pi",
                workspaceId: "  \(staleWorkspace.id.uuidString) \n",
                surfaceId: "  \(surfaceId.uuidString) \n",
                toolName: "Bash",
                requestId: "pi-live-batch-request-\(index)"
            )
        }

        let result = TerminalController.shared.v2IngestAcknowledgedFeedEvents(events)
        guard case .ok(let rawPayload) = result,
              let payload = rawPayload as? [String: Any],
              let itemIds = payload["item_ids"] as? [String]
        else {
            Issue.record("expected one authoritative batch acknowledgment")
            return
        }
        #expect(itemIds.count == 64)
        #expect(Set(itemIds).count == 64)
        #expect(store.items.count == 64)
        #expect(insertedEvents.count == 64)
        #expect(insertedEvents.allSatisfy { $0.workspaceId == liveWorkspace.id.uuidString })
        #expect(insertedEvents.allSatisfy { $0.surfaceId == surfaceId.uuidString })
    }

    @MainActor
    @Test
    func blockingInsertionUsesOneLiveWorkspaceSnapshotForEveryConsumer() async throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        AppDelegate.shared = appDelegate
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        appDelegate.tabManager = tabManager

        let staleWorkspace = tabManager.addWorkspace(select: false)
        let liveWorkspace = tabManager.addWorkspace(select: true)
        let surfaceId = try #require(liveWorkspace.focusedPanelId)
        defer {
            FeedCoordinatorTestHooks.afterBlockingEventIngested = nil
            FeedCoordinatorTestHooks.attentionSurfaceObserver = nil
            for workspace in [staleWorkspace, liveWorkspace]
                where tabManager.tabs.contains(where: { $0.id == workspace.id }) {
                tabManager.closeWorkspace(workspace)
            }
            appDelegate.tabManager = nil
            AppDelegate.shared = previousAppDelegate
        }

        let insertedEvents = PiFeedEventRecorder()
        let attentionEvents = PiFeedEventRecorder()
        let acceptedEvents = PiFeedEventRecorder()
        let requestId = "pi-live-blocking-request"
        let store = WorkstreamStore(
            ringCapacity: 10,
            titleProvider: { event in
                insertedEvents.record(event)
                return nil
            }
        )
        FeedCoordinator.shared.install(store: store)
        FeedCoordinatorTestHooks.attentionSurfaceObserver = { event in
            attentionEvents.record(event)
        }
        FeedCoordinatorTestHooks.afterBlockingEventIngested = { _, ingestedRequestId in
            guard ingestedRequestId == requestId else { return }
            FeedCoordinator.shared.deliverReply(
                requestId: ingestedRequestId,
                decision: .permission(.once)
            )
        }

        let event = WorkstreamEvent(
            sessionId: "pi-live-blocking-test",
            hookEventName: .permissionRequest,
            source: "pi",
            workspaceId: staleWorkspace.id.uuidString,
            surfaceId: surfaceId.uuidString,
            toolName: "Bash",
            requestId: requestId
        )
        let result = await Task.detached {
            FeedCoordinator.shared.ingestBlocking(
                event: event,
                waitTimeout: 1,
                onAccepted: { acceptedEvents.record($0) }
            )
        }.value

        guard case .resolved(_, .permission(.once)) = result else {
            Issue.record("expected blocking Feed event to resolve")
            return
        }
        #expect(insertedEvents.events.first?.workspaceId == liveWorkspace.id.uuidString)
        #expect(insertedEvents.events.first?.surfaceId == surfaceId.uuidString)
        #expect(attentionEvents.events.first?.workspaceId == liveWorkspace.id.uuidString)
        #expect(attentionEvents.events.first?.surfaceId == surfaceId.uuidString)
        #expect(acceptedEvents.events.first?.workspaceId == liveWorkspace.id.uuidString)
        #expect(acceptedEvents.events.first?.surfaceId == surfaceId.uuidString)
    }

    @MainActor
    @Test
    func blockingInsertionRejectsUnavailableSurfaceWithoutTimingOut() async {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        AppDelegate.shared = appDelegate
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        appDelegate.tabManager = tabManager
        defer {
            appDelegate.tabManager = nil
            AppDelegate.shared = previousAppDelegate
        }

        let store = WorkstreamStore(ringCapacity: 10)
        FeedCoordinator.shared.install(store: store)
        let event = WorkstreamEvent(
            sessionId: "pi-unavailable-blocking-test",
            hookEventName: .permissionRequest,
            source: "pi",
            workspaceId: UUID().uuidString,
            surfaceId: UUID().uuidString,
            toolName: "Bash",
            requestId: "pi-unavailable-blocking-request"
        )
        let result = await Task.detached {
            FeedCoordinator.shared.ingestBlocking(event: event, waitTimeout: 0.01)
        }.value

        guard case .unavailable = result else {
            Issue.record("unavailable Feed targets must fail before entering the decision wait")
            return
        }
        #expect(store.items.isEmpty)
    }
}

private final class PiFeedEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEvents: [WorkstreamEvent] = []

    var events: [WorkstreamEvent] {
        lock.lock()
        defer { lock.unlock() }
        return recordedEvents
    }

    func record(_ event: WorkstreamEvent) {
        lock.lock()
        recordedEvents.append(event)
        lock.unlock()
    }
}
