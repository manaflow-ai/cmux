import CmuxAgentJournal
import CmuxSettings
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A turn's notification, once read or dismissed, stays dismissed: Claude's
/// ~60 s `idle_prompt` reminder and replayed completions for the same turn
/// must not create a new unread entry, while real new attention still does.
extension AgentNotificationRegressionTests {
    private struct JournalHarness {
        let center: AgentJournalLifecycleCenter
        let directory: URL
        let restoreDefaults: () -> Void

        func close() {
            restoreDefaults()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func makeJournalHarness(_ fixture: Fixture, source: String) throws -> JournalHarness {
        fixture.source.surfaceResumeBindingsByPanelId[fixture.panelId] = SurfaceResumeBindingSnapshot(
            name: source, kind: source, command: "agent resume", checkpointId: "session",
            source: "agent-hook", updatedAt: 1)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-acknowledged-turn-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Pin the shipped defaults so a developer's own settings cannot hide
        // the reminder this suite proves is suppressed for the right reason.
        let catalog = NotificationsCatalogSection()
        let keys = [catalog.agentIdleReminder.userDefaultsKey, catalog.agentTurnComplete.userDefaultsKey]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        catalog.agentIdleReminder.set(true, in: .standard)
        catalog.agentTurnComplete.set("always", in: .standard)
        return JournalHarness(
            center: AgentJournalLifecycleCenter(databaseURL: directory.appendingPathComponent("journal.sqlite3")),
            directory: directory,
            restoreDefaults: {
                for (key, value) in zip(keys, saved) {
                    if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
                }
            })
    }

    private func draft(_ fixture: Fixture, _ kind: AgentJournalEventKind, source: String, at time: Int64,
                       turn: String? = nil, request: String? = nil, category: String? = nil,
                       body: String = "Done", nativeEvent: String? = nil) -> AgentJournalEventDraft {
        AgentJournalEventDraft(kind: kind, occurredAtMs: time, source: source,
            agentKey: source == "claude" ? "claude_code" : source, sessionId: "session",
            workspaceId: fixture.source.id.uuidString, surfaceId: fixture.panelId.uuidString,
            nativeEvent: nativeEvent,
            attention: AgentAttentionContext(turnIdentity: turn, requestIdentity: request,
                notification: category.map {
                    AgentJournalNotification(title: source, subtitle: "", body: body, category: $0)
                }))
    }

    /// Runs observations through the live consumer, then waits on a no-op
    /// admission: the operation stream is FIFO, so its reply orders after them.
    private func settle(_ harness: JournalHarness, _ fixture: Fixture, _ drafts: [AgentJournalEventDraft]) async {
        for draft in drafts { harness.center.observe(draft) }
        _ = await harness.center.admitNotification(AgentJournalEventDraft(kind: .stateChanged, occurredAtMs: 0,
            source: "barrier", agentKey: "barrier", unattributedReason: "test-barrier"))
        TerminalMutationBus.shared.drainForTesting()
    }

    private func unreadCount(_ fixture: Fixture) -> Int {
        fixture.store.notifications.filter { !$0.isRead && $0.surfaceId == fixture.panelId }.count
    }

    /// Claude Code fires `Notification(idle_prompt)` about 60 s after a turn
    /// settles. Once the user read that turn's completion, the reminder is not
    /// new attention and must not come back as an unread entry.
    @Test func claudeIdleReminderAfterReadCompletionStaysQuiet() async throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        let harness = try makeJournalHarness(fixture, source: "claude")
        defer { harness.close() }

        await settle(harness, fixture, [
            draft(fixture, .sessionStarted, source: "claude", at: 1),
            draft(fixture, .turnStarted, source: "claude", at: 2),
            draft(fixture, .turnCompleted, source: "claude", at: 3, category: "turn-complete", nativeEvent: "Stop"),
        ])
        #expect(unreadCount(fixture) == 1)
        fixture.store.markRead(forTabId: fixture.source.id, surfaceId: fixture.panelId)
        #expect(unreadCount(fixture) == 0)

        let reminder = draft(fixture, .idleObserved, source: "claude", at: 60_003, category: "idle-reminder",
                             body: "Claude is waiting for your input", nativeEvent: "Notification")
        #expect(await !harness.center.admitNotification(reminder))
        await settle(harness, fixture, [])
        #expect(unreadCount(fixture) == 0)
    }

