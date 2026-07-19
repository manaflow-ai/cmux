import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

@Suite(.serialized)
struct RemoteInitialCommandBootstrapFailureTests {
    private struct ProcessResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    @Test
    func posixDecodeFailureDoesNotConsumeCommand() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-remote-initial-command-decode-retry-\(UUID().uuidString)")
        let home = root.appendingPathComponent("home")
        let bin = root.appendingPathComponent("bin")
        let output = home.appendingPathComponent("decode retry.txt")
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try writeExecutable(
            to: bin.appendingPathComponent("bash"),
            body: """
            #!/bin/sh
            while [ "$#" -gt 0 ]; do
              case "$1" in
                --rcfile) cmux_test_rcfile="$2"; shift 2 ;;
                *) shift ;;
              esac
            done
            env > "$HOME/bash startup environment.txt"
            for cmux_test_payload in "${cmux_test_rcfile%/*}"/.initial-command.payload.*; do
              [ -f "$cmux_test_payload" ] || continue
              stat -f '%Lp' "$cmux_test_payload" > "$HOME/initial command payload mode.txt"
              break
            done
            [ -n "${cmux_test_rcfile:-}" ] && . "$cmux_test_rcfile"
            """
        )
        try writeFailingThenWorkingBase64(to: bin.appendingPathComponent("base64"))

        let script = RemoteInteractiveShellBootstrapBuilder.script(
            remoteRelayPort: 0,
            shellFeatures: "ssh-env,ssh-terminfo",
            initialCommand: #"printf '%s\n' "decode retry" >> "$HOME/decode retry.txt""#
        )
        let environment = ProcessInfo.processInfo.environment.merging([
            "HOME": home.path,
            "PATH": "\(bin.path):/usr/bin:/bin",
            "SHELL": bin.appendingPathComponent("bash").path,
        ]) { _, new in new }

        let failedDecode = try runShell(script, environment: environment)
        #expect(failedDecode.status == 0, Comment(rawValue: failedDecode.stderr))
        #expect(!fileManager.fileExists(atPath: output.path))
        #expect(try initialCommandMarkerCount(home: home) == 0)
        let startupEnvironment = try String(
            contentsOf: home.appendingPathComponent("bash startup environment.txt"),
            encoding: .utf8
        )
        #expect(!startupEnvironment.contains("CMUX_INITIAL_COMMAND_B64="))
        let payloadMode = try String(
            contentsOf: home.appendingPathComponent("initial command payload mode.txt"),
            encoding: .utf8
        )
        #expect(payloadMode == "600\n")

        let retry = try runShell(script, environment: environment)
        #expect(retry.status == 0, Comment(rawValue: retry.stderr))
        let reattach = try runShell(script, environment: environment)
        #expect(reattach.status == 0, Comment(rawValue: reattach.stderr))

