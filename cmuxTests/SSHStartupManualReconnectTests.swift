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
    struct ProcessRunResult {
        let status: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
    }

    final class MockSocketServerState: @unchecked Sendable {
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

    @Test func failedVMStartupClosesAfterDismissalWithoutImplicitReconnect() throws {
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

        let prompt = try Self.makeTerminalExitPromptProcess(TerminalExitPromptFixture(
            startupCommand: startupCommand,
            environment: environment,
            temporaryDirectory: root
        ))
        defer { Self.stopAndCleanUp(prompt) }
        try #require(Self.waitForTerminalExitPrompt(prompt), "the failed VM connection must reach its dismissal prompt")

        // Startup no longer owns manual reconnect. The old retry character is
        // ordinary input; Enter dismisses this failed attempt without an RPC.
        try prompt.standardInput.fileHandleForWriting.write(contentsOf: Data("r\n".utf8))
        try #require(Self.waitForExit(prompt.process, timeout: 3))
        #expect(prompt.process.terminationStatus == 1)
        #expect(try String(contentsOf: attemptFile, encoding: .utf8) == "1")
        let recordedCalls = try String(contentsOf: logFile, encoding: .utf8)
        #expect(recordedCalls.split(separator: "\n").filter { $0.contains("ssh-session-end") }.count == 1)
        #expect(!recordedCalls.contains("rpc workspace.remote.reconnect "))
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
        let prompt = try Self.makeTerminalExitPromptProcess(TerminalExitPromptFixture(
            startupCommand: startupURL.path,
            environment: environment,
            temporaryDirectory: root
        ))
        defer { Self.stopAndCleanUp(prompt) }
        try #require(Self.waitForTerminalExitPrompt(prompt))
        try prompt.standardInput.fileHandleForWriting.write(contentsOf: Data([0x0A]))
        try #require(Self.waitForExit(prompt.process, timeout: 3))
        #expect(prompt.process.terminationStatus == 7)
        let transcript = try String(contentsOf: prompt.transcriptURL, encoding: .utf8)
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

    @Test func directSignalTerminatesPersistentAttachAuthenticationProcessTree() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-foreground-auth-tree-\(UUID().uuidString)", isDirectory: true)
        let fakeCLI = root.appendingPathComponent("cmux")
        let fakeSSH = root.appendingPathComponent("ssh")
        let childPIDFile = root.appendingPathComponent("auth-child-pid")
        let grandchildPIDFile = root.appendingPathComponent("auth-grandchild-pid")

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try Self.writeShellFile(at: fakeCLI, lines: ["#!/bin/sh", "exit 0"])
        try Self.writeShellFile(at: fakeSSH, lines: [
            "#!/bin/sh",
            "trap '' HUP INT TERM",
            "printf '%s\\n' \"$$\" > \"${CMUX_TEST_AUTH_CHILD_PID:?}\"",
            "/bin/sleep 30 &",
            "printf '%s\\n' \"$!\" > \"${CMUX_TEST_AUTH_GRANDCHILD_PID:?}\"",
            "wait $!",
        ])
        for executable in [fakeCLI, fakeSSH] {
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }

        let startupCommand = Self.persistentAttachSupervisorCommand(replacingSystemSSHWith: fakeSSH)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(root.path):\(environment["PATH"] ?? "/usr/bin:/bin")"
        environment["CMUX_BUNDLED_CLI_PATH"] = fakeCLI.path
        environment["CMUX_SOCKET_PATH"] = "/tmp/cmux-debug-test.sock"
        environment["CMUX_WORKSPACE_ID"] = "11111111-1111-1111-1111-111111111111"
        environment["CMUX_SURFACE_ID"] = "22222222-2222-2222-2222-222222222222"
        environment["CMUX_TEST_AUTH_CHILD_PID"] = childPIDFile.path
        environment["CMUX_TEST_AUTH_GRANDCHILD_PID"] = grandchildPIDFile.path
        environment["CMUX_SSH_RECONNECT_DELAY_SECONDS"] = "0"

        let process = Process()
        let processExited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in processExited.signal() }
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "exec " + startupCommand]
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        var childPID: Int32?
        var grandchildPID: Int32?
        defer {
            if let childPID { Darwin.kill(childPID, SIGKILL) }
            if let grandchildPID { Darwin.kill(grandchildPID, SIGKILL) }
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }
        try SSHStartupCommandTestSupport.startProcess(process)
        try #require(Self.waitForFile(at: childPIDFile, containing: "\n", timeout: 3))
        let readyChildPID = try #require(Int32(
            String(contentsOf: childPIDFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        childPID = readyChildPID
        try #require(Self.waitForFile(at: grandchildPIDFile, containing: "\n", timeout: 3))
        let readyGrandchildPID = try #require(Int32(
            String(contentsOf: grandchildPIDFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        grandchildPID = readyGrandchildPID
        // The policy allows one 2s discovery window plus a bounded force pass.
        // Its deadline regression bounds total cleanup at 15s; this TERM-resistant
        // tree exercises that force pass, not a 3s graceful-exit contract.
        let signaledAt = DispatchTime.now()
        try #require(Darwin.kill(process.processIdentifier, SIGINT) == 0)
        let observedExit = processExited.wait(timeout: signaledAt + 15) == .success
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - signaledAt.uptimeNanoseconds) / 1_000_000_000
        try #require(
            observedExit,
            "SIGINT completion after \(elapsed)s: root=\(String(describing: Self.processIsRunning(process.processIdentifier))), child=\(String(describing: Self.processIsRunning(readyChildPID))), grandchild=\(String(describing: Self.processIsRunning(readyGrandchildPID))), FoundationRunning=\(process.isRunning)"
        )
        #expect(process.terminationStatus == 130)
        // A bounded cleanup may escalate to SIGKILL. Verify the processes are
        // gone, rather than requiring a particular signal handler to run.
        #expect(Self.processIsRunning(readyChildPID) == false)
        #expect(Self.processIsRunning(readyGrandchildPID) == false)
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

        let startup = try Self.generatedPersistentSSHForegroundAuthenticationStartupCommand(
            replacingSystemSSHWith: fakeSSH
        )
        defer { Self.removeFixturePaths(startup.cleanupPaths) }
        let startupCommand = startup.command
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

        try SSHStartupCommandTestSupport.startProcess(process)
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

    @Test func directSignalInterruptsPersistentAttachAuthenticationBackoff() throws {
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

        let startupCommand = Self.persistentAttachSupervisorCommand(replacingSystemSSHWith: fakeSSH)
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
        process.arguments = ["-c", "exec " + startupCommand]
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

        try SSHStartupCommandTestSupport.startProcess(process)
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

    @Test func persistentAttachExitsAtForegroundAuthenticationFailureLimit() throws {
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

        let startup = try Self.generatedPersistentSSHForegroundAuthenticationStartupCommand(
            replacingSystemSSHWith: fakeSSH
        )
        defer { Self.removeFixturePaths(startup.cleanupPaths) }
        let startupCommand = startup.command
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
            timeout: 10
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 255, Comment(rawValue: result.stderr))
        let attempts = try String(contentsOf: attemptFile, encoding: .utf8)
        #expect(attempts == "20", Comment(rawValue: result.stderr))
    }

    @Test func establishedStartupRetriesUnclassifiedReauthenticationFailure() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-unclassified-reauth-\(UUID().uuidString)", isDirectory: true)
        let fakeCLI = root.appendingPathComponent("cmux")
        let fakeSSH = root.appendingPathComponent("ssh")
        let fakeSleep = root.appendingPathComponent("sleep")
        let attemptFile = root.appendingPathComponent("ssh-attempts.txt")
        let attachFile = root.appendingPathComponent("attach-attempts.txt")

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try Self.writeShellFile(at: fakeCLI, lines: [
            "#!/bin/sh",
            "case \" $* \" in",
            "  *\" ssh-pty-attach \"*)",
            "    count=$(cat \"${CMUX_TEST_ATTACH_FILE}\" 2>/dev/null || printf 0)",
            "    count=$((count + 1))",
            "    printf '%s' \"$count\" > \"${CMUX_TEST_ATTACH_FILE}\"",
            "    if [ \"$count\" -eq 1 ]; then exit 255; fi ;;",
            "esac",
            "exit 0",
        ])
        try Self.writeShellFile(at: fakeSSH, lines: [
            "#!/bin/sh",
            "count=$(cat \"${CMUX_TEST_ATTEMPT_FILE}\" 2>/dev/null || printf 0)",
            "count=$((count + 1))",
            "printf '%s' \"$count\" > \"${CMUX_TEST_ATTEMPT_FILE}\"",
            "case \"$count\" in",
            "  1) exit 0 ;;",
            "  2) printf '%s\\n' 'unclassified authentication failure' >&2; exit 255 ;;",
            "  *) exit 0 ;;",
            "esac",
        ])
        try Self.writeShellFile(at: fakeSleep, lines: ["#!/bin/sh", "exit 0"])
        for executable in [fakeCLI, fakeSSH, fakeSleep] {
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }

        let startup = try Self.generatedPersistentSSHForegroundAuthenticationStartupCommand(
            replacingSystemSSHWith: fakeSSH
        )
        defer { Self.removeFixturePaths(startup.cleanupPaths) }
        let startupCommand = startup.command
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(root.path):\(environment["PATH"] ?? "/usr/bin:/bin")"
        environment["CMUX_BUNDLED_CLI_PATH"] = fakeCLI.path
        environment["CMUX_SOCKET_PATH"] = "/tmp/cmux-debug-test.sock"
        environment["CMUX_WORKSPACE_ID"] = "11111111-1111-1111-1111-111111111111"
        environment["CMUX_SURFACE_ID"] = "22222222-2222-2222-2222-222222222222"
        environment["CMUX_TEST_ATTEMPT_FILE"] = attemptFile.path
        environment["CMUX_TEST_ATTACH_FILE"] = attachFile.path
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
        let authenticationAttempts = try String(contentsOf: attemptFile, encoding: .utf8)
        let attachAttempts = try String(contentsOf: attachFile, encoding: .utf8)
        #expect(authenticationAttempts == "3")
        #expect(attachAttempts == "2")
    }

    @Test func terminalExitPromptIgnoresQueuedWakeReportsAndEOTUntilFreshEnter() throws {
        let prompt = try Self.makeTerminalExitPromptProcess()
        defer { Self.stopAndCleanUp(prompt) }

        let queuedWakeInput = Data("\u{1B}[I\u{1B}[O\u{1B}[13;2u".utf8) + Data([0x04])
        try prompt.standardInput.fileHandleForWriting.write(contentsOf: queuedWakeInput)
        #expect(
            Self.waitForTerminalExitPrompt(prompt),
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
            Self.waitForTerminalExitPrompt(prompt),
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

        let startup = try Self.generatedPersistentSSHForegroundAuthenticationStartupCommand(
            replacingSystemSSHWith: fakeSSH
        )
        defer { Self.removeFixturePaths(startup.cleanupPaths) }
        let startupCommand = startup.command
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(root.path):\(environment["PATH"] ?? "/usr/bin:/bin")"
        environment["CMUX_BUNDLED_CLI_PATH"] = fakeCLI.path
        environment["CMUX_SOCKET_PATH"] = "/tmp/cmux-debug-test.sock"
        environment["CMUX_WORKSPACE_ID"] = "11111111-1111-1111-1111-111111111111"
        environment["CMUX_SURFACE_ID"] = "22222222-2222-2222-2222-222222222222"
        environment["CMUX_TEST_ATTEMPT_FILE"] = attemptFile.path
        environment["CMUX_SSH_PENDING_SIGNAL"] = "130"
        environment["CMUX_SSH_PENDING_SIGNAL_NAME"] = "INT"
        environment["cmux_ssh_attach_pending_signal"] = "130"
        environment["cmux_ssh_attach_pending_signal_name"] = "INT"

        let result = Self.runProcess(
            executablePath: "/bin/sh",
            arguments: ["-c", startupCommand],
            environment: environment,
            timeout: 5
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        let authenticationAttempts = try String(contentsOf: attemptFile, encoding: .utf8)
        #expect(authenticationAttempts == "1")
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
    @Test func reconnectKeepsConnectedWorkspaceForEndedPaneRetry() throws {
        let workspace = Workspace()
        defer { workspace.disconnectRemoteConnection(clearConfiguration: true) }
        let configuration = Self.makeRemoteConfiguration()
        workspace.configureRemoteConnection(configuration, autoConnect: false)
        workspace.applyRemoteConnectionStateUpdate(
            .connected,
            detail: "Connected to cmux-macmini via shared local proxy 127.0.0.1:64007",
            target: "cmux-macmini"
        )

        let panel = try #require(workspace.newTerminalSurfaceInFocusedPane(focus: false))
        workspace.untrackRemoteTerminalSurface(panel.id)
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
        defer { workspace.disconnectRemoteConnection(clearConfiguration: true) }
        let configuration = Self.makeRemoteConfiguration()
        workspace.configureRemoteConnection(configuration, autoConnect: false)
        workspace.applyRemoteConnectionStateUpdate(
            .connected,
            detail: "Connected controller",
            target: configuration.displayTarget
        )
        let panelId = try #require(workspace.focusedTerminalPanel?.id)
        #expect(
            workspace.markRemoteTerminalSessionConnected(
                surfaceId: panelId,
                relayPort: configuration.relayPort
            )
        )
        #expect(workspace.hasAuthoritativelyConnectedRemoteTerminal)

        #expect(workspace.reconnectRemoteConnection(surfaceId: panelId))

        #expect(workspace.remoteConfiguration != nil)
        #expect(workspace.remoteConnectionState == .connected)
        #expect(workspace.activeRemoteTerminalSessionCount == 1)
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
    @Test func workspaceReconnectKeepsHealthyConnectedTerminal() throws {
        let workspace = Workspace()
        defer { workspace.disconnectRemoteConnection(clearConfiguration: true) }
        let configuration = Self.makeRemoteConfiguration()
        workspace.configureRemoteConnection(configuration, autoConnect: false)
        workspace.applyRemoteConnectionStateUpdate(
            .connected,
            detail: "Connected controller",
            target: configuration.displayTarget
        )
        let panel = try #require(workspace.focusedTerminalPanel)
        try #require(workspace.markRemoteTerminalSessionConnected(
            surfaceId: panel.id,
            relayPort: configuration.relayPort
        ))
        let lifecycleID = panel.surface.terminalLifecycleId

        #expect(!workspace.reconnectRemoteConnection())

        #expect(workspace.terminalPanel(for: panel.id) === panel)
        #expect(panel.surface.terminalLifecycleId == lifecycleID)
        #expect(workspace.remoteConfiguration != nil)
        #expect(workspace.activeRemoteTerminalSessionCount == 1)
        #expect(workspace.remoteTerminalSessionStatesBySurfaceId[panel.id]?.phase == .connected)
        #expect(workspace.hasAuthoritativelyConnectedRemoteTerminal)
        #expect(workspace.remoteConnectionState == .connected)
    }

    @MainActor
    @Test func reconnectingPresentationWithoutOwnerStartsAControllerTransition() async throws {
        let workspace = Workspace()
        defer { workspace.disconnectRemoteConnection(clearConfiguration: true) }
        let configuration = Self.makeRemoteConfiguration()
        workspace.configureRemoteConnection(configuration, autoConnect: false)
        await workspace.remoteSessionTransitionTask?.value
        workspace.applyRemoteConnectionStateUpdate(
            .reconnecting,
            detail: "Reconnecting to cmux-macmini via shared local proxy 127.0.0.1:64007",
            target: "cmux-macmini"
        )

        let panel = try #require(workspace.newTerminalSurfaceInFocusedPane(focus: false))
        workspace.untrackRemoteTerminalSurface(panel.id)
        workspace.pendingRemoteTerminalChildExitSurfaceIds.insert(panel.id)

        #expect(!workspace.isRemoteTerminalSurface(panel.id))
        #expect(workspace.remoteConnectionState == .reconnecting)

        #expect(workspace.remoteSessionController == nil)
        #expect(workspace.remoteSessionTransitionTask == nil)
        #expect(workspace.reconnectRemoteConnection(surfaceId: panel.id))

        #expect(workspace.isRemoteTerminalSurface(panel.id))
        #expect(!workspace.pendingRemoteTerminalChildExitSurfaceIds.contains(panel.id))
        #expect(workspace.remoteConnectionState == .connecting)
        #expect(workspace.remoteSessionTransitionTask != nil)
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

    static func startMockServer(
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

    static func runProcess(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) -> ProcessRunResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let exitSignal = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exitSignal.signal() }
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try SSHStartupCommandTestSupport.startProcess(process)
        } catch {
            return ProcessRunResult(status: -1, stdout: "", stderr: String(describing: error), timedOut: false)
        }

        let timedOut = exitSignal.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            _ = exitSignal.wait(timeout: .now() + 1)
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return ProcessRunResult(status: process.terminationStatus, stdout: stdout, stderr: stderr, timedOut: timedOut)
    }

    static func writeShellFile(at url: URL, lines: [String]) throws {
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

    private static func processIsRunning(_ pid: Int32) -> Bool? {
        var info = proc_bsdinfo()
        let expectedSize = MemoryLayout<proc_bsdinfo>.stride
        let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(expectedSize))
        if Int(size) == expectedSize { return info.pbi_status != UInt32(SZOMB) }
        if size <= 0, errno == ESRCH { return false }
        return nil
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

    private static func waitForTerminalExitPrompt(_ prompt: TerminalExitPromptProcess) -> Bool {
        guard waitForFile(
            at: prompt.transcriptURL,
            containing: "press Enter to close this pane",
            timeout: 3
        ), let path = try? String(contentsOf: prompt.terminalPathURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        let fd = Darwin.open(path, O_RDONLY | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        let deadline = Date.now.addingTimeInterval(3)
        while prompt.process.isRunning, Date.now < deadline {
            var state = termios()
            // The prompt text precedes the CLI helper. Raw input with ISIG is
            // observable only after that helper's atomic TCSAFLUSH boundary.
            if tcgetattr(fd, &state) == 0,
               state.c_lflag & tcflag_t(ICANON | ECHO) == 0,
               state.c_lflag & tcflag_t(ISIG) != 0 {
                return true
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return false
    }

    private static func stopAndCleanUp(_ prompt: TerminalExitPromptProcess) {
        if prompt.process.isRunning {
            // `script` can exit while its EOF-parked CLI child stays alive.
            // Retire the owned tree before losing the root's parent identity.
            let cleanupCommand = SSHForegroundAuthenticationRetryPolicy()
                .processTreeTerminationShellFunction()
                + "\ncmux_ssh_terminate_auth_process_tree \(prompt.process.processIdentifier) \(getpid())"
            let cleanup = runProcess(
                executablePath: "/bin/sh",
                arguments: ["-c", cleanupCommand],
                environment: ProcessInfo.processInfo.environment,
                timeout: 5
            )
            #expect(!cleanup.timedOut, Comment(rawValue: cleanup.stderr))
            #expect(cleanup.status == 0, Comment(rawValue: cleanup.stderr))
            if !waitForExit(prompt.process, timeout: 1) {
                Darwin.kill(prompt.process.processIdentifier, SIGKILL)
                prompt.process.waitUntilExit()
            }
        }
        try? prompt.standardInput.fileHandleForWriting.close()
        try? prompt.transcriptHandle.close()
        try? FileManager.default.removeItem(at: prompt.temporaryDirectory)
    }

    static func makeSocketPath(_ name: String) -> String {
        let shortID = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        return "/tmp/cli-\(name.prefix(3))-\(shortID).sock"
    }

    static func bindUnixSocket(at path: String) throws -> Int32 {
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

    static func v2Response(
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

    static func malformedRequestResponse(raw: String) -> String {
        v2Response(
            id: "unknown",
            ok: false,
            error: ["code": "malformed_request", "message": "invalid or non-JSON payload", "raw": raw]
        )
    }

    static func jsonObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
    }

    static func testError(_ message: String) -> NSError {
        NSError(domain: "cmux.tests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