    /// Dismissing (clearing) the completion acknowledges the turn the same way.
    @Test func claudeIdleReminderAfterDismissedCompletionStaysQuiet() async throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        let harness = try makeJournalHarness(fixture, source: "claude")
        defer { harness.close() }

        await settle(harness, fixture, [
            draft(fixture, .sessionStarted, source: "claude", at: 1),
            draft(fixture, .turnStarted, source: "claude", at: 2),
            draft(fixture, .turnCompleted, source: "claude", at: 3, category: "turn-complete", nativeEvent: "Stop"),
        ])
        fixture.store.clearNotifications(forTabId: fixture.source.id, surfaceId: fixture.panelId)

        await settle(harness, fixture, [
            draft(fixture, .idleObserved, source: "claude", at: 60_003, category: "idle-reminder",
                  body: "Claude is waiting for your input", nativeEvent: "Notification"),
        ])
        #expect(fixture.store.notifications.isEmpty)
    }

    /// The reminder is still the nag the user enabled while the completion is
    /// unread, and a later turn or a permission request is real new attention.
    @Test func claudeUnreadCompletionNewTurnAndPermissionStillNotify() async throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        let harness = try makeJournalHarness(fixture, source: "claude")
        defer { harness.close() }

        await settle(harness, fixture, [
            draft(fixture, .sessionStarted, source: "claude", at: 1),
            draft(fixture, .turnStarted, source: "claude", at: 2),
            draft(fixture, .turnCompleted, source: "claude", at: 3, category: "turn-complete", nativeEvent: "Stop"),
        ])
        let unreadReminder = draft(fixture, .idleObserved, source: "claude", at: 60_003, category: "idle-reminder",
                                   body: "Claude is waiting for your input", nativeEvent: "Notification")
        #expect(await harness.center.admitNotification(unreadReminder))

        fixture.store.markRead(forTabId: fixture.source.id, surfaceId: fixture.panelId)
        await settle(harness, fixture, [
            draft(fixture, .turnStarted, source: "claude", at: 70_000),
            draft(fixture, .turnCompleted, source: "claude", at: 70_001, category: "turn-complete", nativeEvent: "Stop"),
        ])
        #expect(unreadCount(fixture) == 1)

        fixture.store.markRead(forTabId: fixture.source.id, surfaceId: fixture.panelId)
        await settle(harness, fixture, [
            draft(fixture, .turnStarted, source: "claude", at: 80_000),
            draft(fixture, .approvalRequested, source: "claude", at: 80_001, request: "tool-1",
                  category: "needs-permission", body: "Claude needs your permission to use Bash"),
        ])
        #expect(unreadCount(fixture) == 1)
    }

    /// Codex can deliver the same Stop again (a resumed session re-announcing
    /// its last turn, or a second hook producer). The replay keeps its turn
    /// identity and must not resurrect the completion the user read.
    @Test func codexReplayedCompletionAfterReadDoesNotResurrect() async throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        let harness = try makeJournalHarness(fixture, source: "codex")
        defer { harness.close() }

        await settle(harness, fixture, [
            draft(fixture, .sessionStarted, source: "codex", at: 1),
            draft(fixture, .turnStarted, source: "codex", at: 2, turn: "turn-1"),
            draft(fixture, .turnCompleted, source: "codex", at: 3, turn: "turn-1", category: "turn-complete", nativeEvent: "Stop"),
        ])
        #expect(unreadCount(fixture) == 1)
        fixture.store.markRead(forTabId: fixture.source.id, surfaceId: fixture.panelId)

        await settle(harness, fixture, [
            draft(fixture, .turnCompleted, source: "codex", at: 4, turn: "turn-1", category: "turn-complete", nativeEvent: "Stop"),
            draft(fixture, .sessionStarted, source: "codex", at: 5),
            draft(fixture, .turnCompleted, source: "codex", at: 6, turn: "turn-1", category: "turn-complete", nativeEvent: "Stop"),
        ])
        #expect(unreadCount(fixture) == 0)

        await settle(harness, fixture, [
            draft(fixture, .turnStarted, source: "codex", at: 7, turn: "turn-2"),
            draft(fixture, .turnCompleted, source: "codex", at: 8, turn: "turn-2", category: "turn-complete", nativeEvent: "Stop"),
        ])
        #expect(unreadCount(fixture) == 1)
    }
}
