import CMUXAgentLaunch
import CmuxFoundation
import CmuxAgentJournal
import CmuxSettings
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension AgentNotificationRegressionTests {
    private func semanticEvent(_ fixture: Fixture, source: String, sequence: Int64 = 1,
                               request: String = "approval") -> AgentJournalEvent {
        AgentJournalEvent(sequence: sequence, committedAtMs: sequence,
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
    }

    @MainActor private final class FeedEffectRecorder {
        var banners = 0
        var unreadWhenBannerPosted = false
    }

    @Test(arguments: ["claude", "codex"])
    func genuineFeedWaitSharesAdmissionAndRecordedEffects(source: String) async throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = AgentJournalLifecycleCenter(databaseURL: root.appendingPathComponent("journal.sqlite"))
        let previousStore = FeedCoordinator.shared.store
        let previousJournal = FeedCoordinator.shared.notificationJournal
        let previousObserver = FeedCoordinatorTestHooks.notificationPostObserver
        defer {
            FeedCoordinatorTestHooks.notificationPostObserver = previousObserver
            if let previousStore {
                FeedCoordinator.shared.install(store: previousStore, notificationJournal: previousJournal)
            }
        }
        FeedCoordinator.shared.install(store: WorkstreamStore(ringCapacity: 10), notificationJournal: journal)
        let recorder = FeedEffectRecorder()
        let requestID = UUID().uuidString
        let workspaceID = fixture.source.id
        let surfaceID = fixture.panelId
        FeedCoordinatorTestHooks.notificationPostObserver = { _, request in
            MainActor.assumeIsolated {
                guard request == requestID else { return }
                recorder.banners += 1
                recorder.unreadWhenBannerPosted = TerminalNotificationStore.shared
                    .hasUnreadNotification(forTabId: workspaceID, surfaceId: surfaceID)
                FeedCoordinator.shared.deliverReply(requestId: request, decision: .permission(.once))
            }
        }
        let event = WorkstreamEvent(sessionId: try #require(FeedWorkstreamIdentifier(agentID: source, sessionID: "feed-session")).rawValue,
            hookEventName: .permissionRequest, source: source,
            workspaceId: workspaceID.uuidString, surfaceId: surfaceID.uuidString,
            toolName: "Tool", requestId: requestID)
        let result = await Task.detached {
            FeedCoordinator.shared.ingestBlocking(event: event, waitTimeout: 10)
        }.value
        guard case .resolved = result else {
            Issue.record("A genuine Feed wait must notify and accept its reply: \(result)")
            return
        }
        #expect(recorder.banners == 1)
        #expect(recorder.unreadWhenBannerPosted)
    }
}
