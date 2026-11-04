import CMUXAgentLaunch
import CmuxAgentJournal
import CmuxControlSocket
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The index drops a Claude launch capture it cannot trust: a launcher that
/// names another agent (inherited from an ancestor's session) or a shell
/// dispatcher's argv. The session still restores through the bare resume verb,
/// and it must keep its account. A surface without a hook binding has nothing
/// else to carry `CLAUDE_CONFIG_DIR`, and a config dir outside the wrapper's
/// search roots is not found again on resume.
@MainActor
@Suite(.serialized)
struct ClaudeDroppedLaunchCaptureAccountTests {
    private struct Fixture {
        let root: URL
        let workingDirectory: URL
        let hookStateDirectory: URL
        let defaults: UserDefaults
        let defaultsName: String

        var environment: [String: String] {
            ["CMUX_AGENT_HOOK_STATE_DIR": hookStateDirectory.path]
        }

        func transcriptURL(configDirectory: URL, sessionID: String) -> URL {
            configDirectory
                .appendingPathComponent("projects", isDirectory: true)
                .appendingPathComponent(
                    RestorableAgentSessionIndex.encodeClaudeProjectDir(workingDirectory.path),
                    isDirectory: true
                )
                .appendingPathComponent("\(sessionID).jsonl", isDirectory: false)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: defaultsName)
        }
    }

    private func makeFixture() throws -> Fixture {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-claude-dropped-launch-\(UUID().uuidString)", isDirectory: true)
        let workingDirectory = root.appendingPathComponent("repo", isDirectory: true)
        let hookStateDirectory = root.appendingPathComponent("hook-state", isDirectory: true)
        try fileManager.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: hookStateDirectory, withIntermediateDirectories: true)
        let defaultsName = "cmux-claude-dropped-launch-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defaults.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)
        return Fixture(
            root: root,
            workingDirectory: workingDirectory,
            hookStateDirectory: hookStateDirectory,
            defaults: defaults,
            defaultsName: defaultsName
        )
    }

    /// Writes one Claude session's transcript under `configDirectory` and its
    /// hook record with `launchCommand`. No hook binding is published.
    private func writeSession(
        _ fixture: Fixture,
        workspace: Workspace,
        panelID: UUID,
        sessionID: String,
        configDirectory: URL,
        recordsTranscriptPath: Bool,
        launchCommand: [String: Any]
    ) throws {
        let transcript = fixture.transcriptURL(configDirectory: configDirectory, sessionID: sessionID)
        try FileManager.default.createDirectory(
            at: transcript.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        {"type":"user","sessionId":"\(sessionID)","cwd":"\(fixture.workingDirectory.path)","message":{"role":"user","content":"hello"}}

        """.write(to: transcript, atomically: true, encoding: .utf8)
        var record: [String: Any] = [
            "sessionId": sessionID,
            "workspaceId": workspace.id.uuidString,
            "surfaceId": panelID.uuidString,
            "cwd": fixture.workingDirectory.path,
            "updatedAt": 1_800_400_000,
            "launchCommand": launchCommand,
        ]
        if recordsTranscriptPath {
            record["transcriptPath"] = transcript.path
        }
        let storeURL = RestorableAgentKind.claude.hookStoreFileURL(
            homeDirectory: fixture.root.path,
            environment: fixture.environment
        )
        let data = try JSONSerialization.data(
            withJSONObject: ["version": 1, "sessions": [sessionID: record]],
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: storeURL, options: .atomic)
    }

    /// Saves the workspace with a freshly loaded index, restores the snapshot
    /// into a new workspace, and returns what was saved and the record
    /// `cmux restore claude` reads back.
    private func saveAndRestore(
        _ fixture: Fixture,
        workspace: Workspace
    ) throws -> (saved: SessionTerminalPanelSnapshot, record: ControlSurfaceRestoreRecord) {
        let index = RestorableAgentSessionIndex.load(
            homeDirectory: fixture.root.path,
            fileManager: .default,
            registry: CmuxVaultAgentRegistry(registrations: []),
            detectedSnapshots: [:],
            environment: fixture.environment,
            processArgumentsProvider: { _ in nil },
            processPresenceProvider: { _ in .absent }
        )
        var snapshot = try JSONDecoder().decode(
            SessionWorkspaceSnapshot.self,
            from: JSONEncoder().encode(
                workspace.sessionSnapshot(includeScrollback: false, restorableAgentIndex: index)
            )
        )
        let saved = try #require(snapshot.panels.first?.terminal)
        for panelIndex in snapshot.panels.indices {
            snapshot.panels[panelIndex].terminal?.wasAgentRunning = nil
        }

        let restored = Workspace(
            agentSessionAutoResumeDefaults: fixture.defaults,
            restorableAgentIndexProvider: { .empty }
        )
        defer { restored.teardownAllPanels() }
        restored.restoreSessionSnapshot(snapshot)
        let restoredPanelID = try #require(restored.focusedPanelId)
        let agent = try #require(restored.restoredAgentSnapshotsByPanelId[restoredPanelID])
        let record = TerminalController.shared.controlSurfaceAgentContinuationRecord(
            agent: agent,
            source: "test",
            restoredWorkingDirectory: nil,
            binding: restored.surfaceResumeBindingsByPanelId[restoredPanelID],
            compatibilityBinding: nil
        )
        return (saved, record)
    }

    private func expectBareClaudeResume(_ record: ControlSurfaceRestoreRecord, sessionID: String) {
        let arguments = record.preparedArguments ?? []
        #expect(arguments.first.map { ($0 as NSString).lastPathComponent } == "claude", Comment(rawValue: "\(arguments)"))
        #expect(arguments.contains(sessionID), Comment(rawValue: "\(arguments)"))
        #expect(!arguments.contains { $0.contains("codex") || $0.contains("zsh") }, Comment(rawValue: "\(arguments)"))
    }

    @Test("A Claude capture with another agent's launcher keeps the account it recorded")
    func foreignLauncherCaptureKeepsRecordedAccount() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let workspace = Workspace(
            workingDirectory: fixture.workingDirectory.path,
            agentSessionAutoResumeDefaults: fixture.defaults,
            restorableAgentIndexProvider: { .empty }
        )
        defer { workspace.teardownAllPanels() }
        let panelID = try #require(workspace.focusedPanelId)
        let sessionID = UUID().uuidString.lowercased()
        // Outside every root the wrapper searches on resume.
        let configDirectory = fixture.root.appendingPathComponent("claude-work", isDirectory: true)
        try writeSession(
            fixture,
            workspace: workspace,
            panelID: panelID,
            sessionID: sessionID,
            configDirectory: configDirectory,
            recordsTranscriptPath: false,
            launchCommand: [
                "launcher": "codex",
                "executablePath": "/usr/local/bin/codex",
                "arguments": ["/usr/local/bin/codex"],
                "workingDirectory": fixture.workingDirectory.path,
                "environment": ["CLAUDE_CONFIG_DIR": configDirectory.path],
                "capturedAt": 1_800_400_000,
                "source": "test",
            ]
        )

        let result = try saveAndRestore(fixture, workspace: workspace)

        #expect(result.saved.agent?.sessionId == sessionID)
        #expect(result.saved.agent?.launchCommand?.environment?["CLAUDE_CONFIG_DIR"] == configDirectory.path)
        #expect(result.record.launchCommand?.environment?["CLAUDE_CONFIG_DIR"] == configDirectory.path)
        expectBareClaudeResume(result.record, sessionID: sessionID)
    }

    @Test("A Claude capture of a shell dispatcher's argv restores under the transcript's account")
    func shellWrapperCaptureRestoresUnderTranscriptAccount() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let workspace = Workspace(
            workingDirectory: fixture.workingDirectory.path,
            agentSessionAutoResumeDefaults: fixture.defaults,
            restorableAgentIndexProvider: { .empty }
        )
        defer { workspace.teardownAllPanels() }
        let panelID = try #require(workspace.focusedPanelId)
        let sessionID = UUID().uuidString.lowercased()
        let configDirectory = fixture.root.appendingPathComponent("claude-work", isDirectory: true)
        try writeSession(
            fixture,
            workspace: workspace,
            panelID: panelID,
            sessionID: sessionID,
            configDirectory: configDirectory,
            recordsTranscriptPath: true,
            launchCommand: [
                "launcher": "claude",
                "executablePath": "/bin/zsh",
                "arguments": ["/bin/zsh", "-lc", "claude"],
                "workingDirectory": fixture.workingDirectory.path,
                "capturedAt": 1_800_400_000,
                "source": "test",
            ]
        )

        let result = try saveAndRestore(fixture, workspace: workspace)

        #expect(result.saved.agent?.sessionId == sessionID)
        #expect(result.saved.agent?.launchCommand?.environment?["CLAUDE_CONFIG_DIR"] == configDirectory.path)
        #expect(result.record.launchCommand?.environment?["CLAUDE_CONFIG_DIR"] == configDirectory.path)
        expectBareClaudeResume(result.record, sessionID: sessionID)
    }

    /// Crash recovery reopens a lost Claude session from the hook store by the
    /// same rule, so a dropped capture keeps its account there too.
    private func recoveredLaunchCommand(
        _ fixture: Fixture,
        launchCommand: (URL) -> AgentLaunchCommand
    ) throws -> (launch: AgentLaunchCommand?, configDirectory: URL) {
        let sessionID = UUID().uuidString.lowercased()
        let configDirectory = fixture.root.appendingPathComponent("claude-work", isDirectory: true)
        let transcript = fixture.transcriptURL(configDirectory: configDirectory, sessionID: sessionID)
        try FileManager.default.createDirectory(
            at: transcript.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{}\n".utf8).write(to: transcript)
        let now = Date()
        let journalURL = fixture.root.appendingPathComponent("journal.sqlite3")
        let store = try AgentJournalStore(databaseURL: journalURL)
        _ = try store.append(AgentJournalEventDraft(
            kind: .sessionStarted,
            occurredAtMs: Int64(now.addingTimeInterval(-60).timeIntervalSince1970 * 1000),
            source: "claude",
            agentKey: "claude_code",
            sessionId: sessionID,
            workspaceId: UUID().uuidString,
            surfaceId: UUID().uuidString
        ))
        store.close()
        var file = RestorableAgentHookSessionStoreFile()
        file.sessions[sessionID] = RestorableAgentHookSessionRecord(
            sessionId: sessionID,
            workspaceId: UUID().uuidString,
            surfaceId: UUID().uuidString,
            cwd: fixture.workingDirectory.path,
            transcriptPath: transcript.path,
            pid: nil,
            launchCommand: launchCommand(configDirectory),
            isRestorable: true,
            updatedAt: now.timeIntervalSince1970
        )
        try JSONEncoder().encode(file).write(
            to: RestorableAgentKind.claude.hookStoreFileURL(
                homeDirectory: fixture.root.path,
                environment: fixture.environment
            )
        )
        let recovered = AgentSessionRecovery(
            journalURL: journalURL,
            homeDirectory: fixture.root.path,
            environment: fixture.environment
        ).candidates(openSessionIds: [], activeSince: now.addingTimeInterval(-600), now: now)
        let candidate = try #require(recovered.first { $0.sessionId == sessionID })
        return (candidate.launchCommand, configDirectory)
    }

    @Test("Crash recovery keeps the account of a Claude capture with another agent's launcher")
    func recoveryKeepsForeignLauncherAccount() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let result = try recoveredLaunchCommand(fixture) { configDirectory in
            AgentLaunchCommand(
                launcher: "codex",
                executablePath: "/usr/local/bin/codex",
                arguments: ["/usr/local/bin/codex"],
                environment: ["CLAUDE_CONFIG_DIR": configDirectory.path]
            )
        }

        #expect(result.launch?.environment?["CLAUDE_CONFIG_DIR"] == result.configDirectory.path)
        #expect(result.launch?.arguments.isEmpty == true)
        #expect(result.launch?.launcher == "claude")
    }

    @Test("Crash recovery restores a shell-dispatcher Claude capture under the transcript's account")
    func recoveryNamesTranscriptAccountForShellWrapperCapture() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let result = try recoveredLaunchCommand(fixture) { _ in
            AgentLaunchCommand(
                launcher: "claude",
                executablePath: "/bin/zsh",
                arguments: ["/bin/zsh", "-lc", "claude"]
            )
        }

        #expect(result.launch?.environment?["CLAUDE_CONFIG_DIR"] == result.configDirectory.path)
        #expect(result.launch?.arguments.isEmpty == true)
    }
}
