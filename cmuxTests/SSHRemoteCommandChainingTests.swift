import CmuxCore
import CmuxFoundation
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct SSHRemoteCommandChainingTests {
    private let processSupport = CLINotifyProcessIntegrationRegressionTests(invocation: nil)

    @Test
    func resolvedSSHConfigurationDistinguishesConfiguredCommandFromNone() {
        let policy = SSHHostConfiguredRemoteCommand()
        let configured = """
        hostname example.internal
        remotecommand cd "/scratch/project dir" && exec fish
        requesttty true
        """

        #expect(
            policy.configuredCommand(fromSSHConfigOutput: configured)
                == #"cd "/scratch/project dir" && exec fish"#
        )
        #expect(
            policy.configuredCommand(
                fromSSHConfigOutput: "remotecommand none\nrequesttty auto\n"
            ) == nil
        )
    }

    @Test
    func interactiveBootstrapExecutesConfiguredRemoteCommandAfterSetup() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-remote-command-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let workingDirectory = home.appendingPathComponent("project dir", isDirectory: true)
        let helper = root.appendingPathComponent("persistent-pty-exec-helper")
        let resultFile = home.appendingPathComponent("remote-command-result")
        let helperMarker = home.appendingPathComponent("persistent-helper-used")
        try fileManager.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try """
        #!/bin/sh
        [ "${1:-}" = "--internal-persistent-pty-exec" ] || exit 2
        shift
        executable="${1:-}"
        [ -n "$executable" ] || exit 2
        shift
        [ "${1:-}" = "$executable" ] || exit 2
        shift
        printf 'yes\n' > "$HOME/persistent-helper-used"
        exec "$executable" "$@"
        """
        .write(to: helper, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)

        let configuredRemoteCommand = """
        cd "$HOME/project dir" && printf '%s\\n' "command 'ran'" "$CMUX_SOCKET_PATH" "$PWD" > "$HOME/remote-command-result"
        """
        let script = RemoteInteractiveShellBootstrapBuilder.script(
            remoteRelayPort: 64_123,
            shellFeatures: "ssh-env,ssh-terminfo",
            configuredRemoteCommand: configuredRemoteCommand
        )
        let result = processSupport.runProcess(
            executablePath: "/usr/bin/env",
            arguments: [
                "-i",
                "HOME=\(home.path)",
                "SHELL=/bin/sh",
                "PATH=/usr/bin:/bin",
                "USER=\(NSUserName())",
                "CMUX_PERSISTENT_PTY_EXEC_HELPER=\(helper.path)",
                "/bin/sh",
                "-c",
                script,
            ],
            environment: ProcessInfo.processInfo.environment,
            timeout: 5
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(
            try String(contentsOf: helperMarker, encoding: .utf8) == "yes\n",
            "Configured commands must retain persistent-PTY hangup protection"
        )
        #expect(
            try String(contentsOf: resultFile, encoding: .utf8)
                == "command 'ran'\n127.0.0.1:64123\n\(workingDirectory.path)\n"
        )
    }

    @Test
    func approvedInitialCommandTakesPrecedenceOverConfiguredRemoteCommand() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-resume-command-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let helper = root.appendingPathComponent("persistent-pty-exec-helper")
        let resumeMarker = home.appendingPathComponent("resume-command-result")
        let configuredMarker = home.appendingPathComponent("configured-command-result")
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try """
        #!/bin/sh
        [ "${1:-}" = "--internal-persistent-pty-exec" ] || exit 2
        shift
        executable="${1:-}"
        [ -n "$executable" ] || exit 2
        shift
        [ "${1:-}" = "$executable" ] || exit 2
        shift
        exec "$executable" "$@"
        """
        .write(to: helper, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)

        let script = RemoteInteractiveShellBootstrapBuilder.script(
            remoteRelayPort: 64_124,
            shellFeatures: "ssh-env,ssh-terminfo",
            initialCommand: #"printf 'resumed\n' > "$HOME/resume-command-result"; exit 0"#,
            configuredRemoteCommand: #"printf 'configured\n' > "$HOME/configured-command-result""#
        )
        let result = processSupport.runProcess(
            executablePath: "/usr/bin/env",
            arguments: [
                "-i",
                "HOME=\(home.path)",
                "SHELL=/bin/zsh",
                "PATH=/usr/bin:/bin",
                "USER=\(NSUserName())",
                "CMUX_PERSISTENT_PTY_EXEC_HELPER=\(helper.path)",
                "/bin/sh",
                "-c",
                script,
            ],
            environment: ProcessInfo.processInfo.environment,
            timeout: 5
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(try String(contentsOf: resumeMarker, encoding: .utf8) == "resumed\n")
        #expect(!fileManager.fileExists(atPath: configuredMarker.path))
        let shellStateDirectory = home
            .appendingPathComponent(".cmux/relay/64124.shell", isDirectory: true)
        let remainingPayloads = try fileManager.contentsOfDirectory(atPath: shellStateDirectory.path)
            .filter { $0.hasPrefix(".initial-command.payload.") }
        #expect(remainingPayloads.isEmpty, "\(remainingPayloads)")
    }

    @Test
    func persistentWorkspaceRestoreKeepsConfiguredRemoteCommandInNewPaneBootstrap() throws {
        let configuredRemoteCommand = #"cd "/srv/project dir" && exec fish"#
        let liveConfiguration = WorkspaceRemoteConfiguration(
            destination: "dev@example.com",
            port: 2222,
            identityFile: nil,
            sshOptions: [
                "ControlMaster=auto",
                "ControlPersist=600",
                "ControlPath=/tmp/cmux-ssh-%C",
            ],
            localProxyPort: nil,
            relayPort: 64_123,
            relayID: "relay-id",
            relayToken: String(repeating: "a", count: 64),
            localSocketPath: "/tmp/cmux-live.sock",
            terminalStartupCommand: "live startup command",
            configuredRemoteCommand: configuredRemoteCommand,
            preserveAfterTerminalExit: true,
            persistentDaemonSlot: "ssh-restore-slot"
        )
        let encodedSnapshot = try JSONEncoder().encode(try #require(liveConfiguration.sessionSnapshot()))
        let snapshot = try JSONDecoder().decode(
            SessionRemoteWorkspaceSnapshot.self,
            from: encodedSnapshot
        )
        let restored = try #require(
            snapshot.workspaceConfiguration(localSocketPath: "/tmp/cmux-restored.sock")
        )
        let startupCommand = try #require(restored.terminalStartupCommand)
        let expectedBootstrap = SSHPTYAttachStartupCommandBuilder.restoredRemoteShellCommand(
            relayPort: 64_123,
            configuredRemoteCommand: configuredRemoteCommand
        )
        let expectedBootstrapBase64 = Data(expectedBootstrap.utf8).base64EncodedString()

        #expect(snapshot.configuredRemoteCommand == configuredRemoteCommand)
        #expect(restored.configuredRemoteCommand == configuredRemoteCommand)
        #expect(startupCommand.contains(expectedBootstrapBase64), "\(startupCommand)")
    }

    @Test
    func nonPersistentRestorePreservesExplicitRemoteCommandIntent() throws {
        let cases: [(options: [String], expectedCommandFragment: String?)] = [
            (["RemoteCommand=printf restored-command"], "'RemoteCommand=printf restored-command'"),
            (["RemoteCommand=none"], "RemoteCommand=none"),
            ([], nil),
        ]

        for testCase in cases {
            let snapshot = SessionRemoteWorkspaceSnapshot(
                transport: .ssh,
                terminalTransport: .ssh,
                terminalProfile: .shell,
                destination: "dev@example.com",
                sshOptions: testCase.options,
                preserveAfterTerminalExit: true,
                relayPort: 64_123,
                persistentDaemonSlot: "ssh-restore-slot"
            )
            let restored = try #require(
                snapshot.workspaceConfiguration(
                    localSocketPath: "/tmp/cmux-restored.sock",
                    allowPersistentPTYRestore: false
                )
            )
            let startupCommand = try #require(restored.terminalStartupCommand)

            #expect(restored.sshOptions == testCase.options)
            #expect(startupCommand.hasPrefix("/usr/bin/ssh "), "\(startupCommand)")
            if let expectedCommandFragment = testCase.expectedCommandFragment {
                #expect(startupCommand.contains(expectedCommandFragment), "\(startupCommand)")
            } else {
                #expect(!startupCommand.localizedCaseInsensitiveContains("RemoteCommand"), "\(startupCommand)")
            }
        }
    }

    @Test
    func nonPersistentRestorePreservesConfiguredCommandAcrossOpenSSHReparsing() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-restore-quoting-\(UUID().uuidString)", isDirectory: true)
        let fakeSSH = root.appendingPathComponent("ssh")
        let resultFile = root.appendingPathComponent("configured-command-result")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        // OpenSSH concatenates argv after the destination into one command
        // string, which the remote login shell parses again.
        try """
        #!/bin/sh
        while [ "$#" -gt 0 ]; do
          case "$1" in
            -o|-p|-i) shift 2 ;;
            -tt|-t|-T) shift ;;
            *) shift; break ;;
          esac
        done
        exec /bin/sh -c "$*"
        """.write(to: fakeSSH, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeSSH.path)

        let configuredRemoteCommand = #"printf '%s\n' "command 'ran'" "$PWD" > "$RESULT_FILE""#
        let snapshot = SessionRemoteWorkspaceSnapshot(
            transport: .ssh,
            terminalTransport: .ssh,
            configuredRemoteCommand: configuredRemoteCommand,
            destination: "dev@example.com",
            sshOptions: ["RemoteCommand=printf current-host-command"]
        )
        let restored = try #require(
            snapshot.workspaceConfiguration(allowPersistentPTYRestore: false)
        )
        let startupCommand = try #require(restored.terminalStartupCommand)
            .replacingOccurrences(of: "/usr/bin/ssh", with: fakeSSH.path)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/usr/bin:/bin"
        environment["RESULT_FILE"] = resultFile.path
        environment["SHELL"] = "/bin/sh"
        let result = processSupport.runProcess(
            executablePath: "/bin/sh",
            arguments: ["-c", startupCommand],
            environment: environment,
            timeout: 5
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(
            try String(contentsOf: resultFile, encoding: .utf8)
                == "command 'ran'\n\(FileManager.default.currentDirectoryPath)\n"
        )
    }
}

