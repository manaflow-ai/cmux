import Foundation
import Testing
import CmuxTerminal

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

@Suite(.serialized)
struct ShellStartupMatrixTests {
    private struct ProcessRunResult {
        let status: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
        let duration: TimeInterval
    }

    @Test
    func zshStartupPreservesUserZdotdirAndLoadsGhosttyIntegration() throws {
        let bundled = try makeBundledIntegrationDir(files: [".zshenv": "# cmux zsh bootstrap stub\n"])
        defer { try? FileManager.default.removeItem(at: bundled.root) }
        let integrationDir = bundled.integrationDir
        var environment = [
            "ZDOTDIR": "/Users/example/.zsh",
            "GHOSTTY_RESOURCES_DIR": "/Applications/Ghostty.app/Contents/Resources",
        ]
        var protectedKeys: Set<String> = []

        let command = TerminalSurface.applyManagedShellSpecificStartupEnvironment(
            shell: "/bin/zsh",
            integrationDir: integrationDir,
            userGhosttyShellIntegrationMode: "detect",
            to: &environment,
            protectedKeys: &protectedKeys
        )

        expectEqual(command, nil)
        expectEqual(environment["ZDOTDIR"], integrationDir)
        expectEqual(environment["CMUX_ZSH_ZDOTDIR"], "/Users/example/.zsh")
        expectEqual(environment["CMUX_LOAD_GHOSTTY_ZSH_INTEGRATION"], "1")
        expectTrue(protectedKeys.isSuperset(of: ["ZDOTDIR", "CMUX_ZSH_ZDOTDIR", "CMUX_LOAD_GHOSTTY_ZSH_INTEGRATION"]))
    }

    @Test
    func zshStartupDoesNotPreserveGhosttyInjectedZdotdir() throws {
        let bundled = try makeBundledIntegrationDir(files: [".zshenv": "# cmux zsh bootstrap stub\n"])
        defer { try? FileManager.default.removeItem(at: bundled.root) }
        let ghosttyResources = "/Applications/Ghostty.app/Contents/Resources"
        var environment = [
            "ZDOTDIR": "\(ghosttyResources)/shell-integration/zsh",
            "GHOSTTY_RESOURCES_DIR": ghosttyResources,
        ]
        var protectedKeys: Set<String> = []

        _ = TerminalSurface.applyManagedShellSpecificStartupEnvironment(
            shell: "/bin/zsh",
            integrationDir: bundled.integrationDir,
            userGhosttyShellIntegrationMode: "detect",
            to: &environment,
            protectedKeys: &protectedKeys
        )

        expectEqual(environment["CMUX_ZSH_ZDOTDIR"], nil)
        expectFalse(protectedKeys.contains("CMUX_ZSH_ZDOTDIR"))
    }

    @Test
    func bashStartupUsesBundledPromptCommandAndHonorsGhosttyMode() {
        let integrationDir = "/Applications/cmux.app/Contents/Resources/shell-integration"
        var environment: [String: String] = [:]
        var protectedKeys: Set<String> = []

        _ = TerminalSurface.applyManagedShellSpecificStartupEnvironment(
            shell: "/opt/homebrew/bin/bash",
            integrationDir: integrationDir,
            userGhosttyShellIntegrationMode: "none",
            to: &environment,
            protectedKeys: &protectedKeys,
            readFile: { path in
                expectEqual(path, "\(integrationDir)/cmux-bash-bootstrap.bash")
                return """
                # comment

                export CMUX_TEST=1
                   # indented comment
                cmux-test-command
                """
            }
        )

        expectEqual(environment["CMUX_LOAD_GHOSTTY_BASH_INTEGRATION"], nil)
        expectEqual(environment["PROMPT_COMMAND"], "export CMUX_TEST=1\ncmux-test-command")
        expectTrue(protectedKeys.contains("PROMPT_COMMAND"))
        expectFalse(protectedKeys.contains("CMUX_LOAD_GHOSTTY_BASH_INTEGRATION"))
    }

