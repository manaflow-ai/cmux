import Foundation
import CmuxCore
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct AgentSessionAutoResumeSwiftTests {
    @MainActor
    @Test func claudeAgentHookResumeBindingRestoresFromLaunchCwdWhenRuntimeCwdDrifted() throws {
        try withRestoredDefaults(key: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey) {
            let defaults = UserDefaults.standard
            defaults.removeObject(forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)

            let source = Workspace()
            let sourcePanelId = try #require(source.focusedPanelId)
            let sessionId = "claude-drifted-binding-session"
            let launchCwd = "/tmp/cmux-claude-launch"
            let runtimeCwd = "/tmp/cmux-claude-runtime"
            let agent = SessionRestorableAgentSnapshot(
                kind: .claude,
                sessionId: sessionId,
                workingDirectory: launchCwd,
                launchCommand: AgentLaunchCommandSnapshot(
                    launcher: "claude",
                    executablePath: "/usr/local/bin/claude",
                    arguments: ["/usr/local/bin/claude", "--model", "claude-opus-4-8"],
                    workingDirectory: launchCwd,
                    environment: ["CLAUDE_CONFIG_DIR": "/tmp/cmux-claude-config"],
                    capturedAt: 1_777_777_777,
                    source: "process"
                )
            )
            source.updatePanelShellActivityState(panelId: sourcePanelId, state: .commandRunning)
            source.setRestoredAgentSnapshotForTesting(agent, panelId: sourcePanelId)

            let bindingIndex = SurfaceResumeBindingIndex(bindingsByPanel: [
                SurfaceResumeBindingIndex.PanelKey(workspaceId: source.id, panelId: sourcePanelId): SurfaceResumeBindingSnapshot(
                    name: "Claude",
                    kind: "claude",
                    command: "{ cd -- '\(runtimeCwd)' 2>/dev/null || [ ! -d '\(runtimeCwd)' ]; } && 'claude' '--resume' '\(sessionId)'",
                    cwd: runtimeCwd,
                    checkpointId: sessionId,
                    source: "agent-hook",
                    autoResume: true,
                    updatedAt: 1_777_777_777
                ),
            ])
            let snapshot = source.sessionSnapshot(
                includeScrollback: false,
                surfaceResumeBindingIndex: bindingIndex
            )

            #expect(snapshot.panels.first?.terminal?.agent?.workingDirectory == launchCwd)
            #expect(snapshot.panels.first?.terminal?.resumeBinding?.cwd == runtimeCwd)

            let restored = Workspace()
            restored.restoreSessionSnapshot(snapshot)
            let restoredPanelId = try #require(restored.focusedPanelId)
            let restoredPanel = try #require(restored.terminalPanel(for: restoredPanelId))

            try assertAgentAutoResumeUsesStartupCommand(
                restoredPanel,
                scriptContains: [launchCwd, "--resume", sessionId],
                scriptDoesNotContain: [runtimeCwd]
            )
            #expect(
                restored.sessionSnapshot(includeScrollback: false).panels.first?.terminal?.resumeBinding?.cwd == launchCwd
            )
        }
    }

    @MainActor
    @Test func claudeAgentHookResumeBindingIgnoresStaleRestoredAgentSnapshot() throws {
        try withRestoredDefaults(key: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey) {
            let defaults = UserDefaults.standard
            defaults.removeObject(forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)

            let source = Workspace()
            let sourcePanelId = try #require(source.focusedPanelId)
            let staleSessionId = "claude-stale-restored-session"
            let freshSessionId = "claude-fresh-binding-session"
            let staleLaunchCwd = "/tmp/cmux-claude-stale-launch"
            let freshRuntimeCwd = "/tmp/cmux-claude-fresh-runtime"
            let staleAgent = SessionRestorableAgentSnapshot(
                kind: .claude,
                sessionId: staleSessionId,
                workingDirectory: staleLaunchCwd,
                launchCommand: AgentLaunchCommandSnapshot(
                    launcher: "claude",
                    executablePath: "/usr/local/bin/claude",
                    arguments: ["/usr/local/bin/claude"],
                    workingDirectory: staleLaunchCwd,
                    capturedAt: 1_777_777_777,
                    source: "process"
                )
            )
            source.updatePanelShellActivityState(panelId: sourcePanelId, state: .commandRunning)
            source.setRestoredAgentSnapshotForTesting(staleAgent, panelId: sourcePanelId)

            let bindingIndex = SurfaceResumeBindingIndex(bindingsByPanel: [
                SurfaceResumeBindingIndex.PanelKey(workspaceId: source.id, panelId: sourcePanelId): SurfaceResumeBindingSnapshot(
                    name: "Claude",
                    kind: "claude",
                    command: "{ cd -- '\(freshRuntimeCwd)' 2>/dev/null || [ ! -d '\(freshRuntimeCwd)' ]; } && 'claude' '--resume' '\(freshSessionId)'",
                    cwd: freshRuntimeCwd,
                    checkpointId: freshSessionId,
                    source: "agent-hook",
                    autoResume: true,
                    updatedAt: 1_777_777_778
                ),
            ])
            let snapshot = source.sessionSnapshot(
                includeScrollback: false,
                surfaceResumeBindingIndex: bindingIndex
            )

            let restored = Workspace()
            restored.restoreSessionSnapshot(snapshot)
            let restoredPanelId = try #require(restored.focusedPanelId)
            let restoredPanel = try #require(restored.terminalPanel(for: restoredPanelId))
            let restoredBinding = try #require(
                restored.sessionSnapshot(includeScrollback: false).panels.first?.terminal?.resumeBinding
            )

            #expect(restoredBinding.checkpointId == freshSessionId)
            #expect(restoredBinding.cwd == freshRuntimeCwd)
            #expect(restoredBinding.command.contains(freshRuntimeCwd), Comment(rawValue: restoredBinding.command))
            #expect(!restoredBinding.command.contains(staleLaunchCwd), Comment(rawValue: restoredBinding.command))
            #expect(restored.sessionSnapshot(includeScrollback: false).panels.first?.terminal?.agent == nil)
            try assertAgentAutoResumeUsesStartupCommand(
                restoredPanel,
                scriptContains: [freshRuntimeCwd, "--resume", freshSessionId],
                scriptDoesNotContain: [staleLaunchCwd, staleSessionId]
            )
        }
    }

    @MainActor
    @Test func crossKindAgentHookResumeBindingDoesNotRetainStaleClaudeSnapshot() throws {
        try withRestoredDefaults(key: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey) {
            let defaults = UserDefaults.standard
            defaults.removeObject(forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)

            let source = Workspace()
            let sourcePanelId = try #require(source.focusedPanelId)
            let claudeSessionId = "claude-stale-cross-kind-session"
            let codexSessionId = "codex-fresh-binding-session"
            let cwd = "/tmp/cmux-cross-kind-runtime"
            let claudeAgent = SessionRestorableAgentSnapshot(
                kind: .claude,
                sessionId: claudeSessionId,
                workingDirectory: cwd,
                launchCommand: AgentLaunchCommandSnapshot(
                    launcher: "claude",
                    executablePath: "/usr/local/bin/claude",
                    arguments: ["/usr/local/bin/claude", "--model", "claude-opus-4-8"],
                    workingDirectory: cwd,
                    environment: ["CLAUDE_CONFIG_DIR": "/tmp/cmux-claude-config"],
                    capturedAt: 1_777_777_777,
                    source: "process"
                )
            )
            source.updatePanelShellActivityState(panelId: sourcePanelId, state: .commandRunning)
            source.setRestoredAgentSnapshotForTesting(claudeAgent, panelId: sourcePanelId)

            let bindingIndex = SurfaceResumeBindingIndex(bindingsByPanel: [
                SurfaceResumeBindingIndex.PanelKey(workspaceId: source.id, panelId: sourcePanelId): SurfaceResumeBindingSnapshot(
                    name: "Codex",
                    kind: "codex",
                    command: "{ cd -- '\(cwd)' 2>/dev/null || [ ! -d '\(cwd)' ]; } && 'codex' 'resume' '\(codexSessionId)'",
                    cwd: cwd,
                    checkpointId: codexSessionId,
                    source: "agent-hook",
                    autoResume: true,
                    updatedAt: 1_777_777_778
                ),
            ])
            let snapshot = source.sessionSnapshot(
                includeScrollback: false,
                surfaceResumeBindingIndex: bindingIndex
            )

            let restored = Workspace()
            restored.restoreSessionSnapshot(snapshot)
            let restoredPanelId = try #require(restored.focusedPanelId)
            let restoredPanel = try #require(restored.terminalPanel(for: restoredPanelId))
            let restoredTerminal = restored.sessionSnapshot(includeScrollback: false).panels.first?.terminal
            let restoredBinding = try #require(restoredTerminal?.resumeBinding)

            #expect(restoredTerminal?.agent == nil)
            #expect(restoredBinding.kind == "codex")
            #expect(restoredBinding.checkpointId == codexSessionId)
            try assertAgentAutoResumeUsesStartupCommand(
                restoredPanel,
                scriptContains: ["codex", "resume", codexSessionId],
                scriptDoesNotContain: [claudeSessionId, "claude-opus-4-8"]
            )
        }
    }

    @MainActor
    @Test func crossKindAgentHookResumeBindingIgnoresStaleClaudeHibernation() throws {
        try withRestoredDefaults(key: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey) {
            let defaults = UserDefaults.standard
            defaults.removeObject(forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)

            let source = Workspace()
            let sourcePanelId = try #require(source.focusedPanelId)
            let claudeSessionId = "claude-stale-hibernated-session"
            let codexSessionId = "codex-fresh-hibernation-binding-session"
            let cwd = "/tmp/cmux-cross-kind-hibernation-runtime"
            let claudeAgent = SessionRestorableAgentSnapshot(
                kind: .claude,
                sessionId: claudeSessionId,
                workingDirectory: cwd,
                launchCommand: AgentLaunchCommandSnapshot(
                    launcher: "claude",
                    executablePath: "/usr/local/bin/claude",
                    arguments: ["/usr/local/bin/claude", "--model", "claude-opus-4-8"],
                    workingDirectory: cwd,
                    environment: ["CLAUDE_CONFIG_DIR": "/tmp/cmux-claude-config"],
                    capturedAt: 1_777_777_777,
                    source: "process"
                )
            )
            source.enterAgentHibernation(
                panelId: sourcePanelId,
                agent: claudeAgent,
                lastActivityAt: Date(timeIntervalSince1970: 1_777_777_776)
            )

            let bindingIndex = SurfaceResumeBindingIndex(bindingsByPanel: [
                SurfaceResumeBindingIndex.PanelKey(workspaceId: source.id, panelId: sourcePanelId): SurfaceResumeBindingSnapshot(
                    name: "Codex",
                    kind: "codex",
                    command: "{ cd -- '\(cwd)' 2>/dev/null || [ ! -d '\(cwd)' ]; } && 'codex' 'resume' '\(codexSessionId)'",
                    cwd: cwd,
                    checkpointId: codexSessionId,
                    source: "agent-hook",
                    autoResume: true,
                    updatedAt: 1_777_777_778
                ),
            ])
            let snapshot = source.sessionSnapshot(
                includeScrollback: false,
                surfaceResumeBindingIndex: bindingIndex
            )
            let terminalSnapshot = try #require(snapshot.panels.first?.terminal)

            #expect(terminalSnapshot.agent == nil)
            #expect(terminalSnapshot.hibernation == nil)
            #expect(terminalSnapshot.resumeBinding?.kind == "codex")

            let restored = Workspace()
            restored.restoreSessionSnapshot(snapshot)
            let restoredPanelId = try #require(restored.focusedPanelId)
            let restoredPanel = try #require(restored.terminalPanel(for: restoredPanelId))

            try assertAgentAutoResumeUsesStartupCommand(
                restoredPanel,
                scriptContains: ["codex", "resume", codexSessionId],
                scriptDoesNotContain: [claudeSessionId, "claude-opus-4-8"]
            )
        }
    }

    @Test func claudeRestorableIndexFindsNestedTranscriptWithoutTranscriptPath() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-claude-nested-index-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let configDir = root.appendingPathComponent("claude-config", isDirectory: true)
        let launchCwd = root.appendingPathComponent("repo.main", isDirectory: true)
        let runtimeCwd = root.appendingPathComponent("worktree", isDirectory: true)
        try fileManager.createDirectory(at: launchCwd, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: runtimeCwd, withIntermediateDirectories: true)

        let sessionId = "2c5f3e70-393c-485b-a263-601604a47cb2"
        let transcriptURL = configDir
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(expectedClaudeProjectDirName(launchCwd.path), isDirectory: true)
            .appendingPathComponent(sessionId, isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
            .appendingPathComponent("\(sessionId).jsonl", isDirectory: false)
        try writeClaudeTranscript(sessionId: sessionId, transcriptURL: transcriptURL)

        let workspaceId = UUID()
        let panelId = UUID()
        try writeClaudeHookStore(
            root: root,
            sessions: [
                sessionId: claudeHookRecord(
                    sessionId: sessionId,
                    workspaceId: workspaceId,
                    panelId: panelId,
                    recordedCwd: runtimeCwd.path,
                    launchCwd: launchCwd.path,
                    configDir: configDir.path,
                    transcriptPath: nil,
                    updatedAt: 10
                ),
            ]
        )

        let snapshot = try #require(
            RestorableAgentSessionIndex.load(homeDirectory: root.path, fileManager: fileManager)
                .snapshot(workspaceId: workspaceId, panelId: panelId)
        )
        #expect(snapshot.sessionId == sessionId)
        #expect(snapshot.workingDirectory == launchCwd.path)
        #expect(snapshot.resumeCommand?.contains("cd -- '\(launchCwd.path)'") == true)
    }

    @Test func claudeRestorableIndexMapsNestedTranscriptPathToProjectCwd() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-claude-nested-path-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let configDir = root.appendingPathComponent("claude-config", isDirectory: true)
        let staleLaunchCwd = root.appendingPathComponent("stale-launch", isDirectory: true)
        let transcriptCwd = root.appendingPathComponent("repo.main", isDirectory: true)
        try fileManager.createDirectory(at: staleLaunchCwd, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: transcriptCwd, withIntermediateDirectories: true)

        let sessionId = "8cb5975d-0605-4b08-8417-b8922726de18"
        let transcriptURL = configDir
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(expectedClaudeProjectDirName(transcriptCwd.path), isDirectory: true)
            .appendingPathComponent(sessionId, isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
            .appendingPathComponent("\(sessionId).jsonl", isDirectory: false)
        try writeClaudeTranscript(sessionId: sessionId, transcriptURL: transcriptURL)

        let workspaceId = UUID()
        let panelId = UUID()
        try writeClaudeHookStore(
            root: root,
            sessions: [
                sessionId: claudeHookRecord(
                    sessionId: sessionId,
                    workspaceId: workspaceId,
                    panelId: panelId,
                    recordedCwd: transcriptCwd.path,
                    launchCwd: staleLaunchCwd.path,
                    configDir: configDir.path,
                    transcriptPath: transcriptURL.path,
                    updatedAt: 10
                ),
            ]
        )

        let snapshot = try #require(
            RestorableAgentSessionIndex.load(homeDirectory: root.path, fileManager: fileManager)
                .snapshot(workspaceId: workspaceId, panelId: panelId)
        )
        #expect(snapshot.workingDirectory == transcriptCwd.path)
        #expect(snapshot.resumeCommand?.contains("cd -- '\(transcriptCwd.path)'") == true)
        #expect(snapshot.resumeCommand?.contains(staleLaunchCwd.path) == false)
    }

    private func expectedClaudeProjectDirName(_ path: String) -> String {
        path.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
    }

    private func writeClaudeTranscript(sessionId: String, transcriptURL: URL) throws {
        try FileManager.default.createDirectory(
            at: transcriptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        {"type":"last-prompt","sessionId":"\(sessionId)"}

        """.write(to: transcriptURL, atomically: true, encoding: .utf8)
    }

    private func writeClaudeHookStore(root: URL, sessions: [String: [String: Any]]) throws {
        let stateDir = root.appendingPathComponent(".cmuxterm", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: [
                "version": 1,
                "sessions": sessions,
            ],
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: stateDir.appendingPathComponent("claude-hook-sessions.json"))
    }

    private func claudeHookRecord(
        sessionId: String,
        workspaceId: UUID,
        panelId: UUID,
        recordedCwd: String,
        launchCwd: String,
        configDir: String,
        transcriptPath: String?,
        updatedAt: TimeInterval
    ) -> [String: Any] {
        var record: [String: Any] = [
            "sessionId": sessionId,
            "workspaceId": workspaceId.uuidString,
            "surfaceId": panelId.uuidString,
            "cwd": recordedCwd,
            "pid": NSNull(),
            "isRestorable": true,
            "updatedAt": updatedAt,
            "launchCommand": [
                "launcher": "claude",
                "executablePath": "/usr/local/bin/claude",
                "arguments": ["/usr/local/bin/claude"],
                "workingDirectory": launchCwd,
                "environment": ["CLAUDE_CONFIG_DIR": configDir],
                "capturedAt": updatedAt,
                "source": "test",
            ],
        ]
        if let transcriptPath {
            record["transcriptPath"] = transcriptPath
        }
        return record
    }

    private func withRestoredDefaults<T>(
        key: String,
        defaults: UserDefaults = .standard,
        body: () throws -> T
    ) rethrows -> T {
        let previous = defaults.object(forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        return try body()
    }

    @MainActor
    private func assertAgentAutoResumeUsesStartupCommand(
        _ panel: TerminalPanel,
        scriptContains needles: [String],
        scriptDoesNotContain excludedNeedles: [String] = []
    ) throws {
        let command = try #require(panel.surface.debugInitialCommand())
        #expect(command.hasPrefix("/bin/zsh '"), Comment(rawValue: command))
        let scriptPath = String(command.dropFirst("/bin/zsh '".count).dropLast())
        defer { try? FileManager.default.removeItem(atPath: scriptPath) }
        let script = try String(contentsOfFile: scriptPath, encoding: .utf8)
        for needle in needles {
            #expect(script.contains(needle), Comment(rawValue: script))
        }
        for needle in excludedNeedles {
            #expect(!script.contains(needle), Comment(rawValue: script))
        }
        #expect(script.contains("CMUX_SHELL_INTEGRATION_DIR"), Comment(rawValue: script))
        #expect(script.contains("CMUX_ZSH_ZDOTDIR"), Comment(rawValue: script))
        #expect(script.contains("\"$_cmux_resume_shell\" -lic"), Comment(rawValue: script))
        #expect(script.contains("csh|tcsh) \"$_cmux_resume_shell\" -c"), Comment(rawValue: script))
        #expect(script.contains("exec -l \"$_cmux_resume_shell\""), Comment(rawValue: script))
    }
}
