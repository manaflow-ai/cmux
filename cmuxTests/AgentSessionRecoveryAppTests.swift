import CMUXAgentLaunch
import Darwin
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
        try append(.sessionStarted, "0b7a1e7c-3f0a-4c6e-9d59-8a0d8f7c2b11")
        try append(.turnStarted, "0b7a1e7c-3f0a-4c6e-9d59-8a0d8f7c2b11")
        try append(.sessionStarted, "plain")
        try append(.sessionStarted, "finished")
        try append(.sessionEnded, "finished")
        try append(.sessionStarted, "already-open")
        try append(.sessionStarted, "no-transcript")
        try append(.sessionStarted, "no-pid")
        try append(.sessionStarted, "missing-pid-start")
        store.close()

        func record(
            _ id: String,
            cwd: String,
            launch: AgentLaunchCommand,
            hasTranscript: Bool = true,
            pid: Int? = 999_999,
            pidStartSeconds: Int64? = 1
        ) throws -> RestorableAgentHookSessionRecord {
            let transcript = root.appendingPathComponent("\(id).jsonl")
            if hasTranscript { try Data("{}\n".utf8).write(to: transcript) }
            return RestorableAgentHookSessionRecord(
                sessionId: id,
                workspaceId: UUID().uuidString,
                surfaceId: UUID().uuidString,
                cwd: cwd,
                transcriptPath: transcript.path,
                pid: pid,
                pidStartSeconds: pidStartSeconds,
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
            "0b7a1e7c-3f0a-4c6e-9d59-8a0d8f7c2b11": try record("0b7a1e7c-3f0a-4c6e-9d59-8a0d8f7c2b11", cwd: "/Users/me/Projects/my app", launch: proxied),
            "plain": try record("plain", cwd: "/Users/me/Projects/plain", launch: plain),
            "finished": try record("finished", cwd: "/tmp", launch: plain),
            "already-open": try record("already-open", cwd: "/tmp", launch: plain),
            "no-transcript": try record("no-transcript", cwd: "/tmp", launch: plain, hasTranscript: false),
            // A hook that never saw the agent's pid still leaves a resumable session.
            "no-pid": try record("no-pid", cwd: "/tmp", launch: plain, pid: nil),
            // A PID without its process generation is stale evidence. Use
            // this test process so the pre-fix liveness check suppresses it.
            "missing-pid-start": try record(
                "missing-pid-start",
                cwd: "/tmp",
                launch: plain,
                pid: Int(getpid()),
                pidStartSeconds: nil
            ),
        ]
        try JSONEncoder().encode(file).write(to: root.appendingPathComponent("claude-hook-sessions.json"))

        let recovery = AgentSessionRecovery(
            journalURL: journalURL,
            homeDirectory: root.path,
            environment: ["CMUX_AGENT_HOOK_STATE_DIR": root.path]
        )
        let candidates = recovery.candidates(openSessionIds: ["already-open"], now: now)
        #expect(Set(candidates.map(\.sessionId)) == ["0b7a1e7c-3f0a-4c6e-9d59-8a0d8f7c2b11", "plain", "no-pid", "missing-pid-start"])

        let proxiedCandidate = try #require(candidates.first { $0.sessionId == "0b7a1e7c-3f0a-4c6e-9d59-8a0d8f7c2b11" })
        let proxiedCommand = try #require(AgentSessionRecovery.resumeCommand(for: proxiedCandidate))
        // The launcher argv runs inside the portable `/bin/sh -c` wrapper that
        // keeps cmux's Claude shim on PATH for the re-exec'd agent.
        #expect(proxiedCommand.hasPrefix("/bin/sh -c "))
        #expect(proxiedCommand.contains("CMUX_CLAUDE_WRAPPER_SHIM"))
        for word in ["sr", "claude", "proxy", "--account", "me@example.com", "--resume", "0b7a1e7c-3f0a-4c6e-9d59-8a0d8f7c2b11"] {
            #expect(proxiedCommand.contains(word))
        }
        #expect(AgentSessionRecovery.workspaceTitle(for: proxiedCandidate) == "my app")

        let plainCandidate = try #require(candidates.first { $0.sessionId == "plain" })
        let plainCommand = try #require(AgentSessionRecovery.resumeCommand(for: plainCandidate))
        #expect(plainCommand.contains("--resume"))
        #expect(plainCommand.contains("plain"))
    }

    @Test
    func restoreRejectsMalformedSessionIDsBeforeReadingAppState() {
        let invalidValues: [Any] = [
            "one-session",
            [String](),
            [1],
            NSNull(),
        ]
        for value in invalidValues {
            let result = TerminalController.shared.v2AgentRecoveryRestore(
                params: ["session_ids": value]
            )
            guard case let .err(code, _, _) = result else {
                Issue.record("Expected invalid_params for malformed session_ids")
                continue
            }
            #expect(code == "invalid_params")
        }
    }
}
