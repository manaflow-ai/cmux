import CMUXAgentLaunch
import CmuxFoundation
import CmuxAgentJournal
import CmuxNotifications
import CmuxSettings
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Test-only installation control over the shared coordinator's internal state.
extension FeedCoordinator {
    @MainActor var notificationCenterForTesting: (any UserNotificationCenterServing)? { userNotificationCenter }

    @MainActor
    func restoreInstallationForTesting(store: WorkstreamStore?, journal: AgentJournalLifecycleCenter,
                                       center: (any UserNotificationCenterServing)?) {
        waiterRegistry.discardInactive()
        self.store = store
        self.notificationJournal = journal
        self.userNotificationCenter = center
    }

    func waiterCountForTesting(requestId: String) -> Int { waiterRegistry.subscriberCount(requestId) }
}

extension AgentNotificationRegressionTests {
    private func semanticEvent(_ fixture: Fixture, source: String, sequence: Int64 = 1,
                               request: String = "approval") -> AgentJournalEvent {
        fixture.source.surfaceResumeBindingsByPanelId[fixture.panelId] = SurfaceResumeBindingSnapshot(
            name: source, kind: source, command: "agent resume", checkpointId: "session", source: "agent-hook", updatedAt: 1)
        return AgentJournalEvent(sequence: sequence, committedAtMs: sequence,
            draft: AgentJournalEventDraft(kind: .approvalRequested, occurredAtMs: sequence,
                source: source, agentKey: source == "claude" ? "claude_code" : source,
                sessionId: "session", workspaceId: fixture.source.id.uuidString,
                surfaceId: fixture.panelId.uuidString,
                attention: AgentAttentionContext(requestIdentity: request,
                    notification: AgentJournalNotification(title: "Semantic approval", subtitle: "",
                        body: "Approval needed", category: "needs-permission"))))
    }

    @Test(arguments: ["claude", "codex"])
    func semanticReplayAfterReadDoesNotRepeatEffects(source: String) throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let journal = try AgentJournalStore(databaseURL: url.appendingPathComponent("journal.sqlite"))
        defer { journal.close() }
        var reconciler = AgentNotificationReconciler()
        var deliveries: [TerminalNotificationPolicyEffects] = []
        fixture.store.configureNotificationDeliveryHandlerForTesting { _, _, effects in deliveries.append(effects) }
        let first = semanticEvent(fixture, source: source)
        let decision = reconciler.apply(first)
        #expect(AgentJournalLifecycleCenter.claimNotification(first, decision: decision, store: journal))
        AgentJournalLifecycleCenter.deliverNotification(first, identity: try #require(decision.identity))
        TerminalMutationBus.shared.drainForTesting()
        #expect(deliveries.count == 1)
        let effects = try #require(deliveries.first)
        #expect(effects.desktop && effects.sound && effects.command)
        #expect(effects.record && effects.markUnread && effects.paneFlash && effects.reorderWorkspace)
        #expect(fixture.store.notifications.count == 1)
        #expect(fixture.store.hasUnreadNotification(forTabId: fixture.source.id, surfaceId: fixture.panelId))
        #expect(fixture.store.hasUnreadNotificationRequiringPaneFlash(forTabId: fixture.source.id, surfaceId: fixture.panelId))
        fixture.store.clearNotifications(forTabId: fixture.source.id, surfaceId: fixture.panelId)
        let replay = semanticEvent(fixture, source: source, sequence: 2)
        #expect(!AgentJournalLifecycleCenter.claimNotification(replay, decision: reconciler.apply(replay), store: journal))
        TerminalMutationBus.shared.drainForTesting()
        #expect(deliveries.count == 1)
        #expect(fixture.store.notifications.isEmpty)
    }