/// `cmux ssh --cwd` / `cmux mosh --cwd`: the generated remote bootstrap must
/// leave the interactive login shell in the requested directory, both alone and
/// combined with `--command`.
@Suite(.serialized)
struct SSHRemoteWorkingDirectoryTests {
    private let processSupport = CLINotifyProcessIntegrationRegressionTests(invocation: nil)

    private struct RemoteHost {
        let root: URL
        let home: URL
        let helper: URL
        let loginShell: URL
        let pwdResult: URL
    }

    /// Builds a throwaway remote-like $HOME whose login shell records `$PWD`
    /// instead of going interactive, so the test observes where the session
    /// actually landed rather than inspecting the script text.
    private func makeRemoteHost(named name: String) throws -> RemoteHost {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-cwd-\(name)-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)

        let helper = root.appendingPathComponent("persistent-pty-exec-helper")
        try """
        #!/bin/sh
        [ "${1:-}" = "--internal-persistent-pty-exec" ] || exit 2
        shift
        executable="${1:-}"
        [ -n "$executable" ] || exit 2
        shift
        [ "${1:-}" = "$executable" ] || exit 2
        shift
        exec "$executable" "$@"
        """
        .write(to: helper, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)

        let loginShell = root.appendingPathComponent("cmux-test-shell")
        try """
        #!/bin/sh
        pwd > "$HOME/pwd-result"
        exit 0
        """
        .write(to: loginShell, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: loginShell.path)

