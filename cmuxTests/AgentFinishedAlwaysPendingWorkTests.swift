import CmuxAgentJournal
import CmuxSettings
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// With Settings > Notifications > Agent Finished set to Always, a turn that ends
/// while background work is still running notifies when it ends; When idle keeps
/// holding it until the work is done (https://github.com/manaflow-ai/cmux/issues/24386).
///
/// The journal's reconciler decided "delayed" for every completion with pending
/// work before the setting was read, so Always behaved like When idle.
extension AgentNotificationRegressionTests {
    @Test func alwaysNotifiesATurnThatEndsWithBackgroundWorkPending() async throws {
        let delivered = try await deliveriesAfterPendingCompletion(mode: "always")
        #expect(delivered == 1, "Agent Finished: Always did not notify a turn that ended with background work")
    }

    @Test func whenIdleStillHoldsATurnThatEndsWithBackgroundWorkPending() async throws {
        let delivered = try await deliveriesAfterPendingCompletion(mode: "whenIdle")
        #expect(delivered == 0)
    }

    @Test func alwaysStillNotifiesTheTurnAfterTheBackgroundWorkFinishes() async throws {
        let delivered = try await deliveriesAfterPendingCompletion(mode: "always", thenFinishWork: true)
        #expect(delivered == 2, "each turn end notifies with Always")
    }

    /// Claude can also continue the same turn without a new prompt once the work is
    /// done; that settled Stop is the "work finished" notification and must not be
    /// taken for a repeat of the first.
    @Test func alwaysNotifiesTheSameTurnAgainWhenItsWorkSettles() async throws {
        let delivered = try await deliveriesAfterPendingCompletion(mode: "always", thenSettleSameTurn: true)
        #expect(delivered == 2, "the settled Stop of the same turn did not notify")
    }

    /// Claude's hooks carry no turn id. A reply to a prompt sent while the background
    /// work still runs, which ends with work pending again, is its own notification,
    /// and so is the Stop once everything is done (reported by jacob-carlborg).
    @Test func alwaysNotifiesEachReplyWithoutATurnID() async throws {
        let delivered = try await deliveriesAfterPendingCompletion(mode: "always", repliesWithoutTurnIDs: true)
        #expect(delivered == 3, "a reply without a turn id was taken for a repeat of the earlier one")
    }

    /// Runs one Claude turn that stops with background work pending through the
    /// live journal consumer, with Agent Finished set to `mode`, and counts the
    /// notifications delivered to the pane. `thenFinishWork` adds the turn Claude
    /// runs once the background work is done.
    private func deliveriesAfterPendingCompletion(
        mode: String,
        thenFinishWork: Bool = false,
        thenSettleSameTurn: Bool = false,
        repliesWithoutTurnIDs: Bool = false
    ) async throws -> Int {
        // A private suite, so suites that write the same setting to
        // `UserDefaults.standard` cannot change it mid-test.
        let suiteName = "cmux-agent-finished-always-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(mode, forKey: NotificationsCatalogSection().agentTurnComplete.userDefaultsKey)

        let fixture = try makeFixture()
        defer { fixture.restore() }
        fixture.source.surfaceResumeBindingsByPanelId[fixture.panelId] = SurfaceResumeBindingSnapshot(
            name: "claude", kind: "claude", command: "agent resume", checkpointId: "session",
            source: "agent-hook", updatedAt: 1)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-finished-always-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let center = AgentJournalLifecycleCenter(
            databaseURL: directory.appendingPathComponent("journal.sqlite3"),
            notificationDefaults: defaults
        )
        var deliveries = 0
        fixture.store.configureNotificationDeliveryHandlerForTesting { _, _, _ in deliveries += 1 }

        func draft(_ kind: AgentJournalEventKind, at time: Int64, turn: String?,
                   pendingWork: Bool = false, completes: Bool = false) -> AgentJournalEventDraft {
            AgentJournalEventDraft(kind: kind, occurredAtMs: time, source: "claude", agentKey: "claude_code",
                sessionId: "session", workspaceId: fixture.source.id.uuidString,
                surfaceId: fixture.panelId.uuidString, pendingWork: pendingWork,
                nativeEvent: completes ? "Stop" : nil,
                attention: AgentAttentionContext(turnIdentity: turn,
                    notification: completes
                        ? AgentJournalNotification(title: "Claude Code", subtitle: "", body: "Done", category: "turn-complete")
                        : nil))
        }
        if repliesWithoutTurnIDs {
            for draft in [
                draft(.sessionStarted, at: 1, turn: nil),
                draft(.turnStarted, at: 2, turn: nil),
                draft(.turnCompleted, at: 3, turn: nil, pendingWork: true, completes: true),
                draft(.turnStarted, at: 4, turn: nil),
                draft(.turnCompleted, at: 5, turn: nil, pendingWork: true, completes: true),
                draft(.turnCompleted, at: 6, turn: nil, completes: true),
            ] { center.observe(draft) }
            _ = await center.admitNotification(AgentJournalEventDraft(kind: .stateChanged, occurredAtMs: 0,
                source: "barrier", agentKey: "barrier", unattributedReason: "test-barrier"))
            TerminalMutationBus.shared.drainForTesting()
            return deliveries
        }
        var drafts = [
            draft(.sessionStarted, at: 1, turn: "turn-1"),
            draft(.turnStarted, at: 2, turn: "turn-1"),
            // The turn that started `sleep 60` in the background ends with it still running.
            draft(.turnCompleted, at: 3, turn: "turn-1", pendingWork: true, completes: true),
        ]
        if thenFinishWork {
            drafts += [
                draft(.turnStarted, at: 4, turn: "turn-2"),
                draft(.turnCompleted, at: 5, turn: "turn-2", completes: true),
            ]
        }
        if thenSettleSameTurn {
            drafts.append(draft(.turnCompleted, at: 4, turn: "turn-1", completes: true))
        }
        for draft in drafts { center.observe(draft) }
        // The operation stream is FIFO, so this admission's reply orders after the observations.
        _ = await center.admitNotification(AgentJournalEventDraft(kind: .stateChanged, occurredAtMs: 0,
            source: "barrier", agentKey: "barrier", unattributedReason: "test-barrier"))
        TerminalMutationBus.shared.drainForTesting()
        return deliveries
    }
}