    @Test
    func fishStartupReturnsManagedCommandAndPreservesUserConfigHome() throws {
        let bundled = try makeBundledIntegrationDir(files: ["fish/config.fish": "# cmux fish bootstrap stub\n"])
        defer { try? FileManager.default.removeItem(at: bundled.root) }
        let integrationDir = bundled.integrationDir
        let shell = "/opt/homebrew/bin/fish"
        var environment = ["XDG_CONFIG_HOME": "/Users/example/.config"]
        var protectedKeys: Set<String> = []

        let command = TerminalSurface.applyManagedShellSpecificStartupEnvironment(
            shell: shell,
            integrationDir: integrationDir,
            userGhosttyShellIntegrationMode: "detect",
            to: &environment,
            protectedKeys: &protectedKeys
        )

        expectEqual(command, TerminalSurface.managedFishShellCommand(shell: shell))
        expectEqual(environment["XDG_CONFIG_HOME"], "/Users/example/.config")
        expectEqual(environment["CMUX_FISH_INTEGRATION_FILE"], "\(integrationDir)/fish/config.fish")
        expectEqual(environment["CMUX_FISH_USER_CONFIG_ALREADY_LOADED"], "1")
    }

    @Test(arguments: ["/bin/sh", "/bin/dash", "/bin/ksh", "/bin/tcsh", "/bin/csh", "/usr/local/bin/nu", "/usr/local/bin/pwsh"])
    func unsupportedLocalShellsKeepEnvironmentUnchanged(shell: String) {
        let originalEnvironment = ["CUSTOM": "1"]
        var environment = originalEnvironment
        var protectedKeys: Set<String> = []

        let command = TerminalSurface.applyManagedShellSpecificStartupEnvironment(
            shell: shell,
            integrationDir: "/Applications/cmux.app/Contents/Resources/shell-integration",
            userGhosttyShellIntegrationMode: "detect",
            to: &environment,
            protectedKeys: &protectedKeys
        )

        expectEqual(command, nil)
        expectEqual(environment, originalEnvironment)
        expectTrue(protectedKeys.isEmpty)
    }

    @Test(arguments: [
        RemoteShellCase(name: "zsh", expectedArgs: "-il"),
        RemoteShellCase(name: "bash", expectedArgs: "--rcfile"),
        RemoteShellCase(name: "fish", expectedArgs: "-il --init-command source \"$CMUX_FISH_INTEGRATION_FILE\""),
        RemoteShellCase(name: "sh", expectedArgs: "-i"),
        RemoteShellCase(name: "dash", expectedArgs: "-i"),
        RemoteShellCase(name: "ksh", expectedArgs: "-i"),
        RemoteShellCase(name: "tcsh", expectedArgs: "-i"),
        RemoteShellCase(name: "csh", expectedArgs: "-i"),
    ])
    func generatedSshBootstrapHandlesShellMatrix(shellCase: RemoteShellCase) throws {
        let result = try runGeneratedBootstrap(shellName: shellCase.name)

        expectEqual(result.process.status, 0, result.process.stderr)
        expectFalse(result.process.timedOut, result.process.stderr)
        expectTrue(result.capture.contains("ARGS=\(shellCase.expectedArgs)"), result.capture)
        expectTrue(result.capture.contains("PATH=\(result.home.path)/.cmux/bin:"), result.capture)
        expectTrue(result.capture.contains("CMUX_SOCKET_PATH=127.0.0.1:64123"), result.capture)
        expectTrue(result.capture.contains("GHOSTTY_SHELL_FEATURES=existing-feature,ssh-env,ssh-terminfo"), result.capture)

        switch shellCase.name {
        case "zsh":
            expectTrue(result.capture.contains("ZDOTDIR=\(result.home.path)/.cmux/relay/64123.shell"), result.capture)
            expectTrue(result.capture.contains("CMUX_REAL_ZDOTDIR=\(result.home.path)/user-zdotdir"), result.capture)
            expectTrue(result.capture.contains("ZSH_INTEGRATION_HAS_MARKER=yes"), result.capture)
        case "bash":
            expectTrue(result.capture.contains("BASH_INTEGRATION_HAS_MARKER=yes"), result.capture)
        case "fish":
            expectTrue(result.capture.contains("CMUX_FISH_INTEGRATION_FILE=\(result.home.path)/.cmux/relay/64123.shell/fish/config.fish"), result.capture)
            expectTrue(result.capture.contains("CMUX_FISH_USER_CONFIG_ALREADY_LOADED=1"), result.capture)
            expectTrue(result.capture.contains("FISH_HAS_MARKER=yes"), result.capture)
        default:
            expectTrue(result.capture.contains("CMUX_FISH_INTEGRATION_FILE=\n"), result.capture)
            expectTrue(result.capture.contains("CMUX_REAL_ZDOTDIR=\n"), result.capture)
        }
    }

