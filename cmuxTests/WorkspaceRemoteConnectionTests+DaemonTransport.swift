import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Daemon transport arguments, proxy startup, and capability preflight
extension WorkspaceRemoteConnectionTests {
    func testDaemonSocketForwardArgumentsTargetBakedVMSocket() {
        let configuration = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: 2222,
            identityFile: "/Users/test/.ssh/id_ed25519",
            sshOptions: [
                "ControlPath /tmp/cmux-ssh-%C",
                "StrictHostKeyChecking=accept-new",
            ],
            localProxyPort: nil,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: nil,
            skipDaemonBootstrap: true
        )

        let arguments = WorkspaceRemoteSSHBatchCommandBuilder.daemonSocketForwardArguments(
            configuration: configuration,
            localPort: 64123,
            remoteSocketPath: "/run/cmuxd-remote.sock"
        )

        XCTAssertEqual(Array(arguments.prefix(4)), ["-N", "-T", "-S", "none"])
        XCTAssertTrue(arguments.contains("-p"))
        XCTAssertTrue(arguments.contains("2222"))
        XCTAssertTrue(arguments.contains("-i"))
        XCTAssertTrue(arguments.contains("/Users/test/.ssh/id_ed25519"))
        XCTAssertTrue(arguments.contains("127.0.0.1:64123:/run/cmuxd-remote.sock"))
        XCTAssertEqual(arguments.last, "cmux-macmini")
    }

    func testProxyBrokerTransportKeySeparatesVMBakedSSHFromStandardSSH() {
        let standard = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: 2222,
            identityFile: "/Users/test/.ssh/id_ed25519",
            sshOptions: ["ControlPath /tmp/cmux-ssh-%C"],
            localProxyPort: nil,
            relayPort: 64099,
            relayID: "relay-a",
            relayToken: String(repeating: "a", count: 64),
            localSocketPath: "/tmp/cmux.sock",
            terminalStartupCommand: "ssh cmux-macmini"
        )
        let vmSSH = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: 2222,
            identityFile: "/Users/test/.ssh/id_ed25519",
            sshOptions: ["ControlPath /tmp/cmux-ssh-%C"],
            localProxyPort: nil,
            relayPort: 64099,
            relayID: "relay-a",
            relayToken: String(repeating: "a", count: 64),
            localSocketPath: "/tmp/cmux.sock",
            terminalStartupCommand: "ssh cmux-macmini",
            skipDaemonBootstrap: true
        )
        let persistentPTYSSH = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: 2222,
            identityFile: "/Users/test/.ssh/id_ed25519",
            sshOptions: ["ControlPath /tmp/cmux-ssh-%C"],
            localProxyPort: nil,
            relayPort: 64099,
            relayID: "relay-a",
            relayToken: String(repeating: "a", count: 64),
            localSocketPath: "/tmp/cmux.sock",
            terminalStartupCommand: "ssh-pty-attach",
            preserveAfterTerminalExit: true
        )
        let vmWebSocket = WorkspaceRemoteConfiguration(
            transport: .websocket,
            destination: "vm:abcd1234",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: "cmux vm-pty-attach --id abcd1234",
            daemonWebSocketEndpoint: WorkspaceRemoteWebSocketDaemonEndpoint(
                url: "wss://sandbox.example/rpc",
                headers: ["e2b-traffic-access-token": "header-a"],
                token: "token-a",
                sessionId: "sess-a",
                expiresAtUnix: 1_800_000_000
            ),
            skipDaemonBootstrap: true
        )
        let vmWebSocketRefreshed = WorkspaceRemoteConfiguration(
            transport: .websocket,
            destination: "vm:abcd1234",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: "cmux vm-pty-attach --id abcd1234",
            daemonWebSocketEndpoint: WorkspaceRemoteWebSocketDaemonEndpoint(
                url: "wss://sandbox.example/rpc",
                headers: ["e2b-traffic-access-token": "header-b"],
                token: "token-b",
                sessionId: "sess-b",
                expiresAtUnix: 1_800_000_100
            ),
            skipDaemonBootstrap: true
        )

        XCTAssertNotEqual(standard.proxyBrokerTransportKey, vmSSH.proxyBrokerTransportKey)
        XCTAssertNotEqual(standard.proxyBrokerTransportKey, persistentPTYSSH.proxyBrokerTransportKey)
        XCTAssertNotEqual(vmSSH.proxyBrokerTransportKey, vmWebSocket.proxyBrokerTransportKey)
        XCTAssertNotEqual(vmWebSocket.proxyBrokerTransportKey, vmWebSocketRefreshed.proxyBrokerTransportKey)
    }

    @MainActor
    func testWebSocketVMWithoutDaemonEndpointSkipsProxyStartup() {
        let workspace = Workspace()
        let config = WorkspaceRemoteConfiguration(
            transport: .websocket,
            destination: "vm:test-no-daemon",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: "cmux vm-pty-attach --id test-no-daemon",
            skipDaemonBootstrap: true
        )

        workspace.configureRemoteConnection(config, autoConnect: true)

        XCTAssertEqual(workspace.remoteConnectionState, .connected)
        XCTAssertNil(workspace.remoteProxyEndpoint)
    }

    @MainActor
    func testSkipBootstrapPersistentPTYDoesNotFailBakedCapabilityPreflight() {
        let workspace = Workspace()
        let config = WorkspaceRemoteConfiguration(
            transport: .websocket,
            destination: "vm:test-persistent-no-daemon",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: "ssh-pty-attach",
            preserveAfterTerminalExit: true,
            skipDaemonBootstrap: true
        )

        workspace.configureRemoteConnection(config, autoConnect: true)
        let deadline = Date().addingTimeInterval(0.5)
        while workspace.remoteConnectionState == .connecting && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }

        XCTAssertEqual(workspace.remoteConnectionState, .connected)
        XCTAssertNil(workspace.remoteProxyEndpoint)
        let daemon = workspace.remoteStatusPayload()["daemon"] as? [String: Any]
        XCTAssertFalse((daemon?["detail"] as? String)?.contains("pty.session") == true)
    }

    func testRemoteDaemonCapabilityErrorsUseUserFacingMessage() {
        let message = remoteDaemonMissingRequiredCapabilitiesMessage([
            "pty.session",
            "pty.session.token",
        ])

        XCTAssertEqual(
            message,
            "remote daemon does not support persistent SSH PTY sessions; reconnect the remote workspace to update cmux"
        )
        XCTAssertFalse(message.contains("pty.session"))

        let notificationMessage = remoteDaemonMissingRequiredCapabilitiesMessage([
            "pty.write.notification",
        ])
        XCTAssertEqual(notificationMessage, message)
        XCTAssertFalse(notificationMessage.contains("pty.write.notification"))

        let rawError = NSError(domain: "cmux.remote.daemon", code: 43, userInfo: [
            NSLocalizedDescriptionKey: "remote daemon missing required capability pty.write.notification",
        ])
        let bootstrapMessage = WorkspaceRemoteSessionController.userFacingRemoteDaemonBootstrapErrorMessage(rawError)
        XCTAssertEqual(bootstrapMessage, message)
        XCTAssertFalse(bootstrapMessage.contains("pty.session"))
        XCTAssertFalse(bootstrapMessage.contains("pty.write.notification"))
    }

    @MainActor
    func testWebSocketVMWithDaemonEndpointStartsProxyCapableConnection() {
        let workspace = Workspace()
        let config = WorkspaceRemoteConfiguration(
            transport: .websocket,
            destination: "vm:test-with-daemon",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: "cmux vm-pty-attach --id test-with-daemon",
            daemonWebSocketEndpoint: WorkspaceRemoteWebSocketDaemonEndpoint(
                url: "ws://127.0.0.1:65534/rpc",
                headers: [:],
                token: "token-a",
                sessionId: "sess-a",
                expiresAtUnix: 1_800_000_000
            ),
            skipDaemonBootstrap: true
        )

        workspace.configureRemoteConnection(config, autoConnect: true)

        XCTAssertEqual(workspace.remoteConnectionState, .connecting)
        workspace.disconnectRemoteConnection(clearConfiguration: true)
    }

    func testReverseRelayStartupFailureDetailCapturesImmediateForwardingFailure() throws {
        let process = Process()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "echo 'remote port forwarding failed for listen port 64009' >&2; exit 1"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe

        try process.run()

        let detail = WorkspaceRemoteSessionController.reverseRelayStartupFailureDetail(
            process: process,
            stderrPipe: stderrPipe,
            gracePeriod: 1.0
        )

        XCTAssertEqual(detail, "remote port forwarding failed for listen port 64009")
    }

    func testDaemonTransportArgumentsReuseConfiguredControlPath() {
        let configuration = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: 2222,
            identityFile: "/Users/test/.ssh/id_ed25519",
            sshOptions: [
                "ControlMaster=auto",
                "ControlPersist=600",
                "ControlPath=/tmp/cmux-ssh-%C",
                "StrictHostKeyChecking=accept-new",
            ],
            localProxyPort: nil,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: "ssh cmux-macmini"
        )

        let arguments = WorkspaceRemoteSSHBatchCommandBuilder.daemonTransportArguments(
            configuration: configuration,
            remotePath: "/remote/cmuxd-remote"
        )

        XCTAssertFalse(arguments.contains("-S"))
        XCTAssertTrue(arguments.contains("ControlMaster=no"))
        XCTAssertTrue(arguments.contains(where: { $0 == "ControlPath /tmp/cmux-ssh-%C" || $0 == "ControlPath=/tmp/cmux-ssh-%C" }))
        XCTAssertTrue(arguments.contains("cmux-macmini"))
        XCTAssertTrue(arguments.last?.contains("/remote/cmuxd-remote") ?? false)
    }

    func testDaemonTransportArgumentsReuseWhitespaceConfiguredControlPath() {
        let configuration = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: 2222,
            identityFile: "/Users/test/.ssh/id_ed25519",
            sshOptions: [
                "ControlMaster auto",
                "ControlPersist 600",
                "ControlPath /tmp/cmux-ssh-%C",
                "StrictHostKeyChecking accept-new",
            ],
            localProxyPort: nil,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: "ssh cmux-macmini"
        )

        let arguments = WorkspaceRemoteSSHBatchCommandBuilder.daemonTransportArguments(
            configuration: configuration,
            remotePath: "/remote/cmuxd-remote"
        )

        XCTAssertFalse(arguments.contains("-S"))
        XCTAssertTrue(arguments.contains("ControlMaster=no"))
        XCTAssertTrue(arguments.contains(where: { $0 == "ControlPath /tmp/cmux-ssh-%C" || $0 == "ControlPath=/tmp/cmux-ssh-%C" }))
    }

    func testReverseRelayControlMasterArgumentsReuseConfiguredControlSocket() throws {
        let configuration = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: 2222,
            identityFile: "/Users/test/.ssh/id_ed25519",
            sshOptions: [
                "ControlMaster=auto",
                "ControlPersist=600",
                "ControlPath=/tmp/cmux-ssh-%C",
                "StrictHostKeyChecking=accept-new",
            ],
            localProxyPort: nil,
            relayPort: 64007,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: "ssh cmux-macmini"
        )

        let arguments = try XCTUnwrap(
            WorkspaceRemoteSSHBatchCommandBuilder.reverseRelayControlMasterArguments(
                configuration: configuration,
                controlCommand: "forward",
                forwardSpec: "127.0.0.1:64007:127.0.0.1:54321"
            )
        )

        XCTAssertFalse(arguments.contains("-S"))
        XCTAssertTrue(arguments.contains("ControlMaster=no"))
        XCTAssertTrue(arguments.contains("ControlPath=/tmp/cmux-ssh-%C"))
        XCTAssertTrue(arguments.contains("-O"))
        XCTAssertTrue(arguments.contains("forward"))
        XCTAssertTrue(arguments.contains("-R"))
        XCTAssertTrue(arguments.contains("127.0.0.1:64007:127.0.0.1:54321"))
        XCTAssertTrue(arguments.contains("cmux-macmini"))
    }

    func testReverseRelayControlMasterCancelArgumentsUseRemoteListenPortOnly() throws {
        let configuration = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: 2222,
            identityFile: "/Users/test/.ssh/id_ed25519",
            sshOptions: [
                "ControlMaster=auto",
                "ControlPersist=600",
                "ControlPath=/tmp/cmux-ssh-%C",
                "StrictHostKeyChecking=accept-new",
            ],
            localProxyPort: nil,
            relayPort: 64007,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: "ssh cmux-macmini"
        )

        let arguments = try XCTUnwrap(
            WorkspaceRemoteSSHBatchCommandBuilder.reverseRelayControlMasterCancelArguments(
                configuration: configuration,
                relayPort: 64007
            )
        )

        XCTAssertFalse(arguments.contains("-S"))
        XCTAssertTrue(arguments.contains("ControlMaster=no"))
        XCTAssertTrue(arguments.contains("ControlPath=/tmp/cmux-ssh-%C"))
        XCTAssertTrue(arguments.contains("-O"))
        XCTAssertTrue(arguments.contains("cancel"))
        XCTAssertTrue(arguments.contains("-R"))
        XCTAssertTrue(arguments.contains("127.0.0.1:64007"))
        XCTAssertFalse(arguments.contains(where: { $0.hasPrefix("127.0.0.1:64007:127.0.0.1:") }))
        XCTAssertTrue(arguments.contains("cmux-macmini"))
    }

    func testReverseRelayControlMasterArgumentsReuseWhitespaceConfiguredControlSocket() throws {
        let configuration = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: 2222,
            identityFile: "/Users/test/.ssh/id_ed25519",
            sshOptions: [
                "ControlMaster auto",
                "ControlPersist 600",
                "ControlPath /tmp/cmux-ssh-%C",
                "StrictHostKeyChecking accept-new",
            ],
            localProxyPort: nil,
            relayPort: 64033,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: "ssh cmux-macmini"
        )

        let arguments = try XCTUnwrap(
            WorkspaceRemoteSSHBatchCommandBuilder.reverseRelayControlMasterArguments(
                configuration: configuration,
                controlCommand: "forward",
                forwardSpec: "127.0.0.1:64033:127.0.0.1:54321"
            )
        )

        XCTAssertFalse(arguments.contains("-S"))
        XCTAssertTrue(arguments.contains("ControlMaster=no"))
        XCTAssertTrue(arguments.contains(where: { $0 == "ControlPath /tmp/cmux-ssh-%C" || $0 == "ControlPath=/tmp/cmux-ssh-%C" }))
        XCTAssertTrue(arguments.contains("-O"))
        XCTAssertTrue(arguments.contains("forward"))
    }

    @MainActor
    func testProxyOnlyErrorsKeepSSHWorkspaceConnectedAndLoggedInSidebar() {
        let workspace = Workspace()
        let config = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64007,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: "ssh cmux-macmini"
        )

        workspace.configureRemoteConnection(config, autoConnect: false)
        XCTAssertEqual(workspace.activeRemoteTerminalSessionCount, 1)

        let proxyError = "Remote proxy to cmux-macmini unavailable: Failed to start local daemon proxy: daemon RPC timeout waiting for hello response (retry in 3s)"
        workspace.applyRemoteConnectionStateUpdate(.error, detail: proxyError, target: "cmux-macmini")

        XCTAssertEqual(workspace.remoteConnectionState, .connected)
        XCTAssertEqual(workspace.remoteConnectionDetail, proxyError)
        XCTAssertEqual(
            workspace.statusEntries["remote.error"]?.value,
            "Remote proxy unavailable (cmux-macmini): \(proxyError)"
        )
        XCTAssertEqual(workspace.logEntries.last?.source, "remote-proxy")
        XCTAssertEqual(workspace.remoteStatusPayload()["connected"] as? Bool, true)
        XCTAssertEqual(
            ((workspace.remoteStatusPayload()["proxy"] as? [String: Any])?["state"] as? String),
            "error"
        )

        workspace.applyRemoteConnectionStateUpdate(.connecting, detail: "Connecting to cmux-macmini", target: "cmux-macmini")

        XCTAssertEqual(workspace.remoteConnectionState, .connected)
        XCTAssertEqual(
            workspace.statusEntries["remote.error"]?.value,
            "Remote proxy unavailable (cmux-macmini): \(proxyError)"
        )

        workspace.applyRemoteConnectionStateUpdate(
            .connected,
            detail: "Connected to cmux-macmini via shared local proxy 127.0.0.1:9999",
            target: "cmux-macmini"
        )

        XCTAssertEqual(workspace.remoteConnectionState, .connected)
        XCTAssertNil(workspace.statusEntries["remote.error"])
        XCTAssertEqual(
            ((workspace.remoteStatusPayload()["proxy"] as? [String: Any])?["state"] as? String),
            "unavailable"
        )
    }
}
