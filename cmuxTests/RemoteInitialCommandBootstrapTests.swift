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
        let fakeBase64 = bin.appendingPathComponent("base64")
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
        try """
        #!/bin/sh
        if [ "${CMUX_TEST_DELAY_STAGE:-0}" = 1 ]; then
          IFS= read -r cmux_test_release < "$HOME/stage-gate"
        fi
        exec /usr/bin/base64 "$@"
        """.write(to: fakeBase64, atomically: true, encoding: .utf8)
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: fakeBase64.path
        )

        let command = #"printf '%s\n' "spaces 'single' \"double\" $CMUX_REMOTE_VALUE $(printf remote-substitution)" >> "$HOME/initial command.txt""#
        let script = RemoteInteractiveShellBootstrapBuilder.script(
            remoteRelayPort: 0,
            shellFeatures: "ssh-env,ssh-terminfo",
            initialCommand: command
        )
        let secondWorkspaceScript = RemoteInteractiveShellBootstrapBuilder.script(
            remoteRelayPort: 0,
            shellFeatures: "ssh-env,ssh-terminfo",
            initialCommand: #"printf '%s\n' "second workspace" >> "$HOME/initial command.txt""#
        )
        let concurrentScript = RemoteInteractiveShellBootstrapBuilder.script(
            remoteRelayPort: 0,
            shellFeatures: "ssh-env,ssh-terminfo",
            initialCommand: #"printf '%s\n' "concurrent reattach" >> "$HOME/initial command.txt""#
        )
        let execScript = RemoteInteractiveShellBootstrapBuilder.script(
            remoteRelayPort: 0,
            shellFeatures: "ssh-env,ssh-terminfo",
            initialCommand: #"exec /bin/sh -c 'printf "%s\n" "exec command" >> "$HOME/initial command.txt"'"#
        )
        let environment = ProcessInfo.processInfo.environment.merging([
            "HOME": home.path,
            "PATH": "\(bin.path):/usr/bin:/bin",
            "SHELL": fakeBash.path,
            "CMUX_REMOTE_VALUE": "remote-only",
        ]) { _, new in new }

        let first = try runShell("umask 022\n" + script, environment: environment)
        #expect(first.status == 0, "stdout: \(first.stdout)\nstderr: \(first.stderr)")
        let second = try runShell("umask 022\n" + script, environment: environment)
        #expect(second.status == 0, "stdout: \(second.stdout)\nstderr: \(second.stderr)")
        let otherWorkspaceFirst = try runShell("umask 022\n" + secondWorkspaceScript, environment: environment)
        #expect(
            otherWorkspaceFirst.status == 0,
            "stdout: \(otherWorkspaceFirst.stdout)\nstderr: \(otherWorkspaceFirst.stderr)"
        )
        let otherWorkspaceSecond = try runShell("umask 022\n" + secondWorkspaceScript, environment: environment)
        #expect(
            otherWorkspaceSecond.status == 0,
            "stdout: \(otherWorkspaceSecond.stdout)\nstderr: \(otherWorkspaceSecond.stderr)"
        )

        let gate = home.appendingPathComponent("stage-gate")
        let mkfifo = Process()
        mkfifo.executableURL = URL(fileURLWithPath: "/usr/bin/mkfifo")
        mkfifo.arguments = [gate.path]
        try mkfifo.run()
        mkfifo.waitUntilExit()
        #expect(mkfifo.terminationStatus == 0)

        let delayed = Process()
        let delayedStdout = Pipe()
        let delayedStderr = Pipe()
        delayed.executableURL = URL(fileURLWithPath: "/bin/sh")
        delayed.arguments = ["-c", "umask 022\n" + concurrentScript]
        delayed.environment = environment.merging(["CMUX_TEST_DELAY_STAGE": "1"]) { _, new in new }
        delayed.standardOutput = delayedStdout
        delayed.standardError = delayedStderr
        try delayed.run()

        let gateWriter = try FileHandle(forWritingTo: gate)
        let concurrent = try runShell("umask 022\n" + concurrentScript, environment: environment)
        #expect(concurrent.status == 0, "stdout: \(concurrent.stdout)\nstderr: \(concurrent.stderr)")
        gateWriter.write(Data("release\n".utf8))
        try gateWriter.close()
        delayed.waitUntilExit()
        let delayedResult = ProcessResult(
            status: delayed.terminationStatus,
            stdout: String(decoding: delayedStdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            stderr: String(decoding: delayedStderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
        #expect(
            delayedResult.status == 0,
            "stdout: \(delayedResult.stdout)\nstderr: \(delayedResult.stderr)"
        )
        let execResult = try runShell("umask 022\n" + execScript, environment: environment)
        #expect(execResult.status == 0, "stdout: \(execResult.stdout)\nstderr: \(execResult.stderr)")

        let captured = try String(contentsOf: output, encoding: .utf8)
        #expect(
            captured == "spaces 'single' \"double\" remote-only remote-substitution\nsecond workspace\nconcurrent reattach\nexec command\n"
        )
        let shellState = home.appendingPathComponent(".cmux/relay/0.shell")
        let shellStateContents = try fileManager.contentsOfDirectory(atPath: shellState.path)
        #expect(shellStateContents.filter { $0.hasPrefix(".initial-command.started.") }.count == 4)
        #expect(!shellStateContents.contains { $0.hasPrefix("initial-command.") })
    }

    @Test
    func generatedZshBootstrapRunsCommandAfterUserZloginOnlyOnce() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-remote-initial-command-zsh-\(UUID().uuidString)")
        let home = root.appendingPathComponent("home")
        let output = home.appendingPathComponent("zsh initial command.txt")
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try "export CMUX_ZSH_STARTUP_ORDER=zshrc\n".write(
            to: home.appendingPathComponent(".zshrc"),
            atomically: true,
            encoding: .utf8
        )
        try "export CMUX_ZSH_STARTUP_ORDER=\"$CMUX_ZSH_STARTUP_ORDER,zlogin\"\ncd \"$HOME\"\n".write(
            to: home.appendingPathComponent(".zlogin"),
            atomically: true,
            encoding: .utf8
        )

        let script = RemoteInteractiveShellBootstrapBuilder.script(
            remoteRelayPort: 0,
            shellFeatures: "ssh-env,ssh-terminfo",
            initialCommand: #"printf '%s|%s\n' "$CMUX_ZSH_STARTUP_ORDER" "$PWD" >> "$HOME/zsh initial command.txt""#
        )
        let environment = ProcessInfo.processInfo.environment.merging([
            "HOME": home.path,
            "PATH": "/usr/bin:/bin",
            "SHELL": "/bin/zsh",
        ]) { _, new in new }

        let first = try runShell(script, environment: environment)
        #expect(first.status == 0, "stdout: \(first.stdout)\nstderr: \(first.stderr)")
        let second = try runShell(script, environment: environment)
        #expect(second.status == 0, "stdout: \(second.stdout)\nstderr: \(second.stderr)")

        let captured = try String(contentsOf: output, encoding: .utf8)
        #expect(captured == "zshrc,zlogin|\(home.path)\n")
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
          -i)
            if [ "${2:-}" = -c ]; then
              cmux_test_command="$3"
              shift 3
              exec /bin/csh -f -c "$cmux_test_command" "$@"
            fi
            printf '%s|%s\n' "$(/bin/pwd)" "${CMUX_FALLBACK_STATE:-}" > "$HOME/fallback state.txt"
            exit 0
            ;;
          -*) printf 'unexpected shell option: %s\\n' "$1" >&2; exit 64 ;;
          '') exit 65 ;;
          *) [ "$#" -eq 1 ] || exit 66; exec /bin/csh "$1" ;;
        esac
        """.write(to: fakeShell, atomically: true, encoding: .utf8)
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: fakeShell.path
        )

        let command = #"cd "$HOME"; setenv CMUX_FALLBACK_STATE preserved; echo "fallback spaces $CMUX_REMOTE_VALUE" >> "$HOME/fallback command.txt""#
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
        let state = try String(
            contentsOf: home.appendingPathComponent("fallback state.txt"),
            encoding: .utf8
        )
        #expect(state == "\(home.path)|preserved\n")
    }

    @Test
    func generatedNushellBootstrapRunsCommandThenEntersInteractiveModeOnlyOnce() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-remote-initial-command-nushell-\(UUID().uuidString)")
        let home = root.appendingPathComponent("home")
        let bin = root.appendingPathComponent("bin")
        let fakeShell = bin.appendingPathComponent("nu")
        let invocations = home.appendingPathComponent("nushell invocations.txt")
        let commandCapture = home.appendingPathComponent("nushell command.txt")
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try """
        #!/bin/sh
        case "${1:-}" in
          --execute)
            [ "$#" -eq 2 ] || exit 66
            [ "$2" = "$CMUX_EXPECTED_COMMAND" ] || exit 68
            printf '%s' "$2" > "$HOME/nushell command.txt"
            printf 'execute|%s|%s\n' "$HOME" "$CMUX_REMOTE_VALUE" >> "$HOME/nushell invocations.txt"
            printf 'interactive\n' >> "$HOME/nushell invocations.txt"
            exit 0
            ;;
          -i)
            [ "$#" -eq 1 ] || exit 67
            printf 'interactive\n' >> "$HOME/nushell invocations.txt"
            exit 0
            ;;
          -c) exit 67 ;;
          -*) printf 'unexpected shell option: %s\\n' "$1" >&2; exit 64 ;;
          '') exit 65 ;;
          *) [ "$#" -eq 1 ] || exit 66; exec /bin/sh "$1" ;;
        esac
        """.write(to: fakeShell, atomically: true, encoding: .utf8)
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: fakeShell.path
        )

        let command = #"let quoted = "spaces 'single' \"double\" $env.CMUX_REMOTE_VALUE""#
        let script = RemoteInteractiveShellBootstrapBuilder.script(
            remoteRelayPort: 0,
            shellFeatures: "ssh-env,ssh-terminfo",
            initialCommand: command
        )
        let environment = ProcessInfo.processInfo.environment.merging([
            "HOME": home.path,
            "PATH": "/usr/bin:/bin",
            "SHELL": fakeShell.path,
            "CMUX_EXPECTED_COMMAND": command,
            "CMUX_REMOTE_VALUE": "remote-only",
        ]) { _, new in new }

        let first = try runShell(script, environment: environment)
        #expect(first.status == 0, "stdout: \(first.stdout)\nstderr: \(first.stderr)")
        let firstCapturedCommand = try String(contentsOf: commandCapture, encoding: .utf8)
        #expect(firstCapturedCommand == command)
        let firstInvocations = try String(contentsOf: invocations, encoding: .utf8)
        #expect(firstInvocations == "execute|\(home.path)|remote-only\ninteractive\n")

        let second = try runShell(script, environment: environment)
        #expect(second.status == 0, "stdout: \(second.stdout)\nstderr: \(second.stderr)")

        let recordedInvocations = try String(contentsOf: invocations, encoding: .utf8)
        #expect(recordedInvocations == "execute|\(home.path)|remote-only\ninteractive\ninteractive\n")
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
