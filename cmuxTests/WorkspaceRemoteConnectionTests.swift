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

        wait(for: [cleanupRequested], timeout: 0.2)

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

        wait(for: [cleanupRequested], timeout: 0.2)

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
        timeout: TimeInterval
    ) -> ProcessRunResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment
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
        DispatchQueue.global(qos: .userInitiated).async {
            var clientAddr = sockaddr_un()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    Darwin.accept(listenerFD, sockaddrPtr, &clientAddrLen)
                }
            }
            guard clientFD >= 0 else {
                handled.fulfill()
                return
            }
            defer {
                Darwin.close(clientFD)
                handled.fulfill()
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
        return handled
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
    func testNotifyFallsBackFromStaleCallerWorkspaceAndSurfaceIDs() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("notify")
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
            if let data = line.data(using: .utf8),
               let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let id = payload["id"] as? String,
               let method = payload["method"] as? String {
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
                default:
                    break
                }
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected", "message": "Unexpected method \(method)"]
                )
            }

            if line == "notify_target \(currentWorkspace) \(currentSurface) Notification||" {
                return "OK"
            }
            return "ERROR: Unexpected command \(line)"
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = staleWorkspace
        environment["CMUX_SURFACE_ID"] = staleSurface
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
            state.commands.contains("notify_target \(currentWorkspace) \(currentSurface) Notification||"),
            "Expected notify_target to use current workspace and surface, saw \(state.commands)"
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
            if line == "notify_target \(workspaceId) \(callerSurface) Notification||" {
                return "OK"
            }

            guard let data = line.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return "ERROR: Unexpected command \(line)"
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
            state.commands.contains("notify_target \(workspaceId) \(callerSurface) Notification||"),
            "Expected notify_target to use caller tty surface, saw \(state.commands)"
        )
        XCTAssertFalse(
            state.commands.contains("notify_target \(workspaceId) \(focusedSurface) Notification||"),
            "Focused surface should not win over caller tty, saw \(state.commands)"
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
            if line == "notify_target \(workspaceId) \(callerSurface) Notification||" {
                return "OK"
            }
            if line == "notify_target \(workspaceId) \(staleSurface) Notification||" {
                return "OK"
            }

            guard let data = line.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return "ERROR: Unexpected command \(line)"
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
            state.commands.contains("notify_target \(workspaceId) \(callerSurface) Notification||"),
            "Expected notify_target to use caller tty surface in tmux, saw \(state.commands)"
        )
        XCTAssertFalse(
            state.commands.contains("notify_target \(workspaceId) \(staleSurface) Notification||"),
            "Stale env surface should not win inside tmux, saw \(state.commands)"
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
