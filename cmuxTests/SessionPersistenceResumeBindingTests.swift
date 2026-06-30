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
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-local-resume-binding-\(UUID().uuidString)", isDirectory: true)
        let localDirectoryURL = root.appendingPathComponent("local repo", isDirectory: true)
        let binURL = root.appendingPathComponent("bin", isDirectory: true)
        let codexOutputURL = root.appendingPathComponent("codex-output.txt", isDirectory: false)
        try fileManager.createDirectory(at: localDirectoryURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: binURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let fakeCodexURL = binURL.appendingPathComponent("codex", isDirectory: false)
        try """
        #!/bin/sh
        printf '%s|%s\\n' "$PWD" "$*" > "$CMUX_FAKE_CODEX_OUTPUT"
        """.write(to: fakeCodexURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeCodexURL.path)

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
        let localDirectory = localDirectoryURL.path
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
        let restoredCommand = try #require(restoredPanel.surface.debugInitialCommand())
        #expect(restoredPanel.surface.debugInitialInputForTesting() == nil)
        #expect(restoredPanel.requestedWorkingDirectory == nil)
        let launcherScriptPath = try launcherScriptPath(from: restoredCommand)
        let launcherEnvironment = try makeOhMyZshLauncherEnvironment(
            root: root,
            integrationDir: shellIntegrationDirectory(),
            pathPrefix: binURL.path,
            codexShimURL: fakeCodexURL,
            codexOutputURL: codexOutputURL
        )
        try runLauncherUntilOutput(
            scriptPath: launcherScriptPath,
            environment: launcherEnvironment,
            outputURL: codexOutputURL
        )
        let codexOutput = try String(contentsOf: codexOutputURL, encoding: .utf8)
        #expect(codexOutput.contains("\(localDirectory)|resume session-local-resume"), "\(codexOutput)")
        #expect(!codexOutput.contains(staleExecutablePath), "\(codexOutput)")
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

    private func runLauncherUntilOutput(
        scriptPath: String,
        environment: [String: String],
        outputURL: URL,
        timeout: TimeInterval = 10
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [scriptPath]
        process.environment = environment
        let stderr = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr

        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let output = try? String(contentsOf: outputURL, encoding: .utf8),
               !output.isEmpty {
                if process.isRunning {
                    process.terminate()
                    process.waitUntilExit()
                }
                return
            }
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }

        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        let errorText = String(
            data: stderr.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        Issue.record("Launcher did not produce Codex output within \(Int(timeout))s. stderr: \(errorText)")
        throw ResumeShellTimeout(shellDescription: "/bin/zsh \(scriptPath)", timeout: timeout)
    }

    private func launcherScriptPath(from command: String) throws -> String {
        let words = TerminalStartupWorkingDirectoryPrefix.shellWordRanges(command).map(\.value)
        #expect(words.first == "/bin/zsh", "\(command)")
        return try #require(words.dropFirst().first, "Expected /bin/zsh launcher script command, saw: \(command)")
    }

    private func shellIntegrationDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/shell-integration", isDirectory: true)
    }

    private func makeOhMyZshLauncherEnvironment(
        root: URL,
        integrationDir: URL,
        pathPrefix: String,
        codexShimURL: URL,
        codexOutputURL: URL
    ) throws -> [String: String] {
        let homeURL = root.appendingPathComponent("home", isDirectory: true)
        let userZdotdirURL = root.appendingPathComponent("zdotdir", isDirectory: true)
        let ohMyZshURL = root.appendingPathComponent("oh-my-zsh", isDirectory: true)
        try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: userZdotdirURL, withIntermediateDirectories: true)
        try writeOhMyZshFixture(at: ohMyZshURL)
        try "\n".write(
            to: userZdotdirURL.appendingPathComponent(".zshenv", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
        try """
        export ZSH="\(ohMyZshURL.path)"
        export ZSH_DISABLE_COMPFIX=true
        export DISABLE_AUTO_UPDATE=true
        ZSH_THEME=""
        plugins=(git zsh-autosuggestions zsh-syntax-highlighting)
        source "$ZSH/oh-my-zsh.sh"
        """.write(
            to: userZdotdirURL.appendingPathComponent(".zshrc", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        return [
            "HOME": homeURL.path,
            "TERM": "xterm-256color",
            "SHELL": "/bin/zsh",
            "USER": NSUserName(),
            "PATH": "\(pathPrefix):/usr/bin:/bin",
            "ZDOTDIR": integrationDir.path,
            "CMUX_ZSH_ZDOTDIR": userZdotdirURL.path,
            "CMUX_SHELL_INTEGRATION": "1",
            "CMUX_SHELL_INTEGRATION_DIR": integrationDir.path,
            "CMUX_ZSH_RESTORE_TERM": "xterm-256color",
            "CMUX_CODEX_WRAPPER_SHIM": codexShimURL.path,
            "CMUX_FAKE_CODEX_OUTPUT": codexOutputURL.path,
            "ZSH_DISABLE_COMPFIX": "true",
            "DISABLE_AUTO_UPDATE": "true",
        ]
    }

    private func writeOhMyZshFixture(at root: URL) throws {
        let customPluginRoot = root.appendingPathComponent("custom/plugins", isDirectory: true)
        let autosuggestionsURL = customPluginRoot
            .appendingPathComponent("zsh-autosuggestions", isDirectory: true)
        let syntaxHighlightingURL = customPluginRoot
            .appendingPathComponent("zsh-syntax-highlighting", isDirectory: true)
        try FileManager.default.createDirectory(at: autosuggestionsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: syntaxHighlightingURL, withIntermediateDirectories: true)

        try """
        autoload -Uz add-zsh-hook
        for plugin in $plugins; do
          plugin_file="$ZSH/custom/plugins/$plugin/$plugin.plugin.zsh"
          [[ -r "$plugin_file" ]] && source "$plugin_file"
        done
        """.write(
            to: root.appendingPathComponent("oh-my-zsh.sh", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
        try """
        autoload -Uz add-zsh-hook
        _cmux_test_autosuggest_precmd() { :; }
        _cmux_test_autosuggest_preexec() { :; }
        add-zsh-hook precmd _cmux_test_autosuggest_precmd
        add-zsh-hook preexec _cmux_test_autosuggest_preexec
        _cmux_test_autosuggest_self_insert() { zle .self-insert }
        zle -N self-insert _cmux_test_autosuggest_self_insert
        """.write(
            to: autosuggestionsURL.appendingPathComponent("zsh-autosuggestions.plugin.zsh", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
        try """
        _cmux_test_syntax_highlighting_line_init() { :; }
        _cmux_test_syntax_highlighting_line_finish() { :; }
        zle -N zle-line-init _cmux_test_syntax_highlighting_line_init
        zle -N zle-line-finish _cmux_test_syntax_highlighting_line_finish
        """.write(
            to: syntaxHighlightingURL.appendingPathComponent("zsh-syntax-highlighting.plugin.zsh", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
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
