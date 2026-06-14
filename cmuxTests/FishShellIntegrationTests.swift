import Foundation
import Testing
import CmuxTerminal

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

private let fishExecutablePath = [
    "/opt/homebrew/bin/fish",
    "/usr/local/bin/fish",
    "/usr/bin/fish",
    "/bin/fish",
].first { FileManager.default.isExecutableFile(atPath: $0) }

@Suite(.serialized)
struct FishShellIntegrationTests {
    private struct ProcessRunResult {
        let status: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
    }

    @Test
    func testApplyManagedFishStartupEnvironmentPreservesUserConfigHome() {
        var environment = ["XDG_CONFIG_HOME": "/Users/example/.config"]
        var protectedKeys: Set<String> = []

        TerminalSurface.applyManagedFishStartupEnvironment(
            integrationDir: "/Applications/cmux.app/Contents/Resources/shell-integration",
            to: &environment,
            protectedKeys: &protectedKeys
        )

        expectEqual(environment["XDG_CONFIG_HOME"], "/Users/example/.config")
        expectEqual(environment["CMUX_FISH_INTEGRATION_FILE"], "/Applications/cmux.app/Contents/Resources/shell-integration/fish/config.fish")
        expectEqual(environment["CMUX_FISH_USER_CONFIG_ALREADY_LOADED"], "1")
        expectFalse(protectedKeys.contains("XDG_CONFIG_HOME"))
        expectTrue(protectedKeys.contains("CMUX_FISH_INTEGRATION_FILE"))
        expectTrue(protectedKeys.contains("CMUX_FISH_USER_CONFIG_ALREADY_LOADED"))
    }

    @Test
    func testApplyManagedFishStartupEnvironmentAvoidsRecursiveConfigHome() {
        var environment = ["XDG_CONFIG_HOME": "/Applications/cmux.app/Contents/Resources/shell-integration/"]
        var protectedKeys: Set<String> = []

        TerminalSurface.applyManagedFishStartupEnvironment(
            integrationDir: "/Applications/cmux.app/Contents/Resources/shell-integration",
            to: &environment,
            protectedKeys: &protectedKeys
        )

        expectEqual(environment["XDG_CONFIG_HOME"], "/Applications/cmux.app/Contents/Resources/shell-integration/")
        expectEqual(environment["CMUX_FISH_INTEGRATION_FILE"], "/Applications/cmux.app/Contents/Resources/shell-integration/fish/config.fish")
        expectEqual(environment["CMUX_FISH_USER_CONFIG_ALREADY_LOADED"], "1")
        expectFalse(protectedKeys.contains("XDG_CONFIG_HOME"))
        expectTrue(protectedKeys.contains("CMUX_FISH_INTEGRATION_FILE"))
        expectTrue(protectedKeys.contains("CMUX_FISH_USER_CONFIG_ALREADY_LOADED"))
    }

    @Test
    func testManagedFishShellCommandLetsGhosttyApplyLoginExecWrapper() {
        let command = TerminalSurface.managedFishShellCommand(shell: "/Applications/cmux DEV fishsh.app/fish")

        expectEqual(command, "'/Applications/cmux DEV fishsh.app/fish' -il --init-command 'source \"$CMUX_FISH_INTEGRATION_FILE\"'")
        expectFalse(command.hasPrefix("exec "))
    }

    @Test(.enabled(if: fishExecutablePath != nil))
    func testFishIntegrationConfigParsesWhenFishIsAvailable() throws {
        let fishExecutable = try requireFishExecutable()
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let integrationPath = repoRoot.appendingPathComponent("Resources/shell-integration/fish/config.fish")

        let result = runProcess(
            executablePath: fishExecutable,
            arguments: ["-n", integrationPath.path],
            environment: ProcessInfo.processInfo.environment,
            timeout: 5
        )

        expectFalse(result.timedOut, result.stderr)
        expectEqual(result.status, 0, result.stderr)
    }

