import CmuxFoundation
import Darwin
import Foundation
import Testing
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// Regression coverage for https://github.com/manaflow-ai/cmux/issues/7246:
// `cmux ssh` against a host whose ~/.ssh/config sets `RequestTTY yes` and
// `RemoteCommand sudo su -` fails with OpenSSH's
// "Cannot execute command-line and remote command." (exit 255) and loops the
// reconnect banner. Every cmux-controlled ssh invocation that supplies its own
// remote command must override the host-configured RemoteCommand (e.g.
// `-o RemoteCommand=none`), while the session hop that intentionally carries
// cmux's own `-o RemoteCommand=<bootstrap>` keeps doing so.
//
// The fake `ssh` below mirrors OpenSSH's actual rule: a positional remote
// command is fatal iff no `-o RemoteCommand=...` override appears on the argv
// (the first RemoteCommand option wins, like OpenSSH's first-obtained-value
// semantics). It records one `invocation kind=<...> override=<...>` event per
// spawn so assertions can distinguish config dumps, control operations,
// interactive sessions, and command-carrying invocations.
@Suite(.serialized)
struct SSHConfiguredRemoteCommandHostTests {
    private typealias MockSocketServerState =
        CLINotifyProcessIntegrationRegressionTests.MockSocketServerState

    private let processSupport = CLINotifyProcessIntegrationRegressionTests(invocation: nil)

