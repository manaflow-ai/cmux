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

    /// The whole phase table, because this one function decides whether an
    /// errored or quota-exhausted pane renders red or orange, and nothing else
    /// pinned it. `error` used to collapse into `needsInput` on the grounds that
    /// nothing rendered errors distinctly; `AgentStatus.error` now does, so that
    /// collapse would make a stuck agent indistinguishable from one waiting on
    /// an answer — the single distinction the state exists to draw.
    @Test func everyJournalPhaseProjectsOntoItsOwnLifecycle() {
        #expect(AgentJournalLifecycleCenter.lifecycle(for: .unknown) == .unknown)
        #expect(AgentJournalLifecycleCenter.lifecycle(for: .running) == .running)
        #expect(AgentJournalLifecycleCenter.lifecycle(for: .idle) == .idle)
        #expect(AgentJournalLifecycleCenter.lifecycle(for: .needsInput) == .needsInput)
        #expect(AgentJournalLifecycleCenter.lifecycle(for: .error) == .error)
        #expect(AgentJournalLifecycleCenter.lifecycle(for: .error) != .needsInput)

        // The projection must stay injective: two phases sharing a lifecycle is
        // exactly how the error state went missing before.
        let projected = AgentLifecyclePhase.allCases.map {
            AgentJournalLifecycleCenter.lifecycle(for: $0)
        }
        #expect(Set(projected).count == AgentLifecyclePhase.allCases.count)
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

    @Test func unavailableJournalReportsError() {
        let center = AgentJournalLifecycleCenter(databaseURL: nil)
        #expect(!center.isAvailable)
        #expect(center.handleAppendCommand("{}") == "ERROR: agent journal unavailable")
    }
}
