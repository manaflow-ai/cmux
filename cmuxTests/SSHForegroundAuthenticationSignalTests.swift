import Foundation
import XCTest

extension CLINotifyProcessIntegrationRegressionTests {
    func testSSHSignalDuringForegroundAuthenticationExitsWithoutWaitingForInput() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-foreground-auth-signal-\(UUID().uuidString)", isDirectory: true)
        let fakeCLI = root.appendingPathComponent("cmux")
        let fakeSSH = root.appendingPathComponent("ssh")

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try writeForegroundAuthSignalShellFile(at: fakeCLI, lines: [
            "#!/bin/sh",
            "exit 0",
        ])
        try writeForegroundAuthSignalShellFile(at: fakeSSH, lines: [
            "#!/bin/sh",
            "kill -INT \"${CMUX_SSH_STARTUP_PID:?}\"",
            "exit 130",
        ])
        for executable in [fakeCLI, fakeSSH] {
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }

        let startupCommand = try generatedVMSSHInitialStartupCommand()
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(root.path):\(environment["PATH"] ?? "/usr/bin:/bin")"
        environment["CMUX_BUNDLED_CLI_PATH"] = fakeCLI.path
        environment["CMUX_SOCKET_PATH"] = "/tmp/cmux-debug-test.sock"
        environment["CMUX_WORKSPACE_ID"] = "11111111-1111-1111-1111-111111111111"
        environment["CMUX_SURFACE_ID"] = "22222222-2222-2222-2222-222222222222"
        environment["CMUX_SSH_RECONNECT_DELAY_SECONDS"] = "0"

        let process = Process()
        let standardInput = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", startupCommand]
        process.environment = environment
        process.standardInput = standardInput
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let exited = expectation(description: "foreground authentication signal exits startup wrapper")
        process.terminationHandler = { _ in exited.fulfill() }
        try process.run()

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

        let startupCommand = try generatedVMSSHInitialStartupCommand()
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
}
