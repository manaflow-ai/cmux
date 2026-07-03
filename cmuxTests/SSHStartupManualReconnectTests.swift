import XCTest

extension CLINotifyProcessIntegrationRegressionTests {
    func testSSHStartupManualReconnectReentersConnectLoop() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-manual-retry-\(UUID().uuidString)", isDirectory: true)
        let fakeCLI = root.appendingPathComponent("cmux")
        let fakeSSH = root.appendingPathComponent("ssh")
        let logFile = root.appendingPathComponent("ssh-session-end.log")
        let attemptFile = root.appendingPathComponent("ssh-attempts.txt")

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try writeShellFile(at: fakeCLI, lines: [
            "#!/bin/sh",
            "printf '%s\\n' \"$*\" >> \"${CMUX_TEST_SESSION_END_LOG}\"",
        ])
        try writeShellFile(at: fakeSSH, lines: [
            "#!/bin/sh",
            "count=$(cat \"${CMUX_TEST_ATTEMPT_FILE}\" 2>/dev/null || printf 0)",
            "count=$((count + 1))",
            "printf '%s' \"$count\" > \"${CMUX_TEST_ATTEMPT_FILE}\"",
            "if [ \"$count\" -ge 2 ]; then exit 0; fi",
            "exit 1",
        ])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeCLI.path)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeSSH.path)

        let startupCommand = try generatedVMSSHInitialStartupCommand()
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(root.path):\(environment["PATH"] ?? "/usr/bin:/bin")"
        environment["CMUX_BUNDLED_CLI_PATH"] = fakeCLI.path
        environment["CMUX_SOCKET_PATH"] = "/tmp/cmux-debug-test.sock"
        environment["CMUX_WORKSPACE_ID"] = "11111111-1111-1111-1111-111111111111"
        environment["CMUX_SURFACE_ID"] = "22222222-2222-2222-2222-222222222222"
        environment["CMUX_TEST_SESSION_END_LOG"] = logFile.path
        environment["CMUX_TEST_ATTEMPT_FILE"] = attemptFile.path
        environment["CMUX_SSH_RECONNECT_DELAY_SECONDS"] = "0"

        let result = runProcess(
            executablePath: "/bin/sh",
            arguments: ["-c", startupCommand],
            environment: environment,
            standardInput: "r\n",
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(
            (try? String(contentsOf: attemptFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines),
            "2",
            "manual `r` retry must re-run the SSH connect loop a second time"
        )
        let recordedCalls = (try? String(contentsOf: logFile, encoding: .utf8)) ?? ""
        let sessionEndCalls = recordedCalls
            .split(separator: "\n")
            .filter { $0.contains("ssh-session-end") }
        XCTAssertEqual(sessionEndCalls.count, 2, result.stderr)
        XCTAssertTrue(
            recordedCalls.contains("rpc workspace.remote.reconnect {\"workspace_id\":\"11111111-1111-1111-1111-111111111111\",\"surface_id\":\"22222222-2222-2222-2222-222222222222\"}"),
            recordedCalls
        )
    }
}