        return RemoteHost(
            root: root,
            home: home,
            helper: helper,
            loginShell: loginShell,
            pwdResult: home.appendingPathComponent("pwd-result")
        )
    }

    private func runBootstrap(
        _ script: String,
        host: RemoteHost,
        shell: String? = nil
    ) -> (status: Int32, stderr: String, timedOut: Bool) {
        let result = processSupport.runProcess(
            executablePath: "/usr/bin/env",
            arguments: [
                "-i",
                "HOME=\(host.home.path)",
                "SHELL=\(shell ?? host.loginShell.path)",
                "PATH=/usr/bin:/bin",
                "USER=\(NSUserName())",
                "CMUX_PERSISTENT_PTY_EXEC_HELPER=\(host.helper.path)",
                "/bin/sh",
                "-c",
                // sshd runs the remote command from the account's home
                // directory; reproduce that so "no --cwd" means "$HOME".
                "cd \"$HOME\" || exit 1\n" + script,
            ],
            environment: ProcessInfo.processInfo.environment,
            timeout: 10
        )
        return (result.status, result.stderr, result.timedOut)
    }

    /// Compares a recorded `pwd` against an expected directory after resolving
    /// symlinks on both sides, since `/var` and `/tmp` are symlinked on macOS
    /// and shells differ on logical vs physical reporting.
    private func expectRecordedDirectory(_ file: URL, equals expected: URL) throws {
        let recorded = try String(contentsOf: file, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(
            URL(fileURLWithPath: recorded).resolvingSymlinksInPath().path
                == expected.resolvingSymlinksInPath().path,
            Comment(rawValue: "recorded=\(recorded) expected=\(expected.path)")
        )
    }

    /// `--cwd` alone lands the interactive login shell in the requested
    /// directory, including one whose name contains spaces.
    @Test
    func interactiveShellStartsInRequestedWorkingDirectory() throws {
        let host = try makeRemoteHost(named: "plain")
        defer { try? FileManager.default.removeItem(at: host.root) }
        let workingDirectory = host.home.appendingPathComponent("srv/app dir", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)

        let script = RemoteInteractiveShellBootstrapBuilder.script(
            remoteRelayPort: 64_201,
            shellFeatures: "ssh-env,ssh-terminfo",
            initialWorkingDirectory: workingDirectory.path
        )
        let result = runBootstrap(script, host: host)

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        try expectRecordedDirectory(host.pwdResult, equals: workingDirectory)
    }

    /// A `~`-relative `--cwd` expands against the remote `$HOME`, since the
    /// local shell never saw the value to expand it.
    @Test
    func tildePathExpandsAgainstTheRemoteHome() throws {
        let host = try makeRemoteHost(named: "tilde")
        defer { try? FileManager.default.removeItem(at: host.root) }
        let workingDirectory = host.home.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)

        let script = RemoteInteractiveShellBootstrapBuilder.script(
            remoteRelayPort: 64_202,
            shellFeatures: "ssh-env,ssh-terminfo",
            initialWorkingDirectory: "~/work"
        )
        let result = runBootstrap(script, host: host)

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        try expectRecordedDirectory(host.pwdResult, equals: workingDirectory)
    }

    /// `--cwd` composes with `--command`: cmux changes directory first, so the
    /// command observes the requested directory rather than `$HOME`.
    @Test
    func initialCommandRunsInsideTheRequestedWorkingDirectory() throws {
        let host = try makeRemoteHost(named: "combined")
        defer { try? FileManager.default.removeItem(at: host.root) }
        let workingDirectory = host.home.appendingPathComponent("srv/app dir", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        let commandResult = host.home.appendingPathComponent("command-pwd-result")

        let script = RemoteInteractiveShellBootstrapBuilder.script(
            remoteRelayPort: 64_203,
            shellFeatures: "ssh-env,ssh-terminfo",
            initialCommand: #"pwd > "$HOME/command-pwd-result"; exit 0"#,
            initialWorkingDirectory: workingDirectory.path
        )
        let result = runBootstrap(script, host: host, shell: "/bin/zsh")

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        try expectRecordedDirectory(commandResult, equals: workingDirectory)
    }

    /// Omitting `--cwd` emits no `cd` at all, preserving the prior behavior of
    /// starting wherever the remote login shell starts.
    @Test
    func omittingWorkingDirectoryKeepsTheLoginShellDefault() throws {
        let host = try makeRemoteHost(named: "default")
        defer { try? FileManager.default.removeItem(at: host.root) }

        let script = RemoteInteractiveShellBootstrapBuilder.script(
            remoteRelayPort: 64_204,
            shellFeatures: "ssh-env,ssh-terminfo"
        )
        let result = runBootstrap(script, host: host)

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        try expectRecordedDirectory(host.pwdResult, equals: host.home)
    }

    /// A `--cwd` that cannot be entered warns on stderr and leaves the user
    /// with a working session instead of dropping the connection.
    @Test
    func unreachableWorkingDirectoryWarnsAndKeepsTheSessionAlive() throws {
        let host = try makeRemoteHost(named: "missing")
        defer { try? FileManager.default.removeItem(at: host.root) }

        let script = RemoteInteractiveShellBootstrapBuilder.script(
            remoteRelayPort: 64_205,
            shellFeatures: "ssh-env,ssh-terminfo",
            initialWorkingDirectory: host.home.appendingPathComponent("nope").path
        )
        let result = runBootstrap(script, host: host)

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stderr.contains("cmux: --cwd: cannot change to"), Comment(rawValue: result.stderr))
        try expectRecordedDirectory(host.pwdResult, equals: host.home)
    }

    /// The path is quoted, not evaluated: a directory name containing shell
    /// syntax is entered literally and its embedded command never runs.
    @Test
    func pathsThatCouldInjectShellSyntaxAreQuotedNotEvaluated() throws {
        let host = try makeRemoteHost(named: "injection")
        defer { try? FileManager.default.removeItem(at: host.root) }
        let hostile = host.home.appendingPathComponent("a; touch \"$HOME/pwned\"", isDirectory: true)
        try FileManager.default.createDirectory(at: hostile, withIntermediateDirectories: true)

        let script = RemoteInteractiveShellBootstrapBuilder.script(
            remoteRelayPort: 64_206,
            shellFeatures: "ssh-env,ssh-terminfo",
            initialWorkingDirectory: hostile.path
        )
        let result = runBootstrap(script, host: host)

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(!FileManager.default.fileExists(atPath: host.home.appendingPathComponent("pwned").path))
        try expectRecordedDirectory(host.pwdResult, equals: hostile)
    }
}