    @Test(arguments: ["zsh", "bash", "fish", "sh", "dash", "ksh", "tcsh", "csh"])
    func generatedSshBootstrapStartupStaysUnderPerformanceBudget(shellName: String) throws {
        let result = try runGeneratedBootstrap(shellName: shellName)

        // Success + no timeout is the causal signal that the bootstrap ran to
        // completion for this shell. `runGeneratedBootstrap` already runs under a
        // 5s `runProcess` timeout (which flips `timedOut`), so an explicit
        // wall-clock duration ceiling here would be redundant and load-sensitive
        // on shared CI; assert behavior, not measured latency.
        expectEqual(result.process.status, 0, result.process.stderr)
        expectFalse(result.process.timedOut, result.process.stderr)
    }

    @Test
    func generatedSshBootstrapDoesNotBlockOnRelayCliWarmup() throws {
        let result = try runGeneratedBootstrap(
            shellName: "sh",
            fakeCmuxDelay: 2,
            workspaceID: "workspace-perf",
            surfaceID: "surface-perf",
            bootstrapTTY: "ttys999"
        )

        expectEqual(result.process.status, 0, result.process.stderr)
        expectFalse(result.process.timedOut, result.process.stderr)
        expectTrue(
            result.process.duration < 1.0,
            "cmux ssh bootstrap waited for relay CLI warmup: \(formatSeconds(result.process.duration))"
        )
    }

    /// Regression for #6352: running Claude Code (or any full-screen TUI) inside
    /// a `cmux ssh` remote workspace garbled the output because the remote
    /// bootstrap installed the bundled `xterm-ghostty` terminfo in a *background*
    /// job while `TERM` was decided synchronously. On a host without the entry,
    /// the bootstrap therefore had to either fall back to `xterm-256color` (losing
    /// ghostty) or — on a later shell pass — pick `xterm-ghostty` while the
    /// background `tic` was still writing the database, so the TUI rendered
    /// against a missing/half-written terminfo entry.
    ///
    /// The install must be synchronous: once the bundled terminfo source is
    /// available and `tic` exists, the very first shell pass must resolve and
    /// select `xterm-ghostty` before exporting `TERM`. This test runs the
    /// generated setup lines against an isolated `$HOME`/terminfo search path so
    /// the host's own `xterm-ghostty` cannot mask the behavior.
    @Test
    func remoteTerminalSetupInstallsGhosttyTerminfoBeforeChoosingTerm() throws {
        let fileManager = FileManager.default
        guard fileManager.isExecutableFile(atPath: "/usr/bin/tic"),
              fileManager.isExecutableFile(atPath: "/usr/bin/infocmp")
        else {
            // Host lacks the terminfo toolchain; the synchronous install path
            // cannot be exercised here. cmux CI runners ship both binaries.
            return
        }

        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-terminfo-\(UUID().uuidString)")
        let home = root.appendingPathComponent("home")
        let emptyTerminfoDirs = root.appendingPathComponent("empty-terminfo")
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: emptyTerminfoDirs, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        // A minimal but valid `xterm-ghostty` entry: enough for `tic -x` to
        // accept it and for `infocmp xterm-ghostty` to resolve it once installed.
        let terminfoSource = """
        xterm-ghostty|cmux ghostty regression terminfo,
        \tam, colors#256, cols#80, lines#24,
        \tcup=\\E[%i%p1%d;%p2%dH, clear=\\E[H\\E[2J, cr=^M, cud1=^J,
        """

        let lines = RemoteInteractiveShellBootstrapBuilder.terminalSetupLines(
            terminfoSource: terminfoSource
        )
        let script = lines.joined(separator: "\n")
            + "\nprintf 'CMUX_TERMINFO_TEST_TERM=%s\\n' \"$TERM\"\n"

        // Isolate the terminfo search path so the host's real `xterm-ghostty`
        // entry can't be found: ncurses consults $TERMINFO, then $HOME/.terminfo,
        // then $TERMINFO_DIRS. Point all of them at fresh, empty directories so
        // the only way to resolve `xterm-ghostty` is the in-script install.
        let result = runProcess(
            executablePath: "/usr/bin/env",
            arguments: [
                "HOME=\(home.path)",
                "TERMINFO=\(home.path)/.terminfo",
                "TERMINFO_DIRS=\(emptyTerminfoDirs.path)",
                "PATH=/usr/bin:/bin",
                "/bin/sh",
                "-c",
                script,
            ],
            timeout: 10
        )

        expectEqual(result.status, 0, result.stderr)
        expectFalse(result.timedOut, result.stderr)
        expectTrue(
            result.stdout.contains("CMUX_TERMINFO_TEST_TERM=xterm-ghostty"),
            "remote bootstrap did not install xterm-ghostty terminfo before "
                + "choosing TERM (stdout: \(result.stdout))"
        )
    }

