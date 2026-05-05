import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class WorkspaceRemoteConnectionTests: XCTestCase {
    private struct ProcessRunResult {
        let status: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
    }

    private func runProcess(
        executablePath: String,
        arguments: [String],
        timeout: TimeInterval
    ) -> ProcessRunResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
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

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return ProcessRunResult(
            status: process.terminationStatus,
            stdout: stdout,
            stderr: stderr,
            timedOut: timedOut
        )
    }

    private func writeShellFile(at url: URL, lines: [String]) throws {
        try lines.joined(separator: "\n")
            .appending("\n")
            .write(to: url, atomically: true, encoding: .utf8)
    }

    private func runRelayZshHistfile(
        configureUserHome: (URL) throws -> URL
    ) throws -> String {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory.appendingPathComponent("cmux-relay-zsh-\(UUID().uuidString)")
        let relayDir = home.appendingPathComponent(".cmux/relay/64011.shell")

        try fileManager.createDirectory(at: relayDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: home) }

        let effectiveUserZdotdir = try configureUserHome(home)
        let bootstrap = RemoteRelayZshBootstrap(shellStateDir: relayDir.path)

        try writeShellFile(at: relayDir.appendingPathComponent(".zshenv"), lines: bootstrap.zshEnvLines)
        try writeShellFile(at: relayDir.appendingPathComponent(".zprofile"), lines: bootstrap.zshProfileLines)
        try writeShellFile(at: relayDir.appendingPathComponent(".zshrc"), lines: bootstrap.zshRCLines(commonShellLines: []))
        try writeShellFile(at: relayDir.appendingPathComponent(".zlogin"), lines: bootstrap.zshLoginLines)

        let result = runProcess(
            executablePath: "/usr/bin/env",
            arguments: [
                "HOME=\(home.path)",
                "TERM=xterm-256color",
                "SHELL=/bin/zsh",
                "USER=\(NSUserName())",
                "CMUX_REAL_ZDOTDIR=\(home.path)",
                "ZDOTDIR=\(relayDir.path)",
                "/bin/zsh",
                "-ilc",
                "print -r -- \"$HISTFILE\"",
            ],
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)

        let histfile = result.stdout
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .last(where: { !$0.isEmpty })
        XCTAssertEqual(histfile, effectiveUserZdotdir.appendingPathComponent(".zsh_history").path)
        return histfile ?? ""
    }

    func testRemoteRelayMetadataCleanupScriptRemovesMatchingSocketAddr() {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory.appendingPathComponent("cmux-relay-cleanup-\(UUID().uuidString)")
        let relayDir = home.appendingPathComponent(".cmux/relay")
        let socketAddrURL = home.appendingPathComponent(".cmux/socket_addr")
        let authURL = relayDir.appendingPathComponent("64008.auth")
        let daemonPathURL = relayDir.appendingPathComponent("64008.daemon_path")
        let ttyURL = relayDir.appendingPathComponent("64008.tty")

        XCTAssertNoThrow(try fileManager.createDirectory(at: relayDir, withIntermediateDirectories: true))
        XCTAssertNoThrow(try "127.0.0.1:64008".write(to: socketAddrURL, atomically: true, encoding: .utf8))
        XCTAssertNoThrow(try "auth".write(to: authURL, atomically: true, encoding: .utf8))
        XCTAssertNoThrow(try "daemon".write(to: daemonPathURL, atomically: true, encoding: .utf8))
        XCTAssertNoThrow(try "ttys001".write(to: ttyURL, atomically: true, encoding: .utf8))
        defer { try? fileManager.removeItem(at: home) }

        let result = runProcess(
            executablePath: "/usr/bin/env",
            arguments: [
                "HOME=\(home.path)",
                "/bin/sh",
                "-c",
                WorkspaceRemoteSessionController.remoteRelayMetadataCleanupScript(relayPort: 64008),
            ],
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertFalse(fileManager.fileExists(atPath: socketAddrURL.path))
        XCTAssertFalse(fileManager.fileExists(atPath: authURL.path))
        XCTAssertFalse(fileManager.fileExists(atPath: daemonPathURL.path))
        XCTAssertFalse(fileManager.fileExists(atPath: ttyURL.path))
    }

    func testRemoteRelayMetadataCleanupScriptPreservesDifferentSocketAddr() {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory.appendingPathComponent("cmux-relay-cleanup-preserve-\(UUID().uuidString)")
        let relayDir = home.appendingPathComponent(".cmux/relay")
        let socketAddrURL = home.appendingPathComponent(".cmux/socket_addr")
        let authURL = relayDir.appendingPathComponent("64009.auth")
        let daemonPathURL = relayDir.appendingPathComponent("64009.daemon_path")
        let ttyURL = relayDir.appendingPathComponent("64009.tty")

        XCTAssertNoThrow(try fileManager.createDirectory(at: relayDir, withIntermediateDirectories: true))
        XCTAssertNoThrow(try "127.0.0.1:64010".write(to: socketAddrURL, atomically: true, encoding: .utf8))
        XCTAssertNoThrow(try "auth".write(to: authURL, atomically: true, encoding: .utf8))
        XCTAssertNoThrow(try "daemon".write(to: daemonPathURL, atomically: true, encoding: .utf8))
        XCTAssertNoThrow(try "ttys002".write(to: ttyURL, atomically: true, encoding: .utf8))
        defer { try? fileManager.removeItem(at: home) }

        let result = runProcess(
            executablePath: "/usr/bin/env",
            arguments: [
                "HOME=\(home.path)",
                "/bin/sh",
                "-c",
                WorkspaceRemoteSessionController.remoteRelayMetadataCleanupScript(relayPort: 64009),
            ],
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(fileManager.fileExists(atPath: socketAddrURL.path))
        XCTAssertFalse(fileManager.fileExists(atPath: authURL.path))
        XCTAssertFalse(fileManager.fileExists(atPath: daemonPathURL.path))
        XCTAssertFalse(fileManager.fileExists(atPath: ttyURL.path))
    }

    func testRelayZshBootstrapUsesRealHomeHistoryByDefault() throws {
        let histfile = try runRelayZshHistfile { home in
            try ":\n".write(to: home.appendingPathComponent(".zshenv"), atomically: true, encoding: .utf8)
            try ":\n".write(to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
            return home
        }

        XCTAssertTrue(histfile.hasSuffix("/.zsh_history"))
    }

    func testRelayZshBootstrapUsesUserUpdatedZdotdirHistory() throws {
        let histfile = try runRelayZshHistfile { home in
            let altZdotdir = home.appendingPathComponent("dotfiles")
            try FileManager.default.createDirectory(at: altZdotdir, withIntermediateDirectories: true)
            try "export ZDOTDIR=\"$HOME/dotfiles\"\n".write(
                to: home.appendingPathComponent(".zshenv"),
                atomically: true,
                encoding: .utf8
            )
            try ":\n".write(to: altZdotdir.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
            return altZdotdir
        }

        XCTAssertTrue(histfile.contains("/dotfiles/.zsh_history"))
    }

    func testRemoteUTF8LocaleSetupLinesSeedUTF8LocaleWhenMissing() {
        let script = (RemoteShellEnvironment.utf8LocaleSetupLines() + [
            #"printf '%s' "${LANG}|${LC_CTYPE}|${LC_ALL}""#,
        ])
            .joined(separator: "\n")

        let result = runProcess(
            executablePath: "/usr/bin/env",
            arguments: [
                "LANG=",
                "LC_CTYPE=",
                "LC_ALL=",
                "/bin/sh",
                "-c",
                script,
            ],
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "C.UTF-8|C.UTF-8|C.UTF-8")
    }

    func testRemoteUTF8LocaleSetupLinesPreserveExistingUTF8Locale() {
        let script = (RemoteShellEnvironment.utf8LocaleSetupLines() + [
            #"printf '%s' "${LANG}|${LC_CTYPE}|${LC_ALL}""#,
        ])
            .joined(separator: "\n")

        let result = runProcess(
            executablePath: "/usr/bin/env",
            arguments: [
                "LANG=ja_JP.UTF-8",
                "LC_CTYPE=",
                "LC_ALL=",
                "/bin/sh",
                "-c",
                script,
            ],
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "ja_JP.UTF-8||")
    }

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

    func testExecutableSearchPathsIncludesHomebrewAndHomeFallbacks() {
        let paths = WorkspaceRemoteSessionController.executableSearchPaths(
            environment: [
                "HOME": "/Users/tester",
                "PATH": "/usr/bin:/bin",
            ],
            pathHelperOutput: "PATH=\"/opt/homebrew/bin:/usr/local/bin:/usr/bin\"; export PATH;\n"
        )

        XCTAssertEqual(
            paths,
            [
                "/usr/bin",
                "/bin",
                "/Users/tester/.local/bin",
                "/Users/tester/go/bin",
                "/Users/tester/bin",
                "/opt/homebrew/bin",
                "/usr/local/bin",
                "/opt/homebrew/sbin",
                "/usr/local/sbin",
                "/usr/sbin",
                "/sbin",
            ]
        )
    }

    func testParsePathHelperPathsExtractsPathEntries() {
        XCTAssertEqual(
            WorkspaceRemoteSessionController.parsePathHelperPaths(
                "PATH=\"/opt/homebrew/bin:/usr/local/bin:/usr/bin\"; export PATH;\n"
            ),
            [
                "/opt/homebrew/bin",
                "/usr/local/bin",
                "/usr/bin",
            ]
        )
    }

    func testParsePathHelperPathsIgnoresMANPATHAssignments() {
        XCTAssertEqual(
            WorkspaceRemoteSessionController.parsePathHelperPaths(
                """
                MANPATH="/opt/homebrew/share/man:/usr/share/man"; export MANPATH;
                PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin"; export PATH;
                """
            ),
            [
                "/opt/homebrew/bin",
                "/usr/local/bin",
                "/usr/bin",
            ]
        )
    }

    @MainActor
    func testRemoteTerminalSurfaceLookupTracksOnlyActiveSSHSurfaces() throws {
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

        let panelID = try XCTUnwrap(workspace.focusedTerminalPanel?.id)
        XCTAssertTrue(workspace.isRemoteTerminalSurface(panelID))

        workspace.markRemoteTerminalSessionEnded(surfaceId: panelID, relayPort: 64007)
        XCTAssertFalse(workspace.isRemoteTerminalSurface(panelID))
    }

    @MainActor
    func testForegroundSSHAuthReadyBeforeRemoteConfigureStartsDeferredConnect() {
        let workspace = Workspace()
        let config = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64029,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: "ssh cmux-macmini",
            foregroundAuthToken: "token-a"
        )

        workspace.notifyRemoteForegroundAuthenticationReady(token: "token-a")
        workspace.configureRemoteConnection(config, autoConnect: false)

        XCTAssertEqual(workspace.remoteConnectionState, .connecting)
        workspace.disconnectRemoteConnection(clearConfiguration: true)
    }

    @MainActor
    func testForegroundSSHAuthReadyReconnectsConfiguredDisconnectedRemoteWorkspace() {
        let workspace = Workspace()
        let config = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64030,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: "ssh cmux-macmini",
            foregroundAuthToken: "token-a"
        )

        workspace.configureRemoteConnection(config, autoConnect: false)
        XCTAssertEqual(workspace.remoteConnectionState, .disconnected)

        workspace.notifyRemoteForegroundAuthenticationReady(token: "token-a")

        XCTAssertEqual(workspace.remoteConnectionState, .connecting)
        workspace.disconnectRemoteConnection(clearConfiguration: true)
    }

    @MainActor
    func testForegroundSSHAuthReadyBufferedTokenDoesNotReconnectDifferentConfiguration() {
        let workspace = Workspace()
        let config = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64031,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: "ssh cmux-macmini",
            foregroundAuthToken: "token-b"
        )

        workspace.notifyRemoteForegroundAuthenticationReady(token: "token-a")
        workspace.configureRemoteConnection(config, autoConnect: false)

        XCTAssertEqual(workspace.remoteConnectionState, .disconnected)
    }

    @MainActor
    func testForegroundSSHAuthReadyIgnoresMismatchedConfiguredToken() {
        let workspace = Workspace()
        let config = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64032,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: "ssh cmux-macmini",
            foregroundAuthToken: "token-a"
        )

        workspace.configureRemoteConnection(config, autoConnect: false)
        workspace.notifyRemoteForegroundAuthenticationReady(token: "token-b")

        XCTAssertEqual(workspace.remoteConnectionState, .disconnected)
    }

    @MainActor
    func testRemoteTerminalSessionEndRequestsControlMasterCleanupWhenWorkspaceDemotes() throws {
        let workspace = Workspace()
        let config = WorkspaceRemoteConfiguration(
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
            relayPort: 64012,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: "ssh cmux-macmini"
        )
        let cleanupRequested = expectation(description: "control master cleanup requested")
        var capturedArguments: [String] = []

        Workspace.runSSHControlMasterCommandOverrideForTesting = { arguments in
            capturedArguments = arguments
            cleanupRequested.fulfill()
        }
        defer { Workspace.runSSHControlMasterCommandOverrideForTesting = nil }

        workspace.configureRemoteConnection(config, autoConnect: false)

        let panelID = try XCTUnwrap(workspace.focusedTerminalPanel?.id)
        workspace.markRemoteTerminalSessionEnded(surfaceId: panelID, relayPort: 64012)

        wait(for: [cleanupRequested], timeout: 1.0)

        XCTAssertFalse(workspace.isRemoteWorkspace)
        XCTAssertEqual(workspace.activeRemoteTerminalSessionCount, 0)
        XCTAssertEqual(
            capturedArguments,
            [
                "-o", "BatchMode=yes",
                "-o", "ControlMaster=no",
                "-p", "2222",
                "-i", "/Users/test/.ssh/id_ed25519",
                "-o", "ControlPath=/tmp/cmux-ssh-%C",
                "-o", "StrictHostKeyChecking=accept-new",
                "-O", "exit",
                "cmux-macmini",
            ]
        )
    }

    @MainActor
    func testTeardownRemoteConnectionRequestsControlMasterCleanupWhileStillConnecting() {
        let workspace = Workspace()
        let config = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: nil,
            identityFile: nil,
            sshOptions: [
                "ControlMaster=auto",
                "ControlPersist=600",
                "ControlPath=/tmp/cmux-ssh-%C",
            ],
            localProxyPort: nil,
            relayPort: 64014,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: "ssh cmux-macmini"
        )
        let cleanupRequested = expectation(description: "control master cleanup requested")
        var capturedArguments: [String] = []

        Workspace.runSSHControlMasterCommandOverrideForTesting = { arguments in
            capturedArguments = arguments
            cleanupRequested.fulfill()
        }
        defer { Workspace.runSSHControlMasterCommandOverrideForTesting = nil }

        workspace.configureRemoteConnection(config, autoConnect: false)
        workspace.applyRemoteConnectionStateUpdate(
            .connecting,
            detail: "Connecting to cmux-macmini",
            target: "cmux-macmini"
        )

        workspace.teardownRemoteConnection()

        wait(for: [cleanupRequested], timeout: 1.0)

        XCTAssertFalse(workspace.isRemoteWorkspace)
        XCTAssertEqual(
            capturedArguments,
            [
                "-o", "BatchMode=yes",
                "-o", "ControlMaster=no",
                "-o", "ControlPath=/tmp/cmux-ssh-%C",
                "-O", "exit",
                "cmux-macmini",
            ]
        )
    }

    @MainActor
    func testTeardownRemoteConnectionRequestsControlMasterCleanupWithoutExplicitControlPath() {
        let workspace = Workspace()
        let config = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64015,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: "ssh cmux-macmini"
        )
        let cleanupRequested = expectation(description: "control master cleanup requested")
        var capturedArguments: [String] = []

        Workspace.runSSHControlMasterCommandOverrideForTesting = { arguments in
            capturedArguments = arguments
            cleanupRequested.fulfill()
        }
        defer { Workspace.runSSHControlMasterCommandOverrideForTesting = nil }

        workspace.configureRemoteConnection(config, autoConnect: false)
        workspace.applyRemoteConnectionStateUpdate(
            .connecting,
            detail: "Connecting to cmux-macmini",
            target: "cmux-macmini"
        )

        workspace.teardownRemoteConnection()

        wait(for: [cleanupRequested], timeout: 1.0)

        XCTAssertFalse(workspace.isRemoteWorkspace)
        XCTAssertEqual(
            capturedArguments,
            [
                "-o", "BatchMode=yes",
                "-o", "ControlMaster=no",
                "-O", "exit",
                "cmux-macmini",
            ]
        )
    }

    @MainActor
    func testClosingRemoteWorkspaceRequestsControlMasterCleanup() throws {
        let manager = TabManager()
        let remainingWorkspace = try XCTUnwrap(manager.selectedWorkspace)
        let remoteWorkspace = manager.addWorkspace()
        let config = WorkspaceRemoteConfiguration(
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
            relayPort: 64018,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: "ssh cmux-macmini"
        )
        let cleanupRequested = expectation(description: "control master cleanup requested")
        var capturedArguments: [String] = []

        Workspace.runSSHControlMasterCommandOverrideForTesting = { arguments in
            capturedArguments = arguments
            cleanupRequested.fulfill()
        }
        defer { Workspace.runSSHControlMasterCommandOverrideForTesting = nil }

        remoteWorkspace.configureRemoteConnection(config, autoConnect: false)

        manager.closeWorkspace(remoteWorkspace)

        wait(for: [cleanupRequested], timeout: 1.0)

        XCTAssertEqual(manager.tabs.count, 1)
        XCTAssertEqual(manager.tabs.first?.id, remainingWorkspace.id)
        XCTAssertFalse(manager.tabs.contains(where: { $0.id == remoteWorkspace.id }))
        XCTAssertFalse(remoteWorkspace.isRemoteWorkspace)
        XCTAssertEqual(
            capturedArguments,
            [
                "-o", "BatchMode=yes",
                "-o", "ControlMaster=no",
                "-p", "2222",
                "-i", "/Users/test/.ssh/id_ed25519",
                "-o", "ControlPath=/tmp/cmux-ssh-%C",
                "-o", "StrictHostKeyChecking=accept-new",
                "-O", "exit",
                "cmux-macmini",
            ]
        )
    }

    @MainActor
    func testDetachLastRemoteSurfacePreservesRemoteSessionWithoutCleanup() throws {
        let workspace = Workspace()
        let config = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: nil,
            identityFile: nil,
            sshOptions: [
                "ControlMaster=auto",
                "ControlPersist=600",
                "ControlPath=/tmp/cmux-ssh-%C",
            ],
            localProxyPort: nil,
            relayPort: 64016,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: "ssh cmux-macmini"
        )
        let cleanupRequested = expectation(description: "control master cleanup requested")
        cleanupRequested.isInverted = true

        Workspace.runSSHControlMasterCommandOverrideForTesting = { _ in
            cleanupRequested.fulfill()
        }
        defer { Workspace.runSSHControlMasterCommandOverrideForTesting = nil }

        workspace.configureRemoteConnection(config, autoConnect: false)

        let paneID = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let panelID = try XCTUnwrap(workspace.focusedTerminalPanel?.id)
        let detached = try XCTUnwrap(workspace.detachSurface(panelId: panelID))

        wait(for: [cleanupRequested], timeout: 1.0)

        XCTAssertTrue(detached.isRemoteTerminal)
        XCTAssertTrue(workspace.isRemoteWorkspace)
        XCTAssertEqual(workspace.activeRemoteTerminalSessionCount, 0)

        let reattachedSurfaceID = workspace.attachDetachedSurface(detached, inPane: paneID, focus: false)

        XCTAssertNotNil(reattachedSurfaceID)
        XCTAssertTrue(workspace.isRemoteWorkspace)
        XCTAssertEqual(workspace.activeRemoteTerminalSessionCount, 1)
        XCTAssertTrue(workspace.isRemoteTerminalSurface(detached.panelId))
    }

    @MainActor
    func testClosingSourceWorkspaceAfterDetachingRemoteSurfaceSkipsControlMasterCleanup() throws {
        let manager = TabManager()
        let sourceWorkspace = try XCTUnwrap(manager.selectedWorkspace)
        let destinationWorkspace = manager.addWorkspace()
        let config = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: nil,
            identityFile: nil,
            sshOptions: [
                "ControlMaster=auto",
                "ControlPersist=600",
                "ControlPath=/tmp/cmux-ssh-%C",
            ],
            localProxyPort: nil,
            relayPort: 64017,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: "ssh cmux-macmini"
        )
        let cleanupRequested = expectation(description: "control master cleanup requested")
        cleanupRequested.isInverted = true

        Workspace.runSSHControlMasterCommandOverrideForTesting = { _ in
            cleanupRequested.fulfill()
        }
        defer { Workspace.runSSHControlMasterCommandOverrideForTesting = nil }

        sourceWorkspace.configureRemoteConnection(config, autoConnect: false)

        let panelID = try XCTUnwrap(sourceWorkspace.focusedTerminalPanel?.id)
        let detached = try XCTUnwrap(sourceWorkspace.detachSurface(panelId: panelID))
        let destinationPaneID = try XCTUnwrap(destinationWorkspace.bonsplitController.allPaneIds.first)

        let restoredPanelID = destinationWorkspace.attachDetachedSurface(
            detached,
            inPane: destinationPaneID,
            focus: false
        )

        XCTAssertNotNil(restoredPanelID)
        XCTAssertTrue(destinationWorkspace.panels.keys.contains(detached.panelId))
        XCTAssertTrue(sourceWorkspace.panels.isEmpty)

        manager.closeWorkspace(sourceWorkspace)

        wait(for: [cleanupRequested], timeout: 1.0)

        XCTAssertFalse(manager.tabs.contains(where: { $0.id == sourceWorkspace.id }))
        XCTAssertTrue(destinationWorkspace.panels.keys.contains(detached.panelId))
    }

    @MainActor
    func testClosingMixedSourceWorkspaceAfterDetachingLastRemoteSurfaceSkipsControlMasterCleanup() throws {
        let manager = TabManager()
        let sourceWorkspace = try XCTUnwrap(manager.selectedWorkspace)
        let destinationWorkspace = manager.addWorkspace()
        let sourcePaneID = try XCTUnwrap(sourceWorkspace.bonsplitController.allPaneIds.first)
        let config = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: nil,
            identityFile: nil,
            sshOptions: [
                "ControlMaster=auto",
                "ControlPersist=600",
                "ControlPath=/tmp/cmux-ssh-%C",
            ],
            localProxyPort: nil,
            relayPort: 64018,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: "ssh cmux-macmini"
        )
        let cleanupRequested = expectation(description: "control master cleanup requested")
        cleanupRequested.isInverted = true

        Workspace.runSSHControlMasterCommandOverrideForTesting = { _ in
            cleanupRequested.fulfill()
        }
        defer { Workspace.runSSHControlMasterCommandOverrideForTesting = nil }

        sourceWorkspace.configureRemoteConnection(config, autoConnect: false)
        _ = sourceWorkspace.newBrowserSurface(inPane: sourcePaneID, url: URL(string: "https://example.com"), focus: false)

        let panelID = try XCTUnwrap(sourceWorkspace.focusedTerminalPanel?.id)
        let detached = try XCTUnwrap(sourceWorkspace.detachSurface(panelId: panelID))
        let destinationPaneID = try XCTUnwrap(destinationWorkspace.bonsplitController.allPaneIds.first)

        let restoredPanelID = destinationWorkspace.attachDetachedSurface(
            detached,
            inPane: destinationPaneID,
            focus: false
        )

        XCTAssertNotNil(restoredPanelID)
        XCTAssertEqual(sourceWorkspace.panels.count, 1)
        XCTAssertTrue(destinationWorkspace.panels.keys.contains(detached.panelId))

        manager.closeWorkspace(sourceWorkspace)

        wait(for: [cleanupRequested], timeout: 1.0)

        XCTAssertFalse(manager.tabs.contains(where: { $0.id == sourceWorkspace.id }))
        XCTAssertTrue(destinationWorkspace.panels.keys.contains(detached.panelId))
    }

    @MainActor
    func testTransferredRemoteSurfaceCleansUpControlMasterWhenSessionEndsInLocalWorkspace() throws {
        let manager = TabManager()
        let sourceWorkspace = try XCTUnwrap(manager.selectedWorkspace)
        let destinationWorkspace = manager.addWorkspace()
        let config = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: nil,
            identityFile: nil,
            sshOptions: [
                "ControlMaster=auto",
                "ControlPersist=600",
                "ControlPath=/tmp/cmux-ssh-%C",
            ],
            localProxyPort: nil,
            relayPort: 64019,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: "ssh cmux-macmini"
        )
        let cleanupRequested = expectation(description: "control master cleanup requested")
        var cleanupArguments: [[String]] = []

        Workspace.runSSHControlMasterCommandOverrideForTesting = { arguments in
            cleanupArguments.append(arguments)
            cleanupRequested.fulfill()
        }
        defer { Workspace.runSSHControlMasterCommandOverrideForTesting = nil }

        sourceWorkspace.configureRemoteConnection(config, autoConnect: false)

        let panelID = try XCTUnwrap(sourceWorkspace.focusedTerminalPanel?.id)
        let detached = try XCTUnwrap(sourceWorkspace.detachSurface(panelId: panelID))
        let destinationPaneID = try XCTUnwrap(destinationWorkspace.bonsplitController.allPaneIds.first)

        let restoredPanelID = destinationWorkspace.attachDetachedSurface(
            detached,
            inPane: destinationPaneID,
            focus: false
        )

        XCTAssertNotNil(restoredPanelID)
        XCTAssertFalse(destinationWorkspace.isRemoteWorkspace)
        XCTAssertEqual(destinationWorkspace.activeRemoteTerminalSessionCount, 0)

        manager.closeWorkspace(sourceWorkspace)
        destinationWorkspace.markRemoteTerminalSessionEnded(surfaceId: detached.panelId, relayPort: config.relayPort)

        wait(for: [cleanupRequested], timeout: 1.0)

        XCTAssertEqual(cleanupArguments.count, 1)
        XCTAssertEqual(cleanupArguments.first?.suffix(2), ["exit", "cmux-macmini"])
    }

    @MainActor
    func testRemoteTerminalSessionEndSkipsControlMasterCleanupWhenBrowserPanelsKeepWorkspaceRemote() throws {
        let workspace = Workspace()
        let paneID = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let initialTerminalID = try XCTUnwrap(workspace.focusedTerminalPanel?.id)
        let config = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: nil,
            identityFile: nil,
            sshOptions: [
                "ControlMaster=auto",
                "ControlPersist=600",
                "ControlPath=/tmp/cmux-ssh-%C",
            ],
            localProxyPort: nil,
            relayPort: 64013,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: "ssh cmux-macmini"
        )
        let cleanupRequested = expectation(description: "control master cleanup requested")
        cleanupRequested.isInverted = true

        Workspace.runSSHControlMasterCommandOverrideForTesting = { _ in
            cleanupRequested.fulfill()
        }
        defer { Workspace.runSSHControlMasterCommandOverrideForTesting = nil }

        workspace.configureRemoteConnection(config, autoConnect: false)
        _ = workspace.newBrowserSurface(inPane: paneID, url: URL(string: "https://example.com"), focus: false)

        workspace.markRemoteTerminalSessionEnded(surfaceId: initialTerminalID, relayPort: 64013)

        wait(for: [cleanupRequested], timeout: 1.0)

        XCTAssertTrue(workspace.isRemoteWorkspace)
        XCTAssertEqual(workspace.activeRemoteTerminalSessionCount, 0)
    }

    func testRemoteDropPathUsesLowercasedExtensionAndProvidedUUID() throws {
        let fileURL = URL(fileURLWithPath: "/Users/test/Screen Shot.PNG")
        let uuid = try XCTUnwrap(UUID(uuidString: "12345678-1234-1234-1234-1234567890AB"))

        let remotePath = WorkspaceRemoteSessionController.remoteDropPath(for: fileURL, uuid: uuid)

        XCTAssertEqual(remotePath, "/tmp/cmux-drop-12345678-1234-1234-1234-1234567890ab.png")
    }

    @MainActor
    func testDetachAttachPreservesRemoteTerminalSurfaceTracking() throws {
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

        let originalPanelID = try XCTUnwrap(workspace.focusedTerminalPanel?.id)
        let originalPaneID = try XCTUnwrap(workspace.paneId(forPanelId: originalPanelID))
        let movedPanel = try XCTUnwrap(
            workspace.newTerminalSplit(from: originalPanelID, orientation: .horizontal)
        )

        XCTAssertTrue(workspace.isRemoteTerminalSurface(originalPanelID))
        XCTAssertTrue(workspace.isRemoteTerminalSurface(movedPanel.id))

        let detached = try XCTUnwrap(workspace.detachSurface(panelId: movedPanel.id))
        XCTAssertTrue(detached.isRemoteTerminal)
        XCTAssertEqual(detached.remoteRelayPort, config.relayPort)

        let restoredPanelID = workspace.attachDetachedSurface(
            detached,
            inPane: originalPaneID,
            focus: false
        )

        XCTAssertEqual(restoredPanelID, movedPanel.id)
        XCTAssertTrue(workspace.isRemoteTerminalSurface(movedPanel.id))
    }

    @MainActor
    func testDetachAttachPreservesSurfaceTTYMetadata() throws {
        let source = Workspace()
        let destination = Workspace()

        let panelID = try XCTUnwrap(source.focusedTerminalPanel?.id)
        let sourcePaneID = try XCTUnwrap(source.paneId(forPanelId: panelID))
        let destinationPaneID = try XCTUnwrap(destination.bonsplitController.allPaneIds.first)
        source.surfaceTTYNames[panelID] = "/dev/ttys004"

        let detached = try XCTUnwrap(source.detachSurface(panelId: panelID))
        XCTAssertEqual(source.surfaceTTYNames[panelID], nil)

        let restoredPanelID = destination.attachDetachedSurface(
            detached,
            inPane: destinationPaneID,
            focus: false
        )

        XCTAssertEqual(restoredPanelID, panelID)
        XCTAssertEqual(destination.surfaceTTYNames[panelID], "/dev/ttys004")
        XCTAssertEqual(source.bonsplitController.tabs(inPane: sourcePaneID).count, 0)
    }

    func testDetectedSSHUploadFailureCleansUpEarlierRemoteUploads() throws {
        let fileManager = FileManager.default
        let directoryURL = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-detected-ssh-upload-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directoryURL) }

        let firstFileURL = directoryURL.appendingPathComponent("first.png")
        let secondFileURL = directoryURL.appendingPathComponent("second.png")
        try Data("first".utf8).write(to: firstFileURL)
        try Data("second".utf8).write(to: secondFileURL)

        let session = DetectedSSHSession(
            destination: "lawrence@example.com",
            port: 2200,
            identityFile: "/Users/test/.ssh/id_ed25519",
            configFile: nil,
            jumpHost: nil,
            controlPath: nil,
            useIPv4: false,
            useIPv6: false,
            forwardAgent: false,
            compressionEnabled: false,
            sshOptions: []
        )

        var invocations: [(executable: String, arguments: [String])] = []
        var scpInvocationCount = 0
        DetectedSSHSession.runProcessOverrideForTesting = { executable, arguments, _, _ in
            invocations.append((executable, arguments))
            if executable == "/usr/bin/scp" {
                scpInvocationCount += 1
                if scpInvocationCount == 1 {
                    return (status: 0, stdout: "", stderr: "")
                }
                return (status: 1, stdout: "", stderr: "copy failed")
            }
            if executable == "/usr/bin/ssh" {
                return (status: 0, stdout: "", stderr: "")
            }
            XCTFail("unexpected executable \(executable)")
            return (status: 1, stdout: "", stderr: "unexpected executable")
        }
        defer { DetectedSSHSession.runProcessOverrideForTesting = nil }

        XCTAssertThrowsError(
            try session.uploadDroppedFilesSyncForTesting([firstFileURL, secondFileURL])
        )

        let firstSCPDestination = try XCTUnwrap(
            invocations
                .first(where: { $0.executable == "/usr/bin/scp" })?
                .arguments
                .last
        )
        let uploadedRemotePath = try XCTUnwrap(firstSCPDestination.split(separator: ":", maxSplits: 1).last)
        let cleanupInvocation = try XCTUnwrap(
            invocations.first(where: { $0.executable == "/usr/bin/ssh" })
        )
        let cleanupCommand = cleanupInvocation.arguments.joined(separator: " ")

        XCTAssertTrue(cleanupCommand.contains(String(uploadedRemotePath)))
    }

    func testDetectsForegroundSSHSessionForTTY() {
        let session = TerminalSSHSessionDetector.detectForTesting(
            ttyName: "/dev/ttys004",
            processes: [
                .init(pid: 2145, pgid: 1967, tpgid: 1967, tty: "ttys004", executableName: "ssh"),
            ],
            argumentsByPID: [
                2145: [
                    "ssh",
                    "-o", "ControlMaster=auto",
                    "-o", "ControlPath=/tmp/cmux-ssh-%C",
                    "-o", "StrictHostKeyChecking=accept-new",
                    "-p", "2200",
                    "-i", "/Users/test/.ssh/id_ed25519",
                    "lawrence@example.com",
                ],
            ]
        )

        XCTAssertEqual(
            session,
            DetectedSSHSession(
                destination: "lawrence@example.com",
                port: 2200,
                identityFile: "/Users/test/.ssh/id_ed25519",
                configFile: nil,
                jumpHost: nil,
                controlPath: "/tmp/cmux-ssh-%C",
                useIPv4: false,
                useIPv6: false,
                forwardAgent: false,
                compressionEnabled: false,
                sshOptions: [
                    "StrictHostKeyChecking=accept-new",
                ]
            )
        )
    }

    func testDetectsForegroundSSHSessionWithShortControlPathFlag() {
        let session = TerminalSSHSessionDetector.detectForTesting(
            ttyName: "/dev/ttys004",
            processes: [
                .init(pid: 2145, pgid: 1967, tpgid: 1967, tty: "ttys004", executableName: "ssh"),
            ],
            argumentsByPID: [
                2145: [
                    "ssh",
                    "-S", "/tmp/cmux-ssh-%C",
                    "-p", "2200",
                    "lawrence@example.com",
                ],
            ]
        )

        XCTAssertEqual(session?.controlPath, "/tmp/cmux-ssh-%C")
        let scpArgs = session?.scpArgumentsForTesting(
            localPath: "/tmp/local.png",
            remotePath: "/tmp/cmux-drop-123.png"
        ) ?? []
        XCTAssertTrue(scpArgs.contains("ControlPath=/tmp/cmux-ssh-%C"))
        XCTAssertFalse(scpArgs.contains("-S"))
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

    func testDetectedSSHSessionBracketsIPv6LiteralSCPDestination() {
        let session = DetectedSSHSession(
            destination: "lawrence@2001:db8::1",
            port: nil,
            identityFile: nil,
            configFile: nil,
            jumpHost: nil,
            controlPath: nil,
            useIPv4: false,
            useIPv6: false,
            forwardAgent: false,
            compressionEnabled: false,
            sshOptions: []
        )

        let scpArgs = session.scpArgumentsForTesting(
            localPath: "/tmp/local.png",
            remotePath: "/tmp/cmux-drop-123.png"
        )

        XCTAssertEqual(scpArgs.last, "lawrence@[2001:db8::1]:/tmp/cmux-drop-123.png")
    }

    func testDetectsForegroundSSHSessionWithLowercaseAgentFlag() {
        let session = TerminalSSHSessionDetector.detectForTesting(
            ttyName: "/dev/ttys004",
            processes: [
                .init(pid: 2145, pgid: 1967, tpgid: 1967, tty: "ttys004", executableName: "ssh"),
            ],
            argumentsByPID: [
                2145: [
                    "ssh",
                    "-a",
                    "lawrence@example.com",
                ],
            ]
        )

        XCTAssertEqual(session?.destination, "lawrence@example.com")
        XCTAssertFalse(session?.forwardAgent ?? true)
    }

    func testDetectsForegroundSSHSessionIgnoringBindInterfaceValue() {
        let session = TerminalSSHSessionDetector.detectForTesting(
            ttyName: "/dev/ttys004",
            processes: [
                .init(pid: 2145, pgid: 1967, tpgid: 1967, tty: "ttys004", executableName: "ssh"),
            ],
            argumentsByPID: [
                2145: [
                    "ssh",
                    "-B", "en0",
                    "lawrence@example.com",
                ],
            ]
        )

        XCTAssertEqual(session?.destination, "lawrence@example.com")
    }

    func testIgnoresBackgroundSSHProcessForTTY() {
        let session = TerminalSSHSessionDetector.detectForTesting(
            ttyName: "ttys004",
            processes: [
                .init(pid: 2145, pgid: 2145, tpgid: 1967, tty: "ttys004", executableName: "ssh"),
            ],
            argumentsByPID: [
                2145: ["ssh", "lawrence@example.com"],
            ]
        )

        XCTAssertNil(session)
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

final class CLINotifyProcessIntegrationTests: XCTestCase {
    private struct ProcessRunResult {
        let status: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
    }

    private final class MockSocketServerState: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var commands: [String] = []

        func append(_ command: String) {
            lock.lock()
            commands.append(command)
            lock.unlock()
        }
    }

    private func makeSocketPath(_ name: String) -> String {
        let shortID = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cli-\(name.prefix(6))-\(shortID).sock")
            .path
    }

    private func waitForProcess(_ process: Process, toHoldOpenFile path: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var consecutiveHits = 0
        while Date() < deadline {
            guard process.isRunning else { return false }
            let result = runProcess(
                executablePath: "/usr/sbin/lsof",
                arguments: ["-n", "-p", "\(process.processIdentifier)", "-Fn"],
                environment: ProcessInfo.processInfo.environment,
                timeout: 1
            )
            if result.status == 0, result.stdout.contains(path) {
                consecutiveHits += 1
                if consecutiveHits >= 2 {
                    return true
                }
            } else {
                consecutiveHits = 0
            }
            _ = DispatchSemaphore(value: 0).wait(timeout: .now() + 0.05)
        }
        return false
    }

    private func bundledCLIPath() throws -> String {
        let fileManager = FileManager.default
        let appBundleURL = Bundle(for: Self.self)
            .bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let enumerator = fileManager.enumerator(
            at: appBundleURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        while let item = enumerator?.nextObject() as? URL {
            guard item.lastPathComponent == "cmux",
                  item.path.contains(".app/Contents/Resources/bin/cmux") else {
                continue
            }
            return item.path
        }

        throw XCTSkip("Bundled cmux CLI not found in \(appBundleURL.path)")
    }

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
        process.environment = environment
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

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return ProcessRunResult(
            status: process.terminationStatus,
            stdout: stdout,
            stderr: stderr,
            timedOut: timedOut
        )
    }

    func testAgentHookLaunchEnvironmentDoesNotPersistPathOrShell() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("hook")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-hook-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            return self.v2Response(
                id: line,
                ok: false,
                error: ["code": "unexpected", "message": "Unexpected command \(line)"]
            )
        }

        var environment = ProcessInfo.processInfo.environment
        for key in [
            "ANTHROPIC_MODEL",
            "CLAUDE_CONFIG_DIR",
            "CMUX_CUSTOM_CLAUDE_PATH",
            "NODE_OPTIONS",
            "OPENCODE_CONFIG_DIR"
        ] {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_AGENT_LAUNCH_KIND"] = "codex"
        environment["CMUX_AGENT_LAUNCH_EXECUTABLE"] = "/usr/local/bin/codex"
        environment["CMUX_AGENT_LAUNCH_ARGV_B64"] = base64NULSeparated([
            "/usr/local/bin/codex",
            "--model",
            "gpt-5.4",
            "old prompt"
        ])
        environment["CMUX_AGENT_LAUNCH_CWD"] = "/tmp/repo"
        environment["CODEX_HOME"] = "/tmp/codex home"
        environment["PATH"] = "/tmp/custom-bin:/usr/bin"
        environment["SHELL"] = "/bin/zsh"
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "session-start"],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "{}\n")

        let storeURL = root.appendingPathComponent("codex-hook-sessions.json", isDirectory: false)
        let data = try Data(contentsOf: storeURL)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data, options: []) as? [String: Any])
        let sessions = try XCTUnwrap(json["sessions"] as? [String: Any])
        let session = try XCTUnwrap(sessions[surfaceId] as? [String: Any])
        let launchCommand = try XCTUnwrap(session["launchCommand"] as? [String: Any])
        let persistedEnvironment = try XCTUnwrap(launchCommand["environment"] as? [String: String])
        XCTAssertEqual(persistedEnvironment, ["CODEX_HOME": "/tmp/codex home"])
    }

    func testCodexHookStopSetsRateLimitStatusFromTranscript() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("codex")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-hook-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-session-error"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        let transcriptDirectory = try codexSessionDirectory(in: codexHome)
        let transcriptURL = transcriptDirectory.appendingPathComponent("rollout-\(sessionId).jsonl")
        try """
        {"timestamp":"2026-04-25T07:55:29.462Z","type":"session_meta","payload":{"id":"\(sessionId)","cwd":"\(root.path)"}}
        {"timestamp":"2026-04-25T07:55:29.799Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"credits":{"has_credits":false,"unlimited":false,"balance":"0"}}}}
        {"timestamp":"2026-04-25T07:55:29.803Z","type":"event_msg","payload":{"type":"error","message":"You've hit your usage limit. Visit https://chatgpt.com/codex/settings/usage to purchase more credits or try again at 4:05 AM.","codex_error_info":"usage_limit_exceeded"}}
        {"timestamp":"2026-04-25T07:55:29.804Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-1","last_agent_message":null}}
        """.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            if let data = line.data(using: .utf8),
               let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let id = payload["id"] as? String {
                return self.v2Response(id: id, ok: true, result: [:])
            }
            return "OK"
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CODEX_HOME"] = codexHome.path

        let hookInput = """
        {"session_id":"\(sessionId)","turn_id":"turn-1","cwd":"\(root.path)","hook_event_name":"Stop","model":"gpt-5.5","permission_mode":"default","stop_hook_active":false,"last_assistant_message":null}
        """
        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "stop"],
            environment: environment,
            standardInput: hookInput,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "{}\n")
        XCTAssertTrue(
            state.commands.contains { command in
                command.contains("notify_target \(workspaceId) \(surfaceId) Codex|Rate limit|")
            },
            "Expected Codex failure notification, saw \(state.commands)"
        )
        XCTAssertTrue(
            state.commands.contains { command in
                command.contains("set_status codex Codex rate limit") &&
                    command.contains("--icon=exclamationmark.triangle.fill") &&
                    command.contains("--color=#FF453A") &&
                    command.contains("--priority=100") &&
                    command.contains("--tab=\(workspaceId)")
            },
            "Expected high-priority Codex rate limit status, saw \(state.commands)"
        )
    }

    func testCodexHookStopTreatsTypedCodexErrorEventAsFailure() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("codex")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-hook-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-session-typed-error"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let transcriptURL = root.appendingPathComponent("rollout-\(sessionId).jsonl")
        try """
        {"timestamp":"2026-04-25T07:55:29.462Z","type":"session_meta","payload":{"id":"\(sessionId)","cwd":"\(root.path)"}}
        {"timestamp":"2026-04-25T07:55:29.803Z","type":"event_msg","payload":{"type":"error","message":"Try again later.","codex_error_info":"server_overloaded"}}
        {"timestamp":"2026-04-25T07:55:29.804Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-3","last_agent_message":null}}
        """.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            if let data = line.data(using: .utf8),
               let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let id = payload["id"] as? String {
                return self.v2Response(id: id, ok: true, result: [:])
            }
            return "OK"
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let hookInput = """
        {"session_id":"\(sessionId)","turn_id":"turn-3","transcript_path":"\(transcriptURL.path)","cwd":"\(root.path)","hook_event_name":"Stop","model":"gpt-5.5","permission_mode":"default","stop_hook_active":false,"last_assistant_message":null}
        """
        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "stop"],
            environment: environment,
            standardInput: hookInput,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "{}\n")
        XCTAssertTrue(
            state.commands.contains { command in
                command.contains("notify_target \(workspaceId) \(surfaceId) Codex|Error|Try again later.")
            },
            "Expected typed Codex error notification, saw \(state.commands)"
        )
        XCTAssertTrue(
            state.commands.contains { command in
                command.contains("set_status codex Codex error") &&
                    command.contains("--icon=exclamationmark.triangle.fill") &&
                    command.contains("--color=#FF453A") &&
                    command.contains("--priority=100") &&
                    command.contains("--tab=\(workspaceId)")
            },
            "Expected high-priority Codex error status, saw \(state.commands)"
        )
    }

    func testCodexHookStopFallsBackToDiscoveredTranscriptWhenProvidedPathUnavailable() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("codex")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-hook-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-session-stale-provided-path"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        let transcriptDirectory = try codexSessionDirectory(in: codexHome)
        let discoveredTranscriptURL = transcriptDirectory.appendingPathComponent("rollout-\(sessionId).jsonl")
        try """
        {"timestamp":"2026-04-25T07:55:29.462Z","type":"session_meta","payload":{"id":"\(sessionId)","cwd":"\(root.path)"}}
        {"timestamp":"2026-04-25T07:55:29.803Z","type":"event_msg","payload":{"type":"error","turn_id":"turn-stale-path","message":"Stream disconnected before completion.","codex_error_info":"response_stream_disconnected"}}
        {"timestamp":"2026-04-25T07:55:29.804Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-stale-path","last_agent_message":null}}
        """.write(to: discoveredTranscriptURL, atomically: true, encoding: .utf8)

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            if let data = line.data(using: .utf8),
               let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let id = payload["id"] as? String {
                return self.v2Response(id: id, ok: true, result: [:])
            }
            return "OK"
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CODEX_HOME"] = codexHome.path

        let unavailableTranscriptURL = root.appendingPathComponent("missing-\(sessionId).jsonl")
        let hookInput = """
        {"session_id":"\(sessionId)","turn_id":"turn-stale-path","transcript_path":"\(unavailableTranscriptURL.path)","cwd":"\(root.path)","hook_event_name":"Stop","model":"gpt-5.5","permission_mode":"default","stop_hook_active":false,"last_assistant_message":null}
        """
        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "stop"],
            environment: environment,
            standardInput: hookInput,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "{}\n")
        XCTAssertTrue(
            state.commands.contains { command in
                command.contains("notify_target \(workspaceId) \(surfaceId) Codex|Network error|Stream disconnected before completion.")
            },
            "Expected discovered transcript failure notification, saw \(state.commands)"
        )
        XCTAssertTrue(
            state.commands.contains { command in
                command.contains("set_status codex Codex network error") &&
                    command.contains("--icon=exclamationmark.triangle.fill") &&
                    command.contains("--color=#FF453A") &&
                    command.contains("--priority=100") &&
                    command.contains("--tab=\(workspaceId)")
            },
            "Expected discovered transcript failure status, saw \(state.commands)"
        )
    }

    func testCodexHookStopTreatsCodexErrorInfoPayloadAsFailure() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("codex")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-hook-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-session-payload-error"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            if let data = line.data(using: .utf8),
               let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let id = payload["id"] as? String {
                return self.v2Response(id: id, ok: true, result: [:])
            }
            return "OK"
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let hookInput = """
        {"session_id":"\(sessionId)","turn_id":"turn-4","cwd":"\(root.path)","hook_event_name":"Stop","model":"gpt-5.5","permission_mode":"default","stop_hook_active":false,"last_assistant_message":null,"message":"Try again later.","codex_error_info":"server_overloaded"}
        """
        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "stop"],
            environment: environment,
            standardInput: hookInput,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "{}\n")
        XCTAssertTrue(
            state.commands.contains { command in
                command.contains("set_status codex Codex error") &&
                    command.contains("--icon=exclamationmark.triangle.fill") &&
                    command.contains("--color=#FF453A") &&
                    command.contains("--priority=100") &&
                    command.contains("--tab=\(workspaceId)")
            },
            "Expected high-priority Codex error status from codex_error_info, saw \(state.commands)"
        )
    }

    func testCodexHookStopTreatsStructuredCodexErrorInfoPayloadAsFailure() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("codex")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-hook-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-session-structured-error"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            if let data = line.data(using: .utf8),
               let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let id = payload["id"] as? String {
                return self.v2Response(id: id, ok: true, result: [:])
            }
            return "OK"
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let hookInput = """
        {"session_id":"\(sessionId)","turn_id":"turn-structured","cwd":"\(root.path)","hook_event_name":"Stop","model":"gpt-5.5","permission_mode":"default","stop_hook_active":false,"last_assistant_message":null,"message":"Try again later.","codex_error_info":{"code":"server_overloaded","retryable":true}}
        """
        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "stop"],
            environment: environment,
            standardInput: hookInput,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "{}\n")
        XCTAssertTrue(
            state.commands.contains { command in
                command.contains("set_status codex Codex error") &&
                    command.contains("--icon=exclamationmark.triangle.fill") &&
                    command.contains("--color=#FF453A") &&
                    command.contains("--priority=100") &&
                    command.contains("--tab=\(workspaceId)")
            },
            "Expected structured codex_error_info to publish high-priority Codex error status, saw \(state.commands)"
        )
    }

    func testCodexHookStopTreatsCamelCaseCodexErrorInfoPayloadAsFailure() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("codex")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-hook-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-session-camel-error"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            if let data = line.data(using: .utf8),
               let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let id = payload["id"] as? String {
                return self.v2Response(id: id, ok: true, result: [:])
            }
            return "OK"
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let hookInput = """
        {"session_id":"\(sessionId)","turn_id":"turn-5","cwd":"\(root.path)","hook_event_name":"Stop","model":"gpt-5.5","permission_mode":"default","stop_hook_active":false,"last_assistant_message":null,"message":"Try again later.","codexErrorInfo":"server_overloaded"}
        """
        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "stop"],
            environment: environment,
            standardInput: hookInput,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "{}\n")
        XCTAssertTrue(
            state.commands.contains { command in
                command.contains("set_status codex Codex error") &&
                    command.contains("--icon=exclamationmark.triangle.fill") &&
                    command.contains("--color=#FF453A") &&
                    command.contains("--priority=100") &&
                    command.contains("--tab=\(workspaceId)")
            },
            "Expected high-priority Codex error status from camelCase codexErrorInfo, saw \(state.commands)"
        )
    }

    func testCodexHookStopTreatsTypedHookPayloadAsFailure() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("codex")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-hook-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-session-hook-type-error"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            if let data = line.data(using: .utf8),
               let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let id = payload["id"] as? String {
                return self.v2Response(id: id, ok: true, result: [:])
            }
            return "OK"
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let hookInput = """
        {"session_id":"\(sessionId)","turn_id":"turn-6","cwd":"\(root.path)","hook_event_name":"Stop","model":"gpt-5.5","permission_mode":"default","stop_hook_active":false,"last_assistant_message":null,"type":"error","message":"Try again later."}
        """
        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "stop"],
            environment: environment,
            standardInput: hookInput,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "{}\n")
        XCTAssertTrue(
            state.commands.contains { command in
                command.contains("set_status codex Codex error") &&
                    command.contains("--icon=exclamationmark.triangle.fill") &&
                    command.contains("--color=#FF453A") &&
                    command.contains("--priority=100") &&
                    command.contains("--tab=\(workspaceId)")
            },
            "Expected typed hook payload to publish high-priority Codex error status, saw \(state.commands)"
        )
    }

    func testCodexHookStopTreatsExplicitErrorFieldAsFailureSignal() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("codex")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-hook-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-session-explicit-error-field"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            if let data = line.data(using: .utf8),
               let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let id = payload["id"] as? String {
                return self.v2Response(id: id, ok: true, result: [:])
            }
            return "OK"
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let hookInput = """
        {"session_id":"\(sessionId)","turn_id":"turn-explicit-error","cwd":"\(root.path)","hook_event_name":"Stop","model":"gpt-5.5","permission_mode":"default","stop_hook_active":false,"last_assistant_message":null,"error":"quota exceeded"}
        """
        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "stop"],
            environment: environment,
            standardInput: hookInput,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "{}\n")
        XCTAssertTrue(
            state.commands.contains { command in
                command.contains("notify_target \(workspaceId) \(surfaceId) Codex|Error|quota exceeded")
            },
            "Expected explicit error field notification, saw \(state.commands)"
        )
        XCTAssertTrue(
            state.commands.contains { command in
                command.contains("set_status codex Codex error") &&
                    command.contains("--icon=exclamationmark.triangle.fill") &&
                    command.contains("--color=#FF453A") &&
                    command.contains("--priority=100") &&
                    command.contains("--tab=\(workspaceId)")
            },
            "Expected explicit error field status, saw \(state.commands)"
        )
    }

    func testCodexHookStopDoesNotKeepOldTranscriptErrorAfterSuccessfulTurn() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("codex")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-hook-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-session-success"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let transcriptURL = root.appendingPathComponent("rollout-\(sessionId).jsonl")
        try """
        {"timestamp":"2026-04-25T07:55:29.462Z","type":"session_meta","payload":{"id":"\(sessionId)","cwd":"\(root.path)"}}
        {"timestamp":"2026-04-25T07:55:29.803Z","type":"event_msg","payload":{"type":"error","message":"You've hit your usage limit.","codex_error_info":"usage_limit_exceeded"}}
        {"timestamp":"2026-04-25T07:56:00.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Done"}],"phase":"final_answer"}}
        {"timestamp":"2026-04-25T07:56:00.100Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-2","last_agent_message":"Done"}}
        """.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            if let data = line.data(using: .utf8),
               let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let id = payload["id"] as? String {
                return self.v2Response(id: id, ok: true, result: [:])
            }
            return "OK"
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let hookInput = """
        {"session_id":"\(sessionId)","turn_id":"turn-2","transcript_path":"\(transcriptURL.path)","cwd":"\(root.path)","hook_event_name":"Stop","model":"gpt-5.5","permission_mode":"default","stop_hook_active":false,"last_assistant_message":"Done"}
        """
        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "stop"],
            environment: environment,
            standardInput: hookInput,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "{}\n")
        XCTAssertTrue(
            state.commands.contains { command in
                command.contains("set_status codex Idle") &&
                    command.contains("--icon=pause.circle.fill") &&
                    command.contains("--tab=\(workspaceId)")
            },
            "Expected successful Codex turn to report Idle, saw \(state.commands)"
        )
        XCTAssertFalse(
            state.commands.contains { $0.contains("set_status codex Codex rate limit") || $0.contains("#FF453A") },
            "Did not expect stale transcript error status, saw \(state.commands)"
        )
        XCTAssertFalse(
            state.commands.contains { command in
                command.contains("notify_target") &&
                    (command.contains("Rate limit") || command.contains("Error") || command.contains("#FF453A"))
            },
            "Did not expect stale failure notification, saw \(state.commands)"
        )
    }

    func testCodexHookStopPrefersExplicitErrorPayloadOverHealthyTranscript() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("codex")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-hook-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-session-payload-beats-transcript"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let transcriptURL = root.appendingPathComponent("rollout-\(sessionId).jsonl")
        try """
        {"timestamp":"2026-04-25T07:55:29.462Z","type":"session_meta","payload":{"id":"\(sessionId)","cwd":"\(root.path)"}}
        {"timestamp":"2026-04-25T07:56:00.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Done"}],"phase":"final_answer"}}
        {"timestamp":"2026-04-25T07:56:00.100Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-payload-error","last_agent_message":"Done"}}
        """.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            if let data = line.data(using: .utf8),
               let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let id = payload["id"] as? String {
                return self.v2Response(id: id, ok: true, result: [:])
            }
            return "OK"
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let hookInput = """
        {"session_id":"\(sessionId)","turn_id":"turn-payload-error","transcript_path":"\(transcriptURL.path)","cwd":"\(root.path)","hook_event_name":"Stop","model":"gpt-5.5","permission_mode":"default","stop_hook_active":false,"last_assistant_message":"Partial answer","type":"error","message":"Try again later."}
        """
        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "stop"],
            environment: environment,
            standardInput: hookInput,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "{}\n")
        XCTAssertTrue(
            state.commands.contains { command in
                command.contains("notify_target \(workspaceId) \(surfaceId) Codex|Error|Try again later.")
            },
            "Expected payload error notification to beat healthy transcript, saw \(state.commands)"
        )
        XCTAssertTrue(
            state.commands.contains { command in
                command.contains("set_status codex Codex error") &&
                    command.contains("--icon=exclamationmark.triangle.fill") &&
                    command.contains("--color=#FF453A") &&
                    command.contains("--priority=100") &&
                    command.contains("--tab=\(workspaceId)")
            },
            "Expected payload error status to beat healthy transcript, saw \(state.commands)"
        )
    }

    func testCodexHookStopTreatsCompletedTurnWithoutAssistantAsFailure() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("codex")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-hook-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-session-no-final"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let transcriptURL = root.appendingPathComponent("rollout-\(sessionId).jsonl")
        try """
        {"timestamp":"2026-04-25T07:55:29.462Z","type":"session_meta","payload":{"id":"\(sessionId)","cwd":"\(root.path)"}}
        {"timestamp":"2026-04-25T07:55:29.600Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Previous turn completed."}]}}
        {"timestamp":"2026-04-25T07:55:29.804Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-no-final","last_agent_message":null}}
        """.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            if let data = line.data(using: .utf8),
               let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let id = payload["id"] as? String {
                return self.v2Response(id: id, ok: true, result: [:])
            }
            return "OK"
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let hookInput = """
        {"session_id":"\(sessionId)","turn_id":"turn-no-final","transcript_path":"\(transcriptURL.path)","cwd":"\(root.path)","hook_event_name":"Stop","model":"gpt-5.5","permission_mode":"default","stop_hook_active":false,"last_assistant_message":null}
        """
        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "stop"],
            environment: environment,
            standardInput: hookInput,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "{}\n")
        XCTAssertTrue(
            state.commands.contains { command in
                command.contains("notify_target \(workspaceId) \(surfaceId) Codex|Error|Codex ended before sending a final response")
            },
            "Expected no-final-response notification, saw \(state.commands)"
        )
        XCTAssertTrue(
            state.commands.contains { command in
                command.contains("set_status codex Codex error") &&
                    command.contains("--icon=exclamationmark.triangle.fill") &&
                    command.contains("--color=#FF453A") &&
                    command.contains("--priority=100") &&
                    command.contains("--tab=\(workspaceId)")
            },
            "Expected high-priority Codex error status, saw \(state.commands)"
        )
    }

    func testCodexHookStopDoesNotSynthesizeNoFinalResponseAfterScopedAssistantMessage() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("codex")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-hook-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-session-scoped-assistant"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let transcriptURL = root.appendingPathComponent("rollout-\(sessionId).jsonl")
        try """
        {"timestamp":"2026-04-25T07:55:29.462Z","type":"session_meta","payload":{"id":"\(sessionId)","cwd":"\(root.path)"}}
        {"timestamp":"2026-04-25T07:55:29.500Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-scoped-assistant","started_at":1777107522}}
        {"timestamp":"2026-04-25T07:55:29.600Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Done"}]}}
        {"timestamp":"2026-04-25T07:55:29.804Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-scoped-assistant","last_agent_message":null}}
        """.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            if let data = line.data(using: .utf8),
               let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let id = payload["id"] as? String {
                return self.v2Response(id: id, ok: true, result: [:])
            }
            return "OK"
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let hookInput = """
        {"session_id":"\(sessionId)","turn_id":"turn-scoped-assistant","transcript_path":"\(transcriptURL.path)","cwd":"\(root.path)","hook_event_name":"Stop","model":"gpt-5.5","permission_mode":"default","stop_hook_active":false,"last_assistant_message":null}
        """
        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "stop"],
            environment: environment,
            standardInput: hookInput,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "{}\n")
        XCTAssertTrue(
            state.commands.contains { command in
                command.contains("set_status codex Idle") &&
                    command.contains("--tab=\(workspaceId)")
            },
            "Expected scoped assistant reply to suppress no-final-response error, saw \(state.commands)"
        )
        XCTAssertFalse(
            state.commands.contains { command in
                command.contains("Codex ended before sending a final response") || command.contains("--color=#FF453A")
            },
            "Did not expect no-final-response error after scoped assistant reply, saw \(state.commands)"
        )
    }

    func testCodexHookStopIgnoresUnscopedTranscriptErrorWithoutTurnEvidence() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("codex")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-hook-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-session-stale-unscoped-error"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let transcriptURL = root.appendingPathComponent("rollout-\(sessionId).jsonl")
        try """
        {"timestamp":"2026-04-25T07:55:29.462Z","type":"session_meta","payload":{"id":"\(sessionId)","cwd":"\(root.path)"}}
        {"timestamp":"2026-04-25T07:55:29.803Z","type":"event_msg","payload":{"type":"error","message":"Stream disconnected before completion.","codex_error_info":"response_stream_disconnected"}}
        """.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            if let data = line.data(using: .utf8),
               let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let id = payload["id"] as? String {
                return self.v2Response(id: id, ok: true, result: [:])
            }
            return "OK"
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let hookInput = """
        {"session_id":"\(sessionId)","turn_id":"turn-current","transcript_path":"\(transcriptURL.path)","cwd":"\(root.path)","hook_event_name":"Stop","model":"gpt-5.5","permission_mode":"default","stop_hook_active":false,"last_assistant_message":null}
        """
        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "stop"],
            environment: environment,
            standardInput: hookInput,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "{}\n")
        XCTAssertTrue(
            state.commands.contains { command in
                command.contains("set_status codex Idle") &&
                    command.contains("--tab=\(workspaceId)")
            },
            "Expected stale unscoped error to leave Codex idle, saw \(state.commands)"
        )
        XCTAssertFalse(
            state.commands.contains { command in
                command.contains("set_status codex Codex network error") || command.contains("--color=#FF453A")
            },
            "Did not expect stale unscoped error status, saw \(state.commands)"
        )
    }

    func testCodexHookMonitorSetsErrorStatusFromCompletedTranscriptWithoutAssistant() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("codex")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-monitor-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-session-monitor-no-final"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let transcriptURL = root.appendingPathComponent("rollout-\(sessionId).jsonl")
        try """
        {"timestamp":"2026-04-25T07:55:29.462Z","type":"session_meta","payload":{"id":"\(sessionId)","cwd":"\(root.path)"}}
        {"timestamp":"2026-04-25T07:55:29.600Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Previous turn completed."}]}}
        {"timestamp":"2026-04-25T07:55:29.804Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-monitor","last_agent_message":null}}
        """.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            if let data = line.data(using: .utf8),
               let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let id = payload["id"] as? String {
                return self.v2Response(id: id, ok: true, result: [:])
            }
            return "OK"
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "hooks", "codex", "monitor",
                "--workspace",
                workspaceId,
                "--surface",
                surfaceId,
                "--session",
                sessionId,
                "--turn",
                "turn-monitor",
                "--transcript",
                transcriptURL.path,
            ],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "")
        XCTAssertTrue(
            state.commands.contains { command in
                command.contains("notify_target \(workspaceId) \(surfaceId) Codex|Error|Codex ended before sending a final response")
            },
            "Expected monitor to send no-final-response notification, saw \(state.commands)"
        )
        XCTAssertTrue(
            state.commands.contains { command in
                command.contains("set_status codex Codex error") &&
                    command.contains("--icon=exclamationmark.triangle.fill") &&
                    command.contains("--color=#FF453A") &&
                    command.contains("--priority=100") &&
                    command.contains("--tab=\(workspaceId)")
            },
            "Expected monitor to publish high-priority Codex error status, saw \(state.commands)"
        )
    }

    func testCodexHookMonitorReportsExplicitErrorBeforeTerminalCompletion() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("codex")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-monitor-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-session-monitor-stream-error"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let transcriptURL = root.appendingPathComponent("rollout-\(sessionId).jsonl")
        try """
        {"timestamp":"2026-04-25T07:55:29.462Z","type":"session_meta","payload":{"id":"\(sessionId)","cwd":"\(root.path)"}}
        {"timestamp":"2026-04-25T07:55:29.500Z","type":"event_msg","payload":{"type":"task_started","turnId":"turn-monitor-stream-error","started_at":1777107522}}
        {"timestamp":"2026-04-25T07:55:29.803Z","type":"event_msg","payload":{"type":"error","message":"Stream disconnected before completion.","codex_error_info":"response_stream_disconnected"}}
        """.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            if let data = line.data(using: .utf8),
               let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let id = payload["id"] as? String {
                return self.v2Response(id: id, ok: true, result: [:])
            }
            return "OK"
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "hooks", "codex", "monitor",
                "--workspace",
                workspaceId,
                "--surface",
                surfaceId,
                "--session",
                sessionId,
                "--turn",
                "turn-monitor-stream-error",
                "--transcript",
                transcriptURL.path,
            ],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "")
        XCTAssertTrue(
            state.commands.contains { command in
                command.contains("notify_target \(workspaceId) \(surfaceId) Codex|Network error|Stream disconnected before completion.")
            },
            "Expected monitor to send stream error notification before terminal completion, saw \(state.commands)"
        )
        XCTAssertTrue(
            state.commands.contains { command in
                command.contains("set_status codex Codex network error") &&
                    command.contains("--icon=exclamationmark.triangle.fill") &&
                    command.contains("--color=#FF453A") &&
                    command.contains("--priority=100") &&
                    command.contains("--tab=\(workspaceId)")
            },
            "Expected monitor to publish high-priority Codex network error status, saw \(state.commands)"
        )
    }

    func testCodexHookMonitorReResolvesUnavailableTranscriptPath() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("codex")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-monitor-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-session-monitor-reresolve"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        let transcriptDirectory = try codexSessionDirectory(in: codexHome)
        let staleTranscriptURL = root.appendingPathComponent("missing-rollout-\(sessionId).jsonl")
        let transcriptURL = transcriptDirectory.appendingPathComponent("rollout-\(sessionId).jsonl")
        try """
        {"timestamp":"2026-04-25T07:55:29.462Z","type":"session_meta","payload":{"id":"\(sessionId)","cwd":"\(root.path)"}}
        {"timestamp":"2026-04-25T07:55:29.500Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-monitor-reresolve","started_at":1777107522}}
        {"timestamp":"2026-04-25T07:55:29.804Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-monitor-reresolve","last_agent_message":null}}
        """.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            if let data = line.data(using: .utf8),
               let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let id = payload["id"] as? String {
                return self.v2Response(id: id, ok: true, result: [:])
            }
            return "OK"
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CODEX_HOME"] = codexHome.path

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "hooks", "codex", "monitor",
                "--workspace",
                workspaceId,
                "--surface",
                surfaceId,
                "--session",
                sessionId,
                "--turn",
                "turn-monitor-reresolve",
                "--transcript",
                staleTranscriptURL.path,
            ],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "")
        XCTAssertTrue(
            state.commands.contains { command in
                command.contains("notify_target \(workspaceId) \(surfaceId) Codex|Error|Codex ended before sending a final response")
            },
            "Expected monitor to recover from stale transcript path, saw \(state.commands)"
        )
        XCTAssertTrue(
            state.commands.contains { command in
                command.contains("set_status codex Codex error") &&
                    command.contains("--icon=exclamationmark.triangle.fill") &&
                    command.contains("--color=#FF453A") &&
                    command.contains("--priority=100") &&
                    command.contains("--tab=\(workspaceId)")
            },
            "Expected monitor to publish high-priority Codex error status after re-resolving transcript path, saw \(state.commands)"
        )
    }

    func testCodexHookMonitorIgnoresUnscopedTerminalForTurnScopedMonitor() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("codex")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-monitor-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-session-monitor-turn-scoped"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let transcriptURL = root.appendingPathComponent("rollout-\(sessionId).jsonl")
        try """
        {"timestamp":"2026-04-25T07:55:29.462Z","type":"session_meta","payload":{"id":"\(sessionId)","cwd":"\(root.path)"}}
        {"timestamp":"2026-04-25T07:55:29.804Z","type":"event_msg","payload":{"type":"task_complete","last_agent_message":"Old unscoped turn completed."}}
        """.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let serverHandled = startMockServerSignal(listenerFD: listenerFD, state: state) { line in
            if let data = line.data(using: .utf8),
               let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let id = payload["id"] as? String {
                return self.v2Response(id: id, ok: true, result: [:])
            }
            return "OK"
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = [
            "hooks", "codex", "monitor",
            "--workspace",
            workspaceId,
            "--surface",
            surfaceId,
            "--session",
            sessionId,
            "--turn",
            "turn-monitor-scoped",
            "--transcript",
            transcriptURL.path,
        ]
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
            }
        }

        let exitSignal = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            exitSignal.signal()
        }

        XCTAssertTrue(
            waitForProcess(process, toHoldOpenFile: transcriptURL.path, timeout: 2),
            "Monitor did not start watching the initial transcript before scoped append"
        )
        XCTAssertTrue(process.isRunning, "Monitor exited on an unscoped terminal event before the scoped turn wrote an error")

        let appendHandle = try FileHandle(forWritingTo: transcriptURL)
        try appendHandle.seekToEnd()
        appendHandle.write(Data("\n".utf8))
        appendHandle.write(Data("""
        {"timestamp":"2026-04-25T07:55:30.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-monitor-scoped","started_at":1777107530}}
        {"timestamp":"2026-04-25T07:55:30.100Z","type":"event_msg","payload":{"type":"error","message":"Stream disconnected before completion.","codex_error_info":"response_stream_disconnected"}}
        """.utf8))
        try appendHandle.close()

        let serverTimedOut = serverHandled.wait(timeout: .now() + 5) == .timedOut
        let timedOut = exitSignal.wait(timeout: .now() + 5) == .timedOut
        if timedOut {
            process.terminate()
            _ = exitSignal.wait(timeout: .now() + 1)
        }
        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertFalse(serverTimedOut, "Timed out waiting for mock socket command. stderr: \(stderr)")
        XCTAssertFalse(timedOut, stderr)
        XCTAssertEqual(process.terminationStatus, 0, stderr)
        XCTAssertEqual(stdout, "")
        XCTAssertTrue(
            state.commands.contains { command in
                command.contains("notify_target \(workspaceId) \(surfaceId) Codex|Network error|Stream disconnected before completion.")
            },
            "Expected monitor to ignore old unscoped terminal event and report scoped stream error, saw \(state.commands)"
        )
        XCTAssertTrue(
            state.commands.contains { command in
                command.contains("set_status codex Codex network error") &&
                    command.contains("--icon=exclamationmark.triangle.fill") &&
                    command.contains("--color=#FF453A") &&
                    command.contains("--priority=100") &&
                    command.contains("--tab=\(workspaceId)")
            },
            "Expected monitor to publish scoped Codex network error status, saw \(state.commands)"
        )
    }

    private func codexSessionDirectory(in codexHome: URL, date: Date = Date()) throws -> URL {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let year = try XCTUnwrap(components.year)
        let month = try XCTUnwrap(components.month)
        let day = try XCTUnwrap(components.day)
        let directory = codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(String(format: "%04d", year), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", month), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", day), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func base64NULSeparated(_ values: [String]) -> String {
        var data = Data()
        for value in values {
            data.append(contentsOf: value.utf8)
            data.append(0)
        }
        return data.base64EncodedString()
    }

    private func bindUnixSocket(at path: String) throws -> Int32 {
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "Failed to create Unix socket"]
            )
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxPathLength = MemoryLayout.size(ofValue: addr.sun_path)
        path.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let pathBuf = UnsafeMutableRawPointer(pathPtr).assumingMemoryBound(to: CChar.self)
                strncpy(pathBuf, ptr, maxPathLength - 1)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let code = Int(errno)
            Darwin.close(fd)
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: code,
                userInfo: [NSLocalizedDescriptionKey: "Failed to bind Unix socket"]
            )
        }

        guard Darwin.listen(fd, 1) == 0 else {
            let code = Int(errno)
            Darwin.close(fd)
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: code,
                userInfo: [NSLocalizedDescriptionKey: "Failed to listen on Unix socket"]
            )
        }

        return fd
    }

    private func startMockServer(
        listenerFD: Int32,
        state: MockSocketServerState,
        handler: @escaping @Sendable (String) -> String
    ) -> XCTestExpectation {
        let handled = expectation(description: "cli mock socket handled")
        runMockServer(listenerFD: listenerFD, state: state, onHandled: {
            handled.fulfill()
        }, handler: handler)
        return handled
    }

    private func startMockServerSignal(
        listenerFD: Int32,
        state: MockSocketServerState,
        handler: @escaping @Sendable (String) -> String
    ) -> DispatchSemaphore {
        let handled = DispatchSemaphore(value: 0)
        runMockServer(listenerFD: listenerFD, state: state, onHandled: {
            handled.signal()
        }, handler: handler)
        return handled
    }

    private func runMockServer(
        listenerFD: Int32,
        state: MockSocketServerState,
        onHandled: @escaping @Sendable () -> Void,
        handler: @escaping @Sendable (String) -> String
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            var clientAddr = sockaddr_un()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    Darwin.accept(listenerFD, sockaddrPtr, &clientAddrLen)
                }
            }
            guard clientFD >= 0 else {
                onHandled()
                return
            }
            defer {
                Darwin.close(clientFD)
                onHandled()
            }

            var pending = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)

            while true {
                let count = Darwin.read(clientFD, &buffer, buffer.count)
                if count < 0 {
                    if errno == EINTR { continue }
                    return
                }
                if count == 0 { return }
                pending.append(buffer, count: count)

                while let newlineRange = pending.firstRange(of: Data([0x0A])) {
                    let lineData = pending.subdata(in: 0..<newlineRange.lowerBound)
                    pending.removeSubrange(0...newlineRange.lowerBound)
                    guard let line = String(data: lineData, encoding: .utf8) else { continue }
                    state.append(line)
                    let response = handler(line) + "\n"
                    _ = response.withCString { ptr in
                        Darwin.write(clientFD, ptr, strlen(ptr))
                    }
                }
            }
        }
    }

    private func v2Response(
        id: String,
        ok: Bool,
        result: [String: Any]? = nil,
        error: [String: Any]? = nil
    ) -> String {
        var payload: [String: Any] = ["id": id, "ok": ok]
        if let result {
            payload["result"] = result
        }
        if let error {
            payload["error"] = error
        }
        let data = try? JSONSerialization.data(withJSONObject: payload, options: [])
        return String(data: data ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
    }

    @MainActor
    func testNotifyWithWorkspaceHandleKeepsCallerSurfaceFallback() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("notify")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let currentWorkspace = "11111111-1111-1111-1111-111111111111"
        let currentSurface = "22222222-2222-2222-2222-222222222222"
        let staleSurface = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            if let data = line.data(using: .utf8),
               let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let id = payload["id"] as? String,
               let method = payload["method"] as? String {
                if method == "workspace.list" { return self.v2Response(id: id, ok: true, result: ["workspaces": [["id": currentWorkspace, "index": 1]]]) }
                if method == "notification.create_for_caller" {
                    let params = payload["params"] as? [String: Any] ?? [:]
                    XCTAssertEqual(params["preferred_workspace_id"] as? String, currentWorkspace)
                    XCTAssertEqual(params["preferred_surface_id"] as? String, staleSurface)
                    XCTAssertEqual(params["prefer_tty"] as? Bool, false)
                    return self.v2Response(
                        id: id,
                        ok: true,
                        result: ["workspace_id": currentWorkspace, "surface_id": currentSurface]
                    )
                }
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected", "message": "Unexpected method \(method)"]
                )
            }

            return "ERROR: Unexpected command \(line)"
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
        environment["CMUX_SURFACE_ID"] = staleSurface
        environment["TMUX"] = "/tmp/tmux-current,123,0"
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["notify", "--workspace", "1"],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "OK\n")
        XCTAssertTrue(result.stderr.isEmpty, result.stderr)
        XCTAssertTrue(
            state.commands.contains { $0.contains("\"method\":\"notification.create_for_caller\"") },
            "Expected notify to use single-call caller notification path, saw \(state.commands)"
        )
    }

    @MainActor
    func testNotifyWithWorkspaceHandlePreservesSyncTargetValidation() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("notify-handle")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let staleSurface = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            if let data = line.data(using: .utf8),
               let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let id = payload["id"] as? String,
               let method = payload["method"] as? String {
                switch method {
                case "workspace.list":
                    return self.v2Response(
                        id: id,
                        ok: true,
                        result: [
                            "workspaces": [
                                ["id": workspaceId, "index": 1]
                            ]
                        ]
                    )
                default:
                    return self.v2Response(
                        id: id,
                        ok: false,
                        error: ["code": "unexpected", "message": "Unexpected method \(method)"]
                    )
                }
            }

            if line.hasPrefix("notify_target \(workspaceId) \(staleSurface) ") {
                return "ERROR: Panel not found"
            }
            if line.hasPrefix("notify_target_async ") {
                return "OK"
            }
            return "ERROR: Unexpected command \(line)"
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["notify", "--workspace", "1", "--surface", staleSurface, "--title", "Mixed"],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("ERROR: Panel not found"), result.stderr)
        XCTAssertTrue(
            state.commands.contains { $0.hasPrefix("notify_target \(workspaceId) \(staleSurface) ") },
            "Expected notify to use synchronous target validation, saw \(state.commands)"
        )
        XCTAssertFalse(
            state.commands.contains { $0.hasPrefix("notify_target_async ") },
            "Expected no async target dispatch for mixed handles, saw \(state.commands)"
        )
    }

    @MainActor
    func testTriggerFlashFallsBackFromStaleCallerWorkspaceAndSurfaceIDs() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("flash")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let currentWorkspace = "11111111-1111-1111-1111-111111111111"
        let currentSurface = "22222222-2222-2222-2222-222222222222"
        let staleWorkspace = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
        let staleSurface = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let data = line.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.v2Response(
                    id: "unknown",
                    ok: false,
                    error: ["code": "unexpected", "message": "Unexpected payload"]
                )
            }

            let params = payload["params"] as? [String: Any] ?? [:]
            switch method {
            case "surface.list":
                let workspaceId = params["workspace_id"] as? String
                if workspaceId == staleWorkspace {
                    return self.v2Response(
                        id: id,
                        ok: false,
                        error: ["code": "not_found", "message": "Workspace not found"]
                    )
                }
                if workspaceId == currentWorkspace {
                    return self.v2Response(
                        id: id,
                        ok: true,
                        result: [
                            "surfaces": [
                                [
                                    "id": currentSurface,
                                    "ref": "surface:1",
                                    "index": 0,
                                    "focused": true
                                ]
                            ]
                        ]
                    )
                }
            case "workspace.current":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: ["workspace_id": currentWorkspace]
                )
            case "surface.trigger_flash":
                let workspaceId = params["workspace_id"] as? String
                let surfaceId = params["surface_id"] as? String
                if workspaceId == currentWorkspace, surfaceId == currentSurface {
                    return self.v2Response(id: id, ok: true, result: [:])
                }
            default:
                break
            }

            return self.v2Response(
                id: id,
                ok: false,
                error: ["code": "unexpected", "message": "Unexpected method \(method)"]
            )
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = staleWorkspace
        environment["CMUX_SURFACE_ID"] = staleSurface
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["trigger-flash"],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "OK\n")
        XCTAssertTrue(result.stderr.isEmpty, result.stderr)
        XCTAssertTrue(
            state.commands.contains { command in
                guard let data = command.data(using: .utf8),
                      let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                      let method = payload["method"] as? String,
                      method == "surface.trigger_flash" else {
                    return false
                }
                let params = payload["params"] as? [String: Any] ?? [:]
                return (params["workspace_id"] as? String) == currentWorkspace
                    && (params["surface_id"] as? String) == currentSurface
            },
            "Expected surface.trigger_flash to use current workspace and surface, saw \(state.commands)"
        )
    }

    @MainActor
    func testSSHCommandCreatesConfiguresAndSelectsRemoteWorkspaceViaCLI() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("ssh")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let workspaceID = "11111111-1111-1111-1111-111111111111"
        let workspaceRef = "workspace:7"
        let windowID = "22222222-2222-2222-2222-222222222222"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let data = line.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.v2Response(
                    id: "unknown",
                    ok: false,
                    error: ["code": "unexpected", "message": "Unexpected payload"]
                )
            }

            switch method {
            case "workspace.create":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "workspace_id": workspaceID,
                        "window_id": windowID,
                    ]
                )
            case "workspace.rename":
                return self.v2Response(id: id, ok: true, result: ["workspace_id": workspaceID])
            case "workspace.remote.configure":
                let params = payload["params"] as? [String: Any] ?? [:]
                let autoConnect = (params["auto_connect"] as? Bool) ?? true
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "workspace_id": workspaceID,
                        "workspace_ref": workspaceRef,
                        "remote": [
                            "enabled": true,
                            "state": autoConnect ? "connecting" : "disconnected",
                        ],
                    ]
                )
            case "workspace.select":
                return self.v2Response(id: id, ok: true, result: ["workspace_id": workspaceID])
            default:
                return self.v2Response(
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

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "ssh",
                "--name", "SSH Workspace",
                "--port", "2222",
                "--identity", "/Users/test/.ssh/id_ed25519",
                "--ssh-option", "ControlPath /tmp/cmux-ssh-%C",
                "--ssh-option", "StrictHostKeyChecking=accept-new",
                "cmux-macmini",
            ],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "OK workspace=\(workspaceRef) target=cmux-macmini state=disconnected\n")
        XCTAssertTrue(result.stderr.isEmpty, result.stderr)

        let requests = try state.commands.map { line -> [String: Any] in
            let data = try XCTUnwrap(line.data(using: .utf8))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data, options: []) as? [String: Any])
        }
        XCTAssertEqual(
            requests.compactMap { $0["method"] as? String },
            ["workspace.create", "workspace.rename", "workspace.remote.configure", "workspace.select"]
        )

        let createParams = try XCTUnwrap(requests[0]["params"] as? [String: Any])
        let initialCommand = try XCTUnwrap(createParams["initial_command"] as? String)
        XCTAssertFalse(initialCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        let renameParams = try XCTUnwrap(requests[1]["params"] as? [String: Any])
        XCTAssertEqual(renameParams["workspace_id"] as? String, workspaceID)
        XCTAssertEqual(renameParams["title"] as? String, "SSH Workspace")

        let configureParams = try XCTUnwrap(requests[2]["params"] as? [String: Any])
        XCTAssertEqual(configureParams["workspace_id"] as? String, workspaceID)
        XCTAssertEqual(configureParams["destination"] as? String, "cmux-macmini")
        XCTAssertEqual(configureParams["port"] as? Int, 2222)
        XCTAssertEqual(configureParams["identity_file"] as? String, "/Users/test/.ssh/id_ed25519")
        XCTAssertEqual(configureParams["local_socket_path"] as? String, socketPath)
        XCTAssertEqual(configureParams["auto_connect"] as? Bool, false)
        let relayPort = try XCTUnwrap(configureParams["relay_port"] as? Int)
        XCTAssertGreaterThan(relayPort, 0)
        let relayID = try XCTUnwrap(configureParams["relay_id"] as? String)
        XCTAssertFalse(relayID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let relayToken = try XCTUnwrap(configureParams["relay_token"] as? String)
        XCTAssertEqual(relayToken.count, 64)
        let foregroundAuthToken = try XCTUnwrap(configureParams["foreground_auth_token"] as? String)
        XCTAssertFalse(foregroundAuthToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let terminalStartupCommand = try XCTUnwrap(configureParams["terminal_startup_command"] as? String)
        XCTAssertFalse(terminalStartupCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let sshOptions = try XCTUnwrap(configureParams["ssh_options"] as? [String])
        XCTAssertTrue(sshOptions.contains("ControlMaster=auto"))
        XCTAssertTrue(sshOptions.contains("ControlPersist=600"))
        XCTAssertTrue(sshOptions.contains("ControlPath /tmp/cmux-ssh-%C"))
        XCTAssertTrue(sshOptions.contains("StrictHostKeyChecking=accept-new"))

        // `cmux ssh` should land the user in the new SSH workspace immediately.
        let selectParams = try XCTUnwrap(requests[3]["params"] as? [String: Any])
        XCTAssertEqual(selectParams["workspace_id"] as? String, workspaceID)
        XCTAssertEqual(selectParams["window_id"] as? String, windowID)
    }

    @MainActor
    func testSSHCommandDoesNotDeferReconnectWhenWhitespaceControlMasterDisablesMultiplexing() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("ssh-controlmaster-no")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let workspaceID = "11111111-1111-1111-1111-111111111111"
        let workspaceRef = "workspace:9"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let data = line.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.v2Response(
                    id: "unknown",
                    ok: false,
                    error: ["code": "unexpected", "message": "Unexpected payload"]
                )
            }

            switch method {
            case "workspace.create":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "workspace_id": workspaceID,
                    ]
                )
            case "workspace.remote.configure":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "workspace_id": workspaceID,
                        "workspace_ref": workspaceRef,
                        "remote": [
                            "enabled": true,
                            "state": "connecting",
                        ],
                    ]
                )
            default:
                return self.v2Response(
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

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "ssh",
                "--no-focus",
                "--port", "2222",
                "--ssh-option", "ControlMaster no",
                "--ssh-option", "ControlPath /tmp/cmux-ssh-%C",
                "cmux-macmini",
            ],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "OK workspace=\(workspaceRef) target=cmux-macmini state=connecting\n")
        XCTAssertTrue(result.stderr.isEmpty, result.stderr)

        let requests = try state.commands.map { line -> [String: Any] in
            let data = try XCTUnwrap(line.data(using: .utf8))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data, options: []) as? [String: Any])
        }
        XCTAssertEqual(
            requests.compactMap { $0["method"] as? String },
            ["workspace.create", "workspace.remote.configure"]
        )

        let configureParams = try XCTUnwrap(requests[1]["params"] as? [String: Any])
        XCTAssertEqual(configureParams["auto_connect"] as? Bool, true)
        XCTAssertNil(configureParams["foreground_auth_token"])
        let sshOptions = try XCTUnwrap(configureParams["ssh_options"] as? [String])
        XCTAssertTrue(sshOptions.contains("ControlMaster no"))
        XCTAssertTrue(sshOptions.contains("ControlPath /tmp/cmux-ssh-%C"))
    }

    @MainActor
    func testNotifyPrefersCallerTTYOverFocusedSurfaceWhenCallerIDsAreStale() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("notify-tty")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let callerTTY = "/dev/ttys777"
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let callerSurface = "22222222-2222-2222-2222-222222222222"
        let focusedSurface = "33333333-3333-3333-3333-333333333333"
        let staleWorkspace = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
        let staleSurface = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let data = line.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return "ERROR: Unexpected command \(line)"
            }

            let params = payload["params"] as? [String: Any] ?? [:]
            switch method {
            case "notification.create_for_caller":
                XCTAssertEqual(params["preferred_workspace_id"] as? String, staleWorkspace)
                XCTAssertEqual(params["preferred_surface_id"] as? String, staleSurface)
                XCTAssertEqual(params["caller_tty"] as? String, "ttys777")
                XCTAssertEqual(params["prefer_tty"] as? Bool, false)
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: ["workspace_id": workspaceId, "surface_id": callerSurface]
                )
            default:
                break
            }

            return self.v2Response(
                id: id,
                ok: false,
                error: ["code": "unexpected", "message": "Unexpected method \(method)"]
            )
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = staleWorkspace
        environment["CMUX_SURFACE_ID"] = staleSurface
        environment["CMUX_CLI_TTY_NAME"] = callerTTY
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["notify"],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "OK\n")
        XCTAssertTrue(result.stderr.isEmpty, result.stderr)
        XCTAssertTrue(
            state.commands.contains { $0.contains("\"method\":\"notification.create_for_caller\"") },
            "Expected notify to use single-call caller notification path, saw \(state.commands)"
        )
    }

    @MainActor
    func testNotifyInTmuxPrefersCallerTTYOverStaleValidSurfaceID() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("notify-tmux-tty")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let callerTTY = "/dev/ttys777"
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let callerSurface = "22222222-2222-2222-2222-222222222222"
        let staleSurface = "33333333-3333-3333-3333-333333333333"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let data = line.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return "ERROR: Unexpected command \(line)"
            }

            let params = payload["params"] as? [String: Any] ?? [:]
            switch method {
            case "notification.create_for_caller":
                XCTAssertEqual(params["preferred_workspace_id"] as? String, workspaceId)
                XCTAssertEqual(params["preferred_surface_id"] as? String, staleSurface)
                XCTAssertEqual(params["caller_tty"] as? String, "ttys777")
                XCTAssertEqual(params["prefer_tty"] as? Bool, true)
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: ["workspace_id": workspaceId, "surface_id": callerSurface]
                )
            default:
                break
            }

            return self.v2Response(
                id: id,
                ok: false,
                error: ["code": "unexpected", "message": "Unexpected method \(method)"]
            )
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = staleSurface
        environment["CMUX_CLI_TTY_NAME"] = callerTTY
        environment["TMUX"] = "/tmp/tmux-current,123,0"
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["notify"],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "OK\n")
        XCTAssertTrue(result.stderr.isEmpty, result.stderr)
        XCTAssertTrue(
            state.commands.contains { $0.contains("\"method\":\"notification.create_for_caller\"") },
            "Expected notify to use single-call caller notification path in tmux, saw \(state.commands)"
        )
    }

    @MainActor
    func testTriggerFlashPrefersCallerTTYOverFocusedSurfaceWhenCallerIDsAreStale() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("flash-tty")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let callerTTY = "/dev/ttys777"
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let callerSurface = "22222222-2222-2222-2222-222222222222"
        let focusedSurface = "33333333-3333-3333-3333-333333333333"
        let staleWorkspace = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
        let staleSurface = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let data = line.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.v2Response(
                    id: "unknown",
                    ok: false,
                    error: ["code": "unexpected", "message": "Unexpected payload"]
                )
            }

            let params = payload["params"] as? [String: Any] ?? [:]
            switch method {
            case "surface.list":
                let requestedWorkspace = params["workspace_id"] as? String
                if requestedWorkspace == staleWorkspace {
                    return self.v2Response(
                        id: id,
                        ok: false,
                        error: ["code": "not_found", "message": "Workspace not found"]
                    )
                }
                if requestedWorkspace == workspaceId {
                    return self.v2Response(
                        id: id,
                        ok: true,
                        result: [
                            "surfaces": [
                                [
                                    "id": callerSurface,
                                    "ref": "surface:1",
                                    "index": 0,
                                    "focused": false
                                ],
                                [
                                    "id": focusedSurface,
                                    "ref": "surface:2",
                                    "index": 1,
                                    "focused": true
                                ]
                            ]
                        ]
                    )
                }
            case "workspace.current":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: ["workspace_id": workspaceId]
                )
            case "debug.terminals":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "count": 2,
                        "terminals": [
                            [
                                "workspace_id": workspaceId,
                                "surface_id": callerSurface,
                                "tty": callerTTY
                            ],
                            [
                                "workspace_id": workspaceId,
                                "surface_id": focusedSurface,
                                "tty": "/dev/ttys778"
                            ]
                        ]
                    ]
                )
            case "surface.trigger_flash":
                let requestedWorkspace = params["workspace_id"] as? String
                let requestedSurface = params["surface_id"] as? String
                if requestedWorkspace == workspaceId, requestedSurface == callerSurface {
                    return self.v2Response(id: id, ok: true, result: [:])
                }
            default:
                break
            }

            return self.v2Response(
                id: id,
                ok: false,
                error: ["code": "unexpected", "message": "Unexpected method \(method)"]
            )
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = staleWorkspace
        environment["CMUX_SURFACE_ID"] = staleSurface
        environment["CMUX_CLI_TTY_NAME"] = callerTTY
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["trigger-flash"],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "OK\n")
        XCTAssertTrue(result.stderr.isEmpty, result.stderr)
        XCTAssertTrue(
            state.commands.contains { command in
                guard let data = command.data(using: .utf8),
                      let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                      let method = payload["method"] as? String,
                      method == "surface.trigger_flash" else {
                    return false
                }
                let params = payload["params"] as? [String: Any] ?? [:]
                return (params["workspace_id"] as? String) == workspaceId
                    && (params["surface_id"] as? String) == callerSurface
            },
            "Expected surface.trigger_flash to use caller tty surface, saw \(state.commands)"
        )
        XCTAssertFalse(
            state.commands.contains { command in
                guard let data = command.data(using: .utf8),
                      let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                      let method = payload["method"] as? String,
                      method == "surface.trigger_flash" else {
                    return false
                }
                let params = payload["params"] as? [String: Any] ?? [:]
                return (params["workspace_id"] as? String) == workspaceId
                    && (params["surface_id"] as? String) == focusedSurface
            },
            "Focused surface should not win over caller tty, saw \(state.commands)"
        )
    }

    @MainActor
    func testTriggerFlashInTmuxPrefersCallerTTYOverStaleValidSurfaceID() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("flash-tmux-tty")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let callerTTY = "/dev/ttys777"
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let callerSurface = "22222222-2222-2222-2222-222222222222"
        let staleSurface = "33333333-3333-3333-3333-333333333333"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let data = line.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.v2Response(
                    id: "unknown",
                    ok: false,
                    error: ["code": "unexpected", "message": "Unexpected payload"]
                )
            }

            let params = payload["params"] as? [String: Any] ?? [:]
            switch method {
            case "surface.list":
                let requestedWorkspace = params["workspace_id"] as? String
                if requestedWorkspace == workspaceId {
                    return self.v2Response(
                        id: id,
                        ok: true,
                        result: [
                            "surfaces": [
                                [
                                    "id": callerSurface,
                                    "ref": "surface:1",
                                    "index": 0,
                                    "focused": false
                                ],
                                [
                                    "id": staleSurface,
                                    "ref": "surface:2",
                                    "index": 1,
                                    "focused": true
                                ]
                            ]
                        ]
                    )
                }
            case "debug.terminals":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "count": 2,
                        "terminals": [
                            [
                                "workspace_id": workspaceId,
                                "surface_id": callerSurface,
                                "tty": callerTTY
                            ],
                            [
                                "workspace_id": workspaceId,
                                "surface_id": staleSurface,
                                "tty": "/dev/ttys778"
                            ]
                        ]
                    ]
                )
            case "surface.trigger_flash":
                let requestedWorkspace = params["workspace_id"] as? String
                let requestedSurface = params["surface_id"] as? String
                if requestedWorkspace == workspaceId,
                   (requestedSurface == callerSurface || requestedSurface == staleSurface) {
                    return self.v2Response(id: id, ok: true, result: [:])
                }
            default:
                break
            }

            return self.v2Response(
                id: id,
                ok: false,
                error: ["code": "unexpected", "message": "Unexpected method \(method)"]
            )
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = staleSurface
        environment["CMUX_CLI_TTY_NAME"] = callerTTY
        environment["TMUX"] = "/tmp/tmux-current,123,0"
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["trigger-flash"],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "OK\n")
        XCTAssertTrue(result.stderr.isEmpty, result.stderr)
        XCTAssertTrue(
            state.commands.contains { command in
                guard let data = command.data(using: .utf8),
                      let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                      let method = payload["method"] as? String,
                      method == "surface.trigger_flash" else {
                    return false
                }
                let params = payload["params"] as? [String: Any] ?? [:]
                return (params["workspace_id"] as? String) == workspaceId
                    && (params["surface_id"] as? String) == callerSurface
            },
            "Expected trigger-flash to use caller tty surface in tmux, saw \(state.commands)"
        )
        XCTAssertFalse(
            state.commands.contains { command in
                guard let data = command.data(using: .utf8),
                      let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                      let method = payload["method"] as? String,
                      method == "surface.trigger_flash" else {
                    return false
                }
                let params = payload["params"] as? [String: Any] ?? [:]
                return (params["workspace_id"] as? String) == workspaceId
                    && (params["surface_id"] as? String) == staleSurface
            },
            "Stale env surface should not win inside tmux, saw \(state.commands)"
        )
    }
}
