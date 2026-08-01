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
        let cases: [(
            options: [String],
            expectedConfiguredCommand: String?,
            expectedRestoredOptions: [String]
        )] = [
            (["RemoteCommand=printf restored-command"], "printf restored-command", []),
            (["RemoteCommand=none"], nil, ["RemoteCommand=none"]),
            ([], nil, []),
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
            let expectedBootstrap = RemoteInteractiveShellBootstrapBuilder.script(
                remoteRelayPort: 64_123,
                shellFeatures: RemoteInteractiveShellBootstrapBuilder.shellFeatures(),
                configuredRemoteCommand: testCase.expectedConfiguredCommand,
                bundledZshIntegration: RemoteInteractiveShellBootstrapBuilder
                    .bundledShellIntegrationScript(named: "cmux-zsh-integration.zsh"),
                bundledBashIntegration: RemoteInteractiveShellBootstrapBuilder
                    .bundledShellIntegrationScript(named: "cmux-bash-integration.bash"),
                bundledFishIntegration: RemoteInteractiveShellBootstrapBuilder
                    .bundledShellIntegrationScript(named: "fish/config.fish"),
                terminalProfile: .shell
            )
            let expectedBootstrapBase64 = Data(expectedBootstrap.utf8).base64EncodedString()

            #expect(restored.sshOptions == testCase.expectedRestoredOptions)
            #expect(restored.configuredRemoteCommand == testCase.expectedConfiguredCommand)
            #expect(
                startupCommand.hasPrefix("/bin/sh -c "),
                "Restored SSH launches must retain the local lifecycle wrapper"
            )
            #expect(startupCommand.contains("rpc workspace.remote.terminal_session_launching"))
            #expect(
                startupCommand.contains(expectedBootstrapBase64),
                "The staged remote bootstrap must retain the saved RemoteCommand intent"
            )
        }
    }

    @Test
    func legacyRemoteCommandTokensAreExpandedByOpenSSHDuringRestore() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-restore-token-expansion-\(UUID().uuidString)", isDirectory: true)
        let fakeSSH = root.appendingPathComponent("ssh")
        let eventsFile = root.appendingPathComponent("ssh-events")
        let resultFile = root.appendingPathComponent("remote-command-result")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try """
        #!/bin/sh
        mode=session
        while [ "$#" -gt 0 ]; do
          case "$1" in
            -G) mode=config; shift ;;
            -o|-p|-i) shift 2 ;;
            -tt|-t|-T) shift ;;
            -*) shift ;;
            *) shift; break ;;
          esac
        done
        if [ "$mode" = config ]; then
          printf 'config\n' >> "$SSH_EVENTS_FILE"
          printf '%s\n' "remotecommand printf '%s\\n' 'caller % resolved.example dev-alias 2233 remote-user' > \"$RESULT_FILE\""
          exit 0
        fi
        printf 'session\n' >> "$SSH_EVENTS_FILE"
        exec /bin/sh -c "$*"
        """
        .write(to: fakeSSH, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeSSH.path)

        let legacyRemoteCommand = #"printf '%s\n' 'caller %% %h %n %p %r' > "$RESULT_FILE""#
        let snapshot = SessionRemoteWorkspaceSnapshot(
            transport: .ssh,
            terminalTransport: .ssh,
            terminalProfile: .shell,
            destination: "dev-alias",
            port: 2233,
            sshOptions: [
                "HostName=resolved.example",
                "User=remote-user",
                "RemoteCommand=\(legacyRemoteCommand)",
            ]
        )
        let restored = try #require(snapshot.workspaceConfiguration())
        let startupCommand = try #require(restored.terminalStartupCommand)
            .replacingOccurrences(of: "/usr/bin/ssh", with: fakeSSH.path)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/usr/bin:/bin"
        environment["RESULT_FILE"] = resultFile.path
        environment["SSH_EVENTS_FILE"] = eventsFile.path
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
                == "caller % resolved.example dev-alias 2233 remote-user\n"
        )
        #expect(
            try String(contentsOf: eventsFile, encoding: .utf8) == "config\nsession\n",
            "Restore must ask OpenSSH for the effective, token-expanded RemoteCommand before launching it"
        )
    }

    @Test(
        "explicit empty command suppresses a legacy SSH RemoteCommand",
        arguments: ["", "none"]
    )
    func explicitEmptyCommandSuppressesLegacyRemoteCommand(configuredRemoteCommand: String) throws {
        let legacyRemoteCommand = "printf legacy-command"
        let snapshot = SessionRemoteWorkspaceSnapshot(
            transport: .ssh,
            terminalTransport: .ssh,
            terminalProfile: .shell,
            configuredRemoteCommand: configuredRemoteCommand,
            destination: "dev@example.com",
            sshOptions: [
                "ServerAliveInterval=15",
                "RemoteCommand=\(legacyRemoteCommand)",
            ]
        )

        let restored = try #require(snapshot.workspaceConfiguration())
        let startupCommand = try #require(restored.terminalStartupCommand)

        #expect(restored.configuredRemoteCommand == nil)
        #expect(restored.sshOptions.contains("ServerAliveInterval=15"))
        #expect(restored.sshOptions.contains("RemoteCommand=none"))
        #expect(!startupCommand.contains(legacyRemoteCommand), Comment(rawValue: startupCommand))
    }

    @Test(
        "explicit empty command overrides a live host-configured RemoteCommand",
        arguments: ["", "none"]
    )
    func explicitEmptyCommandOverridesHostConfiguredRemoteCommand(
        configuredRemoteCommand: String
    ) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-disabled-remote-command-\(UUID().uuidString)", isDirectory: true)
        let fakeSSH = root.appendingPathComponent("ssh")
        let hostCommandMarker = root.appendingPathComponent("host-command-ran")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try """
        #!/bin/sh
        remote_command_override=inherited
        while [ "$#" -gt 0 ]; do
          case "$1" in
            -o)
              if [ "$#" -gt 1 ]; then
                option=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')
                [ "$option" = remotecommand=none ] && remote_command_override=none
                shift 2
              else
                shift
              fi
              ;;
            -o*)
              option=$(printf '%s' "${1#-o}" | tr '[:upper:]' '[:lower:]')
              [ "$option" = remotecommand=none ] && remote_command_override=none
              shift
              ;;
            *) shift ;;
          esac
        done
        if [ "$remote_command_override" = inherited ]; then
          printf 'ran\n' > "$HOST_COMMAND_MARKER"
        fi
        """
        .write(to: fakeSSH, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeSSH.path)

        let snapshot = SessionRemoteWorkspaceSnapshot(
            transport: .ssh,
            terminalTransport: .ssh,
            terminalProfile: .shell,
            configuredRemoteCommand: configuredRemoteCommand,
            destination: "dev@example.com",
            sshOptions: []
        )
        let restored = try #require(snapshot.workspaceConfiguration())
        let startupCommand = try #require(restored.terminalStartupCommand)
            .replacingOccurrences(of: "/usr/bin/ssh", with: fakeSSH.path)
        var environment = ProcessInfo.processInfo.environment
        environment["HOST_COMMAND_MARKER"] = hostCommandMarker.path
        environment["PATH"] = "/usr/bin:/bin"
        let result = processSupport.runProcess(
            executablePath: "/bin/sh",
            arguments: ["-c", startupCommand],
            environment: environment,
            timeout: 5
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(startupCommand.contains("RemoteCommand=none"), Comment(rawValue: startupCommand))
        #expect(!fileManager.fileExists(atPath: hostCommandMarker.path))
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
