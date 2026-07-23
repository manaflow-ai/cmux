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
    func acknowledgedInsertionRehomesSurfaceToItsLiveWorkspace() async throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        AppDelegate.shared = appDelegate
        appDelegate.didAttemptStartupSessionRestore = true
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
        let result = await Self.ingestAcknowledgedOffMainActor([event])
        guard case .ok(let rawPayload) = result,
              let payload = rawPayload as? [String: Any],
              let rawItemId = payload["item_id"] as? String,
              let itemId = UUID(uuidString: rawItemId) else {
            Issue.record("expected authoritative Pi Feed insertion")
            return
        }

        #expect(store.items.contains(where: { $0.id == itemId }))
        #expect(insertedEvent?.workspaceId == liveWorkspace.id.uuidString)
        #expect(insertedEvent?.surfaceId == surfaceId.uuidString)
    }

    @MainActor
    @Test
    func acknowledgedInsertionRejectsClosedAndMalformedSurfaceClaims() async {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        AppDelegate.shared = appDelegate
        appDelegate.didAttemptStartupSessionRestore = true
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
            let result = await Self.ingestAcknowledgedOffMainActor([event])
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
    func acknowledgedBatchUsesOneLiveWorkspaceSnapshotForEveryEvent() async throws {
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

        let result = await Self.ingestAcknowledgedOffMainActor(events)
        guard case .ok(let rawPayload) = result,
              let payload = rawPayload as? [String: Any],
              let itemIds = payload["item_ids"] as? [String]
        else {
            Issue.record("expected one authoritative batch acknowledgment")
            return
        }
        #expect(itemIds.count == 64)
        #expect(Set(itemIds).count == 64)
        #expect(payload["workspace_id"] as? String == liveWorkspace.id.uuidString)
        #expect(payload["surface_id"] as? String == surfaceId.uuidString)
        #expect(store.items.count == 64)
        #expect(insertedEvents.count == 64)
        #expect(insertedEvents.allSatisfy { $0.workspaceId == liveWorkspace.id.uuidString })
        #expect(insertedEvents.allSatisfy { $0.surfaceId == surfaceId.uuidString })
    }

    @MainActor
    @Test
    func startupResolutionGapIsRetryableButClosedSurfaceIsNotFound() async {
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
            sessionId: "pi-startup-resolution-gap",
            hookEventName: .postToolUse,
            source: "pi",
            workspaceId: UUID().uuidString,
            surfaceId: UUID().uuidString,
            toolName: "Bash",
            requestId: "pi-startup-resolution-gap-request"
        )

        appDelegate.didAttemptStartupSessionRestore = false
        let startupResult = await Self.ingestAcknowledgedOffMainActor([event])
        guard case .err(let startupCode, _, _) = startupResult else {
            Issue.record("startup resolution gap received an acknowledgment")
            return
        }
        #expect(startupCode == "unavailable")

        appDelegate.didAttemptStartupSessionRestore = true
        let closedResult = await Self.ingestAcknowledgedOffMainActor([event])
        guard case .err(let closedCode, _, _) = closedResult else {
            Issue.record("closed surface received an acknowledgment")
            return
        }
        #expect(closedCode == "not_found")
        #expect(store.items.isEmpty)
    }

    @MainActor
    @Test
    func sameSessionPiPostToolBatchCoalescesTranscriptUpdate() async throws {
        let previousAppDelegate = AppDelegate.shared
        let previousTranscriptService = TerminalController.shared.agentChatTranscriptService
        let appDelegate = AppDelegate()
        AppDelegate.shared = appDelegate
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        appDelegate.tabManager = tabManager

        let workspace = tabManager.addWorkspace(select: true)
        let surfaceId = try #require(workspace.focusedPanelId)
        let registry = AgentChatSessionRegistry()
        TerminalController.shared.agentChatTranscriptService = AgentChatTranscriptService(
            registry: registry,
            hasEventSubscribers: { false },
            emitEventPayload: { _ in }
        )
        defer {
            if tabManager.tabs.contains(where: { $0.id == workspace.id }) {
                tabManager.closeWorkspace(workspace)
            }
            TerminalController.shared.agentChatTranscriptService = previousTranscriptService
            appDelegate.tabManager = nil
            AppDelegate.shared = previousAppDelegate
        }

        let store = WorkstreamStore(ringCapacity: 100)
        FeedCoordinator.shared.install(store: store)
        let sessionId = "pi-coalesced-transcript-batch"
        let events = (0..<64).map { index in
            WorkstreamEvent(
                sessionId: sessionId,
                hookEventName: .postToolUse,
                source: "pi",
                workspaceId: workspace.id.uuidString,
                surfaceId: surfaceId.uuidString,
                toolName: "Bash",
                requestId: "pi-coalesced-transcript-request-\(index)",
                receivedAt: Date(timeIntervalSinceReferenceDate: TimeInterval(index))
            )
        }

        guard case .ok = await Self.ingestAcknowledgedOffMainActor(events) else {
            Issue.record("expected Pi PostToolUse batch acknowledgment")
            return
        }
        let record = try #require(registry.record(sessionID: sessionId))
        #expect(record.version == 1)
        #expect(record.lastActivityAt == events.last?.receivedAt)
        #expect(store.items.count == 64)
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
    func blockingInsertionRejectsClosedSurfaceWithoutTimingOut() async {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        AppDelegate.shared = appDelegate
        appDelegate.didAttemptStartupSessionRestore = true
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

        guard case .notFound = result else {
            Issue.record("closed Feed targets must fail before entering the decision wait")
            return
        }
        #expect(store.items.isEmpty)
    }

    @MainActor
    @Test
    func positiveWaitWithoutEventRequestIdCannotAcknowledgeUnavailableSurface() async throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        AppDelegate.shared = appDelegate
        appDelegate.didAttemptStartupSessionRestore = true
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        appDelegate.tabManager = tabManager
        defer {
            appDelegate.tabManager = nil
            AppDelegate.shared = previousAppDelegate
        }

        let store = WorkstreamStore(ringCapacity: 10)
        FeedCoordinator.shared.install(store: store)
        let request: [String: Any] = [
            "id": "outer-feed-request",
            "method": "feed.push",
            "params": [
                "wait_timeout_seconds": 0.01,
                "event": [
                    "session_id": "missing-inner-request-id",
                    "hook_event_name": "PermissionRequest",
                    "_source": "pi",
                    "workspace_id": UUID().uuidString,
                    "surface_id": UUID().uuidString,
                    "tool_name": "Bash",
                ],
            ],
        ]
        let requestData = try JSONSerialization.data(withJSONObject: request)
        let requestLine = try #require(String(data: requestData, encoding: .utf8))
        let responseLine = await Task.detached {
            TerminalController.shared.handleSocketLine(requestLine)
        }.value
        let responseData = try #require(responseLine.data(using: .utf8))
        let response = try #require(
            JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        )
        let error = try #require(response["error"] as? [String: Any])

        #expect(error["code"] as? String == "not_found")
        #expect(store.items.isEmpty)
    }

    @MainActor @Test
    func surfaceLessFeedRejectsClosedWorkspaceClaim() async {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        AppDelegate.shared = appDelegate
        appDelegate.didAttemptStartupSessionRestore = true
        appDelegate.tabManager = TabManager(autoWelcomeIfNeeded: false)
        defer {
            appDelegate.tabManager = nil
            AppDelegate.shared = previousAppDelegate
        }

        let store = WorkstreamStore(ringCapacity: 10)
        FeedCoordinator.shared.install(store: store)
        let event = WorkstreamEvent(
            sessionId: "pi-closed-workspace-only",
            hookEventName: .postToolUse,
            source: "pi",
            workspaceId: UUID().uuidString,
            requestId: "pi-closed-workspace-only-request"
        )
        let result = await Self.ingestAcknowledgedOffMainActor([event])
        guard case .err(let code, _, _) = result else {
            Issue.record("closed workspace-only claim received an acknowledgment")
            return
        }
        #expect(code == "not_found")
        #expect(store.items.isEmpty)
    }

    @MainActor @Test
    func surfaceLessFeedNormalizesLiveWorkspaceClaim() async throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        AppDelegate.shared = appDelegate
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        appDelegate.tabManager = tabManager
        let workspace = tabManager.addWorkspace(select: true)
        defer {
            tabManager.closeWorkspace(workspace)
            appDelegate.tabManager = nil
            AppDelegate.shared = previousAppDelegate
        }
        var insertedEvent: WorkstreamEvent?
        let store = WorkstreamStore(ringCapacity: 10) {
            insertedEvent = $0
            return nil
        }
        FeedCoordinator.shared.install(store: store)
        let event = WorkstreamEvent(
            sessionId: "pi-live-workspace-only",
            hookEventName: .postToolUse,
            source: "pi",
            workspaceId: "  \(workspace.id.uuidString) \n",
            requestId: "pi-live-workspace-only-request"
        )
        let result = await Self.ingestAcknowledgedOffMainActor([event])
        guard case .ok(let rawPayload) = result,
              let payload = rawPayload as? [String: Any] else {
            Issue.record("live workspace-only claim was not acknowledged")
            return
        }
        #expect(payload["workspace_id"] as? String == workspace.id.uuidString)
        #expect(payload["surface_id"] == nil)
        #expect(insertedEvent?.workspaceId == workspace.id.uuidString)
        #expect(insertedEvent?.surfaceId == nil)
        #expect(store.items.count == 1)
    }

    private static func ingestAcknowledgedOffMainActor(
        _ events: [WorkstreamEvent]
    ) async -> TerminalController.V2CallResult {
        let resultBox = PiFeedV2CallResultBox()
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                resultBox.value = TerminalController.shared.v2IngestAcknowledgedFeedEvents(events)
                continuation.resume()
            }
        }
        return resultBox.value!
    }
}

// Written once on a socket worker and read only after its continuation resumes.
private final class PiFeedV2CallResultBox: @unchecked Sendable {
    var value: TerminalController.V2CallResult?
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
