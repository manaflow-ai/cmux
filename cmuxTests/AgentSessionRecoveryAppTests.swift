import CMUXAgentLaunch
import CmuxAgentJournal
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Incident 2026-09-26: cmux died with `sr claude proxy` sessions open and the
/// relaunch brought none back, though the journal and hook store knew them all.
@Suite(.serialized)
struct AgentSessionRecoveryAppTests {
    @Test
    func sessionsKilledWithTheAppResumeThroughTheirLauncher() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date()
        let journalURL = root.appendingPathComponent("journal.sqlite3")
        let store = try AgentJournalStore(databaseURL: journalURL)
        func append(_ kind: AgentJournalEventKind, _ session: String) throws {
            _ = try store.append(AgentJournalEventDraft(
                kind: kind,
                occurredAtMs: Int64(now.addingTimeInterval(-120).timeIntervalSince1970 * 1000),
                source: "claude",
                agentKey: "claude_code",
                sessionId: session,
                workspaceId: UUID().uuidString,
                surfaceId: UUID().uuidString
            ))
        }
        try append(.sessionStarted, "proxied")
        try append(.turnStarted, "proxied")
        try append(.sessionStarted, "plain")
        try append(.sessionStarted, "finished")
        try append(.sessionEnded, "finished")
        try append(.sessionStarted, "already-open")
        try append(.sessionStarted, "no-transcript")
        store.close()

        func record(
            _ id: String,
            cwd: String,
            launch: AgentLaunchCommand,
            hasTranscript: Bool = true
        ) throws -> RestorableAgentHookSessionRecord {
            let transcript = root.appendingPathComponent("\(id).jsonl")
            if hasTranscript { try Data("{}\n".utf8).write(to: transcript) }
            return RestorableAgentHookSessionRecord(
                sessionId: id,
                workspaceId: UUID().uuidString,
                surfaceId: UUID().uuidString,
                cwd: cwd,
                transcriptPath: transcript.path,
                pid: 999_999,
                pidStartSeconds: 1,
                launchCommand: launch,
                isRestorable: true,
                updatedAt: now.timeIntervalSince1970
            )
        }
        let proxied = AgentLaunchCommand(
            launcher: "claude",
            arguments: ["claude"],
            launcherPrefix: ["sr", "claude", "proxy", "--account", "me@example.com"]
        )
        let plain = AgentLaunchCommand(launcher: "claude", arguments: ["claude"])
        var file = RestorableAgentHookSessionStoreFile()
        file.sessions = [
            "proxied": try record("proxied", cwd: "/Users/me/Projects/my app", launch: proxied),
            "plain": try record("plain", cwd: "/Users/me/Projects/plain", launch: plain),
            "finished": try record("finished", cwd: "/tmp", launch: plain),
            "already-open": try record("already-open", cwd: "/tmp", launch: plain),
            "no-transcript": try record("no-transcript", cwd: "/tmp", launch: plain, hasTranscript: false),
        ]
        try JSONEncoder().encode(file).write(to: root.appendingPathComponent("claude-hook-sessions.json"))

        let recovery = AgentSessionRecovery(
            journalURL: journalURL,
            homeDirectory: root.path,
            environment: ["CMUX_AGENT_HOOK_STATE_DIR": root.path]
        )
        let candidates = recovery.candidates(openSessionIds: ["already-open"], now: now)
        #expect(Set(candidates.map(\.sessionId)) == ["proxied", "plain"])

        let proxiedCandidate = try #require(candidates.first { $0.sessionId == "proxied" })
        #expect(
            AgentSessionRecovery.resumeCommand(for: proxiedCandidate)
                == "sr claude proxy --account me@example.com --resume proxied"
        )
        #expect(AgentSessionRecovery.workspaceTitle(for: proxiedCandidate) == "my app")

        let plainCandidate = try #require(candidates.first { $0.sessionId == "plain" })
        let plainCommand = try #require(AgentSessionRecovery.resumeCommand(for: plainCandidate))
        #expect(plainCommand.contains("--resume"))
        #expect(plainCommand.contains("plain"))
    }

    @Test
    func shellQuotingKeepsArgumentsIntact() {
        #expect(AgentSessionRecovery.shellQuoted("me@example.com") == "me@example.com")
        #expect(AgentSessionRecovery.shellQuoted("it's here") == "'it'\\''s here'")
        #expect(AgentSessionRecovery.shellQuoted("") == "''")
    }
}
