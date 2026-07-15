import AppKit
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
    @Test(arguments: [false, true])
    func contextMenuReconnectReattachesFailedPersistentPTY(pendingChildExit: Bool) throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        let tabManager = TabManager()
        let windowID = appDelegate.registerMainWindowContextForTesting(tabManager: tabManager)
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowID)
            AppDelegate.shared = previousAppDelegate
        }

        let workspace = try #require(tabManager.selectedWorkspace)
        let panel = try #require(workspace.focusedTerminalPanel)
        let originalSurface = panel.surface
        workspace.configureRemoteConnection(Self.persistentConfiguration(), autoConnect: false)
        workspace.applyRemoteConnectionStateUpdate(
            .connected,
            detail: "Connected to cmux-macmini via shared local proxy 127.0.0.1:64007",
            target: "cmux-macmini"
        )
        if pendingChildExit {
            workspace.pendingRemoteTerminalChildExitSurfaceIds.insert(panel.id)
        } else {
            workspace.markPersistentRemotePTYAttachFailed(surfaceId: panel.id)
        }

        let menu = NSMenu()
        panel.hostedView.surfaceView.appendReconnectRemotePaneMenuItem(to: menu)
        let reconnectItem = try #require(menu.items.last)
        let action = try #require(reconnectItem.action)
        #expect(NSApplication.shared.sendAction(action, to: reconnectItem.target, from: reconnectItem))

        let reattached = try #require(workspace.terminalPanel(for: panel.id))
        #expect(reattached.surface !== originalSurface)
        let command = try #require(reattached.surface.initialCommand)
        #expect(command.contains("--require-existing"))
        #expect(command.contains(Workspace.defaultSSHPTYSessionID(workspaceId: workspace.id, panelId: panel.id)))
        #expect(!workspace.remoteDisconnectPlaceholderPanelIds.contains(panel.id))
        #expect(!workspace.pendingRemoteTerminalChildExitSurfaceIds.contains(panel.id))
    }

    @MainActor
    @Test func confirmedSSHPTYExitRestartsWithInheritedCustomIdentity() throws {
        let workspace = Workspace()
        let foregroundAuthToken = "foreground-auth-restored-session"
        let configuration = Self.persistentConfiguration(foregroundAuthToken: foregroundAuthToken)
        let initialPanel = try #require(workspace.focusedTerminalPanel)
        workspace.configureRemoteConnection(configuration, autoConnect: false)
        let customSessionID = "ssh-restored-custom-session"
        let panel = try #require(workspace.newTerminalSplit(
            from: initialPanel.id,
            orientation: .horizontal,
            focus: false,
            remotePTYSessionID: customSessionID
        ))
        let originalSurface = panel.surface
        #expect(panel.surface.respawnAdditionalEnvironment["CMUX_REMOTE_PTY_SESSION_ID"] == customSessionID)
        #expect(workspace.remotePTYSessionIDsByPanelId[panel.id] == customSessionID)
        let ended = workspace.markRemotePTYAttachEnded(surfaceId: panel.id, sessionID: customSessionID)
        #expect(ended.clearedRemotePTYSession)
        #expect(workspace.remotePTYSessionIDsByPanelId[panel.id] == nil)

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
        let command = try #require(restarted.surface.initialCommand)
        #expect(command.contains(customSessionID))
        #expect(!command.contains("--require-existing"))
        #expect(command.contains("workspace.remote.foreground_auth_ready"))
        #expect(command.contains(foregroundAuthToken))
        #expect(command.contains("ssh-session-end"))
        #expect(restarted.surface.respawnAdditionalEnvironment["CMUX_REMOTE_PTY_SESSION_ID"] == customSessionID)
        #expect(workspace.remotePTYSessionIDsByPanelId[panel.id] == customSessionID)
        #expect(!workspace.endedPersistentRemotePTYAttachSurfaceIds.contains(panel.id))
        let restartedSnapshot = try #require(
            workspace.sessionSnapshot(includeScrollback: false).panels
                .first { $0.id == panel.id }?.terminal
        )
        #expect(restartedSnapshot.isRemoteTerminal == true)
        #expect(restartedSnapshot.remotePTYSessionID == customSessionID)
    }

    @MainActor
    @Test func confirmedRemotePTYExitIsNotSnapshottedAsLive() throws {
        let workspace = Workspace()
        workspace.configureRemoteConnection(Self.persistentConfiguration(), autoConnect: false)
        let panel = try #require(workspace.focusedTerminalPanel)
        let sessionID = Workspace.defaultSSHPTYSessionID(
            workspaceId: workspace.id,
            panelId: panel.id
        )
        _ = workspace.markRemotePTYAttachEnded(surfaceId: panel.id, sessionID: sessionID)

        workspace.markPersistentRemotePTYAttachFailed(surfaceId: panel.id)

        let terminal = try #require(
            workspace.sessionSnapshot(includeScrollback: false).panels
                .first { $0.id == panel.id }?.terminal
        )
        #expect(terminal.isRemoteTerminal == false)
        #expect(terminal.remotePTYSessionID == nil)
    }

    @MainActor
    @Test func confirmedCloudPTYExitRestartsWithInheritedCustomIdentity() throws {
        let workspace = Workspace()
        let initialPanel = try #require(workspace.focusedTerminalPanel)
        workspace.configureRemoteConnection(Self.persistentCloudConfiguration(), autoConnect: false)
        let customSessionID = "cloud-custom-session"
        let panel = try #require(workspace.newTerminalSplit(
            from: initialPanel.id,
            orientation: .horizontal,
            focus: false,
            remotePTYSessionID: customSessionID
        ))
        #expect(panel.surface.respawnAdditionalEnvironment["CMUX_REMOTE_PTY_SESSION_ID"] == customSessionID)
        #expect(workspace.remotePTYSessionIDsByPanelId[panel.id] == customSessionID)

        let ended = workspace.markRemotePTYAttachEnded(
            surfaceId: panel.id,
            sessionID: customSessionID
        )
        #expect(ended.clearedRemotePTYSession)
        #expect(workspace.remotePTYSessionIDsByPanelId[panel.id] == nil)
        #expect(panel.surface.respawnAdditionalEnvironment["CMUX_REMOTE_PTY_SESSION_ID"] == customSessionID)
        workspace.markPersistentRemotePTYAttachFailed(surfaceId: panel.id)

        let endedSnapshot = try #require(
            workspace.sessionSnapshot(includeScrollback: false).panels
                .first { $0.id == panel.id }?.terminal
        )
        #expect(endedSnapshot.isRemoteTerminal == false)
        #expect(endedSnapshot.remotePTYSessionID == nil)

        workspace.applyRemoteConnectionStateUpdate(
            .connected,
            detail: "Connected to Cloud VM",
            target: "cloud-vm"
        )
        #expect(workspace.reconnectRemoteConnection(surfaceId: panel.id))

        let restarted = try #require(workspace.terminalPanel(for: panel.id))
        #expect(restarted.surface !== panel.surface)
        let command = try #require(restarted.surface.initialCommand)
        #expect(command.contains("vm-pty-attach"))
        #expect(command.contains("--default-freestyle-sshd"))
        #expect(restarted.surface.respawnAdditionalEnvironment["CMUX_REMOTE_PTY_SESSION_ID"] == customSessionID)
        #expect(workspace.remotePTYSessionIDsByPanelId[panel.id] == customSessionID)
        let restartedSnapshot = try #require(
            workspace.sessionSnapshot(includeScrollback: false).panels
                .first { $0.id == panel.id }?.terminal
        )
        #expect(restartedSnapshot.isRemoteTerminal == true)
        #expect(restartedSnapshot.remotePTYSessionID == customSessionID)
    }

    @Test(arguments: [(nil, Int32(253), "24", 23), ("2O", Int32(255), "21", 20)])
    func foregroundAuthenticatedAttachUsesConfiguredRetryBudget(
        reconnectLimit: String?, expectedStatus: Int32, expectedAttempts: String, expectedSleepCount: Int
    ) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-persistent-backoff-\(UUID().uuidString)", isDirectory: true)
        let fakeCLI = root.appendingPathComponent("cmux")
        let fakeSSH = root.appendingPathComponent("ssh")
        let fakeSleep = root.appendingPathComponent("sleep")
        let attemptFile = root.appendingPathComponent("attach-attempts.txt")
        let authAttemptFile = root.appendingPathComponent("auth-attempts.txt")
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
        try Self.writeShellFile(at: fakeSSH, lines: [
            "#!/bin/sh",
            "count=$(cat \"${CMUX_TEST_AUTH_ATTEMPT_FILE}\" 2>/dev/null || printf 0)",
            "printf '%s' $((count + 1)) > \"${CMUX_TEST_AUTH_ATTEMPT_FILE}\"",
            "exit 0",
        ])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeCLI.path)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeSSH.path)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeSleep.path)

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(root.path):\(environment["PATH"] ?? "/usr/bin:/bin")"
        environment["CMUX_BUNDLED_CLI_PATH"] = fakeCLI.path
        environment["CMUX_SOCKET_PATH"] = "/tmp/cmux-debug-test.sock"
        environment["CMUX_WORKSPACE_ID"] = "11111111-1111-1111-1111-111111111111"
        environment["CMUX_SURFACE_ID"] = "22222222-2222-2222-2222-222222222222"
        environment["CMUX_TEST_ATTEMPT_FILE"] = attemptFile.path
        environment["CMUX_TEST_AUTH_ATTEMPT_FILE"] = authAttemptFile.path
        environment["CMUX_TEST_SLEEP_LOG"] = sleepLog.path
        environment["CMUX_SSH_RECONNECT_LIMIT"] = reconnectLimit
        environment["CMUX_SSH_RECONNECT_DELAY_SECONDS"] = "2"
        environment["CMUX_SSH_RECONNECT_MAX_DELAY_SECONDS"] = "5"

        let result = Self.runProcess(
            command: SSHPTYAttachStartupCommandBuilder.command(
                sessionID: "ssh-test-session",
                foregroundAuth: Self.foregroundAuth()
            ),
            environment: environment
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == expectedStatus, Comment(rawValue: result.stderr))
        #expect(try String(contentsOf: authAttemptFile, encoding: .utf8) == expectedAttempts)
        #expect(try String(contentsOf: attemptFile, encoding: .utf8) == expectedAttempts)
        let delays = try String(contentsOf: sleepLog, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        #expect(delays.count == expectedSleepCount)
        #expect(Array(delays.prefix(4)) == ["2", "4", "5", "5"])
        #expect(delays.last == "5")
    }

    @Test(arguments: [(nil, "0", "0"), ("100000", "0", "0"), (nil, "08", "09"), ("100000", "09", "08")])
    func invalidDelayIsClamped(reconnectLimit: String?, delay: String, maxDelay: String) throws {
        try Self.assertInvalidDelayIsClamped(reconnectLimit: reconnectLimit, delay: delay, maxDelay: maxDelay)
    }

    private static func assertInvalidDelayIsClamped(
        reconnectLimit: String?, delay: String, maxDelay: String
    ) throws {
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
        environment["CMUX_SSH_RECONNECT_DELAY_SECONDS"] = delay
        environment["CMUX_SSH_RECONNECT_MAX_DELAY_SECONDS"] = maxDelay
        if let reconnectLimit {
            environment["CMUX_SSH_RECONNECT_LIMIT"] = reconnectLimit
        }

        let result = Self.runProcess(
            command: SSHPTYAttachStartupCommandBuilder.command(sessionID: "ssh-test-session"),
            environment: environment
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 253, Comment(rawValue: result.stderr))
        #expect(try String(contentsOf: attemptFile, encoding: .utf8) == "2")
        #expect(try String(contentsOf: sleepLog, encoding: .utf8) == "2\n")
    }

    @Test func foregroundAuthenticationFailureDoesNotEnterAttachRetryLoop() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-foreground-auth-failure-\(UUID().uuidString)", isDirectory: true)
        let fakeCLI = root.appendingPathComponent("cmux")
        let fakeSSH = root.appendingPathComponent("ssh")
        let authAttemptFile = root.appendingPathComponent("auth-attempts.txt")
        let cliAttemptFile = root.appendingPathComponent("cli-attempts.txt")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try Self.writeShellFile(at: fakeCLI, lines: [
            "#!/bin/sh", "printf '%s\\n' \"$*\" >> \"${CMUX_TEST_CLI_ATTEMPT_FILE}\"", "exit 0",
        ])
        try Self.writeShellFile(at: fakeSSH, lines: [
            "#!/bin/sh",
            "count=$(cat \"${CMUX_TEST_AUTH_ATTEMPT_FILE}\" 2>/dev/null || printf 0)",
            "printf '%s' $((count + 1)) > \"${CMUX_TEST_AUTH_ATTEMPT_FILE}\"",
            "exit 255",
        ])
        for executable in [fakeCLI, fakeSSH] {
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(root.path):\(environment["PATH"] ?? "/usr/bin:/bin")"
        environment["CMUX_BUNDLED_CLI_PATH"] = fakeCLI.path
        environment["CMUX_SOCKET_PATH"] = "/tmp/cmux-debug-test.sock"
        environment["CMUX_WORKSPACE_ID"] = "11111111-1111-1111-1111-111111111111"
        environment["CMUX_SURFACE_ID"] = "22222222-2222-2222-2222-222222222222"
        environment["CMUX_TEST_AUTH_ATTEMPT_FILE"] = authAttemptFile.path
        environment["CMUX_TEST_CLI_ATTEMPT_FILE"] = cliAttemptFile.path

        let result = Self.runProcess(
            command: SSHPTYAttachStartupCommandBuilder.command(
                sessionID: "ssh-test-session",
                foregroundAuth: Self.foregroundAuth()
            ),
            environment: environment
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 255, Comment(rawValue: result.stderr))
        #expect(try String(contentsOf: authAttemptFile, encoding: .utf8) == "1")
        #expect(!fileManager.fileExists(atPath: cliAttemptFile.path))
    }

    private static func foregroundAuth() -> SSHPTYAttachStartupCommandBuilder.ForegroundAuth {
        SSHPTYAttachStartupCommandBuilder.ForegroundAuth(
            destination: "user@example.test", port: 22, identityFile: nil,
            sshOptions: [], token: "test-auth-token"
        )
    }

    private static func persistentConfiguration(
        foregroundAuthToken: String? = nil
    ) -> WorkspaceRemoteConfiguration {
        WorkspaceRemoteConfiguration(
            destination: "cmux-macmini", port: nil, identityFile: nil, sshOptions: [],
            localProxyPort: nil, relayPort: 64007,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: SSHPTYAttachStartupCommandBuilder.command(requireExisting: false),
            foregroundAuthToken: foregroundAuthToken,
            preserveAfterTerminalExit: true, persistentDaemonSlot: "ssh-test"
        )
    }

    private static func persistentCloudConfiguration() -> WorkspaceRemoteConfiguration {
        WorkspaceRemoteConfiguration(
            destination: "71smiccrg35sw9pydt8k+cmux@vm-ssh.freestyle.sh",
            port: 22,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            managedCloudVMID: "71smiccrg35sw9pydt8k",
            terminalStartupCommand: "ssh -p 22 -tt 71smiccrg35sw9pydt8k+cmux@vm-ssh.freestyle.sh",
            preserveAfterTerminalExit: true,
            persistentDaemonSlot: "cmux-default-freestyle-sshd-v1",
            skipDaemonBootstrap: true
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
