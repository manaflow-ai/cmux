import Foundation
import XCTest

extension CLINotifyProcessIntegrationRegressionTests {
    func testSSHDirectSignalTerminatesForegroundAuthenticationProcessTree() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-foreground-auth-tree-\(UUID().uuidString)", isDirectory: true)
        let fakeCLI = root.appendingPathComponent("cmux")
        let fakeSSH = root.appendingPathComponent("ssh")
        let childPIDFile = root.appendingPathComponent("auth-child-pid")
        let childSignalLog = root.appendingPathComponent("auth-child-signal")

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try writeForegroundAuthSignalShellFile(at: fakeCLI, lines: ["#!/bin/sh", "exit 0"])
        try writeForegroundAuthSignalShellFile(at: fakeSSH, lines: [
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

        let startupCommand = try generatedPersistentSSHForegroundAuthenticationStartupCommand()
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(root.path):\(environment["PATH"] ?? "/usr/bin:/bin")"
        environment["CMUX_BUNDLED_CLI_PATH"] = fakeCLI.path
        environment["CMUX_SOCKET_PATH"] = "/tmp/cmux-debug-test.sock"
        environment["CMUX_WORKSPACE_ID"] = "11111111-1111-1111-1111-111111111111"
        environment["CMUX_SURFACE_ID"] = "22222222-2222-2222-2222-222222222222"
        environment["CMUX_TEST_AUTH_CHILD_PID"] = childPIDFile.path
        environment["CMUX_TEST_AUTH_CHILD_SIGNAL"] = childSignalLog.path
        environment["CMUX_SSH_RECONNECT_DELAY_SECONDS"] = "0"

        let result = runProcess(
            executablePath: "/bin/sh",
            arguments: ["-c", startupCommand],
            environment: environment,
            timeout: 5
        )
        let childPID = try XCTUnwrap(Int32(
            String(contentsOf: childPIDFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        defer {
            Darwin.kill(childPID, SIGKILL)
        }

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 130, result.stderr)
        XCTAssertTrue(
            waitForForegroundAuthenticationSignalLog(childSignalLog) { $0.contains("term") },
            "Direct startup signals must terminate the nested authentication process tree"
        )
    }

    func testSSHControlCThroughForegroundAuthenticationPTYExitsWithoutWaitingForInput() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-foreground-auth-signal-\(UUID().uuidString)", isDirectory: true)
        let fakeCLI = root.appendingPathComponent("cmux")
        let fakeSSH = root.appendingPathComponent("ssh")
        let authReadyMarker = root.appendingPathComponent("auth-ready")

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try writeForegroundAuthSignalShellFile(at: fakeCLI, lines: [
            "#!/bin/sh",
            "exit 0",
        ])
        try writeForegroundAuthSignalShellFile(at: fakeSSH, lines: [
            "#!/bin/sh",
            "trap 'exit 130' INT",
            "printf '%s\\n' ready > \"${CMUX_TEST_AUTH_READY_MARKER:?}\"",
            "while :; do /bin/sleep 30; done",
        ])
        for executable in [fakeCLI, fakeSSH] {
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }

        let startupCommand = try generatedPersistentSSHForegroundAuthenticationStartupCommand()
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
        process.arguments = ["-q", "-e", "/dev/null", "/bin/sh", "-c", startupCommand]
        process.environment = environment
        process.standardInput = standardInput
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let exited = expectation(description: "foreground authentication signal exits startup wrapper")
        process.terminationHandler = { _ in exited.fulfill() }
        try process.run()

        let authReadyDeadline = Date().addingTimeInterval(3)
        while !fileManager.fileExists(atPath: authReadyMarker.path),
              process.isRunning,
              Date() < authReadyDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(
            fileManager.fileExists(atPath: authReadyMarker.path),
            "Timed out waiting for foreground authentication to enter its nested PTY"
        )
        if fileManager.fileExists(atPath: authReadyMarker.path) {
            try standardInput.fileHandleForWriting.write(contentsOf: Data([0x03]))
        }

        let result = XCTWaiter.wait(for: [exited], timeout: 3)
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        try? standardInput.fileHandleForWriting.close()

        XCTAssertEqual(
            result,
            .completed,
            "Ctrl-C during foreground authentication must not fall through to the final Enter prompt"
        )
        XCTAssertEqual(process.terminationStatus, 130)
    }

    func testSSHDirectSignalInterruptsInitialAuthenticationBackoff() throws {
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

        try writeForegroundAuthSignalShellFile(at: fakeCLI, lines: ["#!/bin/sh", "exit 0"])
        try writeForegroundAuthSignalShellFile(at: fakeSSH, lines: [
            "#!/bin/sh",
            "printf '%s\\n' 'ssh: connect to host boot-retry.example.test port 22: Network is unreachable' >&2",
            "exit 255",
        ])
        try writeForegroundAuthSignalShellFile(at: fakeSleep, lines: [
            "#!/bin/sh",
            "printf '%s\\n' ready > \"${CMUX_TEST_BACKOFF_READY:?}\"",
            "printf '%s\\n' \"$$\" > \"${CMUX_TEST_BACKOFF_PID:?}\"",
            "exec /bin/sleep \"$1\"",
        ])
        for executable in [fakeCLI, fakeSSH, fakeSleep] {
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }

        let startupCommand = try generatedPersistentSSHForegroundAuthenticationStartupCommand()
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
        let readyDeadline = Date.now.addingTimeInterval(3)
        while !fileManager.fileExists(atPath: backoffReadyMarker.path),
              process.isRunning,
              Date.now < readyDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(
            fileManager.fileExists(atPath: backoffReadyMarker.path),
            "Timed out waiting for initial authentication retry backoff"
        )
        backoffPID = try XCTUnwrap(Int32(
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

        XCTAssertTrue(exitedPromptly, "SIGINT must interrupt initial authentication backoff promptly")
        XCTAssertEqual(process.terminationStatus, 130)
    }

    func testSSHInitialStartupStopsAtForegroundAuthenticationFailureLimit() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-foreground-auth-limit-\(UUID().uuidString)", isDirectory: true)
        let fakeCLI = root.appendingPathComponent("cmux")
        let fakeSSH = root.appendingPathComponent("ssh")
        let fakeSleep = root.appendingPathComponent("sleep")
        let attemptFile = root.appendingPathComponent("ssh-attempts.txt")

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try writeForegroundAuthSignalShellFile(at: fakeCLI, lines: ["#!/bin/sh", "exit 0"])
        try writeForegroundAuthSignalShellFile(at: fakeSSH, lines: [
            "#!/bin/sh",
            "count=$(cat \"${CMUX_TEST_ATTEMPT_FILE}\" 2>/dev/null || printf 0)",
            "count=$((count + 1))",
            "printf '%s' \"$count\" > \"${CMUX_TEST_ATTEMPT_FILE}\"",
            "printf '%s\\n' 'ssh: connect to host boot-retry.example.test port 22: Network is unreachable' >&2",
            "exit 255",
        ])
        try writeForegroundAuthSignalShellFile(at: fakeSleep, lines: ["#!/bin/sh", "exit 0"])
        for executable in [fakeCLI, fakeSSH, fakeSleep] {
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }

        let startupCommand = try generatedPersistentSSHForegroundAuthenticationStartupCommand()
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(root.path):\(environment["PATH"] ?? "/usr/bin:/bin")"
        environment["CMUX_BUNDLED_CLI_PATH"] = fakeCLI.path
        environment["CMUX_SOCKET_PATH"] = "/tmp/cmux-debug-test.sock"
        environment["CMUX_WORKSPACE_ID"] = "11111111-1111-1111-1111-111111111111"
        environment["CMUX_SURFACE_ID"] = "22222222-2222-2222-2222-222222222222"
        environment["CMUX_TEST_ATTEMPT_FILE"] = attemptFile.path
        environment["CMUX_SSH_RECONNECT_DELAY_SECONDS"] = "2"
        environment["CMUX_SSH_RECONNECT_MAX_DELAY_SECONDS"] = "2"

        let result = runProcess(
            executablePath: "/bin/sh",
            arguments: ["-c", startupCommand],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 255, result.stderr)
        XCTAssertEqual(try String(contentsOf: attemptFile, encoding: .utf8), "20")
    }

    private func writeForegroundAuthSignalShellFile(at url: URL, lines: [String]) throws {
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func waitForForegroundAuthenticationSignalLog(
        _ url: URL,
        predicate: (String) -> Bool
    ) -> Bool {
        let deadline = Date.now.addingTimeInterval(3)
        while Date.now < deadline {
            let contents = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            if predicate(contents) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return false
    }
}
