import CMUXAgentLaunch
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Claude Code writes `<config>/projects/<slug>/<id>.jsonl` only after the
/// first message. A session that was started and quit before any prompt has
/// nothing to resume, so cmux must not save or replay `cmux restore claude`.
@MainActor
@Suite(.serialized)
struct ClaudeTranscriptlessRestoreTests {
    private struct Fixture {
        let root: URL
        let configDirectory: URL
        let workingDirectory: URL
        let hookStateDirectory: URL
        let defaults: UserDefaults
        let defaultsName: String

        var environment: [String: String] {
            ["CMUX_AGENT_HOOK_STATE_DIR": hookStateDirectory.path]
        }

        func transcriptURL(sessionID: String) -> URL {
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
            .appendingPathComponent("cmux-claude-transcriptless-\(UUID().uuidString)", isDirectory: true)
        let configDirectory = root.appendingPathComponent("claude-config", isDirectory: true)
        let workingDirectory = root.appendingPathComponent("repo", isDirectory: true)
        let hookStateDirectory = root.appendingPathComponent("hook-state", isDirectory: true)
        try fileManager.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: hookStateDirectory, withIntermediateDirectories: true)
        let defaultsName = "cmux-claude-transcriptless-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defaults.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)
        let fixture = Fixture(
            root: root,
            configDirectory: configDirectory,
            workingDirectory: workingDirectory,
            hookStateDirectory: hookStateDirectory,
            defaults: defaults,
            defaultsName: defaultsName
        )
        try fileManager.createDirectory(
            at: fixture.transcriptURL(sessionID: "placeholder").deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        return fixture
    }

    private func writeHookRecord(
        _ fixture: Fixture,
        sessionID: String,
        workspaceID: UUID,
        panelID: UUID
    ) throws {
        let storeURL = RestorableAgentKind.claude.hookStoreFileURL(
            homeDirectory: fixture.root.path,
            environment: fixture.environment
        )
        // SessionStart reports where Claude will write the transcript before
        // the file exists.
        let record: [String: Any] = [
            "sessionId": sessionID,
            "workspaceId": workspaceID.uuidString,
            "surfaceId": panelID.uuidString,
            "cwd": fixture.workingDirectory.path,
            "transcriptPath": fixture.transcriptURL(sessionID: sessionID).path,
            "updatedAt": 1_791_483_500,
            "launchCommand": [
                "launcher": "claude",
                "executablePath": "/usr/local/bin/claude",
                "arguments": ["/usr/local/bin/claude"],
                "workingDirectory": fixture.workingDirectory.path,
                "environment": ["CLAUDE_CONFIG_DIR": fixture.configDirectory.path],
                "capturedAt": 1_791_483_500,
                "source": "test",
            ],
        ]
        let data = try JSONSerialization.data(
            withJSONObject: ["version": 1, "sessions": [sessionID: record]],
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: storeURL, options: .atomic)
    }

    private func writeTranscript(_ fixture: Fixture, sessionID: String) throws {
        try """
        {"type":"user","sessionId":"\(sessionID)","cwd":"\(fixture.workingDirectory.path)","message":{"role":"user","content":"hello"}}

        """.write(to: fixture.transcriptURL(sessionID: sessionID), atomically: true, encoding: .utf8)
    }

    private func hookBinding(_ fixture: Fixture, sessionID: String) -> SurfaceResumeBindingSnapshot {
        SurfaceResumeBindingSnapshot(
            name: "Claude Code",
            kind: "claude",
            command: "claude --resume \(sessionID)",
            cwd: fixture.workingDirectory.path,
            checkpointId: sessionID,
            source: "agent-hook",
            environment: ["CLAUDE_CONFIG_DIR": fixture.configDirectory.path],
            autoResume: true,
            approvalPolicy: .auto,
            updatedAt: 1_791_483_501
        )
    }

    private func loadIndex(_ fixture: Fixture) -> RestorableAgentSessionIndex {
        RestorableAgentSessionIndex.load(
            homeDirectory: fixture.root.path,
            fileManager: .default,
            registry: CmuxVaultAgentRegistry(registrations: []),
            detectedSnapshots: [:],
            environment: fixture.environment,
            processArgumentsProvider: { _ in nil },
            processPresenceProvider: { _ in .absent }
        )
    }

