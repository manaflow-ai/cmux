import CmuxCore
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct SSHDeepSleepReattachTests {
    private struct ProcessRunResult {
        let status: Int32
        let stderr: String
        let timedOut: Bool
    }

    @MainActor
    @Test func persistentAttachFailurePreservesReattachIdentityAndConnectionOwner() throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedTerminalPanel)
        workspace.configureRemoteConnection(Self.persistentConfiguration(), autoConnect: false)
        workspace.applyRemoteConnectionStateUpdate(
            .connected,
            detail: "Connected to cmux-macmini via shared local proxy 127.0.0.1:64007",
            target: "cmux-macmini"
        )
        let expectedSessionID = Workspace.defaultSSHPTYSessionID(
            workspaceId: workspace.id,
            panelId: panel.id
        )

        workspace.markPersistentRemotePTYAttachFailed(surfaceId: panel.id)

        #expect(workspace.remoteConnectionState == .connected)
        #expect(workspace.isRemoteTerminalSurface(panel.id))
        #expect(workspace.remoteDisconnectPlaceholderPanelIds.contains(panel.id))
        let terminalSnapshot = try #require(
            workspace.sessionSnapshot(includeScrollback: false).panels.first { $0.id == panel.id }
        )
        #expect(terminalSnapshot.terminal?.remotePTYSessionID == expectedSessionID)
    }

    @MainActor
    @Test func connectedTransitionReattachesEveryPersistentPlaceholder() throws {
        let workspace = Workspace()
        workspace.configureRemoteConnection(Self.persistentConfiguration(), autoConnect: false)
        let first = try #require(workspace.focusedTerminalPanel)
        let second = try #require(workspace.newTerminalSplit(
            from: first.id,
            orientation: .horizontal,
            focus: false
        ))
        let originalSurfaces = [first.id: first.surface, second.id: second.surface]
        workspace.markPersistentRemotePTYAttachFailed(surfaceId: first.id)
        workspace.markPersistentRemotePTYAttachFailed(surfaceId: second.id)
        #expect(workspace.remoteDisconnectPlaceholderPanelIds == Set([first.id, second.id]))

        workspace.applyRemoteConnectionStateUpdate(
            .connected,
            detail: "Connected to cmux-macmini via shared local proxy 127.0.0.1:64007",
            target: "cmux-macmini"
        )

        #expect(workspace.remoteDisconnectPlaceholderPanelIds.isEmpty)
        for panelID in [first.id, second.id] {
            let reattached = try #require(workspace.terminalPanel(for: panelID))
            #expect(reattached.surface !== originalSurfaces[panelID])
            let command = try #require(reattached.surface.initialCommand)
            #expect(command.contains("--require-existing"))
            #expect(command.contains(Workspace.defaultSSHPTYSessionID(workspaceId: workspace.id, panelId: panelID)))
            #expect(workspace.isRemoteTerminalSurface(panelID))
        }
    }

    @MainActor
    @Test func confirmedRemotePTYExitWaitsForManualRestart() throws {
        let workspace = Workspace()
        let configuration = Self.persistentConfiguration()
        workspace.configureRemoteConnection(configuration, autoConnect: false)
        let panel = try #require(workspace.focusedTerminalPanel)
        let originalSurface = panel.surface
        let sessionID = Workspace.defaultSSHPTYSessionID(
            workspaceId: workspace.id,
            panelId: panel.id
        )
        let ended = workspace.markRemotePTYAttachEnded(surfaceId: panel.id, sessionID: sessionID)
        #expect(ended.clearedRemotePTYSession)

        workspace.markPersistentRemotePTYAttachFailed(surfaceId: panel.id)
        workspace.applyRemoteConnectionStateUpdate(
            .connected,
            detail: "Connected to cmux-macmini via shared local proxy 127.0.0.1:64007",
            target: "cmux-macmini"
        )

        #expect(workspace.terminalPanel(for: panel.id)?.surface === originalSurface)
        #expect(workspace.remoteDisconnectPlaceholderPanelIds.contains(panel.id))
        #expect(workspace.endedPersistentRemotePTYAttachSurfaceIds.contains(panel.id))

        #expect(workspace.reconnectRemoteConnection(surfaceId: panel.id))
        let restarted = try #require(workspace.terminalPanel(for: panel.id))
        #expect(restarted.surface !== originalSurface)
        #expect(restarted.surface.initialCommand == configuration.terminalStartupCommand)
        #expect(!workspace.endedPersistentRemotePTYAttachSurfaceIds.contains(panel.id))
    }

    @Test func persistentAttachRetriesPastLegacyBudgetWithCappedBackoff() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-persistent-backoff-\(UUID().uuidString)", isDirectory: true)
        let fakeCLI = root.appendingPathComponent("cmux")
        let fakeSleep = root.appendingPathComponent("sleep")
        let attemptFile = root.appendingPathComponent("attach-attempts.txt")
        let sleepLog = root.appendingPathComponent("sleep-delays.txt")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try Self.writeShellFile(at: fakeCLI, lines: [
            "#!/bin/sh", "case \" $* \" in", "  *\" ssh-pty-attach \"*)",
            "    count=$(cat \"${CMUX_TEST_ATTEMPT_FILE}\" 2>/dev/null || printf 0)",
            "    count=$((count + 1))", "    printf '%s' \"$count\" > \"${CMUX_TEST_ATTEMPT_FILE}\"",
            "    if [ \"$count\" -lt 24 ]; then exit 255; fi", "    exit 253", "    ;;",
            "  *) exit 0 ;;", "esac",
        ])
        try Self.writeShellFile(at: fakeSleep, lines: [
            "#!/bin/sh", "printf '%s\\n' \"$1\" >> \"${CMUX_TEST_SLEEP_LOG}\"",
        ])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeCLI.path)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeSleep.path)

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(root.path):\(environment["PATH"] ?? "/usr/bin:/bin")"
        environment["CMUX_BUNDLED_CLI_PATH"] = fakeCLI.path
        environment["CMUX_SOCKET_PATH"] = "/tmp/cmux-debug-test.sock"
        environment["CMUX_WORKSPACE_ID"] = "11111111-1111-1111-1111-111111111111"
        environment["CMUX_SURFACE_ID"] = "22222222-2222-2222-2222-222222222222"
        environment["CMUX_TEST_ATTEMPT_FILE"] = attemptFile.path
        environment["CMUX_TEST_SLEEP_LOG"] = sleepLog.path
        environment["CMUX_SSH_RECONNECT_DELAY_SECONDS"] = "2"
        environment["CMUX_SSH_RECONNECT_MAX_DELAY_SECONDS"] = "5"

        let result = Self.runProcess(
            command: SSHPTYAttachStartupCommandBuilder.command(sessionID: "ssh-test-session"),
            environment: environment
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 253, Comment(rawValue: result.stderr))
        #expect(try String(contentsOf: attemptFile, encoding: .utf8) == "24")
        let delays = try String(contentsOf: sleepLog, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        #expect(delays.count == 23)
        #expect(Array(delays.prefix(4)) == ["2", "4", "5", "5"])
        #expect(delays.last == "5")
    }

    @Test func defaultUnlimitedRetryClampsZeroDelayToAvoidHotLoop() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-persistent-zero-delay-\(UUID().uuidString)", isDirectory: true)
        let fakeCLI = root.appendingPathComponent("cmux")
        let fakeSleep = root.appendingPathComponent("sleep")
        let attemptFile = root.appendingPathComponent("attach-attempts.txt")
        let sleepLog = root.appendingPathComponent("sleep-delays.txt")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try Self.writeShellFile(at: fakeCLI, lines: [
            "#!/bin/sh", "case \" $* \" in", "  *\" ssh-pty-attach \"*)",
            "    count=$(cat \"${CMUX_TEST_ATTEMPT_FILE}\" 2>/dev/null || printf 0)",
            "    count=$((count + 1))", "    printf '%s' \"$count\" > \"${CMUX_TEST_ATTEMPT_FILE}\"",
            "    if [ \"$count\" -eq 1 ]; then exit 255; fi", "    exit 253", "    ;;",
            "  *) exit 0 ;;", "esac",
        ])
        try Self.writeShellFile(at: fakeSleep, lines: [
            "#!/bin/sh", "printf '%s\\n' \"$1\" >> \"${CMUX_TEST_SLEEP_LOG}\"",
        ])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeCLI.path)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeSleep.path)

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(root.path):\(environment["PATH"] ?? "/usr/bin:/bin")"
        environment["CMUX_BUNDLED_CLI_PATH"] = fakeCLI.path
        environment["CMUX_SOCKET_PATH"] = "/tmp/cmux-debug-test.sock"
        environment["CMUX_WORKSPACE_ID"] = "11111111-1111-1111-1111-111111111111"
        environment["CMUX_SURFACE_ID"] = "22222222-2222-2222-2222-222222222222"
        environment["CMUX_TEST_ATTEMPT_FILE"] = attemptFile.path
        environment["CMUX_TEST_SLEEP_LOG"] = sleepLog.path
        environment["CMUX_SSH_RECONNECT_DELAY_SECONDS"] = "0"
        environment["CMUX_SSH_RECONNECT_MAX_DELAY_SECONDS"] = "0"

        let result = Self.runProcess(
            command: SSHPTYAttachStartupCommandBuilder.command(sessionID: "ssh-test-session"),
            environment: environment
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 253, Comment(rawValue: result.stderr))
        #expect(try String(contentsOf: attemptFile, encoding: .utf8) == "2")
        #expect(try String(contentsOf: sleepLog, encoding: .utf8) == "2\n")
    }

    private static func persistentConfiguration() -> WorkspaceRemoteConfiguration {
        WorkspaceRemoteConfiguration(
            destination: "cmux-macmini", port: nil, identityFile: nil, sshOptions: [],
            localProxyPort: nil, relayPort: 64007,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: SSHPTYAttachStartupCommandBuilder.command(requireExisting: false),
            preserveAfterTerminalExit: true, persistentDaemonSlot: "ssh-test"
        )
    }

    private static func writeShellFile(at url: URL, lines: [String]) throws {
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private static func runProcess(command: String, environment: [String: String]) -> ProcessRunResult {
        let process = Process()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe
        do {
            try process.run()
        } catch {
            return ProcessRunResult(status: -1, stderr: String(describing: error), timedOut: false)
        }
        let exitSignal = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            exitSignal.signal()
        }
        let timedOut = exitSignal.wait(timeout: .now() + 5) == .timedOut
        if timedOut {
            process.terminate()
            _ = exitSignal.wait(timeout: .now() + 1)
        }
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return ProcessRunResult(status: process.terminationStatus, stderr: stderr, timedOut: timedOut)
    }
}