    @Test(.enabled(if: fishExecutablePath != nil))
    func testFishIntegrationSourcesUserConfigAndReportsShellState() throws {
        _ = try requireFishExecutable()
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-fish-shell-integration-\(UUID().uuidString)")
        let userConfigHome = root.appendingPathComponent("user-config", isDirectory: true)
        let logPath = root.appendingPathComponent("send.log", isDirectory: false)

        try writeUserFishConfig(at: userConfigHome)
        defer { try? fileManager.removeItem(at: root) }

        let result = try runInteractiveFish(
            command: """
            functions -e _cmux_socket_is_unix
            function _cmux_socket_is_unix
                return 0
            end
            functions -e _cmux_send_bg
            function _cmux_send_bg
                printf '%s\\n' $argv[1] >> "$CMUX_TEST_LOG"
            end
            set -g _CMUX_TTY_NAME ttys777
            set -g _CMUX_TTY_REPORTED 0
            _cmux_preexec
            _cmux_prompt
            printf 'USER_CONFIG=%s\\n' "$CMUX_USER_FISH_CONFIG_SOURCED"
            printf 'USER_CONFD=%s\\n' "$CMUX_USER_FISH_CONFD_SOURCED"
            printf 'XDG_CONFIG_HOME=%s\\n' "$XDG_CONFIG_HOME"
            printf 'FUNCTION_PATH=%s\\n' (string join : $fish_function_path)
            printf 'COMPLETION_PATH=%s\\n' (string join : $fish_complete_path)
            printf 'FUNCTION_RESULT=%s\\n' (cmux_test_function)
            printf 'CLAUDE_RESULT=%s\\n' (claude test)
            printf 'GROK_RESULT=%s\\n' (grok test)
            printf 'UNIVERSAL=%s\\n' "$CMUX_UNIVERSAL_TEST"
            cat "$CMUX_TEST_LOG"
            """,
            extraEnvironment: [
                "CMUX_TEST_USER_CONFIG_HOME": userConfigHome.path,
                "CMUX_TEST_LOG": logPath.path,
                "CMUX_SOCKET_PATH": root.appendingPathComponent("cmux-test.sock").path,
                "CMUX_TAB_ID": "11111111-1111-1111-1111-111111111111",
                "CMUX_PANEL_ID": "22222222-2222-2222-2222-222222222222",
            ]
        )

        expectTrue(result.stdout.contains("USER_CONFIG=1"), result.stdout)
        expectTrue(result.stdout.contains("USER_CONFD=1"), result.stdout)
        expectTrue(result.stdout.contains("XDG_CONFIG_HOME=\(userConfigHome.path)"), result.stdout)
        expectTrue(result.stdout.contains("FUNCTION_PATH=\(userConfigHome.path)/fish/functions"), result.stdout)
        expectTrue(result.stdout.contains("COMPLETION_PATH=\(userConfigHome.path)/fish/completions"), result.stdout)
        expectTrue(result.stdout.contains("FUNCTION_RESULT=function-loaded"), result.stdout)
        expectTrue(result.stdout.contains("CLAUDE_RESULT=user-claude test"), result.stdout)
        expectTrue(result.stdout.contains("GROK_RESULT=user-grok test"), result.stdout)
        expectTrue(result.stdout.contains("UNIVERSAL=universal-loaded"), result.stdout)
        expectTrue(
            result.stdout.contains("report_tty ttys777 --tab=11111111-1111-1111-1111-111111111111 --panel=22222222-2222-2222-2222-222222222222"),
            result.stdout
        )
        expectTrue(
            result.stdout.contains("report_shell_state running --tab=11111111-1111-1111-1111-111111111111 --panel=22222222-2222-2222-2222-222222222222"),
            result.stdout
        )
        expectTrue(
            result.stdout.contains("ports_kick --tab=11111111-1111-1111-1111-111111111111 --panel=22222222-2222-2222-2222-222222222222 --reason=command"),
            result.stdout
        )
        expectTrue(
            result.stdout.contains("report_shell_state prompt --tab=11111111-1111-1111-1111-111111111111 --panel=22222222-2222-2222-2222-222222222222"),
            result.stdout
        )
    }