    @Test(arguments: ["claude", "codex"])
    func semanticNotificationFollowsMovedSurfaceAndRejectsMissingSurface(source: String) throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        let event = semanticEvent(fixture, source: source)
        try movePanel(fixture)
        #expect(AgentJournalLifecycleCenter.notificationTargetIsCurrent(event.draft))
        AgentJournalLifecycleCenter.deliverNotification(event, identity: "semantic-event")
        TerminalMutationBus.shared.drainForTesting()
        #expect(fixture.store.notifications.map(\.tabId) == [fixture.destination.id])
        #expect(!fixture.store.hasUnreadNotification(forTabId: fixture.source.id, surfaceId: fixture.panelId))
        var stale = event.draft
        stale.surfaceId = UUID().uuidString
        #expect(!AgentJournalLifecycleCenter.notificationTargetIsCurrent(stale))
    }

    @Test(arguments: ["claude", "codex"])
    func continuationCancelsQueuedSemanticEffectsWithoutClearingLaterApproval(source: String) throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        var reconciler = AgentNotificationReconciler()
        let first = semanticEvent(fixture, source: source)
        let decision = reconciler.apply(first)
        AgentJournalLifecycleCenter.deliverNotification(first, identity: try #require(decision.identity))
        var continuation = first.draft
        continuation.kind = .turnStarted
        continuation.occurredAtMs = 2
        continuation.attention = AgentAttentionContext(turnIdentity: "next-turn")
        let continued = AgentJournalEvent(sequence: 2, committedAtMs: 2, draft: continuation)
        AgentJournalLifecycleCenter.clearInvalidatedNotifications(continued, decision: reconciler.apply(continued))
        let later = semanticEvent(fixture, source: source, sequence: 3, request: "later")
        let next = reconciler.apply(later)
        AgentJournalLifecycleCenter.deliverNotification(later, identity: try #require(next.identity))
        TerminalMutationBus.shared.drainForTesting()
        #expect(fixture.store.notifications.count == 1)
        #expect(fixture.store.notifications.first?.correlationKey == next.identity)
    }
    @Test(arguments: ["claude", "codex"])
    func finalDeliveryRejectsReplacedSessionButAcceptsItsResume(source: String) throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        let event = semanticEvent(fixture, source: source)
        fixture.source.surfaceResumeBindingsByPanelId[fixture.panelId] = SurfaceResumeBindingSnapshot(
            name: source, kind: source, command: "agent resume", checkpointId: "replacement",
            source: "agent-hook", updatedAt: 1)
        #expect(!AgentJournalLifecycleCenter.notificationTargetIsCurrent(event.draft))
        fixture.source.surfaceResumeBindingsByPanelId[fixture.panelId]?.checkpointId = "session"
        #expect(AgentJournalLifecycleCenter.notificationTargetIsCurrent(event.draft))
        let request = TerminalNotificationPolicyRequest(tabId: fixture.source.id,
            surfaceId: fixture.panelId, title: "Agent", subtitle: "", body: "Ready", cwd: nil,
            isAppFocused: false, isFocusedPanel: false,
            agent: TerminalNotificationPolicyAgentContext(kind: source, sessionId: "session"))
        #expect(AgentJournalLifecycleCenter.notificationRequestIsCurrent(request))
        fixture.source.surfaceResumeBindingsByPanelId[fixture.panelId]?.checkpointId = "replacement"
        #expect(!AgentJournalLifecycleCenter.notificationRequestIsCurrent(request))
        fixture.source.surfaceResumeBindingsByPanelId[fixture.panelId]?.checkpointId = "session"
        fixture.source.surfaceResumeBindingsByPanelId[fixture.panelId]?.kind = source == "claude" ? "codex" : "claude"
        #expect(!AgentJournalLifecycleCenter.notificationRequestIsCurrent(request))
        fixture.source.surfaceResumeBindingsByPanelId.removeValue(forKey: fixture.panelId)
        #expect(!AgentJournalLifecycleCenter.notificationRequestIsCurrent(request))
    }

    @MainActor private final class FeedEffectRecorder {
        var banners = 0
        var unreadWhenBannerPosted = false
    }

    @Test(arguments: ["claude", "codex"], [false, true])
    func genuineFeedWaitSharesAdmissionAndRecordedEffects(source: String, duplicate: Bool) async throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = AgentJournalLifecycleCenter(databaseURL: root.appendingPathComponent("journal.sqlite"))
        let previousStore = FeedCoordinator.shared.store
        let previousJournal = FeedCoordinator.shared.notificationJournal
        let previousObserver = FeedCoordinatorTestHooks.notificationPostObserver
        let previousCenter = FeedCoordinator.shared.notificationCenterForTesting
        defer {
            FeedCoordinatorTestHooks.notificationPostObserver = previousObserver
            FeedCoordinator.shared.restoreInstallationForTesting(store: previousStore,
                journal: previousJournal, center: previousCenter)
        }
        FeedCoordinator.shared.install(store: WorkstreamStore(ringCapacity: 10), notificationJournal: journal)
        let recorder = FeedEffectRecorder()
        let banner = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        defer { banner.continuation.finish() }
        let requestID = UUID().uuidString
        let workspaceID = fixture.source.id
        let surfaceID = fixture.panelId
        fixture.source.surfaceResumeBindingsByPanelId[surfaceID] = SurfaceResumeBindingSnapshot(
            name: source, kind: source, command: "agent resume", checkpointId: "feed-session", source: "agent-hook", updatedAt: 1)
        FeedCoordinatorTestHooks.notificationPostObserver = { _, request in
            MainActor.assumeIsolated {
                guard request == requestID else { return }
                recorder.banners += 1
                recorder.unreadWhenBannerPosted = TerminalNotificationStore.shared
                    .hasUnreadNotification(forTabId: workspaceID, surfaceId: surfaceID)
                banner.continuation.yield(())
            }
        }
        let event = WorkstreamEvent(sessionId: try #require(FeedWorkstreamIdentifier(agentID: source, sessionID: "feed-session")).rawValue,
            hookEventName: .permissionRequest, source: source,
            workspaceId: workspaceID.uuidString, surfaceId: surfaceID.uuidString,
            toolName: "Tool", requestId: requestID)
        let primary = Task.detached {
            let result = FeedCoordinator.shared.ingestBlocking(event: event, waitTimeout: 15)
            banner.continuation.finish()
            return result
        }
        var iterator = banner.stream.makeAsyncIterator()
        let posted = await iterator.next()
        #expect(posted != nil)
        var secondary: Task<FeedCoordinator.IngestBlockingResult, Never>?
        if duplicate {
            secondary = Task.detached { FeedCoordinator.shared.ingestBlocking(event: event, waitTimeout: 15) }
            let deadline = ContinuousClock.now + .seconds(5)
            while FeedCoordinator.shared.waiterCountForTesting(requestId: requestID) < 2, ContinuousClock.now < deadline {
                await Task.yield()
            }
            #expect(FeedCoordinator.shared.waiterCountForTesting(requestId: requestID) == 2)
        }
        FeedCoordinator.shared.deliverReply(requestId: requestID, decision: .permission(.once))
        let result = await primary.value
        guard case .resolved(let itemID, _) = result else {
            Issue.record("A genuine Feed wait must notify and accept its reply: \(result)")
            return
        }
        if let secondary {
            guard case .resolved(let duplicateID, _) = await secondary.value else {
                Issue.record("A duplicate waiter lost the shared reply")
                return
            }
            #expect(duplicateID == itemID)
        }
        #expect(recorder.banners == 1)
        #expect(recorder.unreadWhenBannerPosted)
    }
    @Test(arguments: ["claude", "codex"])
    func feedToolResultDoesNotReopenSettledCompletion(source: String) throws {
        let workspace = UUID().uuidString
        let surface = UUID().uuidString
        var reconciler = AgentNotificationReconciler()
        let completed = AgentJournalEvent(sequence: 1, committedAtMs: 100,
            draft: AgentJournalEventDraft(kind: .turnCompleted, occurredAtMs: 100,
                source: source, agentKey: source, sessionId: "session",
                workspaceId: workspace, surfaceId: surface,
                attention: AgentAttentionContext(turnIdentity: "turn")))
        _ = reconciler.apply(completed)
        let event = WorkstreamEvent(sessionId: "session", hookEventName: .postToolUse,
            source: source, workspaceId: workspace, surfaceId: surface,
            toolName: "Tool", extraFieldsJSON: "{\"tool_use_id\":\"ordinary-tool\",\"turn_id\":\"turn\"}")
        let draft = try #require(AgentFeedSemanticInput(event: event, agentKey: source).draft())
        #expect(!draft.pendingWork)
        let result = AgentJournalEvent(sequence: 2, committedAtMs: 200, draft: draft)
        #expect(reconciler.apply(result).invalidatedCorrelationKeys.isEmpty)
        #expect(reconciler.lifecycleEvent(result).draft.declaredPhase == .idle)
    }

    @Test(arguments: ["claude", "codex"])
    func observedChildCompletionDeliversTheReleasedCompletion(source: String) async throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let center = AgentJournalLifecycleCenter(databaseURL: root.appendingPathComponent("journal.sqlite"))
        fixture.source.surfaceResumeBindingsByPanelId[fixture.panelId] = SurfaceResumeBindingSnapshot(
            name: source, kind: source, command: "agent resume", checkpointId: "session", source: "agent-hook", updatedAt: 1)
        func draft(_ kind: AgentJournalEventKind, at occurredAt: Int64, request: String? = nil,
                   notify: Bool = false) -> AgentJournalEventDraft {
            AgentJournalEventDraft(kind: kind, occurredAtMs: occurredAt, source: source,
                agentKey: source == "claude" ? "claude_code" : source, sessionId: "session",
                workspaceId: fixture.source.id.uuidString, surfaceId: fixture.panelId.uuidString,
                attention: AgentAttentionContext(turnIdentity: "turn", requestIdentity: request,
                    notification: notify ? AgentJournalNotification(title: "Agent", subtitle: "",
                        body: "Ready", category: "turn-complete") : nil))
        }
        // Nothing awaits an observation, so the completion a child release unlocks
        // must be delivered by the journal worker itself, not just receipted.
        center.observe(draft(.turnStarted, at: 1))
        center.observe(draft(.childSpawned, at: 2, request: "child"))
        center.observe(draft(.turnCompleted, at: 3, notify: true))
        center.observe(draft(.childCompleted, at: 4, request: "child"))
        let deadline = ContinuousClock.now + .seconds(10)
        while fixture.store.notifications.isEmpty, ContinuousClock.now < deadline {
            TerminalMutationBus.shared.drainForTesting()
            try await Task.sleep(for: .milliseconds(20))
        }
        TerminalMutationBus.shared.drainForTesting()
        #expect(fixture.store.notifications.map(\.body) == ["Ready"])
        #expect(fixture.store.hasUnreadNotification(forTabId: fixture.source.id, surfaceId: fixture.panelId))
    }

}
