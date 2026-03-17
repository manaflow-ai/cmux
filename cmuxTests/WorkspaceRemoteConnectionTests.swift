import XCTest

#if canImport(cmux)
@testable import cmux
#elseif canImport(cmux_DEV)
@testable import cmux_DEV
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

    func testRemoteRelayMetadataCleanupScriptRemovesMatchingSocketAddr() {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory.appendingPathComponent("cmux-relay-cleanup-\(UUID().uuidString)")
        let relayDir = home.appendingPathComponent(".cmux/relay")
        let socketAddrURL = home.appendingPathComponent(".cmux/socket_addr")
        let authURL = relayDir.appendingPathComponent("64008.auth")
        let daemonPathURL = relayDir.appendingPathComponent("64008.daemon_path")

        XCTAssertNoThrow(try fileManager.createDirectory(at: relayDir, withIntermediateDirectories: true))
        XCTAssertNoThrow(try "127.0.0.1:64008".write(to: socketAddrURL, atomically: true, encoding: .utf8))
        XCTAssertNoThrow(try "auth".write(to: authURL, atomically: true, encoding: .utf8))
        XCTAssertNoThrow(try "daemon".write(to: daemonPathURL, atomically: true, encoding: .utf8))
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
    }

    func testRemoteRelayMetadataCleanupScriptPreservesDifferentSocketAddr() {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory.appendingPathComponent("cmux-relay-cleanup-preserve-\(UUID().uuidString)")
        let relayDir = home.appendingPathComponent(".cmux/relay")
        let socketAddrURL = home.appendingPathComponent(".cmux/socket_addr")
        let authURL = relayDir.appendingPathComponent("64009.auth")
        let daemonPathURL = relayDir.appendingPathComponent("64009.daemon_path")

        XCTAssertNoThrow(try fileManager.createDirectory(at: relayDir, withIntermediateDirectories: true))
        XCTAssertNoThrow(try "127.0.0.1:64010".write(to: socketAddrURL, atomically: true, encoding: .utf8))
        XCTAssertNoThrow(try "auth".write(to: authURL, atomically: true, encoding: .utf8))
        XCTAssertNoThrow(try "daemon".write(to: daemonPathURL, atomically: true, encoding: .utf8))
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
