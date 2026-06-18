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
            source.setRestoredAgentSnapshotForTesting(agent, panelId: sourcePanelId)
            source.updatePanelShellActivityState(panelId: sourcePanelId, state: .commandRunning)

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
                scriptContains: [launchCwd, "'--resume' '\(sessionId)'"],
                scriptDoesNotContain: [runtimeCwd]
            )
            #expect(
                restored.sessionSnapshot(includeScrollback: false).panels.first?.terminal?.resumeBinding?.cwd == launchCwd
            )
        }
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
