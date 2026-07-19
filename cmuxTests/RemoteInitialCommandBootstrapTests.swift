import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

@Suite(.serialized)
struct RemoteInitialCommandBootstrapTests {
    private struct ProcessResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    @Test
    func generatedBashBootstrapPreservesCommandTextAndRunsItOnlyOnce() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-remote-initial-command-\(UUID().uuidString)")
        let home = root.appendingPathComponent("home")
        let bin = root.appendingPathComponent("bin")
        let fakeBash = bin.appendingPathComponent("bash")
        let output = home.appendingPathComponent("initial command.txt")
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try """
        #!/bin/sh
        cmux_test_rcfile=''
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --rcfile) cmux_test_rcfile="$2"; shift 2 ;;
            *) shift ;;
          esac
        done
        [ -n "$cmux_test_rcfile" ] && . "$cmux_test_rcfile"
        """.write(to: fakeBash, atomically: true, encoding: .utf8)
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: fakeBash.path
        )

        let command = #"printf '%s\n' "spaces 'single' \"double\" $CMUX_REMOTE_VALUE $(printf remote-substitution)" >> "$HOME/initial command.txt""#
        let script = RemoteInteractiveShellBootstrapBuilder.script(
            remoteRelayPort: 0,
            shellFeatures: "ssh-env,ssh-terminfo",
            initialCommand: command
        )
        let environment = ProcessInfo.processInfo.environment.merging([
            "HOME": home.path,
            "PATH": "/usr/bin:/bin",
            "SHELL": fakeBash.path,
            "CMUX_REMOTE_VALUE": "remote-only",
        ]) { _, new in new }

        let first = try runShell(script, environment: environment)
        #expect(first.status == 0, "stdout: \(first.stdout)\nstderr: \(first.stderr)")
        let second = try runShell(script, environment: environment)
        #expect(second.status == 0, "stdout: \(second.stdout)\nstderr: \(second.stderr)")

        let captured = try String(contentsOf: output, encoding: .utf8)
        #expect(captured == "spaces 'single' \"double\" remote-only remote-substitution\n")

        let shellState = home.appendingPathComponent(".cmux/relay/0.shell")
        var isDirectory = ObjCBool(false)
        #expect(
            fileManager.fileExists(
                atPath: shellState.appendingPathComponent(".initial-command.started").path,
                isDirectory: &isDirectory
            )
        )
        #expect(isDirectory.boolValue)
        #expect(!fileManager.fileExists(atPath: shellState.appendingPathComponent("initial-command").path))
    }

    @Test
    func generatedFallbackBootstrapRunsCommandAsShellScriptOnlyOnce() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-remote-initial-command-fallback-\(UUID().uuidString)")
        let home = root.appendingPathComponent("home")
        let bin = root.appendingPathComponent("bin")
        let fakeShell = bin.appendingPathComponent("tcsh")
        let output = home.appendingPathComponent("fallback command.txt")
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try """
        #!/bin/sh
        case "${1:-}" in
          -i) exit 0 ;;
          -*) printf 'unexpected shell option: %s\\n' "$1" >&2; exit 64 ;;
          '') exit 65 ;;
          *) [ "$#" -eq 1 ] || exit 66; exec /bin/csh "$1" ;;
        esac
        """.write(to: fakeShell, atomically: true, encoding: .utf8)
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: fakeShell.path
        )

        let command = #"echo "fallback spaces $CMUX_REMOTE_VALUE" >> "$HOME/fallback command.txt""#
        let script = RemoteInteractiveShellBootstrapBuilder.script(
            remoteRelayPort: 0,
            shellFeatures: "ssh-env,ssh-terminfo",
            initialCommand: command
        )
        let environment = ProcessInfo.processInfo.environment.merging([
            "HOME": home.path,
            "PATH": "/usr/bin:/bin",
            "SHELL": fakeShell.path,
            "CMUX_REMOTE_VALUE": "remote-only",
        ]) { _, new in new }

        let first = try runShell(script, environment: environment)
        #expect(first.status == 0, "stdout: \(first.stdout)\nstderr: \(first.stderr)")
        let second = try runShell(script, environment: environment)
        #expect(second.status == 0, "stdout: \(second.stdout)\nstderr: \(second.stderr)")

        let captured = try String(contentsOf: output, encoding: .utf8)
        #expect(captured == "fallback spaces remote-only\n")
    }

    @Test
    func whitespaceOnlyCommandDoesNotAddBootstrapWork() {
        let bootstrap = RemoteInitialCommandBootstrap(command: " \n\t ")

        #expect(bootstrap.preparationLines.isEmpty)
        #expect(bootstrap.posixInteractiveShellLines.isEmpty)
        #expect(bootstrap.fishInteractiveShellCommand == nil)
        #expect(bootstrap.fallbackShellLines.isEmpty)
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
