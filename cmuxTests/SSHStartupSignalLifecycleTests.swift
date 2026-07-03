import XCTest
import Darwin

extension CLINotifyProcessIntegrationRegressionTests {
    func testSSHPaneCloseSignalDoesNotReportSessionEndToSharedTransport() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-pane-close-\(UUID().uuidString)", isDirectory: true)
        let fakeCLI = root.appendingPathComponent("cmux")
        let fakeSSH = root.appendingPathComponent("ssh")
        let logFile = root.appendingPathComponent("ssh-session-end.log")

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try writeShellFile(at: fakeCLI, lines: [
            "#!/bin/sh",
            "printf '%s\\n' \"$*\" >> \"${CMUX_TEST_SESSION_END_LOG}\"",
        ])
        try writeShellFile(at: fakeSSH, lines: [
            "#!/bin/sh",
            "kill -\"${CMUX_TEST_SIGNAL:?}\" \"${CMUX_SSH_STARTUP_PID:-$PPID}\"",
            "sleep 0.1",
            "exit 0",
        ])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeCLI.path)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeSSH.path)

        let expectedStatuses: [String: Int32] = [
            "HUP": 129,
            "INT": 130,
            "TERM": 143,
        ]
        for signal in ["HUP", "INT", "TERM"] {
            try? fileManager.removeItem(at: logFile)
            let startupCommand = try generatedVMSSHInitialStartupCommand()

            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "\(root.path):\(environment["PATH"] ?? "/usr/bin:/bin")"
            environment["CMUX_BUNDLED_CLI_PATH"] = fakeCLI.path
            environment["CMUX_SOCKET_PATH"] = "/tmp/cmux-debug-test.sock"
            environment["CMUX_WORKSPACE_ID"] = "11111111-1111-1111-1111-111111111111"
            environment["CMUX_SURFACE_ID"] = "22222222-2222-2222-2222-222222222222"
            environment["CMUX_TEST_SESSION_END_LOG"] = logFile.path
            environment["CMUX_TEST_SIGNAL"] = signal

            let result = runProcess(
                executablePath: "/bin/sh",
                arguments: ["-c", startupCommand],
                environment: environment,
                timeout: 5
            )

            XCTAssertFalse(result.timedOut, result.stderr)
            let expectedStatus = try XCTUnwrap(expectedStatuses[signal])
            XCTAssertEqual(result.status, expectedStatus, result.stderr)
            let recordedCalls = (try? String(contentsOf: logFile, encoding: .utf8)) ?? ""
            let sessionEndCalls = recordedCalls
                .split(separator: "\n")
                .filter { $0.contains("ssh-session-end") }
            XCTAssertTrue(
                sessionEndCalls.isEmpty,
                "Pane-close \(signal) must not call ssh-session-end because that can tear down the shared SSH transport and kill sibling panes; recorded: \(recordedCalls)"
            )
        }
    }

    func testSSHPaneCloseSignalDoesNotTerminateWrappedSSHChild() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-pane-close-child-\(UUID().uuidString)", isDirectory: true)
        let fakeCLI = root.appendingPathComponent("cmux")
        let fakeSSH = root.appendingPathComponent("ssh")
        let logFile = root.appendingPathComponent("ssh-session-end.log")
        let childSignalLog = root.appendingPathComponent("ssh-child-signal.log")

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try writeShellFile(at: fakeCLI, lines: [
            "#!/bin/sh",
            "printf '%s\\n' \"$*\" >> \"${CMUX_TEST_SESSION_END_LOG}\"",
        ])
        try writeShellFile(at: fakeSSH, lines: [
            "#!/bin/sh",
            "trap 'printf \"%s\\n\" child-hup >> \"${CMUX_TEST_CHILD_SIGNAL_LOG}\"; exit 0' HUP",
            "trap 'printf \"%s\\n\" child-int >> \"${CMUX_TEST_CHILD_SIGNAL_LOG}\"; exit 0' INT",
            "trap 'printf \"%s\\n\" child-term >> \"${CMUX_TEST_CHILD_SIGNAL_LOG}\"; exit 0' TERM",
            "printf '%s\\n' child-started >> \"${CMUX_TEST_CHILD_SIGNAL_LOG}\"",
            "kill -\"${CMUX_TEST_SIGNAL:?}\" \"${CMUX_SSH_STARTUP_PID:-$PPID}\"",
            "sleep 0.2",
            "printf '%s\\n' child-completed >> \"${CMUX_TEST_CHILD_SIGNAL_LOG}\"",
            "exit 0",
        ])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeCLI.path)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeSSH.path)

        let expectedStatuses: [String: Int32] = [
            "HUP": 129,
            "INT": 130,
            "TERM": 143,
        ]
        for signal in ["HUP", "INT", "TERM"] {
            try? fileManager.removeItem(at: logFile)
            try? fileManager.removeItem(at: childSignalLog)

            let startupCommand = try generatedVMSSHInitialStartupCommand()
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "\(root.path):\(environment["PATH"] ?? "/usr/bin:/bin")"
            environment["CMUX_BUNDLED_CLI_PATH"] = fakeCLI.path
            environment["CMUX_SOCKET_PATH"] = "/tmp/cmux-debug-test.sock"
            environment["CMUX_WORKSPACE_ID"] = "11111111-1111-1111-1111-111111111111"
            environment["CMUX_SURFACE_ID"] = "22222222-2222-2222-2222-222222222222"
            environment["CMUX_TEST_SESSION_END_LOG"] = logFile.path
            environment["CMUX_TEST_CHILD_SIGNAL_LOG"] = childSignalLog.path
            environment["CMUX_TEST_SIGNAL"] = signal

            let result = runProcess(
                executablePath: "/bin/sh",
                arguments: ["-c", startupCommand],
                environment: environment,
                timeout: 5
            )

            XCTAssertFalse(result.timedOut, result.stderr)
            let expectedStatus = try XCTUnwrap(expectedStatuses[signal])
            XCTAssertEqual(result.status, expectedStatus, result.stderr)
            XCTAssertTrue(
                waitForSSHSignalLifecycleLog(childSignalLog) { contents in
                    contents.contains("child-completed") ||
                    contents.contains("child-hup") ||
                    contents.contains("child-int") ||
                    contents.contains("child-term")
                },
                "Timed out waiting for fake SSH child to record completion or signal for \(signal)"
            )
            let childSignalLogContents = (try? String(contentsOf: childSignalLog, encoding: .utf8)) ?? ""
            XCTAssertTrue(childSignalLogContents.contains("child-started"), childSignalLogContents)
            XCTAssertFalse(
                childSignalLogContents.contains("child-hup") ||
                childSignalLogContents.contains("child-int") ||
                childSignalLogContents.contains("child-term"),
                "Pane-close \(signal) should let the terminal/PTY teardown own the child process; explicitly signaling the SSH child can kill the shared control-master path and sibling panes. Log: \(childSignalLogContents)"
            )
            let recordedCalls = (try? String(contentsOf: logFile, encoding: .utf8)) ?? ""
            let sessionEndCalls = recordedCalls
                .split(separator: "\n")
                .filter { $0.contains("ssh-session-end") }
            XCTAssertTrue(sessionEndCalls.isEmpty, recordedCalls)
        }
    }

    func testSSHStartupRetriesTransientSSHExitBeforeReportingSessionEnd() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-reconnect-\(UUID().uuidString)", isDirectory: true)
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
            "count=0",
            "if [ -r \"${CMUX_TEST_ATTEMPT_FILE}\" ]; then count=$(cat \"${CMUX_TEST_ATTEMPT_FILE}\"); fi",
            "count=$((count + 1))",
            "printf '%s\\n' \"$count\" > \"${CMUX_TEST_ATTEMPT_FILE}\"",
            "if [ \"$count\" -eq 1 ]; then exit 255; fi",
            "exit 0",
        ])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeCLI.path)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeSSH.path)

        let startupCommand = try generatedSSHStartupCommand()
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
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        // The regular `cmux ssh` bootstrap path runs one SSH command to install
        // the remote bootstrap and another to open the session. A transient
        // install-channel failure therefore yields three raw SSH invocations:
        // failed install, retried install, successful session.
        XCTAssertEqual((try? String(contentsOf: attemptFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines), "3")
        let recordedCalls = (try? String(contentsOf: logFile, encoding: .utf8)) ?? ""
        let sessionEndCalls = recordedCalls
            .split(separator: "\n")
            .filter { $0.contains("ssh-session-end") }
        XCTAssertEqual(sessionEndCalls.count, 1, recordedCalls)
    }

    func testSSHStartupRemovesStaleCmuxControlSocketBeforeLaunchingPaneSSH() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-stale-control-\(UUID().uuidString)", isDirectory: true)
        let fakeCLI = root.appendingPathComponent("cmux")
        let fakeSSH = root.appendingPathComponent("ssh")
        let logFile = root.appendingPathComponent("ssh.log")
        let staleControlPath = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("cmux-ssh-\(getuid())-\(UUID().uuidString.prefix(8)).sock")

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: root)
            unlink(staleControlPath.path)
        }

        let staleSocketFD = try bindUnixSocket(at: staleControlPath.path)
        Darwin.close(staleSocketFD)
        XCTAssertTrue(fileManager.fileExists(atPath: staleControlPath.path))

        try writeShellFile(at: fakeCLI, lines: [
            "#!/bin/sh",
            "printf '%s\\n' \"$*\" >> \"${CMUX_TEST_SESSION_END_LOG}\"",
        ])
        try writeShellFile(at: fakeSSH, lines: [
            "#!/bin/sh",
            "printf '%s\\n' \"$*\" >> \"${CMUX_TEST_SSH_LOG}\"",
            "for arg in \"$@\"; do",
            "  if [ \"$arg\" = '-G' ]; then",
            "    printf 'controlpath %s\\n' \"${CMUX_TEST_CONTROL_PATH}\"",
            "    exit 0",
            "  fi",
            "done",
            "previous_arg=",
            "for arg in \"$@\"; do",
            "  if [ \"$previous_arg\" = '-O' ] && [ \"$arg\" = 'check' ]; then",
            "    exit 255",
            "  fi",
            "  previous_arg=\"$arg\"",
            "done",
            "if [ -e \"${CMUX_TEST_CONTROL_PATH}\" ]; then",
            "  printf 'ControlSocket %s already exists, disabling multiplexing\\n' \"${CMUX_TEST_CONTROL_PATH}\" >&2",
            "  exit 99",
            "fi",
            "exit 0",
        ])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeCLI.path)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeSSH.path)

        let startupCommand = try generatedSSHStartupCommand(sshOptions: [
            "ControlMaster auto",
            "ControlPersist 600",
            "ControlPath \(staleControlPath.path)",
        ])
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(root.path):\(environment["PATH"] ?? "/usr/bin:/bin")"
        environment["CMUX_BUNDLED_CLI_PATH"] = fakeCLI.path
        environment["CMUX_SOCKET_PATH"] = "/tmp/cmux-debug-test.sock"
        environment["CMUX_WORKSPACE_ID"] = "11111111-1111-1111-1111-111111111111"
        environment["CMUX_SURFACE_ID"] = "22222222-2222-2222-2222-222222222222"
        environment["CMUX_TEST_CONTROL_PATH"] = staleControlPath.path
        environment["CMUX_TEST_SESSION_END_LOG"] = root.appendingPathComponent("ssh-session-end.log").path
        environment["CMUX_TEST_SSH_LOG"] = logFile.path
        environment["CMUX_SSH_RECONNECT_DELAY_SECONDS"] = "0"

        let result = runProcess(
            executablePath: "/bin/sh",
            arguments: ["-c", startupCommand],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertFalse(fileManager.fileExists(atPath: staleControlPath.path))

        let sshLog = (try? String(contentsOf: logFile, encoding: .utf8)) ?? ""
        XCTAssertTrue(sshLog.contains("-G"), sshLog)
        XCTAssertTrue(sshLog.contains("-O check"), sshLog)
    }

    func testSSHStartupStopsAtConfiguredReconnectLimit() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-retry-limit-\(UUID().uuidString)", isDirectory: true)
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
            "count=0",
            "if [ -r \"${CMUX_TEST_ATTEMPT_FILE}\" ]; then count=$(cat \"${CMUX_TEST_ATTEMPT_FILE}\"); fi",
            "count=$((count + 1))",
            "printf '%s\\n' \"$count\" > \"${CMUX_TEST_ATTEMPT_FILE}\"",
            "exit 255",
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
        environment["CMUX_SSH_RECONNECT_LIMIT"] = "2"

        let result = runProcess(
            executablePath: "/bin/sh",
            arguments: ["-c", startupCommand],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 255, result.stderr)
        XCTAssertEqual((try? String(contentsOf: attemptFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines), "3")
        let recordedCalls = (try? String(contentsOf: logFile, encoding: .utf8)) ?? ""
        let sessionEndCalls = recordedCalls
            .split(separator: "\n")
            .filter { $0.contains("ssh-session-end") }
        XCTAssertEqual(sessionEndCalls.count, 1, recordedCalls)
    }

    func testSSHStartupDoesNotRetryNonTransientSSHExit() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-no-retry-\(UUID().uuidString)", isDirectory: true)
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
            "count=0",
            "if [ -r \"${CMUX_TEST_ATTEMPT_FILE}\" ]; then count=$(cat \"${CMUX_TEST_ATTEMPT_FILE}\"); fi",
            "count=$((count + 1))",
            "printf '%s\\n' \"$count\" > \"${CMUX_TEST_ATTEMPT_FILE}\"",
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
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 1, result.stderr)
        XCTAssertEqual((try? String(contentsOf: attemptFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines), "1")
        let recordedCalls = (try? String(contentsOf: logFile, encoding: .utf8)) ?? ""
        let sessionEndCalls = recordedCalls
            .split(separator: "\n")
            .filter { $0.contains("ssh-session-end") }
        XCTAssertEqual(sessionEndCalls.count, 1, recordedCalls)
    }

    func testSSHSignalDerivedChildExitReportsSessionEnd() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-child-signal-exit-\(UUID().uuidString)", isDirectory: true)
        let fakeCLI = root.appendingPathComponent("cmux")
        let fakeSSH = root.appendingPathComponent("ssh")
        let logFile = root.appendingPathComponent("ssh-session-end.log")

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try writeShellFile(at: fakeCLI, lines: [
            "#!/bin/sh",
            "printf '%s\\n' \"$*\" >> \"${CMUX_TEST_SESSION_END_LOG}\"",
        ])
        try writeShellFile(at: fakeSSH, lines: [
            "#!/bin/sh",
            "exit 130",
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
        environment["CMUX_SSH_RECONNECT_DELAY_SECONDS"] = "0"

        let result = runProcess(
            executablePath: "/bin/sh",
            arguments: ["-c", startupCommand],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 130, result.stderr)
        let recordedCalls = (try? String(contentsOf: logFile, encoding: .utf8)) ?? ""
        let sessionEndCalls = recordedCalls
            .split(separator: "\n")
            .filter { $0.contains("ssh-session-end") }
        XCTAssertEqual(sessionEndCalls.count, 1, recordedCalls)
    }

    func testSSHSignalDuringReconnectDelayDoesNotStartAnotherSSH() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-signal-during-reconnect-\(UUID().uuidString)", isDirectory: true)
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
            "count=0",
            "if [ -r \"${CMUX_TEST_ATTEMPT_FILE}\" ]; then count=$(cat \"${CMUX_TEST_ATTEMPT_FILE}\"); fi",
            "count=$((count + 1))",
            "printf '%s\\n' \"$count\" > \"${CMUX_TEST_ATTEMPT_FILE}\"",
            "if [ \"$count\" -eq 1 ]; then",
            "  ( sleep 0.2; kill -TERM \"${CMUX_SSH_STARTUP_PID:?}\" ) &",
            "  exit 255",
            "fi",
            "exit 0",
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
        environment["CMUX_SSH_RECONNECT_DELAY_SECONDS"] = "2"
        environment["CMUX_SSH_RECONNECT_LIMIT"] = "2"

        let result = runProcess(
            executablePath: "/bin/sh",
            arguments: ["-c", startupCommand],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 143, result.stderr)
        XCTAssertEqual((try? String(contentsOf: attemptFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines), "1")
        let recordedCalls = (try? String(contentsOf: logFile, encoding: .utf8)) ?? ""
        let sessionEndCalls = recordedCalls
            .split(separator: "\n")
            .filter { $0.contains("ssh-session-end") }
        XCTAssertEqual(sessionEndCalls.count, 1, recordedCalls)
    }

    func testSSHStartupPrintsFinalErrorBannerWhenStderrIsCaptured() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-error-banner-\(UUID().uuidString)", isDirectory: true)
        let fakeCLI = root.appendingPathComponent("cmux")
        let fakeSSH = root.appendingPathComponent("ssh")
        let logFile = root.appendingPathComponent("ssh-session-end.log")

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try writeShellFile(at: fakeCLI, lines: [
            "#!/bin/sh",
            "printf '%s\\n' \"$*\" >> \"${CMUX_TEST_SESSION_END_LOG}\"",
        ])
        try writeShellFile(at: fakeSSH, lines: [
            "#!/bin/sh",
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
        environment["CMUX_SSH_RECONNECT_DELAY_SECONDS"] = "0"

        let result = runProcess(
            executablePath: "/bin/sh",
            arguments: ["-c", startupCommand],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 1, result.stderr)
        XCTAssertTrue(result.stderr.contains("[cmux] ssh exited with status 1."), result.stderr)
        XCTAssertTrue(
            result.stderr.contains("[cmux] press r then Enter to reconnect, or Enter to close this pane."),
            result.stderr
        )
        // EOF on the hold prompt (no stdin) dismisses: session-end cleanup runs exactly once.
        let dismissSessionEndCalls = ((try? String(contentsOf: logFile, encoding: .utf8)) ?? "")
            .split(separator: "\n")
            .filter { $0.contains("ssh-session-end") }
        XCTAssertEqual(dismissSessionEndCalls.count, 1, result.stderr)
    }

    func testSSHStartupManualReconnectReentersConnectLoop() throws {
        // When the automatic reconnect loop gives up on a non-retryable exit, the hold
        // prompt lets the user press `r` (then Enter) to re-run the SSH connect loop from
        // scratch instead of closing the pane. Here the fake ssh fails on the first pass
        // and succeeds on the second, so a single `r` must produce a clean (status 0)
        // session with the transport session-end reported exactly once (on final exit).
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
        // Fail on the first invocation (status 1, non-retryable so the inner loop stops
        // immediately and reaches the hold prompt), then succeed on the second so the
        // manual retry produces a clean session.
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
            "manual `r` retry must re-run the ssh connect loop a second time"
        )
        // Manual retry must not report session-end between the failed and successful
        // passes; cleanup runs exactly once, on the final clean exit.
        let sessionEndCalls = ((try? String(contentsOf: logFile, encoding: .utf8)) ?? "")
            .split(separator: "\n")
            .filter { $0.contains("ssh-session-end") }
        XCTAssertEqual(sessionEndCalls.count, 1, result.stderr)
    }

    func testSSHStartupForwardsStdinToBackgroundedSSH() throws {
        // Regression test for cmux ssh sessions where output flowed back from
        // the remote (prompt rendered) but typed keystrokes never reached the
        // remote shell after PR #3786 backgrounded `ssh` inside the startup
        // wrapper. POSIX sh redirects stdin of an async command to /dev/null
        // when job control is off, so without an explicit `<&0` on the `&`'d
        // ssh invocation, the local PTY stdin is dropped and the user types
        // into a dead pipe.
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-stdin-forward-\(UUID().uuidString)", isDirectory: true)
        let fakeCLI = root.appendingPathComponent("cmux")
        let fakeSSH = root.appendingPathComponent("ssh")
        let sessionEndLog = root.appendingPathComponent("ssh-session-end.log")
        let stdinCapture = root.appendingPathComponent("ssh-stdin.txt")

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try writeShellFile(at: fakeCLI, lines: [
            "#!/bin/sh",
            "printf '%s\\n' \"$*\" >> \"${CMUX_TEST_SESSION_END_LOG}\"",
        ])
        // Fake ssh reads one line from stdin and records it so the test can
        // verify the wrapper's stdin reached the backgrounded ssh process.
        try writeShellFile(at: fakeSSH, lines: [
            "#!/bin/sh",
            "IFS= read -r line || line='<EOF>'",
            "printf '%s\\n' \"$line\" > \"${CMUX_TEST_STDIN_LOG}\"",
            "exit 0",
        ])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeCLI.path)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeSSH.path)

        let startupCommand = try generatedSSHStartupCommand()
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(root.path):\(environment["PATH"] ?? "/usr/bin:/bin")"
        environment["CMUX_BUNDLED_CLI_PATH"] = fakeCLI.path
        environment["CMUX_SOCKET_PATH"] = "/tmp/cmux-debug-test.sock"
        environment["CMUX_WORKSPACE_ID"] = "11111111-1111-1111-1111-111111111111"
        environment["CMUX_SURFACE_ID"] = "22222222-2222-2222-2222-222222222222"
        environment["CMUX_TEST_SESSION_END_LOG"] = sessionEndLog.path
        environment["CMUX_TEST_STDIN_LOG"] = stdinCapture.path
        environment["CMUX_SSH_RECONNECT_DELAY_SECONDS"] = "0"

        let result = runProcess(
            executablePath: "/bin/sh",
            arguments: ["-c", startupCommand],
            environment: environment,
            standardInput: "FORWARDED_KEYSTROKE\n",
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        let recorded = (try? String(contentsOf: stdinCapture, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        XCTAssertEqual(
            recorded,
            "FORWARDED_KEYSTROKE",
            "Backgrounded ssh in the startup wrapper must inherit the wrapper's stdin so that keystrokes from the surface PTY reach the remote shell. Got: \(recorded.isEmpty ? "<empty>" : recorded)"
        )
    }

    private func generatedSSHStartupCommand(
        sshOptions: [String] = [
            "ControlMaster no",
            "ControlPath /tmp/cmux-ssh-%C",
        ]
    ) throws -> String {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("ssh-pane-close")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let workspaceID = "11111111-1111-1111-1111-111111111111"
        let workspaceRef = "workspace:9"

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

            switch method {
            case "workspace.create":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "workspace_id": workspaceID,
                    ]
                )
            case "workspace.remote.configure":
                return self.v2Response(
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
                return self.v2Response(
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

        var arguments = [
            "ssh",
            "--no-focus",
            "--port", "2222",
        ]
        for option in sshOptions {
            arguments += ["--ssh-option", option]
        }
        arguments.append("cmux-macmini")

        let result = runProcess(
            executablePath: cliPath,
            arguments: arguments,
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stderr.isEmpty, result.stderr)

        let requests = try state.commands.map { line -> [String: Any] in
            let data = try XCTUnwrap(line.data(using: .utf8))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data, options: []) as? [String: Any])
        }
        let configureRequest = try XCTUnwrap(
            requests.first { ($0["method"] as? String) == "workspace.remote.configure" }
        )
        let configureParams = try XCTUnwrap(configureRequest["params"] as? [String: Any])
        return try XCTUnwrap(configureParams["terminal_startup_command"] as? String)
    }

    private func generatedVMSSHInitialStartupCommand() throws -> String {
        let cliPath = try bundledCLIPath()
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
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }

            switch method {
            case "vm.attach_info":
                let params = payload["params"] as? [String: Any] ?? [:]
                XCTAssertEqual(params["id"] as? String, vmID)
                XCTAssertEqual(params["require_daemon"] as? Bool, true)
                return self.v2Response(
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
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "workspace_id": workspaceID,
                    ]
                )
            case "workspace.rename":
                return self.v2Response(id: id, ok: true, result: ["workspace_id": workspaceID])
            case "workspace.remote.configure":
                return self.v2Response(
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
                return self.v2Response(id: id, ok: true, result: ["workspace_id": workspaceID])
            default:
                return self.v2Response(
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
            arguments: ["vm", "ssh", vmID],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stderr.isEmpty, result.stderr)

        let requests = try state.commands.map { line -> [String: Any] in
            let data = try XCTUnwrap(line.data(using: .utf8))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data, options: []) as? [String: Any])
        }
        let createRequest = try XCTUnwrap(
            requests.first { ($0["method"] as? String) == "workspace.create" }
        )
        let createParams = try XCTUnwrap(createRequest["params"] as? [String: Any])
        return try XCTUnwrap(createParams["initial_command"] as? String)
    }

    private func writeShellFile(at url: URL, lines: [String]) throws {
        try lines.joined(separator: "\n")
            .appending("\n")
            .write(to: url, atomically: true, encoding: .utf8)
    }

    private func waitForSSHSignalLifecycleLog(
        _ url: URL,
        timeout: TimeInterval = 2,
        condition: (String) -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let contents = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            if condition(contents) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        let contents = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return condition(contents)
    }
}
