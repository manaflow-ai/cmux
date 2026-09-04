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
}
