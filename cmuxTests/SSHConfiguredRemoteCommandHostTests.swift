import CmuxFoundation
import Darwin
import Foundation
import Testing

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

    /// `cmux ssh` default flow (ControlMaster/ControlPath defaults →
    /// foreground auth + persistent SSH PTY attach): the foreground auth hop
    /// runs `ssh ... <dest> true`, which a host-configured RemoteCommand used
    /// to break before the attach could ever start.
    @Test
    func sshStartupConnectsWhenHostConfigSetsRemoteCommandAndRequestTTY() throws {
        let cliPath = try processSupport.bundledCLIPath()
        let socketPath = processSupport.makeSocketPath("ssh-rc-host")
        let listenerFD = try processSupport.bindUnixSocket(at: socketPath)
        let workspaceID = "11111111-1111-1111-1111-111111111111"
        let surfaceID = "22222222-2222-2222-2222-222222222222"
        let sessionID = "ssh-\(workspaceID)-\(surfaceID)"
        let harness = try makeRemoteCommandHostHarness(prefix: "cmux-ssh-rc-default")

        defer {
            harness.cleanup()
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        // Phase 1: capture the generated startup command from the CLI.
        let captureState = MockSocketServerState()
        let captureHandled = processSupport.startMockServer(listenerFD: listenerFD, state: captureState) { line in
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

        var captureEnvironment = ProcessInfo.processInfo.environment
        captureEnvironment["CMUX_SOCKET_PATH"] = socketPath
        captureEnvironment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        captureEnvironment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        let captureResult = runProcess(
            executablePath: cliPath,
            arguments: [
                "ssh",
                "--no-focus",
                "--ssh-option", "RemoteCommand=sudo su -",
                "--ssh-option", "RequestTTY=yes",
                "cmux-remotecommand-host",
            ],
            environment: captureEnvironment,
            timeout: 20
        )
        processSupport.wait(for: [captureHandled], timeout: 5)
        #expect(!captureResult.timedOut, Comment(rawValue: captureResult.stderr))
        #expect(captureResult.status == 0, Comment(rawValue: captureResult.stderr))

        let requests = captureState.commands.compactMap(processSupport.jsonObject)
        let createParams = try #require(
            requests.first { $0["method"] as? String == "workspace.create" }?["params"] as? [String: Any]
        )
        let startupCommand = try #require(createParams["initial_command"] as? String)
        let startupURL = URL(fileURLWithPath: startupCommand)
        let startupArtifact: String
        if FileManager.default.fileExists(atPath: startupURL.path) {
            startupArtifact = try String(contentsOf: startupURL, encoding: .utf8)
        } else if let payloadPrefix = startupCommand.range(of: "cmux_payload="),
                  let lineEnd = startupCommand[payloadPrefix.upperBound...].firstIndex(of: "\n") {
            let encodedScript = String(startupCommand[payloadPrefix.upperBound..<lineEnd])
            let scriptData = try #require(Data(base64Encoded: encodedScript))
            startupArtifact = try #require(String(data: scriptData, encoding: .utf8))
        } else {
            startupArtifact = startupCommand
        }
        var recoverySequenceCursor = startupArtifact.startIndex
        for marker in [
            "CMUX_SSH_AUTH_GROUP_DIR=$(cmux_ssh_auth_create_group_dir)",
            "export CMUX_SSH_AUTH_GROUP_DIR",
            "cmux_ssh_schedule_failed_auth_group_recovery",
            "( cmux_ssh_foreground_auth )",
        ] {
            let range = try #require(
                startupArtifact.range(
                    of: marker,
                    range: recoverySequenceCursor..<startupArtifact.endIndex
                ),
                "Foreground authentication must schedule recovery after group creation and before authentication starts"
            )
            recoverySequenceCursor = range.upperBound
        }
        #expect(
            startupArtifact.contains(
                "if [ -n \"${CMUX_SSH_PENDING_SIGNAL:-}\" ]; then cmux_ssh_retire_for_signal \"$CMUX_SSH_PENDING_SIGNAL\"; fi; cmux_ssh_status=255; break"
            ),
            "Authentication group creation failure must preserve a pending termination signal"
        )
        let configureParams = try #require(
            requests.first { $0["method"] as? String == "workspace.remote.configure" }?["params"] as? [String: Any]
        )
        #expect(configureParams["configured_remote_command"] as? String == "sudo su -")
        let executableStartupCommand = try harness.startupCommandUsingFakeSSH(startupCommand)

        // Phase 2: the attach leg of the startup script connects back for the
        // remote PTY bridge once foreground auth has succeeded.
        let bridge = try processSupport.bindLoopbackTCP()
        defer { Darwin.close(bridge.fd) }
        let bridgeInput = MockBridgeInputCapture()
        let bridgeHandled = processSupport.startBridgeReadyCapturingInputUntilEOF(
            listenerFD: bridge.fd,
            capture: bridgeInput
        )
        let attachState = MockSocketServerState()
        let attachHandled = processSupport.startMockServer(
            listenerFD: listenerFD,
            state: attachState
        ) { line in
            guard let payload = processSupport.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return processSupport.malformedRequestResponse(raw: line)
            }
            switch method {
            case "workspace.remote.foreground_auth_ready":
                return processSupport.v2Response(id: id, ok: true, result: [
                    "workspace_id": workspaceID,
                    "workspace_ref": "workspace:9",
                    "remote": ["enabled": true, "state": "connecting"],
                ])
            case "workspace.remote.pty_bridge":
                return processSupport.v2Response(id: id, ok: true, result: [
                    "host": "127.0.0.1",
                    "port": bridge.port,
                    "token": "bridge-token",
                    "session_id": sessionID,
                    "attachment_id": surfaceID,
                ])
            case "workspace.remote.pty_sessions":
                return processSupport.v2Response(id: id, ok: true, result: ["sessions": []])
            case "workspace.remote.pty_attach_end":
                return processSupport.v2Response(id: id, ok: true, result: [
                    "workspace_id": workspaceID,
                    "surface_id": surfaceID,
                    "session_id": sessionID,
                    "cleared_remote_pty_session": true,
                ])
            default:
                return processSupport.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected", "message": "Unexpected method \(method)"]
                )
            }
        }

        let startupResult = runProcess(
            executablePath: "/bin/sh",
            arguments: ["-c", executableStartupCommand],
            environment: harness.startupEnvironment(
                socketPath: socketPath,
                workspaceID: workspaceID,
                surfaceID: surfaceID
            ),
            timeout: 10
        )

        try #require(
            !startupResult.timedOut,
            "Startup timed out; stdout: \(startupResult.stdout); stderr: \(startupResult.stderr)"
        )
        try #require(
            startupResult.status == 0,
            "Startup exited \(startupResult.status); stdout: \(startupResult.stdout); stderr: \(startupResult.stderr)"
        )
        #expect(
            !startupResult.stderr.contains("Cannot execute command-line and remote command."),
            "cmux-controlled ssh invocations must override a host-configured RemoteCommand; stderr: \(startupResult.stderr)"
        )
        #expect(
            !startupResult.stderr.contains("[cmux] ssh exited with status"),
            Comment(rawValue: startupResult.stderr)
        )

        let events = harness.recordedSSHEvents()
        try #require(
            events.contains("invocation kind=command override=none"),
            "The foreground auth hop must pass -o RemoteCommand=none; events: \(events); stdout: \(startupResult.stdout); stderr: \(startupResult.stderr)"
        )
        #expect(
            !events.contains("invocation kind=command override=absent"),
            "A cmux-supplied command-line remote command reached ssh without a RemoteCommand override; events: \(events)"
        )

        processSupport.wait(for: [attachHandled], timeout: 5)
        #expect(bridgeHandled.wait(timeout: .now() + 5) == .success)
        let attachMethods = attachState.commands.compactMap {
            processSupport.jsonObject($0)?["method"] as? String
        }
        #expect(
            attachMethods.contains("workspace.remote.pty_bridge"),
            "Foreground auth should succeed and hand off to ssh-pty-attach; observed methods: \(attachMethods)"
        )
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
        arguments += [
            "--ssh-option", "RemoteCommand=printf explicit-fallback",
            "--ssh-option", "CmuxTestInvalidOption=yes",
            "cmux-config-unavailable-host",
        ]
        let result = runProcess(
            executablePath: cliPath,
            arguments: arguments,
            environment: environment,
            timeout: 20
        )
        processSupport.wait(for: [handled], timeout: 5)

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
        #expect(
            startupArtifact.contains("\ncmux_ssh_schedule_failed_auth_group_recovery\nwhile :; do\n"),
            "Ordinary SSH startup must schedule durable failed-auth cleanup before its long-lived loop: \(startupArtifact)"
        )
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

    /// `cmux ssh` bootstrap-install flow (ControlMaster disabled → staged
    /// installer hop + interactive session hop): a caller-supplied
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

        let captureResult = runProcess(
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
                "cmux-remotecommand-host",
            ],
            environment: captureEnvironment,
            timeout: 20
        )
        processSupport.wait(for: [captureHandled], timeout: 5)
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

        let startupResult = runProcess(
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

    /// The app-side restore/reattach startup script builder shares the same
    /// foreground-auth `ssh ... <dest> true` shape as the CLI.
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
        let lifecycleUUIDAssignment = "cmux_ssh_attach_lifecycle_id=$(/usr/bin/uuidgen"
        #expect(
            command.components(separatedBy: lifecycleUUIDAssignment).count - 1 == 1,
            "The restored wrapper needs one persistent lifecycle UUID: \(command)"
        )
        #expect(
            command.components(separatedBy: "CMUX_SSH_ATTEMPT_ID=$(/usr/bin/uuidgen").count - 1 == 1,
            "The restored wrapper needs one per-attempt readiness UUID: \(command)"
        )
        #expect(!command.contains("-$$"), Comment(rawValue: command))
        #expect(
            command.contains("--lifecycle-id \"$cmux_ssh_attach_lifecycle_id\""),
            Comment(rawValue: command)
        )
        #expect(command.contains("ssh-session-end --lifecycle-only"), Comment(rawValue: command))
    }

    private struct ProcessRunResult {
        let status: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
    }

    /// Runs this Swift Testing suite's child processes without delegating exit
    /// observation to the shared global queue. App-host work can starve a queued
    /// `waitUntilExit` task after the child has already exited and create a false
    /// timeout at the exact deadline.
    private func runProcess(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        standardInput: String? = nil,
        timeout: TimeInterval
    ) -> ProcessRunResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = standardInput == nil ? nil : Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = isolatedChildEnvironment(environment)
        process.standardInput = stdinPipe ?? FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return ProcessRunResult(
                status: -1,
                stdout: "",
                stderr: String(describing: error),
                timedOut: false
            )
        }
        if let standardInput, let stdinPipe {
            stdinPipe.fileHandleForWriting.write(Data(standardInput.utf8))
            try? stdinPipe.fileHandleForWriting.close()
        }

        let outputLock = NSLock()
        var stdoutData = Data()
        var stderrData = Data()
        let outputGroup = DispatchGroup()

        outputGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            outputLock.lock()
            stdoutData = data
            outputLock.unlock()
            outputGroup.leave()
        }
        outputGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            outputLock.lock()
            stderrData = data
            outputLock.unlock()
            outputGroup.leave()
        }

        let exitDeadline = Date.now.addingTimeInterval(processSupport.processTimeout(timeout))
        while process.isRunning, Date.now < exitDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        let timedOut = process.isRunning
        if timedOut {
            process.terminate()
            let terminationDeadline = Date.now.addingTimeInterval(1)
            while process.isRunning, Date.now < terminationDeadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
                let killDeadline = Date.now.addingTimeInterval(1)
                while process.isRunning, Date.now < killDeadline {
                    Thread.sleep(forTimeInterval: 0.01)
                }
            }
        }
        if !process.isRunning {
            process.waitUntilExit()
        }

        _ = outputGroup.wait(timeout: .now() + 2)
        outputLock.lock()
        let finalStdout = stdoutData
        let finalStderr = stderrData
        outputLock.unlock()
        return ProcessRunResult(
            status: process.isRunning ? SIGKILL : process.terminationStatus,
            stdout: String(data: finalStdout, encoding: .utf8) ?? "",
            stderr: String(data: finalStderr, encoding: .utf8) ?? "",
            timedOut: timedOut
        )
    }

    private func isolatedChildEnvironment(_ environment: [String: String]) -> [String: String] {
        guard environment["CMUX_APP_HOST_ISOLATION_REQUIRED"] == "1",
              let rawHome = environment["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawHome.isEmpty else {
            return environment
        }

        var resolved = environment
        resolved["CFFIXED_USER_HOME"] = rawHome
        resolved["XDG_CONFIG_HOME"] = URL(
            fileURLWithPath: rawHome,
            isDirectory: true
        ).appendingPathComponent(".config", isDirectory: true).path
        return resolved
    }

    // MARK: - Fake RemoteCommand-host harness

    struct RemoteCommandHostHarness {
        let root: URL
        let binDirectory: URL
        let eventsFile: URL
        let fakeCLILog: URL

        func startupEnvironment(
            socketPath: String,
            workspaceID: String,
            surfaceID: String
        ) -> [String: String] {
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "/usr/bin:/bin"
            environment["CMUX_BUNDLED_CLI_PATH"] = binDirectory.appendingPathComponent("cmux").path
            environment["CMUX_SOCKET_PATH"] = socketPath
            environment["CMUX_WORKSPACE_ID"] = workspaceID
            environment["CMUX_SURFACE_ID"] = surfaceID
            environment["CMUX_FAKE_SSH_EVENTS"] = eventsFile.path
            environment["CMUX_FAKE_CLI_LOG"] = fakeCLILog.path
            environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
            environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"
            environment["CMUX_SSH_RECONNECT_LIMIT"] = "1"
            environment["CMUX_SSH_RECONNECT_DELAY_SECONDS"] = "0"
            // The durable cleanup queue is process-external state. Keep this
            // harness independent from other SSH tests and prior test runs.
            environment["TMPDIR"] = root.path
            return environment
        }

        func startupCommandUsingFakeSSH(_ startupCommand: String) throws -> String {
            let systemSSHPath = "/usr/bin/ssh"
            let fakeSSHPath = binDirectory.appendingPathComponent("ssh").path
            func replacingSystemSSH(
                in command: String,
                encodedRange: Range<String.Index>
            ) -> String? {
                let encodedScript = String(command[encodedRange])
                guard let scriptData = Data(base64Encoded: encodedScript),
                      let script = String(data: scriptData, encoding: .utf8),
                      script.contains(systemSSHPath) else {
                    return nil
                }
                let rewrittenScript = script.replacingOccurrences(
                    of: systemSSHPath,
                    with: fakeSSHPath
                )
                var rewrittenCommand = command
                rewrittenCommand.replaceSubrange(
                    encodedRange,
                    with: Data(rewrittenScript.utf8).base64EncodedString()
                )
                return rewrittenCommand
            }
            let trimmedCommand = startupCommand.trimmingCharacters(in: .whitespacesAndNewlines)
            let commandURL = URL(fileURLWithPath: trimmedCommand)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false

            if FileManager.default.fileExists(atPath: commandURL.path, isDirectory: &isDirectory),
               !isDirectory.boolValue {
                let contents = try String(contentsOf: commandURL, encoding: .utf8)
                guard contents.contains(systemSSHPath) else {
                    throw NSError(
                        domain: "SSHConfiguredRemoteCommandHostTests",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Generated startup script did not pin \(systemSSHPath)"]
                    )
                }
                let rewrittenURL = root.appendingPathComponent("startup-with-fake-ssh.sh")
                try contents
                    .replacingOccurrences(of: systemSSHPath, with: fakeSSHPath)
                    .write(to: rewrittenURL, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o700],
                    ofItemAtPath: rewrittenURL.path
                )
                return rewrittenURL.path
            }

            guard startupCommand.contains(systemSSHPath) else {
                let payloadPrefix = "cmux_payload="
                if let prefixRange = startupCommand.range(of: payloadPrefix),
                   let lineEnd = startupCommand[prefixRange.upperBound...].firstIndex(of: "\n") {
                    let encodedRange = prefixRange.upperBound..<lineEnd
                    if let rewrittenCommand = replacingSystemSSH(
                        in: startupCommand,
                        encodedRange: encodedRange
                    ) {
                        return rewrittenCommand
                    }
                }
                let encodedPrefix = "(printf %s "
                let encodedSuffix = " | base64"
                if let prefixRange = startupCommand.range(of: encodedPrefix),
                   let suffixRange = startupCommand.range(
                       of: encodedSuffix,
                       range: prefixRange.upperBound..<startupCommand.endIndex
                   ) {
                    let encodedRange = prefixRange.upperBound..<suffixRange.lowerBound
                    if let rewrittenCommand = replacingSystemSSH(
                        in: startupCommand,
                        encodedRange: encodedRange
                    ) {
                        return rewrittenCommand
                    }
                }
                throw NSError(
                    domain: "SSHConfiguredRemoteCommandHostTests",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Generated startup command did not pin \(systemSSHPath)"]
                )
            }
            return startupCommand.replacingOccurrences(of: systemSSHPath, with: fakeSSHPath)
        }

        func recordedSSHEvents() -> [String] {
            ((try? String(contentsOf: eventsFile, encoding: .utf8)) ?? "")
                .split(separator: "\n")
                .map(String.init)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// Installs a fake `ssh` that enforces OpenSSH's configured-command
    /// conflict semantics, and a fake `cmux` for the startup script's
    /// session-end reporting. Tests first assert that the production artifact
    /// pins `/usr/bin/ssh`, then substitute this executable in that artifact.
    func makeRemoteCommandHostHarness(prefix: String) throws -> RemoteCommandHostHarness {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        let binDirectory = root.appendingPathComponent("bin", isDirectory: true)
        try fileManager.createDirectory(at: binDirectory, withIntermediateDirectories: true)

        let harness = RemoteCommandHostHarness(
            root: root,
            binDirectory: binDirectory,
            eventsFile: root.appendingPathComponent("fake-ssh-events.log"),
            fakeCLILog: root.appendingPathComponent("fake-cli.log")
        )

        // Mirrors OpenSSH: the first -o RemoteCommand=... wins; a positional
        // command with no override is fatal exactly like a host-configured
        // RemoteCommand conflict. `-G` prints a config dump and `-O` control
        // operations never execute a remote command.
        let fakeSSH = """
        #!/bin/sh
        events="${CMUX_FAKE_SSH_EVENTS:?}"
        override=absent
        remotecommand_value=
        remotecommand_options=0
        mode=session
        while [ $# -gt 0 ]; do
          case "$1" in
            -o)
              case "$2" in
                RemoteCommand=*|remotecommand=*)
                  remotecommand_options=$((remotecommand_options + 1))
                  remotecommand_value="${2#*=}"
                  ;;
              esac
              if [ "$override" = absent ]; then
                case "$2" in
                  RemoteCommand=none|remotecommand=none) override=none ;;
                  RemoteCommand=*|remotecommand=*) override=custom ;;
                esac
              fi
              shift 2 ;;
            -o*)
              case "${1#-o}" in
                RemoteCommand=*|remotecommand=*)
                  remotecommand_options=$((remotecommand_options + 1))
                  remotecommand_value="${1#*=}"
                  ;;
              esac
              if [ "$override" = absent ]; then
                case "${1#-o}" in
                  RemoteCommand=none|remotecommand=none) override=none ;;
                  RemoteCommand=*|remotecommand=*) override=custom ;;
                esac
              fi
              shift ;;
            -G) mode=config; shift ;;
            -O) mode=controlop; shift 2 ;;
            -S|-p|-i|-l|-F|-E|-e|-b|-c|-D|-I|-J|-L|-m|-Q|-R|-W|-w|-B) shift 2 ;;
            --) shift; shift; break ;;
            -*) shift ;;
            *) shift; break ;;
          esac
        done
        if [ "$mode" = config ]; then
          printf 'invocation kind=config override=%s\\n' "$override" >> "$events"
          printf 'controlpath none\\n'
          case "$override" in
            custom) printf 'remotecommand %s\\n' "$remotecommand_value" ;;
            none) printf 'remotecommand none\\n' ;;
            *) printf 'remotecommand sudo su -\\n' ;;
          esac
          printf 'requesttty yes\\n'
          exit 0
        fi
        if [ "$mode" = controlop ]; then
          printf 'invocation kind=controlop override=%s\\n' "$override" >> "$events"
          exit 0
        fi
        if [ $# -gt 0 ]; then mode=command; fi
        printf 'invocation kind=%s override=%s\\n' "$mode" "$override" >> "$events"
        printf 'remotecommand-options kind=%s count=%s\\n' "$mode" "$remotecommand_options" >> "$events"
        if [ "$mode" = command ] && [ "$override" = absent ]; then
          printf '%s\\n' 'Cannot execute command-line and remote command.' >&2
          exit 255
        fi
        cat >/dev/null 2>&1 || true
        exit 0
        """
        let fakeSSHURL = binDirectory.appendingPathComponent("ssh")
        try fakeSSH.appending("\n").write(to: fakeSSHURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeSSHURL.path)

        let fakeCLI = """
        #!/bin/sh
        printf '%s\\n' "$*" >> "${CMUX_FAKE_CLI_LOG:?}"
        exit 0
        """
        let fakeCLIURL = binDirectory.appendingPathComponent("cmux")
        try fakeCLI.appending("\n").write(to: fakeCLIURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeCLIURL.path)

        return harness
    }
}