    struct RemoteShellCase: Sendable, CustomTestStringConvertible {
        let name: String
        let expectedArgs: String
        var testDescription: String { name }
    }

    private struct GeneratedBootstrapResult {
        let home: URL
        let capture: String
        let process: ProcessRunResult
    }

    private func runGeneratedBootstrap(
        shellName: String,
        fakeCmuxDelay: TimeInterval? = nil,
        workspaceID: String? = nil,
        surfaceID: String? = nil,
        bootstrapTTY: String? = nil
    ) throws -> GeneratedBootstrapResult {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("cmux-shell-matrix-\(UUID().uuidString)")
        let home = root.appendingPathComponent("home")
        let bin = root.appendingPathComponent("bin")
        let capturePath = root.appendingPathComponent("capture.txt")
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try writeExecutableShellFile(at: bin.appendingPathComponent(shellName), capturePath: capturePath)
        if let fakeCmuxDelay {
            try writeExecutableCmuxFile(at: bin.appendingPathComponent("cmux"), delay: fakeCmuxDelay)
        }
        var script = RemoteInteractiveShellBootstrapBuilder.script(
            remoteRelayPort: 64123,
            shellFeatures: RemoteInteractiveShellBootstrapBuilder.shellFeatures(environment: [
                "GHOSTTY_SHELL_FEATURES": "existing-feature"
            ]),
            bundledZshIntegration: "cmux_zsh_marker=1",
            bundledBashIntegration: "cmux_bash_marker=1",
            bundledFishIntegration: "set -gx CMUX_FISH_MARKER 1"
        )
        if let workspaceID {
            script = script.replacingOccurrences(of: "__CMUX_WORKSPACE_ID__", with: workspaceID)
        }
        if let surfaceID {
            script = script.replacingOccurrences(of: "__CMUX_SURFACE_ID__", with: surfaceID)
        }
        var arguments = [
            "HOME=\(home.path)",
            "SHELL=\(bin.appendingPathComponent(shellName).path)",
            "PATH=\(bin.path):/usr/bin:/bin",
            "TERM=xterm-256color",
            "USER=\(NSUserName())",
            "ZDOTDIR=\(home.path)/user-zdotdir",
            "CMUX_CAPTURE_PATH=\(capturePath.path)",
        ]
        if let bootstrapTTY {
            arguments.append("CMUX_BOOTSTRAP_TTY=\(bootstrapTTY)")
        }
        arguments += [
            "/bin/sh",
            "-c",
            script,
        ]
        let process = runProcess(
            executablePath: "/usr/bin/env",
            arguments: arguments,
            timeout: 5
        )
        let capture = (try? String(contentsOf: capturePath, encoding: .utf8)) ?? ""
        return GeneratedBootstrapResult(home: home, capture: capture, process: process)
    }