        #expect(try String(contentsOf: output, encoding: .utf8) == "decode retry\n")
        #expect(try initialCommandMarkerCount(home: home) == 1)
        let shellStateContents = try fileManager.contentsOfDirectory(
            atPath: home.appendingPathComponent(".cmux/relay/0.shell").path
        )
        #expect(!shellStateContents.contains { $0.hasPrefix(".initial-command.payload.") })
        #expect(!shellStateContents.contains { $0.hasPrefix("initial-command.") })
    }

    @Test(.enabled(if: RemoteInitialCommandBootstrapFailureTests.fishExecutablePath != nil))
    func fishDecodeFailureDoesNotConsumeCommand() throws {
        let fish = try #require(Self.fishExecutablePath)
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-remote-initial-command-fish-decode-retry-\(UUID().uuidString)")
        let home = root.appendingPathComponent("home")
        let bin = root.appendingPathComponent("bin")
        let cmuxBin = home.appendingPathComponent(".cmux/bin")
        let output = home.appendingPathComponent("fish decode retry.txt")
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: cmuxBin, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try writeFailingThenWorkingBase64(to: cmuxBin.appendingPathComponent("base64"))
        let script = RemoteInteractiveShellBootstrapBuilder.script(
            remoteRelayPort: 0,
            shellFeatures: "ssh-env,ssh-terminfo",
            initialCommand: #"printf '%s\n' "fish decode retry" >> "$HOME/fish decode retry.txt""#,
            bundledFishIntegration: "set -gx PATH \"\(cmuxBin.path)\" $PATH\n"
        )
        let environment = ProcessInfo.processInfo.environment.merging([
            "HOME": home.path,
            "PATH": "\(bin.path):/usr/bin:/bin",
            "SHELL": fish,
            "XDG_CONFIG_HOME": home.appendingPathComponent(".config").path,
        ]) { _, new in new }

        let failedDecode = try runShell(script, environment: environment)
        #expect(failedDecode.status == 0, Comment(rawValue: failedDecode.stderr))
        #expect(!fileManager.fileExists(atPath: output.path))
        #expect(try initialCommandMarkerCount(home: home) == 0)

        let retry = try runShell(script, environment: environment)
        #expect(retry.status == 0, Comment(rawValue: retry.stderr))
        let reattach = try runShell(script, environment: environment)
        #expect(reattach.status == 0, Comment(rawValue: reattach.stderr))

        #expect(try String(contentsOf: output, encoding: .utf8) == "fish decode retry\n")
        #expect(try initialCommandMarkerCount(home: home) == 1)
    }

    @Test
    func unsupportedShellDoesNotRunOrConsumeCommand() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-remote-initial-command-unsupported-shell-\(UUID().uuidString)")
        let home = root.appendingPathComponent("home")
        let bin = root.appendingPathComponent("bin")
        let unsupportedShell = bin.appendingPathComponent("xonsh")
        let invocations = home.appendingPathComponent("shell invocations.txt")
        let output = home.appendingPathComponent("unsupported shell command.txt")
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try writeExecutable(
            to: unsupportedShell,
            body: """
            #!/bin/sh
            printf '%s\n' "$#" "$@" > "$HOME/shell invocations.txt"
            if [ "${1:-}" = -i ] && [ "${2:-}" = -c ]; then
              /bin/sh -c "$3"
            fi
            exit 0
            """
        )

        let script = RemoteInteractiveShellBootstrapBuilder.script(
            remoteRelayPort: 0,
            shellFeatures: "ssh-env,ssh-terminfo",
            initialCommand: #"printf '%s\n' "must wait" >> "$HOME/unsupported shell command.txt""#
        )
        let unsupportedEnvironment = ProcessInfo.processInfo.environment.merging([
            "HOME": home.path,
            "PATH": "\(bin.path):/usr/bin:/bin",
            "SHELL": unsupportedShell.path,
        ]) { _, new in new }

        let unsupported = try runShell(script, environment: unsupportedEnvironment)
        #expect(unsupported.status == 0, Comment(rawValue: unsupported.stderr))
        #expect(try String(contentsOf: invocations, encoding: .utf8) == "1\n-i\n")
        #expect(!fileManager.fileExists(atPath: output.path))
        #expect(try initialCommandMarkerCount(home: home) == 0)
        let warning = String(
            localized: "cli.ssh.initialCommand.unsupportedShell",
            defaultValue: "[cmux] Initial command was not run because cmux does not support initial commands for this remote login shell. Reconnect with a supported shell to retry it."
        )
        #expect(unsupported.stderr.contains(warning), Comment(rawValue: unsupported.stderr))

        let supportedEnvironment = unsupportedEnvironment.merging(["SHELL": "/bin/sh"]) { _, new in new }
        let retry = try runShell(script, environment: supportedEnvironment)
        #expect(retry.status == 0, Comment(rawValue: retry.stderr))
        let reattach = try runShell(script, environment: supportedEnvironment)
        #expect(reattach.status == 0, Comment(rawValue: reattach.stderr))

        #expect(try String(contentsOf: output, encoding: .utf8) == "must wait\n")
        #expect(try initialCommandMarkerCount(home: home) == 1)
    }

    private static var fishExecutablePath: String? {
        [
            "/opt/homebrew/bin/fish",
            "/usr/local/bin/fish",
            "/usr/bin/fish",
            "/bin/fish",
        ].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func writeFailingThenWorkingBase64(to url: URL) throws {
        try writeExecutable(
            to: url,
            body: """
            #!/bin/sh
            cmux_test_attempt=0
            [ ! -f "$HOME/base64-attempts" ] || cmux_test_attempt=$(cat "$HOME/base64-attempts")
            cmux_test_attempt=$((cmux_test_attempt + 1))
            printf '%s\n' "$cmux_test_attempt" > "$HOME/base64-attempts"
            if [ "$cmux_test_attempt" -le 2 ]; then
              printf partial-output
              exit 1
            fi
            exec /usr/bin/base64 "$@"
            """
        )
    }

    private func writeExecutable(to url: URL, body: String) throws {
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func initialCommandMarkerCount(home: URL) throws -> Int {
        let shellState = home.appendingPathComponent(".cmux/relay/0.shell")
        return try FileManager.default.contentsOfDirectory(atPath: shellState.path)
            .filter { $0.hasPrefix(".initial-command.started.") }
            .count
    }

    private func runShell(
        _ script: String,
        environment: [String: String]
    ) throws -> ProcessResult {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()
        return ProcessResult(
            status: process.terminationStatus,
            stdout: String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            stderr: String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }
}
