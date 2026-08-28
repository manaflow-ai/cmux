import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

private let remoteShellPromptFishExecutablePath = [
    "/opt/homebrew/bin/fish",
    "/usr/local/bin/fish",
    "/usr/bin/fish",
    "/bin/fish",
].first { FileManager.default.isExecutableFile(atPath: $0) }

struct RemoteShellPromptRelayTests {
    @Test("remote shell re-exports the provisioned Codex wrapper shim")
    func remoteShellExportsCodexWrapperShim() {
        let script = RemoteInteractiveShellBootstrapBuilder.script(
            remoteRelayPort: 64_044,
            shellFeatures: "ssh-env,ssh-terminfo"
        )

        #expect(script.contains(
            "unset CMUX_CODEX_WRAPPER_SHIM; if [ -x \"$HOME/.cmux/bin/cmux-codex-wrapper\" ]"
        ))
        #expect(script.contains("command -v bash"))
    }

    @Test("remote zsh prompt reports Git metadata through the relay")
    func remoteZshPromptReportsGitMetadataThroughRelay() throws {
        let output = try runPrompt(
            shell: "/bin/zsh",
            integrationName: "cmux-zsh-integration.zsh",
            shellArguments: ["-f", "-c"],
            promptFunction: "_cmux_precmd",
            mode: "git",
            surfaceID: "22222222-2222-2222-2222-222222222222"
        )

        #expect(output.contains(
            #"rpc surface.report_git_branch {"workspace_id":"11111111-1111-1111-1111-111111111111","branch":"feature/mosh-prompt","surface_id":"22222222-2222-2222-2222-222222222222"}"#
        ), Comment(rawValue: output))
    }

    @Test("remote bash prompt reports Git metadata through the relay")
    func remoteBashPromptReportsGitMetadataThroughRelay() throws {
        let output = try runPrompt(
            shell: "/bin/bash",
            integrationName: "cmux-bash-integration.bash",
            shellArguments: ["--noprofile", "--norc", "-c"],
            promptFunction: "_cmux_prompt_command",
            mode: "git",
            surfaceID: "22222222-2222-2222-2222-222222222222"
        )

        #expect(output.contains(
            #"rpc surface.report_git_branch {"workspace_id":"11111111-1111-1111-1111-111111111111","branch":"feature/mosh-prompt","surface_id":"22222222-2222-2222-2222-222222222222"}"#
        ), Comment(rawValue: output))
    }

    @Test("remote tmux zsh prompt reports shell state through the workspace relay")
    func remoteTmuxZshPromptReportsShellStateThroughWorkspaceRelay() throws {
        let output = try runPrompt(
            shell: "/bin/zsh",
            integrationName: "cmux-zsh-integration.zsh",
            shellArguments: ["-f", "-c"],
            promptFunction: "_cmux_precmd",
            mode: "shell-state",
            surfaceID: nil
        )

        #expect(output.contains(
            #"rpc surface.report_shell_state {"workspace_id":"11111111-1111-1111-1111-111111111111","state":"prompt","terminal_lifecycle_id":"33333333-3333-3333-3333-333333333333"}"#
        ), Comment(rawValue: output))
    }

    @Test("remote tmux bash prompt reports shell state through the workspace relay")
    func remoteTmuxBashPromptReportsShellStateThroughWorkspaceRelay() throws {
        let output = try runPrompt(
            shell: "/bin/bash",
            integrationName: "cmux-bash-integration.bash",
            shellArguments: ["--noprofile", "--norc", "-c"],
            promptFunction: "_cmux_prompt_command",
            mode: "shell-state",
            surfaceID: nil
        )

        #expect(output.contains(
            #"rpc surface.report_shell_state {"workspace_id":"11111111-1111-1111-1111-111111111111","state":"prompt","terminal_lifecycle_id":"33333333-3333-3333-3333-333333333333"}"#
        ), Comment(rawValue: output))
    }

    @Test("remote zsh surface shell state carries terminal lifecycle identity")
    func remoteZshSurfaceShellStateCarriesTerminalLifecycleIdentity() throws {
        let output = try runPrompt(
            shell: "/bin/zsh",
            integrationName: "cmux-zsh-integration.zsh",
            shellArguments: ["-f", "-c"],
            promptFunction: "_cmux_precmd",
            mode: "shell-state",
            surfaceID: "22222222-2222-2222-2222-222222222222"
        )

        #expect(output.contains(
            #"rpc surface.report_shell_state {"workspace_id":"11111111-1111-1111-1111-111111111111","state":"prompt","surface_id":"22222222-2222-2222-2222-222222222222","terminal_lifecycle_id":"33333333-3333-3333-3333-333333333333"}"#
        ), Comment(rawValue: output))
    }

    @Test("remote bash surface shell state carries terminal lifecycle identity")
    func remoteBashSurfaceShellStateCarriesTerminalLifecycleIdentity() throws {
        let output = try runPrompt(
            shell: "/bin/bash",
            integrationName: "cmux-bash-integration.bash",
            shellArguments: ["--noprofile", "--norc", "-c"],
            promptFunction: "_cmux_prompt_command",
            mode: "shell-state",
            surfaceID: "22222222-2222-2222-2222-222222222222"
        )

        #expect(output.contains(
            #"rpc surface.report_shell_state {"workspace_id":"11111111-1111-1111-1111-111111111111","state":"prompt","surface_id":"22222222-2222-2222-2222-222222222222","terminal_lifecycle_id":"33333333-3333-3333-3333-333333333333"}"#
        ), Comment(rawValue: output))
    }

    @Test("workspace shell-state relay authenticates its source without pinning the focused target")
    @MainActor
    func workspaceShellStateRelayAuthenticatesSourceWithoutPinningFocusedTarget() throws {
        let previousAppDelegate = AppDelegate.shared
        let previousManager = TerminalController.shared
            .activeTabManagerForCallerNotification()
        let appDelegate = AppDelegate()
        let manager = TabManager(autoWelcomeIfNeeded: false)
        AppDelegate.shared = appDelegate
        appDelegate.tabManager = manager
        TerminalController.shared.setActiveTabManager(manager)
        let windowID = appDelegate.registerMainWindowContextForTesting(
            tabManager: manager
        )
        defer {
            appDelegate.unregisterMainWindowContextForTesting(
                windowId: windowID
            )
            manager.tabs.forEach { $0.teardownAllPanels() }
            TerminalController.shared.setActiveTabManager(previousManager)
            appDelegate.tabManager = nil
            AppDelegate.shared = previousAppDelegate
        }

        let workspace = try #require(manager.selectedWorkspace)
        let reportingTerminal = try #require(workspace.focusedTerminalPanel)
        let paneID = try #require(workspace.bonsplitController.focusedPaneId)
        let focusedTarget = try #require(workspace.newTerminalSurface(
            inPane: paneID,
            focus: true
        ))
        let reportingLifecycleID = reportingTerminal.surface.terminalLifecycleId
        #expect(workspace.focusedPanelId == focusedTarget.id)
        #expect(reportingTerminal.id != focusedTarget.id)
        #expect(GhosttyApp.terminalSurfaceRegistry.isCurrentSurface(
            id: reportingTerminal.id,
            terminalLifecycleID: reportingLifecycleID
        ))

        try reportWorkspaceShellState(
            workspaceID: workspace.id,
            terminalLifecycleID: reportingLifecycleID,
            state: "running"
        )
        #expect(focusedTarget.shellActivity.state == .commandRunning)

        _ = GhosttyApp.terminalSurfaceRegistry.advanceTerminalLifecycle(
            for: reportingTerminal.surface
        )
        #expect(!GhosttyApp.terminalSurfaceRegistry.isCurrentSurface(
            id: reportingTerminal.id,
            terminalLifecycleID: reportingLifecycleID
        ))

        try reportWorkspaceShellState(
            workspaceID: workspace.id,
            terminalLifecycleID: reportingLifecycleID,
            state: "prompt"
        )
        #expect(focusedTarget.shellActivity.state == .commandRunning)
    }

    @Test(
        "remote fish retries TTY registration until the relay acknowledges it",
        .enabled(if: remoteShellPromptFishExecutablePath != nil)
    )
    func remoteFishRetriesTTYRegistrationUntilAcknowledged() throws {
        let fish = try #require(remoteShellPromptFishExecutablePath)
        let integration = try #require(
            RemoteInteractiveShellBootstrapBuilder.bundledShellIntegrationScript(named: "fish/config.fish")
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-fish-relay-tty-\(UUID().uuidString)", isDirectory: true)
        let binDirectory = directory.appendingPathComponent("bin", isDirectory: true)
        let integrationFile = directory.appendingPathComponent("config.fish")
        let cmuxFile = binDirectory.appendingPathComponent("cmux")
        let logFile = directory.appendingPathComponent("relay.log")
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try integration.write(to: integrationFile, atomically: true, encoding: .utf8)
        try Data().write(to: logFile)
        try """
        #!/bin/sh
        if [ "${1:-}" = rpc ] && [ "${2:-}" = surface.report_tty ]; then
          printf 'call\\n' >> "$CMUX_TEST_LOG"
          [ "$(/usr/bin/wc -l < "$CMUX_TEST_LOG")" -gt 1 ] || exit 1
        fi
        printf '{"ok":true}\\n'
        """.write(to: cmuxFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cmuxFile.path)

        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: fish)
        process.arguments = [
            "-c",
            """
            source '\(integrationFile.path)'
            set -g _CMUX_TTY_NAME ttys990
            set -g _CMUX_TTY_REPORTED 0
            _cmux_report_tty_once
            _cmux_report_tty_once
            for _cmux_i in (seq 1 20)
                test -s "$CMUX_TEST_LOG"; and break
                sleep 0.05
            end
            printf 'calls=%s\\nreported=%s\\n' (count (cat "$CMUX_TEST_LOG")) "$_CMUX_TTY_REPORTED"
            """,
        ]
        process.environment = [
            "CMUX_BUNDLED_CLI_PATH": cmuxFile.path,
            "CMUX_SOCKET_PATH": "127.0.0.1:64011",
            "CMUX_SSH_ATTEMPT_ID": "44444444-4444-4444-4444-444444444444",
            "CMUX_TAB_ID": "11111111-1111-1111-1111-111111111111",
            "CMUX_TERMINAL_LIFECYCLE_ID": "33333333-3333-3333-3333-333333333333",
            "CMUX_TEST_LOG": logFile.path,
            "CMUX_WORKSPACE_ID": "11111111-1111-1111-1111-111111111111",
            "HOME": directory.path,
            "PATH": "\(binDirectory.path):/usr/bin:/bin",
            "TERM": "xterm-256color",
        ]
        process.standardOutput = standardOutput
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: standardOutput.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let error = String(decoding: standardError.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

        #expect(process.terminationStatus == 0, "\(error)\n\(output)")
        #expect(output.contains("calls=2"), Comment(rawValue: output))
        #expect(output.contains("reported=1"), Comment(rawValue: output))
    }

    private func runPrompt(
        shell: String,
        integrationName: String,
        shellArguments: [String],
        promptFunction: String,
        mode: String,
        surfaceID: String?
    ) throws -> String {
        let integration = try #require(
            RemoteInteractiveShellBootstrapBuilder.bundledShellIntegrationScript(named: integrationName)
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-relay-prompt-\(UUID().uuidString)", isDirectory: true)
        let repository = directory.appendingPathComponent("repository", isDirectory: true)
        let gitDirectory = repository.appendingPathComponent(".git", isDirectory: true)
        let binDirectory = directory.appendingPathComponent("bin", isDirectory: true)
        let integrationFile = directory.appendingPathComponent(integrationName)
        let cmuxFile = binDirectory.appendingPathComponent("cmux")
        let logFile = directory.appendingPathComponent("relay.log")
        try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        guard Darwin.mkfifo(logFile.path, 0o600) == 0 else { throw POSIXError(.EIO) }
        defer { try? FileManager.default.removeItem(at: directory) }

        try integration.write(to: integrationFile, atomically: true, encoding: .utf8)
        try "ref: refs/heads/feature/mosh-prompt\n".write(
            to: gitDirectory.appendingPathComponent("HEAD"),
            atomically: true,
            encoding: .utf8
        )
        try "#!/bin/sh\nprintf '%s\\n' \"$*\" > \"$CMUX_TEST_LOG\"\n".write(
            to: cmuxFile,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cmuxFile.path)

        let modeSetup = mode == "git"
            ? "_CMUX_SHELL_ACTIVITY_LAST=prompt"
            : "CMUX_NO_GIT_WATCH=1; export CMUX_NO_GIT_WATCH"
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = shellArguments + [
            """
            source '\(integrationFile.path)'
            _CMUX_TTY_REPORTED=1
            _CMUX_PWD_LAST_PWD="$PWD"
            _CMUX_PORTS_LAST_RUN="$(_cmux_now)"
            \(modeSetup)
            exec 9<> "$CMUX_TEST_LOG"
            \(promptFunction)
            cmux_relay_line=""
            IFS= read -r -t 2 cmux_relay_line <&9 || true
            printf '%s\n' "$cmux_relay_line"
            exec 9>&-
            """,
        ]
        process.currentDirectoryURL = repository
        var environment = [
            "CMUX_BUNDLED_CLI_PATH": cmuxFile.path,
            "CMUX_SOCKET_PATH": "127.0.0.1:64011",
            "CMUX_TAB_ID": "11111111-1111-1111-1111-111111111111",
            "CMUX_TERMINAL_LIFECYCLE_ID": "33333333-3333-3333-3333-333333333333",
            "CMUX_TEST_LOG": logFile.path,
            "CMUX_WORKSPACE_ID": "11111111-1111-1111-1111-111111111111",
            "HOME": directory.path,
            "PATH": "\(binDirectory.path):/usr/bin:/bin",
            "TERM": "xterm-256color",
        ]
        if let surfaceID {
            environment["CMUX_PANEL_ID"] = surfaceID
            environment["CMUX_SURFACE_ID"] = surfaceID
        }
        process.environment = environment
        process.standardOutput = standardOutput
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: standardOutput.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let error = String(decoding: standardError.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

        #expect(process.terminationStatus == 0, "\(error)\n\(output)")
        return output
    }

    @MainActor
    private func reportWorkspaceShellState(
        workspaceID: UUID,
        terminalLifecycleID: UUID,
        state: String
    ) throws {
        let request: [String: Any] = [
            "id": state,
            "method": "surface.report_shell_state",
            "params": [
                "workspace_id": workspaceID.uuidString,
                "terminal_lifecycle_id": terminalLifecycleID.uuidString,
                "state": state,
            ],
        ]
        let requestData = try JSONSerialization.data(withJSONObject: request)
        let requestLine = try #require(
            String(data: requestData, encoding: .utf8)
        )
        let rawResponse = TerminalController.shared.handleSocketLine(requestLine)
        let responseData = try #require(rawResponse.data(using: .utf8))
        let response = try #require(
            JSONSerialization.jsonObject(with: responseData)
                as? [String: Any]
        )
        #expect(response["ok"] as? Bool == true, Comment(rawValue: rawResponse))
    }
}
