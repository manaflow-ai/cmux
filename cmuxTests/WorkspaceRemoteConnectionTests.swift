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