    /// Saves the source workspace with `index`, forces unknown liveness (the
    /// live-tab-at-quit case from #20246), and restores the result.
    private enum TranscriptTiming {
        case never
        case beforeIndexLoad
        case afterIndexLoad
    }

    private func saveAndRestore(
        _ fixture: Fixture,
        transcript: TranscriptTiming,
        index: (Fixture) -> RestorableAgentSessionIndex
    ) throws -> (terminal: SessionTerminalPanelSnapshot?, input: String?) {
        let source = Workspace(
            agentSessionAutoResumeDefaults: fixture.defaults,
            restorableAgentIndexProvider: { .empty }
        )
        defer { source.teardownAllPanels() }
        let panelID = try #require(source.focusedPanelId)
        let sessionID = UUID().uuidString.lowercased()
        try writeHookRecord(fixture, sessionID: sessionID, workspaceID: source.id, panelID: panelID)
        if transcript == .beforeIndexLoad {
            try writeTranscript(fixture, sessionID: sessionID)
        }
        source.surfaceResumeBindingsByPanelId[panelID] = hookBinding(fixture, sessionID: sessionID)

        let agentIndex = index(fixture)
        if transcript == .afterIndexLoad {
            try writeTranscript(fixture, sessionID: sessionID)
        }
        var snapshot = source.sessionSnapshot(
            includeScrollback: false,
            restorableAgentIndex: agentIndex
        )
        let savedTerminal = snapshot.panels.first?.terminal
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
        let restoredPanel = try #require(restored.terminalPanel(for: restoredPanelID))
        return (savedTerminal, restoredPanel.surface.debugInitialInputForTesting())
    }

    @Test("A Claude session quit before its first prompt is not saved or restored")
    func transcriptlessClaudeSessionIsNotSavedOrRestored() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let result = try saveAndRestore(fixture, transcript: .never) { loadIndex($0) }

        #expect(result.terminal?.resumeBinding == nil)
        #expect(result.terminal?.agent == nil)
        #expect(result.input == nil, Comment(rawValue: result.input ?? ""))
    }

    @Test("A Claude session with a transcript still saves and restores")
    func claudeSessionWithTranscriptStillRestores() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let result = try saveAndRestore(fixture, transcript: .beforeIndexLoad) { loadIndex($0) }

        let binding = try #require(result.terminal?.resumeBinding)
        #expect(binding.kind == "claude")
        let input = try #require(result.input)
        #expect(input == " cmux restore claude \(binding.checkpointId ?? "")\n", Comment(rawValue: input))
    }

    @Test("A first prompt sent after the index loaded keeps the Claude binding")
    func transcriptWrittenAfterIndexLoadKeepsBinding() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let result = try saveAndRestore(fixture, transcript: .afterIndexLoad) { loadIndex($0) }

        let binding = try #require(result.terminal?.resumeBinding)
        #expect(binding.kind == "claude")
        #expect(result.input == " cmux restore claude \(binding.checkpointId ?? "")\n")
    }

    @Test("A cached index marked incomplete still drops a transcript-less Claude session")
    func cachedIndexDropsTranscriptlessClaudeSession() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        // Update relaunch and the quit deadline fallback save from a cached
        // index. Its evidence is re-checked on disk before anything is dropped.
        let result = try saveAndRestore(fixture, transcript: .never) {
            loadIndex($0).markingIncomplete()
        }

        #expect(result.terminal?.resumeBinding == nil)
        #expect(result.input == nil, Comment(rawValue: result.input ?? ""))
    }

    @Test("A cached index keeps a Claude session whose first prompt landed after it loaded")
    func cachedIndexKeepsClaudeSessionWithLaterTranscript() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let result = try saveAndRestore(fixture, transcript: .afterIndexLoad) {
            loadIndex($0).markingIncomplete()
        }

        #expect(result.terminal?.resumeBinding?.kind == "claude")
    }
}
