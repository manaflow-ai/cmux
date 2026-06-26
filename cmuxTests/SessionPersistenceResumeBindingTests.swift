import Foundation
import CmuxCore
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct SessionPersistenceResumeBindingTests {
    @Test func agentHookSurfaceResumeStartupInputPreservesCustomAbsoluteAgentExecutable() throws {
        let binding = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "'/opt/company/bin/codex' 'resume' 'session-custom-cli'",
            checkpointId: "session-custom-cli",
            source: "agent-hook",
            autoResume: true
        )

        let startupInput = try #require(binding.startupInput)

        #expect(startupInput.contains("'/opt/company/bin/codex'"), "\(startupInput)")
    }

    @Test func decodingAgentHookBindingRewritesPersistedPATHManagedAgentExecutable() throws {
        let executablePath = Self.homeManagedExecutablePath(
            executableName: "claude",
            ".nvm",
            "versions",
            "node",
            "cmux-missing-\(UUID().uuidString)",
            "bin"
        )
        let json = """
        {
          "kind": "claude",
          "command": "{ cd -- '/tmp/project' 2>/dev/null || [ ! -d '/tmp/project' ]; } && '\(executablePath)' '--resume' 'session-moved-cli' '--chrome'",
          "cwd": "/tmp/project",
          "checkpointId": "session-moved-cli",
          "source": "agent-hook",
          "autoResume": true,
          "updatedAt": 123
        }
        """
        let binding = try JSONDecoder().decode(SurfaceResumeBindingSnapshot.self, from: Data(json.utf8))
        let startupInput = try #require(binding.startupInput)

        #expect(binding.command.contains(executablePath), "\(binding.command)")
        #expect(startupInput.contains("/bin/sh -c"), "\(startupInput)")
        #expect(startupInput.contains("CMUX_CLAUDE_WRAPPER_SHIM"), "\(startupInput)")
        #expect(startupInput.contains("--resume"), "\(startupInput)")
        #expect(!startupInput.contains(executablePath), "\(startupInput)")
    }

    @Test func legacyAgentHookBindingWithoutKindRewritesPersistedPATHManagedAgentExecutable() throws {
        let executablePath = Self.homeManagedExecutablePath(
            executableName: "codex",
            ".nvm",
            "versions",
            "node",
            "cmux-missing-\(UUID().uuidString)",
            "bin"
        )
        let json = """
        {
          "command": "'\(executablePath)' 'resume' 'session-legacy-cli'",
          "checkpointId": "session-legacy-cli",
          "source": "agent-hook",
          "autoResume": true,
          "updatedAt": 123
        }
        """
        let binding = try JSONDecoder().decode(SurfaceResumeBindingSnapshot.self, from: Data(json.utf8))
        let startupInput = try #require(binding.startupInput)

        #expect(binding.kind == nil)
        #expect(binding.command.contains(executablePath), "\(binding.command)")
        #expect(startupInput.contains("codex 'resume' 'session-legacy-cli'"), "\(startupInput)")
        #expect(!startupInput.contains(executablePath), "\(startupInput)")
    }

    @Test func agentHookBindingRewritesSupportedLocalManagedExecutablePaths() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-surface-resume-stale-managed-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let executablePaths = [
            Self.localManagedExecutablePath(root: root, executableName: "codex", ".fnm", "current", "bin"),
            "/tmp/cmux-cli-shims/\(UUID().uuidString)/codex",
            Self.localManagedExecutablePath(
                root: root,
                executableName: "codex",
                "Library",
                "Application Support",
                "fnm",
                "node-versions",
                "v24.2.0",
                "installation",
                "bin"
            ),
            Self.localManagedExecutablePath(
                root: root,
                executableName: "codex",
                ".local",
                "share",
                "fnm",
                "node-versions",
                "v24.2.0",
                "installation",
                "bin"
            ),
            Self.localManagedExecutablePath(root: root, executableName: "codex", ".local", "share", "mise", "shims"),
        ]

        for executablePath in executablePaths {
            let binding = SurfaceResumeBindingSnapshot(
                kind: "codex",
                command: "'\(executablePath)' 'resume' 'session-managed-cli'",
                checkpointId: "session-managed-cli",
                source: "agent-hook",
                autoResume: true
            )

            let startupInput = try #require(binding.startupInput)
            #expect(startupInput.contains("codex 'resume' 'session-managed-cli'"), "\(startupInput)")
            #expect(!startupInput.contains(executablePath), "\(startupInput)")
        }
    }

    @Test func agentHookBindingWithDirectEnvironmentAssignmentRewritesMovedExecutable() throws {
        let staleExecutablePath = Self.homeManagedExecutablePath(
            executableName: "codex",
            ".nvm",
            "versions",
            "node",
            "cmux-missing-\(UUID().uuidString)",
            "bin"
        )
        let binding = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "CMUX_TRACE=1 '\(staleExecutablePath)' 'resume' 'session-env-cli'",
            checkpointId: "session-env-cli",
            source: "agent-hook",
            autoResume: true
        )

        let startupInput = try #require(binding.startupInput)

        #expect(startupInput.contains("CMUX_TRACE=1 codex 'resume' 'session-env-cli'"), "\(startupInput)")
        #expect(!startupInput.contains(staleExecutablePath), "\(startupInput)")
    }

    @Test func agentHookBindingWithQuotedEnvAssignmentRewritesMovedExecutable() throws {
        let staleExecutablePath = Self.homeManagedExecutablePath(
            executableName: "codex",
            ".nvm",
            "versions",
            "node",
            "cmux-missing-\(UUID().uuidString)",
            "bin"
        )
        let binding = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "env 'CMUX_TRACE=1' '\(staleExecutablePath)' 'resume' 'session-quoted-env-cli'",
            checkpointId: "session-quoted-env-cli",
            source: "agent-hook",
            autoResume: true
        )
        let startupInput = try #require(binding.startupInput)

        #expect(startupInput.contains("env 'CMUX_TRACE=1' codex 'resume' 'session-quoted-env-cli'"), "\(startupInput)")
        #expect(!startupInput.contains(staleExecutablePath), "\(startupInput)")
    }

    @Test func agentHookClaudeBindingWithDirectEnvironmentAssignmentPreservesAssignmentSyntax() throws {
        let staleExecutablePath = Self.homeManagedExecutablePath(
            executableName: "claude",
            ".nvm",
            "versions",
            "node",
            "cmux-missing-\(UUID().uuidString)",
            "bin"
        )
        let binding = SurfaceResumeBindingSnapshot(
            kind: "claude",
            command: "CMUX_TRACE='bar baz' '\(staleExecutablePath)' '--resume' 'session-env-cli'",
            checkpointId: "session-env-cli",
            source: "agent-hook",
            autoResume: true
        )
        let startupInput = try #require(binding.startupInput)

        #expect(startupInput.contains("/bin/sh -c"), "\(startupInput)")
        #expect(startupInput.contains("CMUX_CLAUDE_WRAPPER_SHIM"), "\(startupInput)")
        #expect(startupInput.contains("CMUX_TRACE="), "\(startupInput)")
        #expect(startupInput.contains("bar baz"), "\(startupInput)")
        #expect(!startupInput.contains(staleExecutablePath), "\(startupInput)")
    }

    @Test func agentHookClaudeBindingWithShellOperatorKeepsOriginalCommandShape() throws {
        let staleExecutablePath = Self.homeManagedExecutablePath(
            executableName: "claude",
            ".nvm",
            "versions",
            "node",
            "cmux-missing-\(UUID().uuidString)",
            "bin"
        )
        let redirection = "1>/tmp/cmux-claude-resume.log"
        let binding = SurfaceResumeBindingSnapshot(
            kind: "claude",
            command: "'\(staleExecutablePath)' '--resume' 'session-operator-cli' \(redirection) && echo done",
            checkpointId: "session-operator-cli",
            source: "agent-hook",
            autoResume: true
        )
        let startupInput = try #require(binding.startupInput)

        #expect(binding.command.contains("&& echo done"), "\(binding.command)")
        #expect(binding.command.contains(staleExecutablePath), "\(binding.command)")
        #expect(startupInput.contains("/bin/sh -c"), "\(startupInput)")
        #expect(startupInput.contains("CMUX_CLAUDE_WRAPPER_SHIM"), "\(startupInput)")
        #expect(startupInput.contains("session-operator-cli \(redirection) && echo done"), "\(startupInput)")
        #expect(!startupInput.contains(staleExecutablePath), "\(startupInput)")
    }

    @Test func agentHookBindingPreservesRemoteManagedExecutablePath() throws {
        let remoteExecutablePath = "/home/me/.nvm/versions/node/v24.2.0/bin/codex"
        let binding = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "'\(remoteExecutablePath)' 'resume' 'session-remote-cli'",
            checkpointId: "session-remote-cli",
            source: "agent-hook",
            autoResume: true
        )

        let startupInput = try #require(binding.startupInput)
        #expect(startupInput.contains("'\(remoteExecutablePath)' 'resume' 'session-remote-cli'"), "\(startupInput)")
    }

    @Test func remoteStartupInputPreservesLocalLookingManagedExecutablePaths() throws {
        let executablePaths = [
            Self.homeManagedExecutablePath(
                executableName: "codex",
                ".nvm",
                "versions",
                "node",
                "cmux-missing-\(UUID().uuidString)",
                "bin"
            ),
            "/tmp/cmux-cli-shims/\(UUID().uuidString)/codex",
        ]

        for executablePath in executablePaths {
            let binding = SurfaceResumeBindingSnapshot(
                kind: "codex",
                command: "'\(executablePath)' 'resume' 'session-remote-local-looking-cli'",
                checkpointId: "session-remote-local-looking-cli",
                source: "agent-hook",
                autoResume: true
            )

            let startupInput = try #require(binding.startupInputWithLauncherScript(
                allowLauncherScript: false,
                repairPortableAgentExecutable: false
            ))
            #expect(
                startupInput.contains("'\(executablePath)' 'resume' 'session-remote-local-looking-cli'"),
                "\(startupInput)"
            )
        }
    }

    @Test @MainActor func remoteWorkspaceLocalTerminalResumeBindingUsesLocalRepair() throws {
        let suiteName = "cmux-session-resume-binding-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)

        let remoteWorkspace = Workspace(agentSessionAutoResumeDefaults: defaults)
        remoteWorkspace.setCustomTitle("Remote Workspace With Local Resume Binding")
        remoteWorkspace.configureRemoteConnection(
            WorkspaceRemoteConfiguration(
                destination: "dev@example.com",
                port: 2222,
                identityFile: nil,
                sshOptions: [
                    "StrictHostKeyChecking=accept-new",
                ],
                localProxyPort: nil,
                relayPort: nil,
                relayID: nil,
                relayToken: nil,
                localSocketPath: nil,
                terminalStartupCommand: "ssh -p 2222 dev@example.com",
                preserveAfterTerminalExit: false
            ),
            autoConnect: false
        )
        let paneId = try #require(remoteWorkspace.bonsplitController.allPaneIds.first)
        let localDirectory = "/tmp/cmux-local-resume-binding"
        let localPanel = try #require(remoteWorkspace.newTerminalSurface(
            inPane: paneId,
            focus: true,
            workingDirectory: localDirectory,
            suppressWorkspaceRemoteStartupCommand: true
        ))
        remoteWorkspace.setPanelCustomTitle(panelId: localPanel.id, title: "Local Resume Shell")
        let staleExecutablePath = Self.homeManagedExecutablePath(
            executableName: "codex",
            ".nvm",
            "versions",
            "node",
            "cmux-missing-\(UUID().uuidString)",
            "bin"
        )
        let oversizedArgument = String(
            repeating: "x",
            count: SurfaceResumeBindingSnapshot.maxInlineStartupInputBytes + 1
        )
        let quotedDirectory = "'\(localDirectory)'"
        #expect(remoteWorkspace.setSurfaceResumeBinding(
            SurfaceResumeBindingSnapshot(
                name: "Codex",
                kind: "codex",
                command: "{ cd -- \(quotedDirectory) 2>/dev/null || [ ! -d \(quotedDirectory) ]; } && "
                    + "'\(staleExecutablePath)' 'resume' 'session-local-resume' '\(oversizedArgument)'",
                cwd: localDirectory,
                checkpointId: "session-local-resume",
                source: "agent-hook",
                autoResume: true,
                updatedAt: 10
            ),
            panelId: localPanel.id
        ))

        let snapshot = remoteWorkspace.sessionSnapshot(includeScrollback: false)
        let persistedLocalPanel = try #require(snapshot.panels.first {
            $0.customTitle == "Local Resume Shell"
        })
        #expect(persistedLocalPanel.terminal?.isRemoteTerminal == false)
        #expect(persistedLocalPanel.terminal?.resumeBinding?.command.contains(staleExecutablePath) == true)

        let restoredWorkspace = Workspace(agentSessionAutoResumeDefaults: defaults)
        restoredWorkspace.restoreSessionSnapshot(snapshot)
        let restoredLocalPanel = try #require(
            restoredWorkspace.sessionSnapshot(includeScrollback: false)
                .panels.first { $0.customTitle == "Local Resume Shell" }
        )
        let restoredPanel = try #require(restoredWorkspace.terminalPanel(for: restoredLocalPanel.id))
        let restoredInput = try #require(restoredPanel.surface.debugInitialInputForTesting())
        #expect(restoredPanel.surface.debugInitialCommand() == nil)
        #expect(restoredPanel.requestedWorkingDirectory == nil)
        #expect(restoredInput.contains("codex 'resume' 'session-local-resume'"), "\(restoredInput)")
        #expect(restoredInput.contains(localDirectory), "\(restoredInput)")
        #expect(!restoredInput.contains(staleExecutablePath), "\(restoredInput)")
    }

    // Regression coverage for https://github.com/manaflow-ai/cmux/issues/6597:
    // `app.persistTerminalScrollback` opts out of writing terminal scrollback
    // into the on-disk session snapshot. cmux carries scrollback across
    // restarts by re-persisting whatever a prior launch restored
    // (`restoredTerminalScrollbackByPanelId`), so seed that fallback and verify
    // the next snapshot drops it when the setting is off — proving sensitive
    // output never reaches disk — while still keeping it when the setting is on.
    @Test @MainActor func sessionSnapshotOmitsRestoredScrollbackWhenPersistenceDisabled() throws {
        let suiteName = "cmux-persist-scrollback-off-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(false, forKey: SessionScrollbackPersistenceSettings.persistScrollbackKey)

        let workspace = Workspace(sessionScrollbackPersistenceDefaults: defaults)
        let panelId = try #require(
            workspace.sessionSnapshot(includeScrollback: false).panels.first { $0.terminal != nil }?.id
        )
        workspace.restoredTerminalScrollbackByPanelId[panelId] = "SENSITIVE_TOKEN_OUTPUT"

        let snapshot = workspace.sessionSnapshot(includeScrollback: true)
        let panel = try #require(snapshot.panels.first { $0.id == panelId })

        // Tabs/layout/working directory still restore; only scrollback is withheld.
        #expect(panel.terminal != nil)
        #expect(panel.terminal?.scrollback == nil)
        // The in-memory restored copy is purged so it can't leak into later saves.
        #expect(workspace.restoredTerminalScrollbackByPanelId[panelId] == nil)
    }

    @Test @MainActor func sessionSnapshotKeepsRestoredScrollbackWhenPersistenceEnabled() throws {
        let suiteName = "cmux-persist-scrollback-on-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: SessionScrollbackPersistenceSettings.persistScrollbackKey)

        let workspace = Workspace(sessionScrollbackPersistenceDefaults: defaults)
        let panelId = try #require(
            workspace.sessionSnapshot(includeScrollback: false).panels.first { $0.terminal != nil }?.id
        )
        workspace.restoredTerminalScrollbackByPanelId[panelId] = "SENSITIVE_TOKEN_OUTPUT"

        let snapshot = workspace.sessionSnapshot(includeScrollback: true)
        let panel = try #require(snapshot.panels.first { $0.id == panelId })

        #expect(panel.terminal?.scrollback == "SENSITIVE_TOKEN_OUTPUT")
    }

    // The opt-out must also apply on restore: an existing on-disk snapshot that
    // still contains scrollback must not be replayed onto the screen or seeded
    // back into `restoredTerminalScrollbackByPanelId` once the setting is off,
    // so turning it off before relaunch fully protects the user (#6597).
    @Test @MainActor func restoreDoesNotReplayScrollbackWhenPersistenceDisabled() throws {
        // Mint a snapshot whose terminal carries scrollback, using an enabled
        // workspace and the same restored-scrollback fallback restart uses.
        let onSuite = "cmux-restore-scrollback-on-\(UUID().uuidString)"
        let onDefaults = try #require(UserDefaults(suiteName: onSuite))
        defer { onDefaults.removePersistentDomain(forName: onSuite) }
        onDefaults.set(true, forKey: SessionScrollbackPersistenceSettings.persistScrollbackKey)

        let source = Workspace(sessionScrollbackPersistenceDefaults: onDefaults)
        let sourcePanelId = try #require(
            source.sessionSnapshot(includeScrollback: false).panels.first { $0.terminal != nil }?.id
        )
        source.restoredTerminalScrollbackByPanelId[sourcePanelId] = "SENSITIVE_TOKEN_OUTPUT"
        let snapshot = source.sessionSnapshot(includeScrollback: true)
        #expect(snapshot.panels.contains { $0.terminal?.scrollback == "SENSITIVE_TOKEN_OUTPUT" })

        // Disabled: restoring that snapshot must not seed the scrollback fallback.
        let offSuite = "cmux-restore-scrollback-off-\(UUID().uuidString)"
        let offDefaults = try #require(UserDefaults(suiteName: offSuite))
        defer { offDefaults.removePersistentDomain(forName: offSuite) }
        offDefaults.set(false, forKey: SessionScrollbackPersistenceSettings.persistScrollbackKey)
        let disabledWorkspace = Workspace(sessionScrollbackPersistenceDefaults: offDefaults)
        disabledWorkspace.restoreSessionSnapshot(snapshot)
        #expect(disabledWorkspace.restoredTerminalScrollbackByPanelId.isEmpty)

        // Enabled: restoring the same snapshot still seeds the fallback as before.
        let enabledWorkspace = Workspace(sessionScrollbackPersistenceDefaults: onDefaults)
        enabledWorkspace.restoreSessionSnapshot(snapshot)
        #expect(enabledWorkspace.restoredTerminalScrollbackByPanelId.values.contains("SENSITIVE_TOKEN_OUTPUT"))
    }

    @Test func agentHookSurfaceResumeStartupInputPreservesExistingPATHManagedAgentExecutable() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-surface-resume-existing-agent-\(UUID().uuidString)", isDirectory: true)
        let executable = root
            .appendingPathComponent(".nvm", isDirectory: true)
            .appendingPathComponent("versions", isDirectory: true)
            .appendingPathComponent("node", isDirectory: true)
            .appendingPathComponent("v24.2.0", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("codex", isDirectory: false)
        try fileManager.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: executable, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        defer { try? fileManager.removeItem(at: root) }

        let binding = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "'\(executable.path)' 'resume' 'session-existing-cli'",
            checkpointId: "session-existing-cli",
            source: "agent-hook",
            autoResume: true
        )

        let startupInput = try #require(binding.startupInput)
        #expect(startupInput.contains("'\(executable.path)'"), "\(startupInput)")
    }

    @Test func agentHookSurfaceResumeStartupInputFallsBackWhenRecordedAgentExecutableMoved() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-surface-resume-moved-agent-\(UUID().uuidString)", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let cwd = root.appendingPathComponent("repo", isDirectory: true)
        let movedExecutable = root
            .appendingPathComponent(".nvm", isDirectory: true)
            .appendingPathComponent("versions", isDirectory: true)
            .appendingPathComponent("node", isDirectory: true)
            .appendingPathComponent("v24.2.0", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("codex", isDirectory: false)
        let outputURL = root.appendingPathComponent("codex-output.txt", isDirectory: false)
        try fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: cwd, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let fakeCodex = bin.appendingPathComponent("codex", isDirectory: false)
        try """
        #!/bin/sh
        printf '%s|%s\\n' "$PWD" "$*" > "$CMUX_FAKE_CODEX_OUTPUT"
        """.write(to: fakeCodex, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeCodex.path)

        let quotedCwd = "'\(cwd.path)'"
        let binding = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "{ cd -- \(quotedCwd) 2>/dev/null || [ ! -d \(quotedCwd) ]; } && "
                + "'\(movedExecutable.path)' 'resume' 'session-moved-cli' '--yolo'",
            cwd: cwd.path,
            checkpointId: "session-moved-cli",
            source: "agent-hook",
            autoResume: true
        )
        let startupInput = try #require(binding.startupInput)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-fc", startupInput]
        process.environment = [
            "PATH": "\(bin.path):/usr/bin:/bin",
            "CMUX_FAKE_CODEX_OUTPUT": outputURL.path,
        ]
        let stderr = Pipe()
        process.standardError = stderr

        try runWithBoundedWait(process, shellDescription: "zsh -fc")

        let errorText = String(
            data: stderr.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        #expect(process.terminationStatus == 0, "\(errorText)")

        let output = try String(contentsOf: outputURL, encoding: .utf8)
        #expect(output == "\(cwd.path)|resume session-moved-cli --yolo\n")
        #expect(!startupInput.contains(movedExecutable.path), "\(startupInput)")
    }

    private struct ResumeShellTimeout: Error, CustomStringConvertible {
        let shellDescription: String
        let timeout: TimeInterval

        var description: String {
            "Resume shell (\(shellDescription)) did not exit within \(Int(timeout))s; treating as hung."
        }
    }

    private func runWithBoundedWait(
        _ process: Process,
        shellDescription: String,
        timeout: TimeInterval = 30
    ) throws {
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = exited.wait(timeout: .now() + 2)
            throw ResumeShellTimeout(shellDescription: shellDescription, timeout: timeout)
        }
    }

    private static func homeManagedExecutablePath(executableName: String, _ components: String...) -> String {
        localManagedExecutablePath(root: FileManager.default.homeDirectoryForCurrentUser, executableName: executableName, components)
    }

    private static func localManagedExecutablePath(
        root: URL,
        executableName: String,
        _ components: String...
    ) -> String {
        localManagedExecutablePath(root: root, executableName: executableName, components)
    }

    private static func localManagedExecutablePath(
        root: URL,
        executableName: String,
        _ components: [String]
    ) -> String {
        var directory = root
        for component in components {
            directory.appendPathComponent(component, isDirectory: true)
        }
        return directory.appendingPathComponent(executableName, isDirectory: false).path
    }
}