    @Test
    func testGeneratedFishBootstrapStagesIntegrationAndPreservesUserConfigHome() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-fish-shell-bootstrap-\(UUID().uuidString)")
        let home = root.appendingPathComponent("home")
        let bin = root.appendingPathComponent("bin")
        let userConfigHome = root.appendingPathComponent("user-config")
        let capturePath = root.appendingPathComponent("fish-env.txt")
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: userConfigHome, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try writeExecutableShellFile(
            at: bin.appendingPathComponent("fish"),
            body: """
            #!/bin/sh
            {
              printf 'XDG_CONFIG_HOME=%s\\n' "$XDG_CONFIG_HOME"
              printf 'CMUX_FISH_INTEGRATION_FILE=%s\\n' "$CMUX_FISH_INTEGRATION_FILE"
              printf 'CMUX_FISH_USER_CONFIG_ALREADY_LOADED=%s\\n' "$CMUX_FISH_USER_CONFIG_ALREADY_LOADED"
              printf 'ARGS=%s\\n' "$*"
              printf 'CONFIG<<EOF\\n'
              cat "$CMUX_FISH_INTEGRATION_FILE"
              printf '\\nEOF\\n'
            } > "$CMUX_CAPTURE_FISH"
            """
        )

        let script = RemoteInteractiveShellBootstrapBuilder.script(
            remoteRelayPort: 0,
            shellFeatures: "",
            bundledFishIntegration: "set -gx CMUX_FISH_TEST_INTEGRATION 1"
        )
        let result = runProcess(
            executablePath: "/usr/bin/env",
            arguments: [
                "HOME=\(home.path)",
                "SHELL=\(bin.appendingPathComponent("fish").path)",
                "PATH=\(bin.path):/usr/bin:/bin",
                "TERM=xterm-256color",
                "USER=\(NSUserName())",
                "XDG_CONFIG_HOME=\(userConfigHome.path)",
                "CMUX_CAPTURE_FISH=\(capturePath.path)",
                "/bin/sh",
                "-c",
                script,
            ],
            timeout: 5
        )

        expectFalse(result.timedOut, result.stderr)
        expectEqual(result.status, 0, result.stderr)