    /// `cmux ssh` default flow (ControlMaster/ControlPath defaults, TTY
    /// requested): the session belongs to cmux-tui, so the CLI must hand the
    /// host-configured RemoteCommand to `workspace.ssh.open` as the program
    /// to chain instead of building a local startup script whose
    /// command-carrying hops could conflict with it.
    @Test
    func sshStartupConnectsWhenHostConfigSetsRemoteCommandAndRequestTTY() throws {
        let cliPath = try processSupport.bundledCLIPath()
        let socketPath = processSupport.makeSocketPath("ssh-rc-host")
        let listenerFD = try processSupport.bindUnixSocket(at: socketPath)
        let workspaceID = "11111111-1111-1111-1111-111111111111"
        let surfaceID = "22222222-2222-2222-2222-222222222222"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let state = MockSocketServerState()
        let handled = processSupport.startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = processSupport.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return processSupport.malformedRequestResponse(raw: line)
            }
            switch method {
            case "workspace.ssh.open":
                return processSupport.v2Response(id: id, ok: true, result: [
                    "workspace_id": workspaceID,
                    "workspace_ref": "workspace:9",
                    "surface_id": surfaceID,
                    "surface_ref": "surface:9",
                ])
            default:
                return processSupport.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected", "message": "Unexpected method \(method)"]
                )
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        let result = processSupport.runProcess(
            executablePath: cliPath,
            arguments: [
                "ssh",
                "--no-focus",
                "--ssh-option", "RemoteCommand=sudo su -",
                "--ssh-option", "RequestTTY=yes",
                "cmux-remotecommand-host",
            ],
            environment: environment,
            timeout: 20
        )
        #expect(
            XCTWaiter().wait(for: [handled], timeout: 5) == .completed,
            "cli mock socket was not handled within 5 seconds"
        )
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))

        let requests = state.commands.compactMap(processSupport.jsonObject)
        let methods = requests.compactMap { $0["method"] as? String }
        #expect(!methods.contains("workspace.create"), "\(methods)")
        #expect(!methods.contains("workspace.remote.configure"), "\(methods)")
        let openParams = try #require(
            requests.first { $0["method"] as? String == "workspace.ssh.open" }?["params"] as? [String: Any]
        )
        #expect(openParams["destination"] as? String == "cmux-remotecommand-host")
        #expect(openParams["focus"] as? Bool == false)
        #expect(
            openParams["configured_remote_command"] as? String == "sudo su -",
            "The host RemoteCommand must reach cmux-tui as the program to chain: \(openParams)"
        )
        #expect(openParams["initial_command"] == nil, "\(openParams)")
        #expect(openParams["terminal_profile"] as? String == "shell")
        let forwardedOptions = openParams["ssh_options"] as? [String] ?? []
        #expect(forwardedOptions.contains("RemoteCommand=sudo su -"), "\(forwardedOptions)")
        #expect(forwardedOptions.contains("RequestTTY=yes"), "\(forwardedOptions)")
    }

    @Test(arguments: [false, true])
    func sshStartupFallsBackToUnmanagedSessionWhenConfigurationResolutionIsUnavailable(
        usesMosh: Bool
    ) throws {
        let cliPath = try processSupport.bundledCLIPath()
        let socketPath = processSupport.makeSocketPath(
            usesMosh ? "mosh-config-unavailable" : "ssh-config-unavailable"
        )
        let listenerFD = try processSupport.bindUnixSocket(at: socketPath)
        let workspaceID = "11111111-1111-1111-1111-111111111111"
        let surfaceID = "22222222-2222-2222-2222-222222222222"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let state = MockSocketServerState()
        let handled = processSupport.startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = processSupport.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return processSupport.malformedRequestResponse(raw: line)
            }
            switch method {
            case "workspace.create":
                return processSupport.v2Response(id: id, ok: true, result: [
                    "workspace_id": workspaceID,
                    "surface_id": surfaceID,
                ])
            case "workspace.remote.configure":
                return processSupport.v2Response(id: id, ok: true, result: [
                    "workspace_id": workspaceID,
                    "workspace_ref": "workspace:9",
                    "remote": ["enabled": true, "state": "connecting"],
                ])
            default:
                return processSupport.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected", "message": "Unexpected method \(method)"]
                )
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        var arguments = [
            "ssh",
            "--no-focus",
        ]
        if usesMosh {
            arguments += ["--transport", "mosh"]
        }
        // The unmanaged fallback forces the ssh transport, so a TTY session
        // would go to cmux-tui through `workspace.ssh.open`. Pin
        // RequestTTY=no to keep covering the startup script this CLI still
        // builds for sessions without a TTY.
        arguments += [
            "--ssh-option", "RemoteCommand=printf explicit-fallback",
            "--ssh-option", "CmuxTestInvalidOption=yes",
            "--ssh-option", "RequestTTY no",
            "cmux-config-unavailable-host",
        ]
        let result = processSupport.runProcess(
            executablePath: cliPath,
            arguments: arguments,
            environment: environment,
            timeout: 20
        )
        #expect(
            XCTWaiter().wait(for: [handled], timeout: 5) == .completed,
            "cli mock socket was not handled within 5 seconds"
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        let requests = state.commands.compactMap(processSupport.jsonObject)
        let methods = requests.compactMap { $0["method"] as? String }
        #expect(methods.contains("workspace.create"), "\(methods)")
        #expect(methods.contains("workspace.remote.configure"), "\(methods)")
        let createParams = try #require(
            requests.first { $0["method"] as? String == "workspace.create" }?["params"]
                as? [String: Any]
        )
        let startupCommand = try #require(createParams["initial_command"] as? String)
        let startupURL = URL(fileURLWithPath: startupCommand)
        let startupArtifact = FileManager.default.fileExists(atPath: startupURL.path)
            ? try String(contentsOf: startupURL, encoding: .utf8)
            : startupCommand
        #expect(startupArtifact.contains("RemoteCommand=printf explicit-fallback"), "\(startupArtifact)")
        #expect(!startupArtifact.contains("ssh-pty-attach"), "\(startupArtifact)")
        #expect(!startupArtifact.contains("cmux_mosh"), "\(startupArtifact)")
        let configureParams = try #require(
            requests.first { $0["method"] as? String == "workspace.remote.configure" }?["params"]
                as? [String: Any]
        )
        #expect(configureParams["configured_remote_command"] == nil)
        #expect(
            configureParams["terminal_transport"] as? String == "ssh",
            "An unmanaged OpenSSH fallback must persist the transport it actually launched: \(configureParams)"
        )
    }

    /// `cmux ssh` bootstrap-install flow without a TTY (ControlMaster
    /// disabled → staged installer hop + session hop): a caller-supplied
    /// `RemoteCommand` is captured as the program to chain and retained in
    /// durable workspace options, while the session hop carries only cmux's
    /// `-o RemoteCommand=<bootstrap>`.
    @Test
    func sshBootstrapStartupChainsExplicitRemoteCommandWithConnectionSharingDisabled() throws {
        let cliPath = try processSupport.bundledCLIPath()
        let socketPath = processSupport.makeSocketPath("ssh-rc-boot")
        let listenerFD = try processSupport.bindUnixSocket(at: socketPath)
        let workspaceID = "11111111-1111-1111-1111-111111111111"
        let harness = try makeRemoteCommandHostHarness(prefix: "cmux-ssh-rc-bootstrap")
        let configuredRemoteCommand = #"printf 'caller %% %h %n %p %r'"#
        let expandedRemoteCommand = #"printf 'caller % resolved.example cmux-remotecommand-host 2233 remote-token-user'"#

        defer {
            harness.cleanup()
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let captureState = MockSocketServerState()
        let captureHandled = processSupport.startMockServer(
            listenerFD: listenerFD,
            state: captureState
        ) { line in
            guard let payload = processSupport.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return processSupport.malformedRequestResponse(raw: line)
            }
            switch method {
            case "workspace.create":
                return processSupport.v2Response(id: id, ok: true, result: ["workspace_id": workspaceID])
            case "workspace.remote.configure":
                return processSupport.v2Response(id: id, ok: true, result: [
                    "workspace_id": workspaceID,
                    "workspace_ref": "workspace:9",
                    "remote": ["enabled": true, "state": "connecting"],
                ])
            default:
                return processSupport.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected", "message": "Unexpected method \(method)"]
                )
            }
        }

        var captureEnvironment = ProcessInfo.processInfo.environment
        captureEnvironment["CMUX_SOCKET_PATH"] = socketPath
        captureEnvironment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        captureEnvironment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        let captureResult = processSupport.runProcess(
            executablePath: cliPath,
            arguments: [
                "ssh",
                "--no-focus",
                "--port", "2233",
                "--ssh-option", "ControlMaster no",
                "--ssh-option", "ControlPath /tmp/cmux-ssh-%C",
                "--ssh-option", "HostName=resolved.example",
                "--ssh-option", "User=remote-token-user",
                "--ssh-option", "RemoteCommand=\(configuredRemoteCommand)",
                // TTY sessions go to cmux-tui through `workspace.ssh.open`;
                // the staged startup script is only built without a TTY.
                "--ssh-option", "RequestTTY no",
                "cmux-remotecommand-host",
            ],
            environment: captureEnvironment,
            timeout: 20
        )
        #expect(
            XCTWaiter().wait(for: [captureHandled], timeout: 5) == .completed,
            "cli mock socket was not handled within 5 seconds"
        )
        #expect(!captureResult.timedOut, Comment(rawValue: captureResult.stderr))
        #expect(captureResult.status == 0, Comment(rawValue: captureResult.stderr))

        let requests = captureState.commands.compactMap(processSupport.jsonObject)
        let createParams = try #require(
            requests.first { $0["method"] as? String == "workspace.create" }?["params"] as? [String: Any]
        )
        let startupCommand = try #require(createParams["initial_command"] as? String)
        let configureParams = try #require(
            requests.first { $0["method"] as? String == "workspace.remote.configure" }?["params"] as? [String: Any]
        )
        #expect(configureParams["configured_remote_command"] as? String == expandedRemoteCommand)
        let forwardedOptions = configureParams["ssh_options"] as? [String] ?? []
        #expect(
            forwardedOptions.contains("RemoteCommand=\(configuredRemoteCommand)"),
            """
            Durable workspace options must preserve the caller's tokenized RemoteCommand \
            so unmanaged OpenSSH fallbacks retain authoritative expansion: \(forwardedOptions)
            """
        )
        let executableStartupCommand = try harness.startupCommandUsingFakeSSH(startupCommand)

        let startupResult = processSupport.runProcess(
            executablePath: "/bin/sh",
            arguments: ["-c", executableStartupCommand],
            environment: harness.startupEnvironment(
                socketPath: socketPath,
                workspaceID: workspaceID,
                surfaceID: "22222222-2222-2222-2222-222222222222"
            ),
            timeout: 10
        )

        #expect(!startupResult.timedOut, Comment(rawValue: startupResult.stderr))
        #expect(
            !startupResult.stderr.contains("Cannot execute command-line and remote command."),
            "The bootstrap installer hop must override a host-configured RemoteCommand; stderr: \(startupResult.stderr)"
        )
        #expect(
            !startupResult.stderr.contains("[cmux] ssh exited with status"),
            Comment(rawValue: startupResult.stderr)
        )
        #expect(startupResult.status == 0, Comment(rawValue: startupResult.stderr))

        let events = harness.recordedSSHEvents()
        #expect(
            events.contains("invocation kind=command override=none"),
            "The bootstrap installer hop must pass -o RemoteCommand=none; events: \(events)"
        )
        #expect(
            !events.contains("invocation kind=command override=absent"),
            "A cmux-supplied command-line remote command reached ssh without a RemoteCommand override; events: \(events)"
        )
        #expect(
            events.contains("invocation kind=session override=custom"),
            "The interactive session hop must keep carrying cmux's own -o RemoteCommand=<bootstrap>, not have it cleared to none; events: \(events)"
        )
        #expect(
            events.contains("remotecommand-options kind=session count=1"),
            "The interactive session must carry only cmux's bootstrap RemoteCommand; events: \(events)"
        )
    }

    /// The app-side restore/reattach startup script builder runs a
    /// foreground-auth `ssh ... <dest> true` hop that must override a
    /// host-configured RemoteCommand.
    @Test
    func sshPTYAttachForegroundAuthOverridesHostConfiguredRemoteCommand() throws {
        let command = SSHPTYAttachStartupCommandBuilder.command(
            sessionID: "ssh-w-s",
            foregroundAuth: SSHPTYAttachStartupCommandBuilder.ForegroundAuth(
                destination: "cmux-remotecommand-host",
                port: 2222,
                identityFile: nil,
                sshOptions: [
                    "ControlMaster=auto",
                    "ControlPersist=600",
                    "ControlPath=/tmp/cmux-ssh-%C",
                    "RemoteCommand=printf caller-command",
                ],
                token: "auth-token"
            ),
            remoteCommand: "printf ready"
        )
        #expect(
            command.contains("-o RemoteCommand=none -T cmux-remotecommand-host true"),
            "Restore foreground auth must override a host-configured RemoteCommand before running its command-line `true`; command: \(command)"
        )
        #expect(
            command.contains("/usr/bin/ssh -o"),
            "Restore foreground auth must use the same system OpenSSH executable as config resolution; command: \(command)"
        )
        #expect(
            !command.contains("RemoteCommand=printf caller-command"),
            """
            Restore foreground auth must not forward the durable caller RemoteCommand \
            alongside cmux's override; command: \(command)
            """
        )
        #expect(!command.contains("-$$"), Comment(rawValue: command))
        #expect(
            command.contains("--lifecycle-id \"$cmux_ssh_attach_lifecycle_id\""),
            Comment(rawValue: command)
        )
        #expect(command.contains("ssh-session-end --lifecycle-only"), Comment(rawValue: command))
    }
}
