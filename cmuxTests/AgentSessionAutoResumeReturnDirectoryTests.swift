import Foundation
import CmuxCore
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct AgentSessionAutoResumeReturnDirectoryTests {
    private let harness = AgentSessionAutoResumeHarness()

    @MainActor
    @Test("auto-resumed agents return the shell to the session directory")
    func restorableAgentMissingCwdReturnsToSessionDirectory() throws {
        try harness.withRestoredDefaults(key: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey) {
            UserDefaults.standard.removeObject(forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)

            let sessionDirectory = "/tmp/cmux-issue-7031-agent-repo"
            let panel = try restoredPanel(
                sessionDirectory: sessionDirectory,
                sessionId: "agent-issue-7031-session",
                surfaceResumeBindingIndex: nil
            )

            try expectReturnShell(panel, to: sessionDirectory)
        }
    }

    @MainActor
    @Test("auto-resumed hook bindings return the shell to the session directory")
    func bindingMissingCwdReturnsToSessionDirectory() throws {
        try harness.withRestoredDefaults(key: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey) {
            UserDefaults.standard.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)

            let sessionDirectory = "/tmp/cmux-issue-7031-binding-repo"
            let panel = try restoredPanel(
                sessionDirectory: sessionDirectory,
                sessionId: "binding-issue-7031-session",
                makeSurfaceResumeBindingIndex: { workspaceId, panelId in
                    SurfaceResumeBindingIndex(bindingsByPanel: [
                        SurfaceResumeBindingIndex.PanelKey(workspaceId: workspaceId, panelId: panelId): SurfaceResumeBindingSnapshot(
                            name: "Codex",
                            kind: "codex",
                            command: "codex resume binding-issue-7031-session",
                            cwd: nil,
                            checkpointId: "binding-issue-7031-session",
                            source: "agent-hook",
                            autoResume: true,
                            updatedAt: 1_777_777_777
                        ),
                    ])
                }
            )

            try expectReturnShell(panel, to: sessionDirectory)
        }
    }

    @MainActor
    private func restoredPanel(
        sessionDirectory: String,
        sessionId: String,
        makeSurfaceResumeBindingIndex: ((UUID, UUID) -> SurfaceResumeBindingIndex?)? = nil
    ) throws -> TerminalPanel {
        let source = Workspace()
        let sourcePanelId = try #require(source.focusedPanelId)
        _ = source.updatePanelDirectory(panelId: sourcePanelId, directory: sessionDirectory)
        let sourceIndex = try harness.makeRestorableAgentIndex(
            workspaceId: source.id,
            panelId: sourcePanelId,
            sessionId: sessionId
        )
        source.updatePanelShellActivityState(panelId: sourcePanelId, state: .commandRunning)
        var snapshot = source.sessionSnapshot(
            includeScrollback: false,
            restorableAgentIndex: sourceIndex,
            surfaceResumeBindingIndex: makeSurfaceResumeBindingIndex?(source.id, sourcePanelId)
        )

        let panelIndex = try #require(snapshot.panels.indices.first)
        snapshot.panels[panelIndex].terminal?.agent?.workingDirectory = nil
        snapshot.panels[panelIndex].terminal?.agent?.launchCommand?.workingDirectory = nil
        snapshot.panels[panelIndex].terminal?.workingDirectory = sessionDirectory
        snapshot.panels[panelIndex].directory = sessionDirectory

        let restored = Workspace()
        restored.restoreSessionSnapshot(snapshot)
        let restoredPanelId = try #require(restored.focusedPanelId)
        return try #require(restored.terminalPanel(for: restoredPanelId))
    }

    @MainActor
    private func expectReturnShell(_ panel: TerminalPanel, to sessionDirectory: String) throws {
        let script = try harness.resumeLauncherScript(from: panel)
        let outerCd = "{ cd -- '\(sessionDirectory)' 2>/dev/null || true; }"
        let exec = "exec -l \"$_cmux_resume_shell\""
        let cdRange = try #require(script.range(of: outerCd))
        let execRange = try #require(script.range(of: exec))
        #expect(cdRange.lowerBound < execRange.lowerBound)
    }
}
