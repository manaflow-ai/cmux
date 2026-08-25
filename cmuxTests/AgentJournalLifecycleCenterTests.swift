import CmuxAgentJournal
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Agent journal lifecycle center", .serialized)
struct AgentJournalLifecycleCenterTests {
    @MainActor
    @Test func liveClaudeCompletionJournalAppliesIdleDespiteLiveProcess() async throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        AppDelegate.shared = appDelegate
        appDelegate.tabManager = tabManager
        let workspace = tabManager.addWorkspace(select: true)
        let panelID = try #require(workspace.focusedPanelId)
        let processID = getpid()
        let generation = try #require(
            Workspace.agentPIDProcessIdentity(pid: processID)
        )
        workspace.recordAgentPID(
            key: "claude_code",
            pid: processID,
            panelId: panelID,
            processIdentity: generation,
            refreshPorts: false
        )
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "agent-journal-live-completion-(UUID().uuidString)",
                isDirectory: true
            )
            .appendingPathComponent("journal.sqlite3", isDirectory: false)
        let center = AgentJournalLifecycleCenter(databaseURL: databaseURL)
        defer {
            workspace.clearAgentPID(
                key: "claude_code",
                panelId: panelID,
                clearStatus: true,
                refreshPorts: false
            )
            if tabManager.tabs.contains(where: { $0.id == workspace.id }) {
                tabManager.closeWorkspace(workspace)
            }
            appDelegate.tabManager = nil
            AppDelegate.shared = previousAppDelegate
            try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent())
        }

        let targetWorkspace = workspace.id.uuidString
        let targetPanel = panelID.uuidString
        let started = AgentJournalEventDraft(
            eventId: "live-claude-start",
            kind: .turnStarted,
            occurredAtMs: 1,
            source: "claude",
            agentKey: "claude_code",
            sessionId: "live-claude-session",
            workspaceId: targetWorkspace,
            surfaceId: targetPanel
        )
        let completed = AgentJournalEventDraft(
            eventId: "live-claude-complete",
            kind: .turnCompleted,
            occurredAtMs: 2,
            source: "claude",
            agentKey: "claude_code",
            sessionId: "live-claude-session",
            workspaceId: targetWorkspace,
            surfaceId: targetPanel
        )
        for draft in [started, completed] {
            let json = try #require(
                String(data: JSONEncoder().encode(draft), encoding: .utf8)
            )
            #expect(center.handleAppendCommand(json).hasPrefix("OK"))
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if workspace.agentLifecycleStatesByPanelId[panelID]?["claude_code"] == .idle {
                break
            }
            await Task.yield()
        }
        #expect(
            workspace.agentLifecycleStatesByPanelId[panelID]?["claude_code"] == .idle,
            "A live Claude process must not block its journaled completion from applying."
        )
    }

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

    @Test func unavailableJournalReportsError() {
        let center = AgentJournalLifecycleCenter(databaseURL: nil)
        #expect(!center.isAvailable)
        #expect(center.handleAppendCommand("{}") == "ERROR: agent journal unavailable")
    }
}
