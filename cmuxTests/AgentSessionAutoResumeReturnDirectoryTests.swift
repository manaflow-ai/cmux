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
            let restored = try restoredCwdIgnorePanel(
                sessionDirectory: sessionDirectory,
                sessionId: "ignore-issue-7031-session",
                defaults: defaults
            )

            #expect(restored.workspace.restoredResumeSessionWorkingDirectoriesByPanelId[restored.panelId] == nil)
            let outerCd = "{ cd -- '\(sessionDirectory)' 2>/dev/null || true; }"
            let script = try harness.resumeLauncherScript(from: restored.panel)
            #expect(!script.contains(outerCd))
            #expect(!script.contains("cd -- '\(sessionDirectory)'"))
            #expect(script.contains("exec -l \"$_cmux_resume_shell\""))
        }
    }

    @MainActor
    @Test("cwd-ignore hook bindings do not return the shell to a saved session directory")
    func cwdIgnoreBindingDoesNotReturnToSessionDirectory() throws {
        try withIsolatedAutoResumeDefaults { defaults in
            defaults.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)

            let sessionDirectory = "/tmp/cmux-issue-7031-ignore-binding-repo"
            let sessionId = "ignore-binding-issue-7031-session"
            let restored = try restoredCwdIgnorePanel(
                sessionDirectory: sessionDirectory,
                sessionId: sessionId,
                defaults: defaults,
                makeSurfaceResumeBindingIndex: { workspaceId, panelId in
                    SurfaceResumeBindingIndex(bindingsByPanel: [
                        SurfaceResumeBindingIndex.PanelKey(workspaceId: workspaceId, panelId: panelId): SurfaceResumeBindingSnapshot(
                            name: "Acme Ignore",
                            kind: "acme-ignore",
                            command: "acme-agent --session \(sessionId)",
                            cwd: nil,
                            checkpointId: sessionId,
                            source: "agent-hook",
                            autoResume: true,
                            updatedAt: 1_777_777_777
                        ),
                    ])
                }
            )

            #expect(restored.workspace.restoredResumeSessionWorkingDirectoriesByPanelId[restored.panelId] == nil)
            let outerCd = "{ cd -- '\(sessionDirectory)' 2>/dev/null || true; }"
            let script = try harness.resumeLauncherScript(from: restored.panel)
            #expect(!script.contains(outerCd))
            #expect(!script.contains("cd -- '\(sessionDirectory)'"))
            #expect(script.contains("exec -l \"$_cmux_resume_shell\""))
        }
    }

    @MainActor
    @Test("binding-only cwd-ignore hook bindings do not return the shell to a saved session directory")
    func bindingOnlyCwdIgnoreDoesNotReturnToSessionDirectory() throws {
        try withIsolatedAutoResumeDefaults { defaults in
            defaults.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)

            let sessionDirectory = try makeTemporaryProjectDirectory(prefix: "cmux-issue-7031-ignore-binding-only")
            defer { try? FileManager.default.removeItem(atPath: sessionDirectory) }
            let registration = cwdIgnoreRegistration()
            try writeVaultAgentConfig(registration, in: sessionDirectory)
            let sessionId = "ignore-binding-only-issue-7031-session"
            let restored = try restoredBindingOnlyPanel(
                sessionDirectory: sessionDirectory,
                sessionId: sessionId,
                defaults: defaults,
                bindingKind: registration.id
            )

            #expect(restored.workspace.restoredResumeSessionWorkingDirectoriesByPanelId[restored.panelId] == nil)
            let script = try harness.resumeLauncherScript(from: restored.panel)
            #expect(!script.contains("cd -- '\(sessionDirectory)'"))
            #expect(script.contains("exec -l \"$_cmux_resume_shell\""))
        }
    }

    @MainActor
    @Test("binding-only cwd-ignore lookup uses the binding cwd before stale terminal cwd")
    func bindingOnlyCwdIgnoreUsesBindingCwdForRegistryLookup() throws {
        try withIsolatedAutoResumeDefaults { defaults in
            defaults.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)

            let projectDirectory = try makeTemporaryProjectDirectory(prefix: "cmux-issue-7031-ignore-binding-cwd")
            let staleDirectory = try makeTemporaryProjectDirectory(prefix: "cmux-issue-7031-stale-binding-cwd")
            defer {
                try? FileManager.default.removeItem(atPath: projectDirectory)
                try? FileManager.default.removeItem(atPath: staleDirectory)
            }
            let registration = cwdIgnoreRegistration()
            try writeVaultAgentConfig(registration, in: projectDirectory)
            let restored = try restoredBindingOnlyPanel(
                sessionDirectory: staleDirectory,
                sessionId: "ignore-binding-cwd-issue-7031-session",
                defaults: defaults,
                bindingKind: registration.id,
                bindingCwd: projectDirectory
            )

            #expect(restored.workspace.restoredResumeSessionWorkingDirectoriesByPanelId[restored.panelId] == nil)
            let script = try harness.resumeLauncherScript(from: restored.panel)
            #expect(!script.contains("cd -- '\(projectDirectory)'"))
            #expect(!script.contains("cd -- '\(staleDirectory)'"))
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
    private func restoredCwdIgnorePanel(
        sessionDirectory: String,
        sessionId: String,
        defaults: UserDefaults,
        makeSurfaceResumeBindingIndex: ((UUID, UUID) -> SurfaceResumeBindingIndex?)? = nil
    ) throws -> (workspace: Workspace, panel: TerminalPanel, panelId: UUID) {
        let registration = cwdIgnoreRegistration()
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
        let snapshot = source.sessionSnapshot(
            includeScrollback: false,
            surfaceResumeBindingIndex: makeSurfaceResumeBindingIndex?(source.id, sourcePanelId)
        )

        let restored = Workspace(agentSessionAutoResumeDefaults: defaults)
        restored.restoreSessionSnapshot(snapshot)
        let restoredPanelId = try #require(restored.focusedPanelId)
        let panel = try #require(restored.terminalPanel(for: restoredPanelId))
        return (restored, panel, restoredPanelId)
    }

    @MainActor
    private func restoredBindingOnlyPanel(
        sessionDirectory: String,
        sessionId: String,
        defaults: UserDefaults,
        bindingKind: String,
        bindingCwd: String? = nil
    ) throws -> (workspace: Workspace, panel: TerminalPanel, panelId: UUID) {
        let source = Workspace(agentSessionAutoResumeDefaults: defaults)
        let sourcePanelId = try #require(source.focusedPanelId)
        source.updatePanelDirectory(panelId: sourcePanelId, directory: sessionDirectory)
        source.updatePanelShellActivityState(panelId: sourcePanelId, state: .commandRunning)
        let bindingIndex = SurfaceResumeBindingIndex(bindingsByPanel: [
            SurfaceResumeBindingIndex.PanelKey(workspaceId: source.id, panelId: sourcePanelId): SurfaceResumeBindingSnapshot(
                name: "Acme Ignore",
                kind: bindingKind,
                command: "acme-agent --session \(sessionId)",
                cwd: bindingCwd,
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

        let restored = Workspace(agentSessionAutoResumeDefaults: defaults)
        restored.restoreSessionSnapshot(snapshot)
        let restoredPanelId = try #require(restored.focusedPanelId)
        let panel = try #require(restored.terminalPanel(for: restoredPanelId))
        return (restored, panel, restoredPanelId)
    }

    private func cwdIgnoreRegistration() -> CmuxVaultAgentRegistration {
        CmuxVaultAgentRegistration(
            id: "acme-ignore",
            name: "Acme Ignore",
            detect: CmuxVaultAgentDetectRule(processName: "acme-agent"),
            sessionIdSource: .argvOption("--session"),
            resumeCommand: "acme-agent --session {{sessionId}}",
            cwd: .ignore
        )
    }

    private func makeTemporaryProjectDirectory(prefix: String) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    private func writeVaultAgentConfig(_ registration: CmuxVaultAgentRegistration, in directory: String) throws {
        let configDirectory = URL(fileURLWithPath: directory, isDirectory: true)
            .appendingPathComponent(".cmux", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        let config = CmuxConfigFile(vault: CmuxVaultConfigDefinition(agents: [registration]))
        let data = try JSONEncoder().encode(config)
        try data.write(to: configDirectory.appendingPathComponent("cmux.json"))
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
