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
        try withIsolatedAutoResumeDefaults { defaults in
            defaults.removeObject(forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)

            let sessionDirectory = "/tmp/cmux-issue-7031-agent-repo"
            let restored = try restoredPanel(
                sessionDirectory: sessionDirectory,
                sessionId: "agent-issue-7031-session",
                defaults: defaults,
                makeSurfaceResumeBindingIndex: nil
            )

            try expectReturnShell(restored.panel, to: sessionDirectory)
        }
    }

    @MainActor
    @Test("auto-resumed hook bindings return the shell to the session directory")
    func bindingMissingCwdReturnsToSessionDirectory() throws {
        try withIsolatedAutoResumeDefaults { defaults in
            defaults.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)

            let sessionDirectory = "/tmp/cmux-issue-7031-binding-repo"
            let restored = try restoredPanel(
                sessionDirectory: sessionDirectory,
                sessionId: "binding-issue-7031-session",
                defaults: defaults,
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

            try expectReturnShell(restored.panel, to: sessionDirectory)
            #expect(
                restored.workspace.restoredResumeSessionWorkingDirectoriesByPanelId[restored.panel.id] == sessionDirectory
            )
        }
    }

    @MainActor
    @Test("cwd-ignore agents do not return the shell to a saved session directory")
    func cwdIgnoreAgentDoesNotReturnToSessionDirectory() throws {
        try withIsolatedAutoResumeDefaults { defaults in
            defaults.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)

            let sessionDirectory = "/tmp/cmux-issue-7031-ignore-repo"
            let sessionId = "ignore-issue-7031-session"
            let registration = CmuxVaultAgentRegistration(
                id: "acme-ignore",
                name: "Acme Ignore",
                detect: CmuxVaultAgentDetectRule(processName: "acme-agent"),
                sessionIdSource: .argvOption("--session"),
                resumeCommand: "acme-agent --session {{sessionId}}",
                cwd: .ignore
            )
            let source = Workspace(agentSessionAutoResumeDefaults: defaults)
            let sourcePanelId = try #require(source.focusedPanelId)
            source.updatePanelDirectory(panelId: sourcePanelId, directory: sessionDirectory)
            source.updatePanelShellActivityState(panelId: sourcePanelId, state: .commandRunning)
            source.setRestoredAgentSnapshotForTesting(
                SessionRestorableAgentSnapshot(
                    kind: .custom(registration.id),
                    sessionId: sessionId,
                    workingDirectory: nil,
                    launchCommand: AgentLaunchCommandSnapshot(
                        processDetectedLauncher: registration.id,
                        executablePath: "/usr/local/bin/acme-agent",
                        arguments: ["/usr/local/bin/acme-agent", "--session", sessionId],
                        workingDirectory: sessionDirectory,
                        environment: [:]
                    ),
                    registration: registration
                ),
                panelId: sourcePanelId
            )
            let snapshot = source.sessionSnapshot(includeScrollback: false)

            let restored = Workspace(agentSessionAutoResumeDefaults: defaults)
            restored.restoreSessionSnapshot(snapshot)
            let restoredPanelId = try #require(restored.focusedPanelId)
            let panel = try #require(restored.terminalPanel(for: restoredPanelId))
            #expect(restored.restoredResumeSessionWorkingDirectoriesByPanelId[restoredPanelId] == nil)

            let script = try harness.resumeLauncherScript(from: panel)
            let outerCd = "{ cd -- '\(sessionDirectory)' 2>/dev/null || true; }"
            #expect(!script.contains(outerCd))
            #expect(script.contains("exec -l \"$_cmux_resume_shell\""))
        }
    }

    private func withIsolatedAutoResumeDefaults<T>(_ body: (UserDefaults) throws -> T) throws -> T {
        let suiteName = "cmux.AgentSessionAutoResumeReturnDirectoryTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        return try body(defaults)
    }

    @MainActor
    private func restoredPanel(
        sessionDirectory: String,
        sessionId: String,
        defaults: UserDefaults,
        makeSurfaceResumeBindingIndex: ((UUID, UUID) -> SurfaceResumeBindingIndex?)? = nil
    ) throws -> (workspace: Workspace, panel: TerminalPanel) {
        let source = Workspace(agentSessionAutoResumeDefaults: defaults)
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

        let restored = Workspace(agentSessionAutoResumeDefaults: defaults)
        restored.restoreSessionSnapshot(snapshot)
        let restoredPanelId = try #require(restored.focusedPanelId)
        return (restored, try #require(restored.terminalPanel(for: restoredPanelId)))
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
