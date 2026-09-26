import CmuxAgentJournal
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Agent journal lifecycle center")
struct AgentJournalLifecycleCenterTests {
    @Test func appendCommandCommitsDurablyAndReplaysIdempotently() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-journal-center-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("journal.sqlite3", isDirectory: false)
        let center = AgentJournalLifecycleCenter(databaseURL: url)
        #expect(center.isAvailable)

        let draft = AgentJournalEventDraft(
            eventId: "event-1",
            kind: .turnStarted,
            occurredAtMs: 1,
            source: "claude",
            agentKey: "claude_code",
            sessionId: "session-1",
            workspaceId: UUID().uuidString,
            surfaceId: UUID().uuidString
        )
        let json = try #require(String(data: JSONEncoder().encode(draft), encoding: .utf8))
        #expect(center.handleAppendCommand(json) == "OK 1")
        // The reply is the durable receipt: a retry with the same event id
        // replays the original sequence instead of double-writing.
        #expect(center.handleAppendCommand(json) == "OK 1 replayed")
        #expect(center.handleAppendCommand("not json").hasPrefix("ERROR:"))
        #expect(center.handleAppendCommand("").hasPrefix("ERROR:"))

        // The committed event survives independent reopen (what startup
        // replay reads after a relaunch).
        let store = try AgentJournalStore(databaseURL: url)
        #expect(try store.headSequence() == 1)
        let events = try store.events(afterSequence: 0, limit: 10)
        #expect(events.count == 1)
        #expect(events.first?.draft == draft)
        store.close()
    }

    @Test func guessedTargetsAreRejectedAtAdmission() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-journal-center-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("journal.sqlite3", isDirectory: false)
        let center = AgentJournalLifecycleCenter(databaseURL: url)
        var draft = AgentJournalEventDraft(
            eventId: "event-guessed",
            kind: .approvalRequested,
            occurredAtMs: 1,
            source: "codex",
            agentKey: "codex",
            workspaceId: UUID().uuidString,
            surfaceId: UUID().uuidString
        )
        draft.unattributedReason = "target-unresolved"
        let json = try #require(String(data: JSONEncoder().encode(draft), encoding: .utf8))
        #expect(center.handleAppendCommand(json).hasPrefix("ERROR:"))
    }

    @Test func goalTargetValidatorRunsBeforeDurableCommit() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-journal-goal-binding-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("journal.sqlite3", isDirectory: false)
        let center = AgentJournalLifecycleCenter(databaseURL: url)
        let goal = AgentGoalLifecycle(
            state: .complete,
            generation: "generation-1",
            updatedAtMs: 1,
            provenance: "provider_hook"
        )
        let draft = AgentJournalEventDraft(
            eventId: "goal-binding-1",
            kind: .goalStateChanged,
            occurredAtMs: 1,
            source: "codex",
            agentKey: "codex",
            sessionId: "session-1",
            workspaceId: UUID().uuidString,
            surfaceId: UUID().uuidString,
            goalLifecycle: goal
        )
        let json = try #require(String(data: JSONEncoder().encode(draft), encoding: .utf8))
        #expect(center.handleAppendCommand(json, goalTargetValidator: { _ in false }) == "ERROR: goal target is no longer bound")
        let store = try AgentJournalStore(databaseURL: url)
        #expect(try store.headSequence() == 0)
        #expect(try store.goalLifecycle(source: "codex", sessionId: "session-1") == nil)
        store.close()
    }

    @Test func goalQueryBatchReturnsAbsentRowsAndRejectsOversizedRequests() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-journal-goal-query-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("journal.sqlite3", isDirectory: false)
        let center = AgentJournalLifecycleCenter(databaseURL: url)
        let goal = AgentGoalLifecycle(
            state: .complete,
            generation: "generation-1",
            updatedAtMs: 1,
            provenance: "provider_hook"
        )
        let draft = AgentJournalEventDraft(
            eventId: "goal-query-1",
            kind: .goalStateChanged,
            occurredAtMs: 1,
            source: "codex",
            agentKey: "codex",
            sessionId: "session-1",
            workspaceId: UUID().uuidString,
            surfaceId: UUID().uuidString,
            nativeEvent: "goal-state",
            goalLifecycle: goal
        )
        let json = try #require(String(data: JSONEncoder().encode(draft), encoding: .utf8))
        #expect(center.handleAppendCommand(json) == "OK 1")
        let query = #"{"sessions":[{"source":"codex","session_id":"session-1"},{"source":"codex","session_id":"missing"}]}"#
        let response = try #require(center.handleGoalQueryCommand(query).data(using: .utf8))
        let object = try #require(JSONSerialization.jsonObject(with: response) as? [String: Any])
        let goals = try #require(object["goals"] as? [[String: Any]])
        #expect(goals.count == 2)
        #expect(goals[0]["goal_lifecycle"] != nil)
        #expect(goals[1]["goal_lifecycle"] is NSNull)
        let oversizedPayload = [
            "sessions": Array(repeating: ["source": "codex", "session_id": "s"], count: 257)
        ] as [String: Any]
        let oversized = try #require(String(
            data: JSONSerialization.data(withJSONObject: oversizedPayload),
            encoding: .utf8
        ))
        #expect(center.handleGoalQueryCommand(oversized) == "ERROR: invalid goal query")
    }

    @Test func unavailableJournalReportsError() {
        let center = AgentJournalLifecycleCenter(databaseURL: nil)
        #expect(!center.isAvailable)
        #expect(center.handleAppendCommand("{}") == "ERROR: agent journal unavailable")
    }
    @Test func cancelledAndTerminatedAdmissionsAlwaysResume() async {
        let cancelled = AgentNotificationAdmissionWaiters()
        let id = UUID()
        cancelled.cancel(id)
        let cancelledResult = await withCheckedContinuation { continuation in
            cancelled.register(id, continuation: continuation)
        }
        #expect(cancelledResult == false)
        cancelled.forget(id)

        let terminated = AgentNotificationAdmissionWaiters()
        let result = await withCheckedContinuation { continuation in
            terminated.register(UUID(), continuation: continuation)
            terminated.finish()
        }
        #expect(result == false)
        let afterTermination = await withCheckedContinuation { continuation in
            terminated.register(UUID(), continuation: continuation)
        }
        #expect(afterTermination == false)
    }

    @Test func completedAdmissionCannotResumeTwice() async {
        let admissions = AgentNotificationAdmissionWaiters()
        let id = UUID()
        let result = await withCheckedContinuation { continuation in
            admissions.register(id, continuation: continuation)
            admissions.complete(id, accepted: true)
            admissions.complete(id, accepted: false)
            admissions.finish()
        }
        #expect(result == true)
    }
}