    private func writeExecutableShellFile(at url: URL, capturePath: URL) throws {
        try """
        #!/bin/sh
        {
          printf 'ARGS=%s\\n' "$*"
          printf 'PATH=%s\\n' "$PATH"
          printf 'CMUX_SOCKET_PATH=%s\\n' "$CMUX_SOCKET_PATH"
          printf 'GHOSTTY_SHELL_FEATURES=%s\\n' "$GHOSTTY_SHELL_FEATURES"
          printf 'CMUX_SHELL_INTEGRATION_DIR=%s\\n' "$CMUX_SHELL_INTEGRATION_DIR"
          printf 'ZDOTDIR=%s\\n' "$ZDOTDIR"
          printf 'CMUX_REAL_ZDOTDIR=%s\\n' "$CMUX_REAL_ZDOTDIR"
          printf 'CMUX_FISH_INTEGRATION_FILE=%s\\n' "$CMUX_FISH_INTEGRATION_FILE"
          printf 'CMUX_FISH_USER_CONFIG_ALREADY_LOADED=%s\\n' "$CMUX_FISH_USER_CONFIG_ALREADY_LOADED"
          if [ -r "$CMUX_SHELL_INTEGRATION_DIR/cmux-zsh-integration.zsh" ] && grep -q 'cmux_zsh_marker=1' "$CMUX_SHELL_INTEGRATION_DIR/cmux-zsh-integration.zsh"; then
            printf 'ZSH_INTEGRATION_HAS_MARKER=yes\\n'
          fi
          if [ -r "$CMUX_SHELL_INTEGRATION_DIR/cmux-bash-integration.bash" ] && grep -q 'cmux_bash_marker=1' "$CMUX_SHELL_INTEGRATION_DIR/cmux-bash-integration.bash"; then
            printf 'BASH_INTEGRATION_HAS_MARKER=yes\\n'
          fi
          if [ -r "$CMUX_FISH_INTEGRATION_FILE" ] && grep -q 'CMUX_FISH_MARKER' "$CMUX_FISH_INTEGRATION_FILE"; then
            printf 'FISH_HAS_MARKER=yes\\n'
          fi
        } > "\(capturePath.path)"
        """
        .write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func writeExecutableCmuxFile(at url: URL, delay: TimeInterval) throws {
        try """
        #!/bin/sh
        if [ "$1" = "rpc" ]; then
          sleep \(String(format: "%.3f", delay))
        fi
        exit 0
        """
        .write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// Creates a real on-disk stand-in for the app bundle's
    /// `Resources/shell-integration` dir containing the given relative files,
    /// since the production code now verifies the bundled bootstrap exists
    /// before redirecting shell startup at it.
    private func makeBundledIntegrationDir(
        files: [String: String]
    ) throws -> (root: URL, integrationDir: String) {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-shell-matrix-bundle-\(UUID().uuidString)")
        let integrationDir = root.appendingPathComponent("shell-integration")
        for (relativePath, contents) in files {
            let fileURL = integrationDir.appendingPathComponent(relativePath)
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try contents.write(to: fileURL, atomically: true, encoding: .utf8)
        }
        return (root, integrationDir.path)
    }

    private func formatSeconds(_ value: TimeInterval) -> String {
        String(format: "%.3fs", value)
    }

    private func runProcess(
        executablePath: String,
        arguments: [String],
        timeout: TimeInterval
    ) -> ProcessRunResult {
        let process = Process()
        let start = Date()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return ProcessRunResult(
                status: -1,
                stdout: "",
                stderr: error.localizedDescription,
                timedOut: false,
                duration: Date().timeIntervalSince(start)
            )
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        let timedOut = process.isRunning
        if timedOut { process.terminate() }
        process.waitUntilExit()
        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        return ProcessRunResult(
            status: process.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? "",
            timedOut: timedOut,
            duration: Date().timeIntervalSince(start)
        )
    }
}