        let output = try String(contentsOf: capturePath, encoding: .utf8)
        expectTrue(output.contains("XDG_CONFIG_HOME=\(userConfigHome.path)"), output)
        expectTrue(output.contains("CMUX_FISH_INTEGRATION_FILE=\(home.path)/.cmux/relay/0.shell/fish/config.fish"), output)
        expectTrue(output.contains("CMUX_FISH_USER_CONFIG_ALREADY_LOADED=1"), output)
        expectTrue(output.contains("ARGS=-il --init-command source \"$CMUX_FISH_INTEGRATION_FILE\""), output)
        expectTrue(output.contains("set -gx CMUX_FISH_TEST_INTEGRATION 1"), output)
    }

    private func writeUserFishConfig(at userConfigHome: URL) throws {
        let userFishConfig = userConfigHome.appendingPathComponent("fish/config.fish", isDirectory: false)
        let userFishConfD = userConfigHome.appendingPathComponent("fish/conf.d/cmux-test.fish", isDirectory: false)
        let userFishFunction = userConfigHome.appendingPathComponent("fish/functions/cmux_test_function.fish", isDirectory: false)
        let userFishCompletion = userConfigHome.appendingPathComponent("fish/completions/cmux-test.fish", isDirectory: false)
        let userFishVariables = userConfigHome.appendingPathComponent("fish/fish_variables", isDirectory: false)
        let fileManager = FileManager.default

        try [
            userFishConfig,
            userFishConfD,
            userFishFunction,
            userFishCompletion,
            userFishVariables,
        ].forEach {
            try fileManager.createDirectory(at: $0.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try """
        set -gx CMUX_USER_FISH_CONFIG_SOURCED 1
        function claude
            echo user-claude $argv
        end
        function grok
            echo user-grok $argv
        end
        """
            .write(to: userFishConfig, atomically: true, encoding: .utf8)
        try "set -gx CMUX_USER_FISH_CONFD_SOURCED 1\n"
            .write(to: userFishConfD, atomically: true, encoding: .utf8)
        try """
        function cmux_test_function
            echo function-loaded
        end
        """.write(to: userFishFunction, atomically: true, encoding: .utf8)
        try "complete -c cmux-test -f\n"
            .write(to: userFishCompletion, atomically: true, encoding: .utf8)
        try """
        # This file contains fish universal variable definitions.
        # VERSION: 3.0
        SETUVAR CMUX_UNIVERSAL_TEST:universal\\x2dloaded
        """.write(to: userFishVariables, atomically: true, encoding: .utf8)
    }

    private func requireFishExecutable() throws -> String {
        guard let fish = fishExecutablePath else {
            Issue.record("fish is not installed")
            throw CancellationError()
        }
        return fish
    }

    private func runInteractiveFish(
        command: String,
        extraEnvironment: [String: String] = [:]
    ) throws -> (stdout: String, stderr: String) {
        let fishExecutable = try requireFishExecutable()
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-fish-shell-integration-\(UUID().uuidString)")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let integrationDir = repoRoot.appendingPathComponent("Resources/shell-integration", isDirectory: true)
        let testIntegrationDir = root.appendingPathComponent("shell integration with spaces", isDirectory: true)
        try fileManager.copyItem(at: integrationDir, to: testIntegrationDir)
        let testBinDir = testIntegrationDir.appendingPathComponent("bin", isDirectory: true)
        try fileManager.createDirectory(at: testBinDir, withIntermediateDirectories: true)
        try writeExecutableShellFile(at: testBinDir.appendingPathComponent("cmux-claude-wrapper"), body: "#!/bin/sh\necho cmux-claude-wrapper \"$@\"\n")
        try writeExecutableShellFile(at: testBinDir.appendingPathComponent("grok"), body: "#!/bin/sh\necho cmux-grok-wrapper \"$@\"\n")
        let integrationFile = testIntegrationDir.appendingPathComponent("fish/config.fish", isDirectory: false)

        var environment: [String: String] = [
            "HOME": root.path,
            "TERM": "xterm-256color",
            "SHELL": fishExecutable,
            "USER": NSUserName(),
            "XDG_CONFIG_HOME": extraEnvironment["CMUX_TEST_USER_CONFIG_HOME"] ?? root.appendingPathComponent("user-config").path,
            "CMUX_SHELL_INTEGRATION": "1",
            "CMUX_SHELL_INTEGRATION_DIR": testIntegrationDir.path,
            "CMUX_FISH_INTEGRATION_FILE": integrationFile.path,
            "CMUX_FISH_USER_CONFIG_ALREADY_LOADED": "1",
        ]
        extraEnvironment.forEach { environment[$0] = $1 }
        environment.removeValue(forKey: "CMUX_TEST_USER_CONFIG_HOME")

        let result = runProcess(
            executablePath: fishExecutable,
            arguments: ["-i", "--init-command", #"source "$CMUX_FISH_INTEGRATION_FILE""#, "-c", command],
            environment: environment,
            timeout: 5
        )
        expectFalse(result.timedOut, result.stderr)
        expectEqual(result.status, 0, result.stderr)
        return (
            stdout: result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            stderr: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func writeExecutableShellFile(at url: URL, body: String) throws {
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func runProcess(
        executablePath: String,
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        timeout: TimeInterval
    ) -> ProcessRunResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return ProcessRunResult(status: -1, stdout: "", stderr: String(describing: error), timedOut: false)
        }

        let exitSignal = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            exitSignal.signal()
        }

        let timedOut = exitSignal.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            _ = exitSignal.wait(timeout: .now() + 1)
        }

        return ProcessRunResult(
            status: process.terminationStatus,
            stdout: String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            stderr: String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            timedOut: timedOut
        )
    }
}
