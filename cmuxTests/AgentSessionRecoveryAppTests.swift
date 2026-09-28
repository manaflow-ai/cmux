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
        // Without a launcher prefix, recovery resumes through the restore verb.
        #expect(plainCommand.hasSuffix(" restore claude plain"))
    }

    /// A routed Claude session resumes through `cmux restore`, the path a
    /// normal restore takes, from a panel carrying its restore record. That
    /// path checks the launcher on PATH, authorizes the wrapper, and reapplies
    /// the observed permission mode.
    @Test
    func routedSessionsResumeThroughTheRestoreVerb() throws {
        let candidate = AgentRecoveryCandidate(
            kind: "claude",
            sessionId: "0b7a1e7c-3f0a-4c6e-9d59-8a0d8f7c2b11",
            workspaceId: nil,
            cwd: "/tmp",
            launchCommand: AgentLaunchCommand(
                launcher: "claude",
                arguments: ["claude", "--model", "opus"],
                environment: [
                    SubrouterClaudeResumeRouting.environmentKey: "sr claude proxy --resume",
                    SubrouterClaudeResumeRouting.launchBoundEnvironmentKey: "sr claude proxy --resume",
                ],
                launcherPrefix: ["sr", "claude", "proxy", "--account", "me@example.com"]
            ),
            permissionMode: "acceptEdits",
            lastActivity: Date()
        )
        let launch = try #require(AgentSessionRecovery.launch(for: candidate))
        guard case let .restoreVerb(input, agent) = launch else {
            Issue.record("Expected the restore verb, got \(launch)")
            return
        }
        #expect(input.hasSuffix(" restore claude 0b7a1e7c-3f0a-4c6e-9d59-8a0d8f7c2b11\n"))
        #expect(agent.sessionId == candidate.sessionId)
        #expect(agent.permissionMode == "acceptEdits")
        #expect(agent.launchCommand?.launcherPrefix == candidate.launchCommand?.launcherPrefix)
    }

    /// Closing a Claude pane kills the agent before its own end hook reports,
    /// so the journal kept the session open and the next crash recovery
    /// reopened a pane the user had closed.
    @MainActor
    @Test
    func closedClaudePaneIsNotRecoveredAfterACrash() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-recovery-close-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let closedID = "5d1c7a52-0d0e-4b1f-9a4e-2f0f7a9c1e01"
        let killedID = "5d1c7a52-0d0e-4b1f-9a4e-2f0f7a9c1e02"
        let now = Date()
        let journalURL = root.appendingPathComponent("journal.sqlite3")
        let store = try AgentJournalStore(databaseURL: journalURL)
        for id in [closedID, killedID] {
            _ = try store.append(AgentJournalEventDraft(
                kind: .sessionStarted,
                occurredAtMs: Int64(now.addingTimeInterval(-60).timeIntervalSince1970 * 1000),
                source: "claude",
                agentKey: "claude_code",
                sessionId: id,
                workspaceId: UUID().uuidString,
                surfaceId: UUID().uuidString
            ))
        }
        store.close()

        var file = RestorableAgentHookSessionStoreFile()
        for id in [closedID, killedID] {
            let transcript = root.appendingPathComponent("\(id).jsonl")
            try Data("{}\n".utf8).write(to: transcript)
            file.sessions[id] = RestorableAgentHookSessionRecord(
                sessionId: id,
                workspaceId: UUID().uuidString,
                surfaceId: UUID().uuidString,
                cwd: "/tmp",
                transcriptPath: transcript.path,
                pid: nil,
                launchCommand: AgentLaunchCommand(launcher: "claude", arguments: ["claude"]),
                isRestorable: true,
                updatedAt: now.timeIntervalSince1970
            )
        }
        try JSONEncoder().encode(file).write(to: root.appendingPathComponent("claude-hook-sessions.json"))

        let center = AgentJournalLifecycleCenter(databaseURL: journalURL)
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        workspace.agentSessionCloseJournal = AgentSessionCloseJournal(center: center)
        let keptPanel = try #require(workspace.focusedPanelId)
        let closedPanel = try #require(workspace.newTerminalSurfaceInFocusedPane(focus: false)).id
        #expect(closedPanel != keptPanel)
        // What the Claude session-start hook leaves on the surface.
        workspace.surfaceResumeBindingsByPanelId[closedPanel] = SurfaceResumeBindingSnapshot(
            name: "Claude Code", kind: "claude", command: "claude --resume \(closedID)",
            checkpointId: closedID, source: "agent-hook", updatedAt: now.timeIntervalSince1970
        )

        #expect(workspace.closePanel(closedPanel, force: true))

        // The close is journaled on the center's consumer; wait for it to land.
        let reader = AgentJournalSessionTailReader(databaseURL: journalURL)
        func closedHasEnded() -> Bool {
            let tails = (try? reader.sessionTails(occurredAtOrAfterMs: 0)) ?? []
            return tails.first { $0.sessionId == closedID }?.hasEnded == true
        }
        for _ in 0..<100 where !closedHasEnded() {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(closedHasEnded())

        // cmux now crashes; the next launch recovers only the session that
        // died with the app.
        let recovery = AgentSessionRecovery(
            journalURL: journalURL,
            homeDirectory: root.path,
            environment: ["CMUX_AGENT_HOOK_STATE_DIR": root.path]
        )
        let recovered = recovery.candidates(openSessionIds: [], activeSince: now.addingTimeInterval(-600), now: now)
        #expect(recovered.map(\.sessionId) == [killedID])
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
