import CmuxCore
import CmuxFoundation
import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct SSHStartupManualReconnectTests {
    private final class BundleToken {}

    private struct ProcessRunResult {
        let status: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
    }

    private struct TerminalExitPromptFixture {
        let startupCommand: String
        let environment: [String: String]
        let temporaryDirectory: URL
    }

    private struct TerminalExitPromptProcess {
        let process: Process
        let standardInput: Pipe
        let transcriptURL: URL
        let transcriptHandle: FileHandle
        let temporaryDirectory: URL
    }

    private final class MockSocketServerState: @unchecked Sendable {
        private let lock = NSLock()
        private var commands: [String] = []

        func append(_ command: String) {
            lock.lock()
            commands.append(command)
            lock.unlock()
        }

        func snapshot() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return commands
        }
    }

    @Test func manualReconnectReentersConnectLoop() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-manual-retry-\(UUID().uuidString)", isDirectory: true)
        let fakeCLI = root.appendingPathComponent("cmux")
        let fakeSSH = root.appendingPathComponent("ssh")
        let logFile = root.appendingPathComponent("ssh-session-end.log")
        let attemptFile = root.appendingPathComponent("ssh-attempts.txt")

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try Self.writeShellFile(at: fakeCLI, lines: [
            "#!/bin/sh",
            "printf '%s\\n' \"$*\" >> \"${CMUX_TEST_SESSION_END_LOG}\"",
        ])
        try Self.writeShellFile(at: fakeSSH, lines: [
            "#!/bin/sh",
            "count=$(cat \"${CMUX_TEST_ATTEMPT_FILE}\" 2>/dev/null || printf 0)",
            "count=$((count + 1))",
            "printf '%s' \"$count\" > \"${CMUX_TEST_ATTEMPT_FILE}\"",
            "if [ \"$count\" -ge 2 ]; then exit 0; fi",
            "exit 1",
        ])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeCLI.path)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeSSH.path)

        let startupCommand = try Self.generatedVMSSHInitialStartupCommand(
            replacingSystemSSHWith: fakeSSH
        )
        #expect(!startupCommand.contains("workspace.remote.terminal_session_connected"))
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(root.path):\(environment["PATH"] ?? "/usr/bin:/bin")"
        environment["CMUX_BUNDLED_CLI_PATH"] = fakeCLI.path
        environment["CMUX_SOCKET_PATH"] = "/tmp/cmux-debug-test.sock"
        environment["CMUX_WORKSPACE_ID"] = "11111111-1111-1111-1111-111111111111"
        environment["CMUX_SURFACE_ID"] = "22222222-2222-2222-2222-222222222222"
        environment["CMUX_TEST_SESSION_END_LOG"] = logFile.path
        environment["CMUX_TEST_ATTEMPT_FILE"] = attemptFile.path
        environment["CMUX_SSH_RECONNECT_DELAY_SECONDS"] = "0"

        let result = Self.runProcess(
            executablePath: "/bin/sh",
            arguments: ["-c", startupCommand],
            environment: environment,
            standardInput: "r\n",
            timeout: 5
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(
            (try? String(contentsOf: attemptFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) == "2",
            "manual `r` retry must re-run the SSH connect loop a second time"
        )
        let recordedCalls = (try? String(contentsOf: logFile, encoding: .utf8)) ?? ""
        let sessionEndCalls = recordedCalls
            .split(separator: "\n")
            .filter { $0.contains("ssh-session-end") }
        #expect(sessionEndCalls.count == 2, Comment(rawValue: result.stderr))
        #expect(
            recordedCalls.contains("rpc workspace.remote.reconnect {\"workspace_id\":\"11111111-1111-1111-1111-111111111111\",\"surface_id\":\"22222222-2222-2222-2222-222222222222\"}"),
            Comment(rawValue: recordedCalls)
        )
    }

    @Test func terminalTeardownDisablesRemoteInputReportingModesBeforePrompt() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-terminal-mode-reset-\(UUID().uuidString)", isDirectory: true)
        let fakeCLI = root.appendingPathComponent("cmux")
        let fakeSSH = root.appendingPathComponent("ssh")

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try Self.writeShellFile(at: fakeCLI, lines: ["#!/bin/sh", "exit 0"])
        try Self.writeShellFile(at: fakeSSH, lines: ["#!/bin/sh", "exit 7"])
        for executable in [fakeCLI, fakeSSH] {
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }

        let generatedStartupCommand = try Self.generatedVMSSHInitialStartupCommand(
            replacingSystemSSHWith: fakeSSH
        )
        let generatedStartupURL = URL(
            fileURLWithPath: generatedStartupCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        defer { try? fileManager.removeItem(at: generatedStartupURL) }
        let generatedStartupScript = try String(contentsOf: generatedStartupURL, encoding: .utf8)
        try #require(generatedStartupScript.contains(fakeSSH.path))
        let startupURL = root.appendingPathComponent("startup-with-fake-ssh.sh")
        try generatedStartupScript.write(to: startupURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: startupURL.path)
        try fileManager.removeItem(at: generatedStartupURL)

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_BUNDLED_CLI_PATH"] = fakeCLI.path
        environment["CMUX_SOCKET_PATH"] = "/tmp/cmux-debug-test.sock"
        environment["CMUX_WORKSPACE_ID"] = "11111111-1111-1111-1111-111111111111"
        environment["CMUX_SURFACE_ID"] = "22222222-2222-2222-2222-222222222222"
        environment["CMUX_SSH_RECONNECT_LIMIT"] = "0"
        let result = Self.runProcess(
            executablePath: "/usr/bin/script",
            arguments: ["-q", "-F", "/dev/null", "/bin/sh", startupURL.path],
            environment: environment,
            standardInput: "\n",
            timeout: 5
        )

        let transcript = result.stdout + result.stderr
        #expect(!result.timedOut, Comment(rawValue: transcript))
        #expect(result.status == 7, Comment(rawValue: transcript))
        let requiredResets = [
            "\u{1B}[?1004l", // focus reporting
            "\u{1B}[?1000l", // mouse reporting
            "\u{1B}[?2004l", // bracketed paste
            "\u{1B}[999<u", // Kitty keyboard stack
            "\u{1B}[0;1=u", // Kitty keyboard flags
            "\u{1B}[?2048l", // in-band resize reports
            "\u{1B}[?2026l", // synchronized output
        ]
        let closePrompt = transcript.range(of: "press Enter to close this pane")
        #expect(closePrompt != nil)
        for reset in requiredResets {
            let resetRange = transcript.range(of: reset)
            #expect(resetRange != nil, Comment(rawValue: transcript))
            if let resetRange, let closePrompt {
                #expect(resetRange.lowerBound < closePrompt.lowerBound)
            }
        }
    }

    @Test func directSignalTerminatesForegroundAuthenticationProcessTree() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-foreground-auth-tree-\(UUID().uuidString)", isDirectory: true)
        let fakeCLI = root.appendingPathComponent("cmux")
        let fakeSSH = root.appendingPathComponent("ssh")
        let childPIDFile = root.appendingPathComponent("auth-child-pid")
        let childSignalLog = root.appendingPathComponent("auth-child-signal")

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try Self.writeShellFile(at: fakeCLI, lines: ["#!/bin/sh", "exit 0"])
        try Self.writeShellFile(at: fakeSSH, lines: [
            "#!/bin/sh",
            "trap '' HUP INT",
            "trap 'printf \"%s\\n\" term > \"${CMUX_TEST_AUTH_CHILD_SIGNAL:?}\"; exit 143' TERM",
            "printf '%s\\n' \"$$\" > \"${CMUX_TEST_AUTH_CHILD_PID:?}\"",
            "kill -INT \"${CMUX_SSH_STARTUP_PID:?}\"",
            "while :; do /bin/sleep 30; done",
        ])
        for executable in [fakeCLI, fakeSSH] {
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }

        let startupCommand = try Self.generatedPersistentSSHForegroundAuthenticationStartupCommand(
            replacingSystemSSHWith: fakeSSH
        )
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(root.path):\(environment["PATH"] ?? "/usr/bin:/bin")"
        environment["CMUX_BUNDLED_CLI_PATH"] = fakeCLI.path
        environment["CMUX_SOCKET_PATH"] = "/tmp/cmux-debug-test.sock"
        environment["CMUX_WORKSPACE_ID"] = "11111111-1111-1111-1111-111111111111"
        environment["CMUX_SURFACE_ID"] = "22222222-2222-2222-2222-222222222222"
        environment["CMUX_TEST_AUTH_CHILD_PID"] = childPIDFile.path
        environment["CMUX_TEST_AUTH_CHILD_SIGNAL"] = childSignalLog.path
        environment["CMUX_SSH_RECONNECT_DELAY_SECONDS"] = "0"

        let result = Self.runProcess(
            executablePath: "/bin/sh",
            arguments: ["-c", startupCommand],
            environment: environment,
            timeout: 5
        )
        let childPID = try #require(Int32(
            String(contentsOf: childPIDFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        defer { Darwin.kill(childPID, SIGKILL) }

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 130, Comment(rawValue: result.stderr))
        #expect(
            Self.waitForFile(at: childSignalLog, containing: "term", timeout: 3),
            "Direct startup signals must terminate the nested authentication process tree"
        )
    }

    @Test func controlCThroughForegroundAuthenticationPTYExitsWithoutWaitingForInput() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-foreground-auth-signal-\(UUID().uuidString)", isDirectory: true)
        let fakeCLI = root.appendingPathComponent("cmux")
        let fakeSSH = root.appendingPathComponent("ssh")
        let authReadyMarker = root.appendingPathComponent("auth-ready")

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try Self.writeShellFile(at: fakeCLI, lines: ["#!/bin/sh", "exit 0"])
        try Self.writeShellFile(at: fakeSSH, lines: [
            "#!/bin/sh",
            "trap 'exit 130' INT",
            "printf '%s\\n' ready > \"${CMUX_TEST_AUTH_READY_MARKER:?}\"",
            "while :; do /bin/sleep 30; done",
        ])
        for executable in [fakeCLI, fakeSSH] {
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }

        let startupCommand = try Self.generatedPersistentSSHForegroundAuthenticationStartupCommand(
            replacingSystemSSHWith: fakeSSH
        )
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(root.path):\(environment["PATH"] ?? "/usr/bin:/bin")"
        environment["CMUX_BUNDLED_CLI_PATH"] = fakeCLI.path
        environment["CMUX_SOCKET_PATH"] = "/tmp/cmux-debug-test.sock"
        environment["CMUX_WORKSPACE_ID"] = "11111111-1111-1111-1111-111111111111"
        environment["CMUX_SURFACE_ID"] = "22222222-2222-2222-2222-222222222222"
        environment["CMUX_TEST_AUTH_READY_MARKER"] = authReadyMarker.path
        environment["CMUX_SSH_RECONNECT_DELAY_SECONDS"] = "0"

        let process = Process()
        let standardInput = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "-F", "/dev/null", "/bin/sh", "-c", startupCommand]
        process.environment = environment
        process.standardInput = standardInput
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        defer {
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
            try? standardInput.fileHandleForWriting.close()
        }

        try process.run()
        let authReady = Self.waitForFile(at: authReadyMarker, containing: "ready", timeout: 3)
        #expect(authReady, "Timed out waiting for foreground authentication to enter its nested PTY")
        if authReady {
            try standardInput.fileHandleForWriting.write(contentsOf: Data([0x03]))
        }

        let exitDeadline = Date.now.addingTimeInterval(3)
        while process.isRunning, Date.now < exitDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        let exitedPromptly = !process.isRunning
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()

        #expect(
            exitedPromptly,
            "Ctrl-C during foreground authentication must not fall through to the final Enter prompt"
        )
        #expect(process.terminationStatus == 130)
    }

    @Test func directSignalInterruptsInitialAuthenticationBackoff() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-foreground-auth-backoff-signal-\(UUID().uuidString)", isDirectory: true)
        let fakeCLI = root.appendingPathComponent("cmux")
        let fakeSSH = root.appendingPathComponent("ssh")
        let fakeSleep = root.appendingPathComponent("sleep")
        let backoffReadyMarker = root.appendingPathComponent("backoff-ready")
        let backoffPIDFile = root.appendingPathComponent("backoff-pid")

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try Self.writeShellFile(at: fakeCLI, lines: ["#!/bin/sh", "exit 0"])
        try Self.writeShellFile(at: fakeSSH, lines: [
            "#!/bin/sh",
            "printf '%s\\n' 'ssh: connect to host boot-retry.example.test port 22: Network is unreachable' >&2",
            "exit 255",
        ])
        try Self.writeShellFile(at: fakeSleep, lines: [
            "#!/bin/sh",
            "printf '%s\\n' ready > \"${CMUX_TEST_BACKOFF_READY:?}\"",
            "printf '%s\\n' \"$$\" > \"${CMUX_TEST_BACKOFF_PID:?}\"",
            "exec /bin/sleep \"$1\"",
        ])
        for executable in [fakeCLI, fakeSSH, fakeSleep] {
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }

        let startupCommand = try Self.generatedPersistentSSHForegroundAuthenticationStartupCommand(
            replacingSystemSSHWith: fakeSSH
        )
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(root.path):\(environment["PATH"] ?? "/usr/bin:/bin")"
        environment["CMUX_BUNDLED_CLI_PATH"] = fakeCLI.path
        environment["CMUX_SOCKET_PATH"] = "/tmp/cmux-debug-test.sock"
        environment["CMUX_WORKSPACE_ID"] = "11111111-1111-1111-1111-111111111111"
        environment["CMUX_SURFACE_ID"] = "22222222-2222-2222-2222-222222222222"
        environment["CMUX_TEST_BACKOFF_READY"] = backoffReadyMarker.path
        environment["CMUX_TEST_BACKOFF_PID"] = backoffPIDFile.path
        environment["CMUX_SSH_RECONNECT_DELAY_SECONDS"] = "30"
        environment["CMUX_SSH_RECONNECT_MAX_DELAY_SECONDS"] = "30"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", startupCommand]
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        var backoffPID: Int32?
        defer {
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
            if let backoffPID {
                Darwin.kill(backoffPID, SIGKILL)
            }
        }

        try process.run()
        try #require(
            Self.waitForFile(at: backoffReadyMarker, containing: "ready", timeout: 3),
            "Timed out waiting for initial authentication retry backoff"
        )
        backoffPID = try #require(Int32(
            String(contentsOf: backoffPIDFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ))

        Darwin.kill(process.processIdentifier, SIGINT)
        let exitDeadline = Date.now.addingTimeInterval(1)
        while process.isRunning, Date.now < exitDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        let exitedPromptly = !process.isRunning
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()

        #expect(exitedPromptly, "SIGINT must interrupt initial authentication backoff promptly")
        #expect(process.terminationStatus == 130)
    }

    @Test func initialStartupStopsAtForegroundAuthenticationFailureLimit() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-foreground-auth-limit-\(UUID().uuidString)", isDirectory: true)
        let fakeCLI = root.appendingPathComponent("cmux")
        let fakeSSH = root.appendingPathComponent("ssh")
        let fakeSleep = root.appendingPathComponent("sleep")
        let attemptFile = root.appendingPathComponent("ssh-attempts.txt")

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try Self.writeShellFile(at: fakeCLI, lines: ["#!/bin/sh", "exit 0"])
        try Self.writeShellFile(at: fakeSSH, lines: [
            "#!/bin/sh",
            "count=$(cat \"${CMUX_TEST_ATTEMPT_FILE}\" 2>/dev/null || printf 0)",
            "count=$((count + 1))",
            "printf '%s' \"$count\" > \"${CMUX_TEST_ATTEMPT_FILE}\"",
            "printf '%s\\n' 'ssh: connect to host boot-retry.example.test port 22: Network is unreachable' >&2",
            "exit 255",
        ])
        try Self.writeShellFile(at: fakeSleep, lines: ["#!/bin/sh", "exit 0"])
        for executable in [fakeCLI, fakeSSH, fakeSleep] {
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }

        let startupCommand = try Self.generatedPersistentSSHForegroundAuthenticationStartupCommand(
            replacingSystemSSHWith: fakeSSH
        )
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(root.path):\(environment["PATH"] ?? "/usr/bin:/bin")"
        environment["CMUX_BUNDLED_CLI_PATH"] = fakeCLI.path
        environment["CMUX_SOCKET_PATH"] = "/tmp/cmux-debug-test.sock"
        environment["CMUX_WORKSPACE_ID"] = "11111111-1111-1111-1111-111111111111"
        environment["CMUX_SURFACE_ID"] = "22222222-2222-2222-2222-222222222222"
        environment["CMUX_TEST_ATTEMPT_FILE"] = attemptFile.path
        environment["CMUX_SSH_RECONNECT_DELAY_SECONDS"] = "2"
        environment["CMUX_SSH_RECONNECT_MAX_DELAY_SECONDS"] = "2"

        let result = Self.runProcess(
            executablePath: "/bin/sh",
            arguments: ["-c", startupCommand],
            environment: environment,
            timeout: 2
        )

        #expect(result.timedOut, "closed stdin must not dismiss the terminal failure prompt")
        #expect(try String(contentsOf: attemptFile, encoding: .utf8) == "20")
    }

    @Test func establishedStartupRetriesUnclassifiedReauthenticationFailure() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-unclassified-reauth-\(UUID().uuidString)", isDirectory: true)
        let fakeCLI = root.appendingPathComponent("cmux")
        let fakeSSH = root.appendingPathComponent("ssh")
        let fakeSleep = root.appendingPathComponent("sleep")
        let attemptFile = root.appendingPathComponent("ssh-attempts.txt")

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try Self.writeShellFile(at: fakeCLI, lines: ["#!/bin/sh", "exit 0"])
        try Self.writeShellFile(at: fakeSSH, lines: [
            "#!/bin/sh",
            "count=$(cat \"${CMUX_TEST_ATTEMPT_FILE}\" 2>/dev/null || printf 0)",
            "count=$((count + 1))",
            "printf '%s' \"$count\" > \"${CMUX_TEST_ATTEMPT_FILE}\"",
            "case \"$count\" in",
            "  1) exit 0 ;;",
            "  2) exit 255 ;;",
            "  3) printf '%s\\n' 'Connection closed by UNKNOWN port 65535' >&2; exit 255 ;;",
            "  *) exit 0 ;;",
            "esac",
        ])
        try Self.writeShellFile(at: fakeSleep, lines: ["#!/bin/sh", "exit 0"])
        for executable in [fakeCLI, fakeSSH, fakeSleep] {
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }

        let startupCommand = try Self.generatedPersistentSSHForegroundAuthenticationStartupCommand(
            replacingSystemSSHWith: fakeSSH
        )
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(root.path):\(environment["PATH"] ?? "/usr/bin:/bin")"
        environment["CMUX_BUNDLED_CLI_PATH"] = fakeCLI.path
        environment["CMUX_SOCKET_PATH"] = "/tmp/cmux-debug-test.sock"
        environment["CMUX_WORKSPACE_ID"] = "11111111-1111-1111-1111-111111111111"
        environment["CMUX_SURFACE_ID"] = "22222222-2222-2222-2222-222222222222"
        environment["CMUX_TEST_ATTEMPT_FILE"] = attemptFile.path
        environment["CMUX_SSH_RECONNECT_DELAY_SECONDS"] = "2"
        environment["CMUX_SSH_RECONNECT_MAX_DELAY_SECONDS"] = "2"

        let result = Self.runProcess(
            executablePath: "/bin/sh",
            arguments: ["-c", startupCommand],
            environment: environment,
            timeout: 5
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(try String(contentsOf: attemptFile, encoding: .utf8) == "5")
    }

    @Test func terminalExitPromptIgnoresQueuedWakeReportsAndEOTUntilFreshEnter() throws {
        let prompt = try Self.makeTerminalExitPromptProcess()
        defer { Self.stopAndCleanUp(prompt) }

        let queuedWakeInput = Data("\u{1B}[I\u{1B}[O\u{1B}[13;2u".utf8) + Data([0x04])
        try prompt.standardInput.fileHandleForWriting.write(contentsOf: queuedWakeInput)
        #expect(
            Self.waitForFile(
                at: prompt.transcriptURL,
                containing: "press Enter to close this pane",
                timeout: 3
            ),
            "terminal exit prompt was not emitted"
        )

        let lateWakeInput = Data([0x04, 0x04])
            + Data("\u{1B}[O\u{1B}[13;2u\u{1B}[200~pasted\nline\u{1B}[201~".utf8)
        try prompt.standardInput.fileHandleForWriting.write(contentsOf: lateWakeInput)
        let dismissedByWakeInput = Self.waitForExit(prompt.process, timeout: 0.5)
        #expect(!dismissedByWakeInput, "late focus reports, CSI-u, paste, and repeated EOT must not dismiss the prompt")
        if !dismissedByWakeInput {
            try prompt.standardInput.fileHandleForWriting.write(contentsOf: Data([0x0A]))
            #expect(Self.waitForExit(prompt.process, timeout: 2), "a fresh Enter must dismiss the prompt")
            if !prompt.process.isRunning {
                #expect(prompt.process.terminationStatus == 255)
            }
        }
    }

    @Test func terminalExitPromptDoesNotDismissOnClosedInput() throws {
        let prompt = try Self.makeTerminalExitPromptProcess()
        defer { Self.stopAndCleanUp(prompt) }

        #expect(
            Self.waitForFile(
                at: prompt.transcriptURL,
                containing: "press Enter to close this pane",
                timeout: 3
            ),
            "terminal exit prompt was not emitted"
        )
        try prompt.standardInput.fileHandleForWriting.close()

        #expect(
            !Self.waitForExit(prompt.process, timeout: 0.5),
            "closed stdin must leave the prompt waiting for a real Enter keypress"
        )
    }

    @Test func persistentStartupIgnoresInheritedInternalPendingSignalState() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-inherited-pending-signal-\(UUID().uuidString)", isDirectory: true)
        let fakeCLI = root.appendingPathComponent("cmux")
        let fakeSSH = root.appendingPathComponent("ssh")
        let attemptFile = root.appendingPathComponent("ssh-attempts.txt")

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try Self.writeShellFile(at: fakeCLI, lines: ["#!/bin/sh", "exit 0"])
        try Self.writeShellFile(at: fakeSSH, lines: [
            "#!/bin/sh",
            "count=$(cat \"${CMUX_TEST_ATTEMPT_FILE}\" 2>/dev/null || printf 0)",
            "count=$((count + 1))",
            "printf '%s' \"$count\" > \"${CMUX_TEST_ATTEMPT_FILE}\"",
            "exit 0",
        ])
        for executable in [fakeCLI, fakeSSH] {
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }

        let startupCommand = try Self.generatedPersistentSSHForegroundAuthenticationStartupCommand(
            replacingSystemSSHWith: fakeSSH
        )
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(root.path):\(environment["PATH"] ?? "/usr/bin:/bin")"
        environment["CMUX_BUNDLED_CLI_PATH"] = fakeCLI.path
        environment["CMUX_SOCKET_PATH"] = "/tmp/cmux-debug-test.sock"
        environment["CMUX_WORKSPACE_ID"] = "11111111-1111-1111-1111-111111111111"
        environment["CMUX_SURFACE_ID"] = "22222222-2222-2222-2222-222222222222"
        environment["CMUX_TEST_ATTEMPT_FILE"] = attemptFile.path
        environment["CMUX_SSH_PENDING_SIGNAL"] = "130"
        environment["CMUX_SSH_PENDING_SIGNAL_NAME"] = "INT"

        let result = Self.runProcess(
            executablePath: "/bin/sh",
            arguments: ["-c", startupCommand],
            environment: environment,
            timeout: 5
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(try String(contentsOf: attemptFile, encoding: .utf8) == "2")
    }

    @MainActor
    @Test func reconnectRejectsUnendedTerminalSurfaceId() throws {
        let workspace = Workspace()
        let initialPanelId = try #require(workspace.focusedTerminalPanel?.id)
        let configuration = WorkspaceRemoteConfiguration(
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
        workspace.configureRemoteConnection(configuration, autoConnect: false)
        workspace.applyRemoteConnectionStateUpdate(
            .connected,
            detail: "Connected to cmux-macmini via shared local proxy 127.0.0.1:64007",
            target: "cmux-macmini"
        )

        let unrelatedPanel = TerminalPanel(workspaceId: workspace.id)
        workspace.panels[unrelatedPanel.id] = unrelatedPanel

        #expect(workspace.isRemoteTerminalSurface(initialPanelId))
        #expect(!workspace.isRemoteTerminalSurface(unrelatedPanel.id))
        let sessionCountBefore = workspace.activeRemoteTerminalSessionCount

        workspace.reconnectRemoteConnection(surfaceId: unrelatedPanel.id)

        #expect(workspace.activeRemoteTerminalSessionCount == sessionCountBefore)
        #expect(!workspace.isRemoteTerminalSurface(unrelatedPanel.id))
        #expect(workspace.remoteConnectionState == .connected)
    }

    @MainActor
    @Test func reconnectKeepsConnectedWorkspaceForEndedPaneRetry() {
        let workspace = Workspace()
        let configuration = Self.makeRemoteConfiguration()
        workspace.configureRemoteConnection(configuration, autoConnect: false)
        workspace.applyRemoteConnectionStateUpdate(
            .connected,
            detail: "Connected to cmux-macmini via shared local proxy 127.0.0.1:64007",
            target: "cmux-macmini"
        )

        let panel = TerminalPanel(workspaceId: workspace.id)
        workspace.panels[panel.id] = panel
        workspace.pendingRemoteTerminalChildExitSurfaceIds.insert(panel.id)

        #expect(!workspace.isRemoteTerminalSurface(panel.id))
        #expect(workspace.remoteConnectionState == .connected)

        workspace.reconnectRemoteConnection(surfaceId: panel.id)

        #expect(workspace.isRemoteTerminalSurface(panel.id))
        #expect(!workspace.pendingRemoteTerminalChildExitSurfaceIds.contains(panel.id))
        #expect(workspace.remoteConnectionState == .connected)
    }

    @MainActor
    @Test func reconnectingConfirmedSurfaceStartsANewLivenessGeneration() throws {
        let workspace = Workspace()
        let configuration = Self.makeRemoteConfiguration()
        workspace.configureRemoteConnection(configuration, autoConnect: false)
        let panelId = try #require(workspace.focusedTerminalPanel?.id)
        #expect(
            workspace.markRemoteTerminalSessionConnected(
                surfaceId: panelId,
                relayPort: configuration.relayPort
            )
        )
        #expect(workspace.hasAuthoritativelyConnectedRemoteTerminal)

        #expect(workspace.reconnectRemoteConnection(surfaceId: panelId))

        #expect(workspace.remoteTerminalSessionStatesBySurfaceId[panelId]?.phase == .launching)
        #expect(!workspace.hasAuthoritativelyConnectedRemoteTerminal)
        workspace.applyRemoteConnectionStateUpdate(
            .reconnecting,
            detail: "Auxiliary daemon reconnecting",
            target: configuration.displayTarget
        )
        #expect(workspace.remoteConnectionState == .reconnecting)
    }

    @MainActor
    @Test func reconnectDefersToInFlightReconnectForEndedPaneRetry() {
        let workspace = Workspace()
        let configuration = Self.makeRemoteConfiguration()
        workspace.configureRemoteConnection(configuration, autoConnect: false)
        workspace.applyRemoteConnectionStateUpdate(
            .reconnecting,
            detail: "Reconnecting to cmux-macmini via shared local proxy 127.0.0.1:64007",
            target: "cmux-macmini"
        )

        let panel = TerminalPanel(workspaceId: workspace.id)
        workspace.panels[panel.id] = panel
        workspace.pendingRemoteTerminalChildExitSurfaceIds.insert(panel.id)

        #expect(!workspace.isRemoteTerminalSurface(panel.id))
        #expect(workspace.remoteConnectionState == .reconnecting)

        workspace.reconnectRemoteConnection(surfaceId: panel.id)

        #expect(workspace.isRemoteTerminalSurface(panel.id))
        #expect(!workspace.pendingRemoteTerminalChildExitSurfaceIds.contains(panel.id))
        #expect(workspace.remoteConnectionState == .reconnecting)
    }

    @MainActor
    @Test func completedRemoteCommandKeepsLogicalSurfaceAndScrollback() async throws {
        let manager = TabManager()
        let workspace = manager.addWorkspace(select: true)
        let panel = try #require(workspace.focusedTerminalPanel)
        let output = "remote-command-output\n"
        workspace.configureRemoteConnection(Self.makeRemoteConfiguration(), autoConnect: false)
        workspace.restoredTerminalScrollbackByPanelId[panel.id] = output

        manager.closePanelAfterChildExited(tabId: workspace.id, surfaceId: panel.id)
        await workspace.waitForRemoteDisconnectTransition(surfaceId: panel.id)

        let disconnectedPanel = try #require(workspace.terminalPanel(for: panel.id))
        #expect(disconnectedPanel.surface !== panel.surface)
        #expect(workspace.remoteDisconnectPlaceholderPanelIds.contains(panel.id))
        let replayPath = try #require(disconnectedPanel.ownedSessionScrollbackReplayFileURL?.path)
        defer { try? FileManager.default.removeItem(atPath: replayPath) }
        #expect(try String(contentsOfFile: replayPath, encoding: .utf8) == output)
        let wrapperPath = try #require(disconnectedPanel.surface.initialCommand)
        defer { try? FileManager.default.removeItem(atPath: wrapperPath) }
        let result = Self.runProcess(
            executablePath: "/bin/sh",
            arguments: [wrapperPath],
            environment: ["PATH": "/usr/bin", SessionScrollbackReplayStore.environmentKey: replayPath],
            timeout: 5
        )
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout.contains(output), Comment(rawValue: result.stdout))
        #expect(!FileManager.default.fileExists(atPath: replayPath))
    }

    private static func makeRemoteConfiguration() -> WorkspaceRemoteConfiguration {
        WorkspaceRemoteConfiguration(
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
    }

    private static func generatedPersistentSSHForegroundAuthenticationStartupCommand(
        replacingSystemSSHWith fakeSSH: URL
    ) throws -> String {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(for: BundleToken.self)
        let socketPath = makeSocketPath("ssh-foreground-auth")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let workspaceID = "11111111-1111-1111-1111-111111111111"
        let workspaceRef = "workspace:9"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return malformedRequestResponse(raw: line)
            }

            switch method {
            case "workspace.create":
                return v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "workspace_id": workspaceID,
                        "surface_id": "surface:1",
                    ]
                )
            case "workspace.remote.configure":
                return v2Response(
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
                return v2Response(
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
                "--ssh-option", "ControlMaster auto",
                "--ssh-option", "ControlPersist 600",
                "--ssh-option", "ControlPath \(SSHConnectionSharingOptions().defaultControlPath)",
                "cmux-macmini",
            ],
            environment: environment,
            timeout: 5
        )

        #expect(serverHandled.wait(timeout: .now() + 5) == .success)
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stderr.isEmpty, Comment(rawValue: result.stderr))

        let requests = state.snapshot().compactMap(jsonObject)
        let configureRequest = try #require(
            requests.first { ($0["method"] as? String) == "workspace.remote.configure" }
        )
        let configureParams = try #require(configureRequest["params"] as? [String: Any])
        let startupCommand = try #require(configureParams["terminal_startup_command"] as? String)
        return try rewritingSystemSSH(in: startupCommand, with: fakeSSH)
    }

    private static func generatedVMSSHInitialStartupCommand(
        replacingSystemSSHWith fakeSSH: URL
    ) throws -> String {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(for: BundleToken.self)
        let socketPath = makeSocketPath("vm-ssh-startup")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let vmID = "vm-test-startup"
        let workspaceID = "11111111-1111-1111-1111-111111111111"
        let workspaceRef = "workspace:vm-startup"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return malformedRequestResponse(raw: line)
            }

            switch method {
            case "vm.ssh_info":
                let params = payload["params"] as? [String: Any] ?? [:]
                guard params["id"] as? String == vmID else {
                    return v2Response(id: id, ok: false, error: ["code": "invalid_params", "message": "unexpected attach params"])
                }
                return v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "transport": "ssh",
                        "host": "gateway.freestyle.sh",
                        "port": 2222,
                        "username": "cmux",
                        "credential": [
                            "kind": "password",
                            "value": "lease-token",
                        ],
                    ]
                )
            case "workspace.create":
                return v2Response(id: id, ok: true, result: ["workspace_id": workspaceID])
            case "workspace.rename":
                return v2Response(id: id, ok: true, result: ["workspace_id": workspaceID])
            case "workspace.remote.configure":
                return v2Response(
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
            case "workspace.select":
                return v2Response(id: id, ok: true, result: ["workspace_id": workspaceID])
            default:
                return v2Response(id: id, ok: false, error: ["code": "unexpected", "message": "Unexpected method \(method)"])
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["vm", "ssh", vmID],
            environment: environment,
            timeout: 5
        )

        #expect(serverHandled.wait(timeout: .now() + 5) == .success)
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stderr.isEmpty, Comment(rawValue: result.stderr))

        let requests = state.snapshot().compactMap(jsonObject)
        let createRequest = try #require(
            requests.first { ($0["method"] as? String) == "workspace.create" }
        )
        let createParams = try #require(createRequest["params"] as? [String: Any])
        let startupCommand = try #require(createParams["initial_command"] as? String)
        return try rewritingSystemSSH(in: startupCommand, with: fakeSSH)
    }

    private static func rewritingSystemSSH(
        in startupCommand: String,
        with fakeSSH: URL
    ) throws -> String {
        let systemSSHPath = "/usr/bin/ssh"
        let commandURL = URL(
            fileURLWithPath: startupCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: commandURL.path, isDirectory: &isDirectory),
           !isDirectory.boolValue {
            let script = try String(contentsOf: commandURL, encoding: .utf8)
            try #require(script.contains(systemSSHPath))
            try script
                .replacingOccurrences(of: systemSSHPath, with: fakeSSH.path)
                .write(to: commandURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: commandURL.path
            )
            return startupCommand
        }

        if startupCommand.contains(systemSSHPath) {
            return startupCommand.replacingOccurrences(of: systemSSHPath, with: fakeSSH.path)
        }

        let encodedPrefix = "(printf %s "
        let encodedSuffix = " | base64"
        let prefixRange = try #require(startupCommand.range(of: encodedPrefix))
        let suffixRange = try #require(
            startupCommand.range(
                of: encodedSuffix,
                range: prefixRange.upperBound..<startupCommand.endIndex
            )
        )
        let encodedRange = prefixRange.upperBound..<suffixRange.lowerBound
        let encodedScript = String(startupCommand[encodedRange])
        let scriptData = try #require(Data(base64Encoded: encodedScript))
        let script = try #require(String(data: scriptData, encoding: .utf8))
        try #require(script.contains(systemSSHPath))
        let rewrittenScript = script.replacingOccurrences(of: systemSSHPath, with: fakeSSH.path)
        var rewrittenCommand = startupCommand
        rewrittenCommand.replaceSubrange(
            encodedRange,
            with: Data(rewrittenScript.utf8).base64EncodedString()
        )
        return rewrittenCommand
    }

    private static func makeTerminalExitPromptFixture() throws -> TerminalExitPromptFixture {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-exit-prompt-fixture-\(UUID().uuidString)", isDirectory: true)
        let fakeCLI = root.appendingPathComponent("cmux")
        let fakeSSH = root.appendingPathComponent("ssh")
        let fakeSleep = root.appendingPathComponent("sleep")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        do {
            try writeShellFile(at: fakeCLI, lines: ["#!/bin/sh", "exit 0"])
            try writeShellFile(at: fakeSSH, lines: [
                "#!/bin/sh",
                "printf '%s\\n' 'Permission denied (publickey).' >&2",
                "exit 255",
            ])
            try writeShellFile(at: fakeSleep, lines: ["#!/bin/sh", "exit 0"])
            for executable in [fakeCLI, fakeSSH, fakeSleep] {
                try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            }

            let startupCommand = try generatedPersistentSSHForegroundAuthenticationStartupCommand(
                replacingSystemSSHWith: fakeSSH
            )
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "\(root.path):\(environment["PATH"] ?? "/usr/bin:/bin")"
            environment["CMUX_BUNDLED_CLI_PATH"] = fakeCLI.path
            environment["CMUX_SOCKET_PATH"] = "/tmp/cmux-debug-test.sock"
            environment["CMUX_WORKSPACE_ID"] = "11111111-1111-1111-1111-111111111111"
            environment["CMUX_SURFACE_ID"] = "22222222-2222-2222-2222-222222222222"
            environment["CMUX_SSH_RECONNECT_DELAY_SECONDS"] = "2"
            environment["CMUX_SSH_RECONNECT_MAX_DELAY_SECONDS"] = "2"
            return TerminalExitPromptFixture(
                startupCommand: startupCommand,
                environment: environment,
                temporaryDirectory: root
            )
        } catch {
            try? fileManager.removeItem(at: root)
            throw error
        }
    }

    private static func makeTerminalExitPromptProcess() throws -> TerminalExitPromptProcess {
        let fixture = try makeTerminalExitPromptFixture()
        let transcriptURL = fixture.temporaryDirectory.appendingPathComponent("transcript.txt")
        try Data().write(to: transcriptURL)
        let transcriptHandle = try FileHandle(forWritingTo: transcriptURL)
        let process = Process()
        let standardInput = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "-F", "/dev/null", "/bin/sh", "-c", fixture.startupCommand]
        process.environment = fixture.environment
        process.standardInput = standardInput
        process.standardOutput = transcriptHandle
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            try? transcriptHandle.close()
            try? FileManager.default.removeItem(at: fixture.temporaryDirectory)
            throw error
        }
        return TerminalExitPromptProcess(
            process: process,
            standardInput: standardInput,
            transcriptURL: transcriptURL,
            transcriptHandle: transcriptHandle,
            temporaryDirectory: fixture.temporaryDirectory
        )
    }

    private static func startMockServer(
        listenerFD: Int32,
        state: MockSocketServerState,
        handler: @escaping @Sendable (String) -> String
    ) -> DispatchSemaphore {
        let handled = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            defer { handled.signal() }

            var clientAddr = sockaddr_un()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    Darwin.accept(listenerFD, sockaddrPtr, &clientAddrLen)
                }
            }
            guard clientFD >= 0 else { return }
            defer { Darwin.close(clientFD) }

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

    private static func runProcess(
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
            return ProcessRunResult(status: -1, stdout: "", stderr: String(describing: error), timedOut: false)
        }

        if let standardInput, let stdinPipe {
            try? stdinPipe.fileHandleForWriting.write(contentsOf: Data(standardInput.utf8))
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
        return ProcessRunResult(status: process.terminationStatus, stdout: stdout, stderr: stderr, timedOut: timedOut)
    }

    private static func writeShellFile(at url: URL, lines: [String]) throws {
        try lines.joined(separator: "\n")
            .appending("\n")
            .write(to: url, atomically: true, encoding: .utf8)
    }

    private static func waitForFile(
        at url: URL,
        containing expectedContents: String,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            let contents = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            if contents.contains(expectedContents) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        let contents = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return contents.contains(expectedContents)
    }

    private static func waitForExit(_ process: Process, timeout: TimeInterval) -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while process.isRunning, Date.now < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if !process.isRunning {
            process.waitUntilExit()
            return true
        }
        return false
    }

    private static func stopAndCleanUp(_ prompt: TerminalExitPromptProcess) {
        if prompt.process.isRunning {
            prompt.process.terminate()
            if !waitForExit(prompt.process, timeout: 1) {
                Darwin.kill(prompt.process.processIdentifier, SIGKILL)
                prompt.process.waitUntilExit()
            }
        }
        try? prompt.standardInput.fileHandleForWriting.close()
        try? prompt.transcriptHandle.close()
        try? FileManager.default.removeItem(at: prompt.temporaryDirectory)
    }

    private static func makeSocketPath(_ name: String) -> String {
        let shortID = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        return "/tmp/cli-\(name.prefix(3))-\(shortID).sock"
    }

    private static func bindUnixSocket(at path: String) throws -> Int32 {
        unlink(path)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw testError("failed to create unix socket")
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxPathLength = MemoryLayout.size(ofValue: addr.sun_path)
        let utf8 = Array(path.utf8)
        guard utf8.count < maxPathLength else {
            Darwin.close(fd)
            throw testError("socket path too long")
        }
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: maxPathLength) { buffer in
                for index in 0..<utf8.count {
                    buffer[index] = CChar(bitPattern: utf8[index])
                }
                buffer[utf8.count] = 0
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(fd, 1) == 0 else {
            Darwin.close(fd)
            throw testError("failed to bind unix socket")
        }
        return fd
    }

    private static func v2Response(
        id: String,
        ok: Bool,
        result: [String: Any]? = nil,
        error: [String: Any]? = nil
    ) -> String {
        var payload: [String: Any] = ["id": id, "ok": ok]
        if let result { payload["result"] = result }
        if let error { payload["error"] = error }
        let data = try? JSONSerialization.data(withJSONObject: payload, options: [])
        return String(data: data ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
    }

    private static func malformedRequestResponse(raw: String) -> String {
        v2Response(
            id: "unknown",
            ok: false,
            error: ["code": "malformed_request", "message": "invalid or non-JSON payload", "raw": raw]
        )
    }

    private static func jsonObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
    }

    private static func testError(_ message: String) -> NSError {
        NSError(domain: "cmux.tests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
