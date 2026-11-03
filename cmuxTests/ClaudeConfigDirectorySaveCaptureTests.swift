import CMUXAgentLaunch
import CmuxControlSocket
import CmuxFoundation
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A Claude session is saved with the `CLAUDE_CONFIG_DIR` its own process ran
/// with, not the app's. The hook record usually carries it, but a capture the
/// sanitizer rejected (or a record from an older build) has no environment.
/// The save then reads it from the config directory that holds the session's
/// transcript, or from the live process when the record names no transcript,
/// and restore reopens the session there. The default `~/.claude` stays unset.
@MainActor
@Suite(.serialized)
struct ClaudeConfigDirectorySaveCaptureTests {
    private struct Session {
        let workspace: Workspace
        let panelID: UUID
        let sessionID: String
        let configDirectory: URL
        let processID: Int
        let processIdentity: AgentPIDProcessIdentity
    }

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
            .appendingPathComponent("cmux-claude-config-capture-\(UUID().uuidString)", isDirectory: true)
        let workingDirectory = root.appendingPathComponent("repo", isDirectory: true)
        let hookStateDirectory = root.appendingPathComponent("hook-state", isDirectory: true)
        try fileManager.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: hookStateDirectory, withIntermediateDirectories: true)
        let defaultsName = "cmux-claude-config-capture-\(UUID().uuidString)"
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

    /// Opens a workspace whose Claude session lives under `configPath`. Its hook
    /// record and binding carry a launch capture with no environment, the shape
    /// a sanitizer-rejected capture leaves.
    private func makeSession(
        _ fixture: Fixture,
        configPath: String,
        processID: Int
    ) throws -> Session {
        let workspace = Workspace(
            workingDirectory: fixture.workingDirectory.path,
            agentSessionAutoResumeDefaults: fixture.defaults,
            restorableAgentIndexProvider: { .empty }
        )
        let panelID = try #require(workspace.focusedPanelId)
        let sessionID = UUID().uuidString.lowercased()
        let configDirectory = fixture.root.appendingPathComponent(configPath, isDirectory: true)
        let transcript = fixture.transcriptURL(configDirectory: configDirectory, sessionID: sessionID)
        try FileManager.default.createDirectory(
            at: transcript.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        {"type":"user","sessionId":"\(sessionID)","cwd":"\(fixture.workingDirectory.path)","message":{"role":"user","content":"hello"}}

        """.write(to: transcript, atomically: true, encoding: .utf8)
        workspace.surfaceResumeBindingsByPanelId[panelID] = SurfaceResumeBindingSnapshot(
            name: "Claude Code",
            kind: "claude",
            command: "claude --resume \(sessionID)",
            cwd: fixture.workingDirectory.path,
            checkpointId: sessionID,
            source: "agent-hook",
            launchCommand: Self.envlessLaunchCommand(fixture),
            autoResume: true,
            approvalPolicy: .auto,
            updatedAt: 1_800_300_001
        )
        return Session(
            workspace: workspace,
            panelID: panelID,
            sessionID: sessionID,
            configDirectory: configDirectory,
            processID: processID,
            processIdentity: AgentPIDProcessIdentity(
                pid: pid_t(processID),
                startSeconds: 1_800_300_000,
                startMicroseconds: Int64(processID % 1_000_000)
            )
        )
    }

    private static func envlessLaunchCommand(_ fixture: Fixture) -> AgentLaunchCommandSnapshot {
        AgentLaunchCommandSnapshot(
            launcher: "claude",
            executablePath: "/usr/local/bin/claude",
            arguments: ["/usr/local/bin/claude"],
            workingDirectory: fixture.workingDirectory.path,
            capturedAt: 1_800_300_000,
            source: "test"
        )
    }

    private func writeHookRecords(
        _ fixture: Fixture,
        _ sessions: [Session],
        includeTranscriptPath: Bool = true
    ) throws {
        let storeURL = RestorableAgentKind.claude.hookStoreFileURL(
            homeDirectory: fixture.root.path,
            environment: fixture.environment
        )
        var records: [String: Any] = [:]
        for session in sessions {
            var record: [String: Any] = [
                "sessionId": session.sessionID,
                "workspaceId": session.workspace.id.uuidString,
                "surfaceId": session.panelID.uuidString,
                "pid": session.processID,
                "pidStartSeconds": session.processIdentity.startSeconds,
                "pidStartMicroseconds": session.processIdentity.startMicroseconds,
                "cwd": fixture.workingDirectory.path,
                "updatedAt": 1_800_300_000,
                "launchCommand": [
                    "launcher": "claude",
                    "executablePath": "/usr/local/bin/claude",
                    "arguments": ["/usr/local/bin/claude"],
                    "workingDirectory": fixture.workingDirectory.path,
                    "capturedAt": 1_800_300_000,
                    "source": "test",
                ],
            ]
            if includeTranscriptPath {
                record["transcriptPath"] = fixture.transcriptURL(
                    configDirectory: session.configDirectory,
                    sessionID: session.sessionID
                ).path
            }
            records[session.sessionID] = record
        }
        let data = try JSONSerialization.data(
            withJSONObject: ["version": 1, "sessions": records],
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: storeURL, options: .atomic)
    }

    /// Loads the index with each session's process alive (or gone) and running
    /// in its own pane under its own `CLAUDE_CONFIG_DIR`.
    private func loadIndex(
        _ fixture: Fixture,
        _ sessions: [Session],
        processesAlive: Bool
    ) -> RestorableAgentSessionIndex {
        let byProcessID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.processID, $0) })
        return RestorableAgentSessionIndex.load(
            homeDirectory: fixture.root.path,
            fileManager: .default,
            registry: CmuxVaultAgentRegistry(registrations: []),
            detectedSnapshots: [:],
            environment: fixture.environment,
            processArgumentsProvider: { processID in
                guard processesAlive, let session = byProcessID[processID] else { return nil }
                return CmuxTopProcessArguments(
                    arguments: ["/usr/local/bin/claude"],
                    environment: [
                        "CLAUDE_CONFIG_DIR": session.configDirectory.path,
                        "CMUX_WORKSPACE_ID": session.workspace.id.uuidString,
                        "CMUX_SURFACE_ID": session.panelID.uuidString,
                    ]
                )
            },
            processPresenceProvider: { processID in
                processesAlive && byProcessID[processID] != nil ? .present : .absent
            },
            processIdentityProvider: { processID in
                processesAlive ? byProcessID[processID]?.processIdentity : nil
            }
        )
    }

    /// Saves `session`, restores the snapshot into a fresh workspace, and
    /// returns what was saved and the record `cmux restore claude` reads back.
    private func saveAndRestore(
        _ fixture: Fixture,
        _ session: Session,
        index: RestorableAgentSessionIndex
    ) throws -> (saved: SessionTerminalPanelSnapshot, record: ControlSurfaceRestoreRecord) {
        var snapshot = try JSONDecoder().decode(
            SessionWorkspaceSnapshot.self,
            from: JSONEncoder().encode(
                session.workspace.sessionSnapshot(includeScrollback: false, restorableAgentIndex: index)
            )
        )
        let saved = try #require(snapshot.panels.first?.terminal)
        // The fixture's processes are not real, so liveness at quit is unknown,
        // as for a tab still open when the app quits.
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
        let binding = restored.surfaceResumeBindingsByPanelId[restoredPanelID]
        let record = TerminalController.shared.controlSurfaceAgentContinuationRecord(
            agent: agent,
            source: "test",
            restoredWorkingDirectory: nil,
            binding: binding,
            compatibilityBinding: nil
        )
        return (saved, record)
    }

    @Test("Two live Claude sessions with different config dirs each restore under their own dir")
    func liveSessionsRestoreUnderTheirOwnConfigDirectory() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        // Account roots the index finds the transcripts in, while the records
        // name no transcript path: only each live process says which is its own.
        let personal = try makeSession(fixture, configPath: ".codex-accounts/claude/personal", processID: 910_001)
        let work = try makeSession(fixture, configPath: ".codex-accounts/claude/work", processID: 910_002)
        defer {
            personal.workspace.teardownAllPanels()
            work.workspace.teardownAllPanels()
        }
        try writeHookRecords(fixture, [personal, work], includeTranscriptPath: false)
        let index = loadIndex(fixture, [personal, work], processesAlive: true)

        for session in [personal, work] {
            let entry = try #require(index.entry(workspaceId: session.workspace.id, panelId: session.panelID))
            #expect(entry.processLiveness == .running, "the fixture's process must count as the live owner")

            let result = try saveAndRestore(fixture, session, index: index)
            let expected = session.configDirectory.path
            #expect(result.saved.agent?.sessionId == session.sessionID)
            #expect(result.saved.agent?.launchCommand?.environment?["CLAUDE_CONFIG_DIR"] == expected)
            #expect(result.saved.resumeBinding?.environment?["CLAUDE_CONFIG_DIR"] == expected)
            #expect(result.record.checkpointID == session.sessionID)
            #expect(result.record.environment["CLAUDE_CONFIG_DIR"] == expected)
            #expect(result.record.launchCommand?.environment?["CLAUDE_CONFIG_DIR"] == expected)
        }
    }

    @Test("A Claude session whose process is gone restores under the config dir that holds its transcript")
    func exitedSessionRestoresUnderItsTranscriptConfigDirectory() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let personal = try makeSession(fixture, configPath: "claude-personal", processID: 910_011)
        let work = try makeSession(fixture, configPath: "claude-work", processID: 910_012)
        defer {
            personal.workspace.teardownAllPanels()
            work.workspace.teardownAllPanels()
        }
        try writeHookRecords(fixture, [personal, work])
        let index = loadIndex(fixture, [personal, work], processesAlive: false)

        for session in [personal, work] {
            let result = try saveAndRestore(fixture, session, index: index)
            let expected = session.configDirectory.path
            #expect(result.saved.agent?.launchCommand?.environment?["CLAUDE_CONFIG_DIR"] == expected)
            #expect(result.record.environment["CLAUDE_CONFIG_DIR"] == expected)
            #expect(result.record.launchCommand?.environment?["CLAUDE_CONFIG_DIR"] == expected)
        }
    }

    @Test("A default-account Claude session is saved without naming ~/.claude")
    func defaultAccountSessionKeepsConfigDirectoryUnset() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        // The fixture root is the home directory, so this is the default root.
        let session = try makeSession(fixture, configPath: ".claude", processID: 910_021)
        defer { session.workspace.teardownAllPanels() }
        try writeHookRecords(fixture, [session])
        let index = loadIndex(fixture, [session], processesAlive: false)

        let result = try saveAndRestore(fixture, session, index: index)
        #expect(result.saved.agent?.sessionId == session.sessionID)
        #expect(result.saved.agent?.launchCommand?.environment?["CLAUDE_CONFIG_DIR"] == nil)
        #expect(result.saved.resumeBinding?.environment?["CLAUDE_CONFIG_DIR"] == nil)
        #expect(result.record.environment["CLAUDE_CONFIG_DIR"] == nil)
    }
}
