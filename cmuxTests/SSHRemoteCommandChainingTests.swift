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
