import XCTest
import CmuxFoundation
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
            let startupCommand = try generatedVMSSHInitialStartupCommand(
                replacingSystemSSHWith: fakeSSH
            )

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

            let startupCommand = try generatedVMSSHInitialStartupCommand(
                replacingSystemSSHWith: fakeSSH
            )
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
        let fakeSleep = root.appendingPathComponent("sleep")
        let logFile = root.appendingPathComponent("ssh-session-end.log")
        let attemptFile = root.appendingPathComponent("ssh-attempts.txt")
        let sleepLog = root.appendingPathComponent("sleep-delays.txt")

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
        try writeShellFile(at: fakeSleep, lines: ["#!/bin/sh", "printf '%s\\n' \"$1\" >> \"${CMUX_TEST_SLEEP_LOG}\""])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeCLI.path)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeSSH.path)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeSleep.path)

        let startupCommand = try generatedSSHStartupCommand(
            replacingSystemSSHWith: fakeSSH
        )
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(root.path):\(environment["PATH"] ?? "/usr/bin:/bin")"
        environment["CMUX_BUNDLED_CLI_PATH"] = fakeCLI.path
        environment["CMUX_SOCKET_PATH"] = "/tmp/cmux-debug-test.sock"
        environment["CMUX_WORKSPACE_ID"] = "11111111-1111-1111-1111-111111111111"
        environment["CMUX_SURFACE_ID"] = "22222222-2222-2222-2222-222222222222"
        environment["CMUX_TEST_SESSION_END_LOG"] = logFile.path
        environment["CMUX_TEST_ATTEMPT_FILE"] = attemptFile.path
        environment["CMUX_TEST_SLEEP_LOG"] = sleepLog.path
        environment["CMUX_SSH_RECONNECT_DELAY_SECONDS"] = "0"

        let result = runProcess(executablePath: "/bin/sh", arguments: ["-c", startupCommand], environment: environment, timeout: 5)

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        // The regular `cmux ssh` bootstrap path runs one SSH command to install
        // the remote bootstrap and another to open the session. A transient
        // install-channel failure therefore yields three raw SSH invocations:
        // failed install, retried install, successful session.
        XCTAssertEqual((try? String(contentsOf: attemptFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines), "3")
        XCTAssertEqual(try String(contentsOf: sleepLog, encoding: .utf8), "2\n")
        let recordedCalls = (try? String(contentsOf: logFile, encoding: .utf8)) ?? ""
        let sessionEndCalls = recordedCalls.split(separator: "\n").filter { $0.contains("ssh-session-end") }
        XCTAssertEqual(sessionEndCalls.count, 1, recordedCalls)
        let launchingCalls = recordedCalls
            .split(separator: "\n")
            .filter { $0.contains("rpc workspace.remote.terminal_session_launching") }
        XCTAssertEqual(
            launchingCalls.count,
            2,
            "Each wrapper attempt must synchronously publish a distinct launching generation before it can report connected; recorded: \(recordedCalls)"
        )
        let attemptIDs = launchingCalls.compactMap { call -> String? in
            guard let marker = call.range(of: "\"attempt_id\":\"") else { return nil }
            let suffix = call[marker.upperBound...]
            return suffix.split(separator: "\"", maxSplits: 1).first.map(String.init)
        }
        XCTAssertEqual(Set(attemptIDs).count, 2, recordedCalls)
    }

    func testSSHStartupDoesNotLaunchWhenAttemptRegistrationNeverSucceeds() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent(
                "cmux-ssh-attempt-registration-\(UUID().uuidString)",
                isDirectory: true
            )
        let fakeCLI = root.appendingPathComponent("cmux")
        let fakeSSH = root.appendingPathComponent("ssh")
        let cliLog = root.appendingPathComponent("cmux.log")
        let sshLog = root.appendingPathComponent("ssh.log")

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try writeShellFile(at: fakeCLI, lines: [
            "#!/bin/sh",
            "printf '%s\\n' \"$*\" >> \"${CMUX_TEST_CLI_LOG}\"",
            "case \"$*\" in",
            "  *'rpc workspace.remote.terminal_session_launching '*) exit 1 ;;",
            "  *) exit 0 ;;",
            "esac",
        ])
        try writeShellFile(at: fakeSSH, lines: [
            "#!/bin/sh",
            "printf '%s\\n' \"$*\" >> \"${CMUX_TEST_SSH_LOG}\"",
            "exit 0",
        ])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeCLI.path)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeSSH.path)

        let startupCommand = try generatedSSHStartupCommand(
            replacingSystemSSHWith: fakeSSH
        )
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(root.path):\(environment["PATH"] ?? "/usr/bin:/bin")"
        environment["CMUX_BUNDLED_CLI_PATH"] = fakeCLI.path
        environment["CMUX_SOCKET_PATH"] = "/tmp/cmux-debug-test.sock"
        environment["CMUX_WORKSPACE_ID"] = "11111111-1111-1111-1111-111111111111"
        environment["CMUX_SURFACE_ID"] = "22222222-2222-2222-2222-222222222222"
        environment["CMUX_TERMINAL_LIFECYCLE_ID"] =
            "33333333-3333-3333-3333-333333333333"
        environment["CMUX_TEST_CLI_LOG"] = cliLog.path
        environment["CMUX_TEST_SSH_LOG"] = sshLog.path

        let result = runProcess(
            executablePath: "/bin/sh",
            arguments: ["-c", startupCommand],
            environment: environment,
            timeout: 10
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertNotEqual(result.status, 0, result.stderr)
        let cliCalls = (try? String(contentsOf: cliLog, encoding: .utf8)) ?? ""
        XCTAssertGreaterThan(
            cliCalls
                .split(separator: "\n")
                .filter {
                    $0.contains("rpc workspace.remote.terminal_session_launching")
                }
                .count,
            1,
            "Attempt registration should be retried before the wrapper gives up: \(cliCalls)"
        )
        XCTAssertFalse(
            fileManager.fileExists(atPath: sshLog.path),
            "SSH must not start with an attempt ID that the app never registered"
        )
    }

    func testSSHStartupDoesNotLaunchWhenSignaledDuringAttemptRegistration() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent(
                "cmux-ssh-registration-signal-\(UUID().uuidString)",
                isDirectory: true
            )
        let fakeCLI = root.appendingPathComponent("cmux")
        let fakeSSH = root.appendingPathComponent("ssh")
        let cliLog = root.appendingPathComponent("cmux.log")
        let sshLog = root.appendingPathComponent("ssh.log")

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try writeShellFile(at: fakeCLI, lines: [
            "#!/bin/sh",
            "printf '%s\\n' \"$*\" >> \"${CMUX_TEST_CLI_LOG}\"",
            "case \"$*\" in",
            "  *'rpc workspace.remote.terminal_session_launching '*)",
            "    kill -TERM \"$PPID\"",
            "    exit 0",
            "    ;;",
            "esac",
            "exit 0",
        ])
        try writeShellFile(at: fakeSSH, lines: [
            "#!/bin/sh",
            "printf '%s\\n' ssh-started >> \"${CMUX_TEST_SSH_LOG}\"",
            "exit 0",
        ])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeCLI.path)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeSSH.path)

        let startupCommand = try generatedSSHStartupCommand(
            replacingSystemSSHWith: fakeSSH
        )
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(root.path):\(environment["PATH"] ?? "/usr/bin:/bin")"
        environment["CMUX_BUNDLED_CLI_PATH"] = fakeCLI.path
        environment["CMUX_SOCKET_PATH"] = "/tmp/cmux-debug-test.sock"
        environment["CMUX_WORKSPACE_ID"] = "11111111-1111-1111-1111-111111111111"
        environment["CMUX_SURFACE_ID"] = "22222222-2222-2222-2222-222222222222"
        environment["CMUX_TERMINAL_LIFECYCLE_ID"] =
            "33333333-3333-3333-3333-333333333333"
        environment["CMUX_TEST_CLI_LOG"] = cliLog.path
        environment["CMUX_TEST_SSH_LOG"] = sshLog.path

        let result = runProcess(
            executablePath: "/bin/sh",
            arguments: ["-c", startupCommand],
            environment: environment,
            timeout: 10
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 143, result.stderr)
        XCTAssertFalse(
            waitForSSHSignalLifecycleLog(sshLog) {
                $0.contains("ssh-started")
            },
            "A pane-close signal accepted during registration must stop before SSH starts"
        )
    }

    func testSSHBootstrapWithoutTTYStillReportsTerminalReadiness() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent(
                "cmux-ssh-no-tty-readiness-\(UUID().uuidString)",
                isDirectory: true
            )
        let home = root.appendingPathComponent("home", isDirectory: true)
        let remoteBin = home.appendingPathComponent(
            ".cmux/bin",
            isDirectory: true
        )
        let fakeCLI = root.appendingPathComponent("cmux")
        let fakeSSH = root.appendingPathComponent("ssh")
        let remoteCLI = remoteBin.appendingPathComponent("cmux")
        let localCLILog = root.appendingPathComponent("local-cmux.log")
        let remoteCLILog = root.appendingPathComponent("remote-cmux.log")
        let readinessAttemptLog = root.appendingPathComponent(
            "remote-readiness-attempts.log"
        )

        try fileManager.createDirectory(at: remoteBin, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try writeShellFile(at: fakeCLI, lines: [
            "#!/bin/sh",
            "printf '%s\\n' \"$*\" >> \"${CMUX_TEST_LOCAL_CLI_LOG}\"",
            "exit 0",
        ])
        try writeShellFile(at: remoteCLI, lines: [
            "#!/bin/sh",
            "printf '%s\\n' \"$*\" >> \"${CMUX_TEST_REMOTE_CLI_LOG}\"",
            "case \"$*\" in",
            "  *'rpc workspace.remote.terminal_session_connected '*)",
            "    cmux_test_attempt=0",
            "    if [ -r \"${CMUX_TEST_READINESS_ATTEMPT_LOG}\" ]; then",
            "      cmux_test_attempt=$(cat \"${CMUX_TEST_READINESS_ATTEMPT_LOG}\")",
            "    fi",
            "    cmux_test_attempt=$((cmux_test_attempt + 1))",
            "    printf '%s\\n' \"$cmux_test_attempt\" > \"${CMUX_TEST_READINESS_ATTEMPT_LOG}\"",
            "    if [ \"$cmux_test_attempt\" -eq 1 ]; then exit 1; fi",
            "    ;;",
            "esac",
            "exit 0",
        ])
        try writeShellFile(at: fakeSSH, lines: [
            "#!/bin/sh",
            "cmux_test_remote_command=",
            "while [ \"$#\" -gt 0 ]; do",
            "  case \"$1\" in",
            "    -G)",
            "      printf '%s\\n' 'controlpath none'",
            "      exit 0",
            "      ;;",
            "    -o)",
            "      case \"$2\" in",
            "        RemoteCommand=none|remotecommand=none) cmux_test_remote_command=none ;;",
            "        RemoteCommand=*|remotecommand=*) cmux_test_remote_command=\"${2#*=}\" ;;",
            "      esac",
            "      shift 2",
            "      ;;",
            "    -oRemoteCommand=*|-oremotecommand=*)",
            "      cmux_test_remote_command=\"${1#*=}\"",
            "      shift",
            "      ;;",
            "    -p|-i|-l|-F|-E|-e|-b|-c|-D|-I|-J|-L|-m|-Q|-R|-S|-W|-w|-B)",
            "      shift 2",
            "      ;;",
            "    -*) shift ;;",
            "    *) shift; break ;;",
            "  esac",
            "done",
            "if [ \"$cmux_test_remote_command\" = none ]; then",
            "  cat >/dev/null 2>&1 || true",
            "elif [ -n \"$cmux_test_remote_command\" ]; then",
            "  /bin/sh -c \"$cmux_test_remote_command\" >/dev/null 2>&1 || true",
            "fi",
            "exit 0",
        ])
        for executable in [fakeCLI, fakeSSH, remoteCLI] {
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: executable.path
            )
        }

        let startupCommand = try generatedSSHStartupCommand(
            replacingSystemSSHWith: fakeSSH,
            sshOptions: [
                "ControlMaster no",
                "ControlPath /tmp/cmux-ssh-%C",
                "RequestTTY no",
            ]
        )
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(root.path):\(environment["PATH"] ?? "/usr/bin:/bin")"
        environment["HOME"] = home.path
        environment["CMUX_BUNDLED_CLI_PATH"] = fakeCLI.path
        environment["CMUX_SOCKET_PATH"] = "/tmp/cmux-debug-test.sock"
        environment["CMUX_WORKSPACE_ID"] = "11111111-1111-1111-1111-111111111111"
        environment["CMUX_SURFACE_ID"] = "22222222-2222-2222-2222-222222222222"
        environment["CMUX_TERMINAL_LIFECYCLE_ID"] =
            "33333333-3333-3333-3333-333333333333"
        environment["CMUX_TEST_LOCAL_CLI_LOG"] = localCLILog.path
        environment["CMUX_TEST_REMOTE_CLI_LOG"] = remoteCLILog.path
        environment["CMUX_TEST_READINESS_ATTEMPT_LOG"] =
            readinessAttemptLog.path

        let result = runProcess(
            executablePath: "/bin/sh",
            arguments: ["-c", startupCommand],
            environment: environment,
            timeout: 10
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        let remoteCalls =
            (try? String(contentsOf: remoteCLILog, encoding: .utf8)) ?? ""
        XCTAssertTrue(
            remoteCalls.contains(
                "rpc workspace.remote.terminal_session_connected"
            ),
            "Readiness must not depend on tty(1) succeeding: \(remoteCalls)"
        )
        XCTAssertEqual(
            remoteCalls
                .split(separator: "\n")
                .filter {
                    $0.contains(
                        "rpc workspace.remote.terminal_session_connected"
                    )
                }
                .count,
            2,
            "A transient readiness failure must be retried before the remote command continues: \(remoteCalls)"
        )
    }

    func testSSHRawRemoteCommandRunsWithoutRemoteReadinessCLI() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent(
                "cmux-ssh-raw-command-no-remote-cli-\(UUID().uuidString)",
                isDirectory: true
            )
        let remoteHome = root.appendingPathComponent("remote-home", isDirectory: true)
        let fakeCLI = root.appendingPathComponent("cmux")
        let fakeSSH = root.appendingPathComponent("ssh")
        let commandLog = root.appendingPathComponent("raw-command.log")

        try fileManager.createDirectory(at: remoteHome, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try writeShellFile(at: fakeCLI, lines: [
            "#!/bin/sh",
            "exit 0",
        ])
        try writeShellFile(at: fakeSSH, lines: [
            "#!/bin/sh",
            "cmux_test_remote_command=",
            "for cmux_test_arg in \"$@\"; do",
            "  if [ \"$cmux_test_arg\" = '-G' ]; then",
            "    printf '%s\\n' 'controlpath none'",
            "    exit 0",
            "  fi",
            "  cmux_test_remote_command=\"$cmux_test_arg\"",
            "done",
            "PATH=/usr/bin:/bin HOME=\"${CMUX_TEST_REMOTE_HOME}\" /bin/sh -c \"$cmux_test_remote_command\"",
        ])
        for executable in [fakeCLI, fakeSSH] {
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: executable.path
            )
        }

        let startupCommand = try generatedSSHStartupCommand(
            replacingSystemSSHWith: fakeSSH,
            remoteCommandArguments: [
                "touch",
                "\"$CMUX_TEST_RAW_COMMAND_LOG\"",
            ]
        )
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(root.path):\(environment["PATH"] ?? "/usr/bin:/bin")"
        environment["CMUX_BUNDLED_CLI_PATH"] = fakeCLI.path
        environment["CMUX_SOCKET_PATH"] = "/tmp/cmux-debug-test.sock"
        environment["CMUX_WORKSPACE_ID"] = "11111111-1111-1111-1111-111111111111"
        environment["CMUX_SURFACE_ID"] = "22222222-2222-2222-2222-222222222222"
        environment["CMUX_TERMINAL_LIFECYCLE_ID"] =
            "33333333-3333-3333-3333-333333333333"
        environment["CMUX_TEST_REMOTE_HOME"] = remoteHome.path
        environment["CMUX_TEST_RAW_COMMAND_LOG"] = commandLog.path
        environment["CMUX_SSH_RECONNECT_LIMIT"] = "1"
        environment["CMUX_SSH_RECONNECT_DELAY_SECONDS"] = "0"

        let result = runProcess(
            executablePath: "/bin/sh",
            arguments: ["-c", startupCommand],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(
            fileManager.fileExists(atPath: commandLog.path),
            "A missing remote cmux CLI must not prevent the caller's raw SSH command from running"
        )
    }

    func testSSHRawRemoteCommandReportsReadinessWithoutGatingUserCommand() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent(
                "cmux-ssh-raw-command-delayed-remote-cli-\(UUID().uuidString)",
                isDirectory: true
            )
        let remoteHome = root.appendingPathComponent("remote-home", isDirectory: true)
        let remoteBin = remoteHome.appendingPathComponent(".cmux/bin", isDirectory: true)
        let fakeCLI = root.appendingPathComponent("cmux")
        let fakeSSH = root.appendingPathComponent("ssh")
        let stagedRemoteCLI = root.appendingPathComponent("staged-remote-cmux")
        let remoteCLI = remoteBin.appendingPathComponent("cmux")
        let eventLog = root.appendingPathComponent("raw-command-events.log")

        try fileManager.createDirectory(at: remoteBin, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try writeShellFile(at: fakeCLI, lines: [
            "#!/bin/sh",
            "exit 0",
        ])
        try writeShellFile(at: stagedRemoteCLI, lines: [
            "#!/bin/sh",
            "printf '%s\\n' readiness >> \"${CMUX_TEST_RAW_EVENT_LOG}\"",
            "exit 0",
        ])
        try writeShellFile(at: fakeSSH, lines: [
            "#!/bin/sh",
            "cmux_test_remote_command=",
            "for cmux_test_arg in \"$@\"; do",
            "  if [ \"$cmux_test_arg\" = '-G' ]; then",
            "    printf '%s\\n' 'controlpath none'",
            "    exit 0",
            "  fi",
            "  cmux_test_remote_command=\"$cmux_test_arg\"",
            "done",
            "(",
            "  /bin/sleep 0.2",
            "  /bin/cp \"${CMUX_TEST_STAGED_REMOTE_CLI}\" \"${CMUX_TEST_REMOTE_CLI}\"",
            "  /bin/chmod 700 \"${CMUX_TEST_REMOTE_CLI}\"",
            ") </dev/null >/dev/null 2>&1 &",
            "PATH=/usr/bin:/bin HOME=\"${CMUX_TEST_REMOTE_HOME}\" /bin/sh -c \"$cmux_test_remote_command\"",
        ])
        for executable in [fakeCLI, fakeSSH, stagedRemoteCLI] {
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: executable.path
            )
        }

        let rawCommand = """
        echo user-start >> "$CMUX_TEST_RAW_EVENT_LOG"
        /bin/sleep 1
        echo user-end >> "$CMUX_TEST_RAW_EVENT_LOG"
        """
        let startupCommand = try generatedSSHStartupCommand(
            replacingSystemSSHWith: fakeSSH,
            remoteCommandArguments: [
                "/bin/sh",
                "-c",
                "'\(rawCommand)'",
            ]
        )
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(root.path):\(environment["PATH"] ?? "/usr/bin:/bin")"
        environment["CMUX_BUNDLED_CLI_PATH"] = fakeCLI.path
        environment["CMUX_SOCKET_PATH"] = "/tmp/cmux-debug-test.sock"
        environment["CMUX_WORKSPACE_ID"] = "11111111-1111-1111-1111-111111111111"
        environment["CMUX_SURFACE_ID"] = "22222222-2222-2222-2222-222222222222"
        environment["CMUX_TERMINAL_LIFECYCLE_ID"] =
            "33333333-3333-3333-3333-333333333333"
        environment["CMUX_TEST_REMOTE_HOME"] = remoteHome.path
        environment["CMUX_TEST_STAGED_REMOTE_CLI"] = stagedRemoteCLI.path
        environment["CMUX_TEST_REMOTE_CLI"] = remoteCLI.path
        environment["CMUX_TEST_RAW_EVENT_LOG"] = eventLog.path
        environment["CMUX_SSH_RECONNECT_LIMIT"] = "1"
        environment["CMUX_SSH_RECONNECT_DELAY_SECONDS"] = "0"

        let result = runProcess(
            executablePath: "/bin/sh",
            arguments: ["-c", startupCommand],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        let events = try String(contentsOf: eventLog, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        XCTAssertEqual(events.first, "user-start", events.joined(separator: "\n"))
        XCTAssertTrue(events.contains("readiness"), events.joined(separator: "\n"))
        XCTAssertEqual(events.last, "user-end", events.joined(separator: "\n"))
    }

    func testMoshDoesNotClaimConnectedBeforeTransportStarts() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent(
                "cmux-mosh-terminal-liveness-\(UUID().uuidString)",
                isDirectory: true
            )
        let fakeCLI = root.appendingPathComponent("cmux")
        let fakeSSH = root.appendingPathComponent("ssh")
        let fakeMosh = root.appendingPathComponent("mosh")
        let cliLog = root.appendingPathComponent("cmux.log")
        let moshLog = root.appendingPathComponent("mosh.log")

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try writeShellFile(at: fakeCLI, lines: [
            "#!/bin/sh",
            "printf '%s\\n' \"$*\" >> \"${CMUX_TEST_CLI_LOG}\"",
            "exit 0",
        ])
        try writeShellFile(at: fakeSSH, lines: [
            "#!/bin/sh",
            "cat >/dev/null 2>&1 || true",
            "exit 0",
        ])
        try writeShellFile(at: fakeMosh, lines: [
            "#!/bin/sh",
            "if [ \"${1:-}\" = '--help' ]; then",
            "  printf '%s\\n' '  --experimental-remote-ip=(local|remote|proxy)'",
            "  exit 0",
            "fi",
            "printf '%s\\n' \"$*\" >> \"${CMUX_TEST_MOSH_LOG}\"",
            "exit 71",
        ])
        for executable in [fakeCLI, fakeSSH, fakeMosh] {
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: executable.path
            )
        }

        let startupCommand = try generatedSSHStartupCommand(
            replacingSystemSSHWith: fakeSSH,
            additionalArguments: ["--transport", "mosh"]
        )
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(root.path):\(environment["PATH"] ?? "/usr/bin:/bin")"
        environment["CMUX_BUNDLED_CLI_PATH"] = fakeCLI.path
        environment["CMUX_SOCKET_PATH"] = "/tmp/cmux-debug-test.sock"
        environment["CMUX_WORKSPACE_ID"] = "11111111-1111-1111-1111-111111111111"
        environment["CMUX_SURFACE_ID"] = "22222222-2222-2222-2222-222222222222"
        environment["CMUX_TERMINAL_LIFECYCLE_ID"] =
            "33333333-3333-3333-3333-333333333333"
        environment["CMUX_TEST_CLI_LOG"] = cliLog.path
        environment["CMUX_TEST_MOSH_LOG"] = moshLog.path

        let result = runProcess(
            executablePath: "/bin/sh",
            arguments: ["-c", startupCommand],
            environment: environment,
            timeout: 10
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 71, result.stderr)
        XCTAssertTrue(fileManager.fileExists(atPath: moshLog.path))
        let cliCalls = (try? String(contentsOf: cliLog, encoding: .utf8)) ?? ""
        XCTAssertTrue(
            cliCalls.contains(
                "rpc workspace.remote.terminal_session_launching"
            ),
            "Mosh must register an attempt before claiming readiness: \(cliCalls)"
        )
        XCTAssertFalse(
            cliCalls.contains(
                "rpc workspace.remote.terminal_session_connected"
            ),
            "Mosh must not claim connected before its transport establishes: \(cliCalls)"
        )
    }

    func testSSHStartupRemovesStaleCmuxControlSocketBeforeLaunchingPaneSSH() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-stale-control-\(UUID().uuidString)", isDirectory: true)
        let fakeCLI = root.appendingPathComponent("cmux")
        let fakeSSH = root.appendingPathComponent("ssh")
        let logFile = root.appendingPathComponent("ssh.log")
        let socketHash = UUID().uuidString
            .replacingOccurrences(of: "-", with: "")
            .lowercased() + "01234567"
        let staleControlPath = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("cmux-ssh-\(getuid())-\(socketHash)")

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: root)
            unlink(staleControlPath.path)
            unlink(staleControlPath.path + ".auth.lock")
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

        let startupCommand = try generatedSSHStartupCommand(
            replacingSystemSSHWith: fakeSSH,
            sshOptions: [
                "ControlMaster auto",
                "ControlPersist 600",
                "ControlPath \(staleControlPath.path)",
            ]
        )
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

    func testSSHStartupRemovesForegroundAuthInflightMarkerAfterSuccess() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-auth-inflight-\(UUID().uuidString)", isDirectory: true)
        let fakeCLI = root.appendingPathComponent("cmux")
        let fakeSSH = root.appendingPathComponent("ssh")
        let controlPath = "/tmp/cmux-ssh-\(getuid())-0123456789abcdef0123456789abcdef01234567"
        let sshOptions = [
            "ControlMaster=auto",
            "ControlPersist=600",
            "ControlPath=\(controlPath)",
        ]
        let lockPath = try XCTUnwrap(SSHConnectionSharingOptions().foregroundAuthenticationLockPath(
            destination: "cmux-macmini",
            port: 2222,
            options: sshOptions
        ))
        let inFlightPath = lockPath + ".inflight"

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: root)
            unlink(lockPath)
            unlink(inFlightPath)
        }

        try writeShellFile(at: fakeCLI, lines: ["#!/bin/sh", "exit 0"])
        try writeShellFile(at: fakeSSH, lines: [
            "#!/bin/sh",
            "previous_arg=",
            "for arg in \"$@\"; do",
            "  if [ \"$arg\" = '-G' ]; then printf 'controlpath %s\\n' \"${CMUX_TEST_CONTROL_PATH}\"; exit 0; fi",
            "  if [ \"$previous_arg\" = '-O' ] && [ \"$arg\" = 'check' ]; then exit 255; fi",
            "  previous_arg=\"$arg\"",
            "done",
            "exit 0",
        ])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeCLI.path)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeSSH.path)

        let startupCommand = try generatedSSHStartupCommand(
            replacingSystemSSHWith: fakeSSH,
            sshOptions: sshOptions
        )
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(root.path):\(environment["PATH"] ?? "/usr/bin:/bin")"
        environment["CMUX_BUNDLED_CLI_PATH"] = fakeCLI.path
        environment["CMUX_SOCKET_PATH"] = "/tmp/cmux-debug-test.sock"
        environment["CMUX_WORKSPACE_ID"] = "11111111-1111-1111-1111-111111111111"
        environment["CMUX_SURFACE_ID"] = "22222222-2222-2222-2222-222222222222"
        environment["CMUX_TEST_CONTROL_PATH"] = controlPath
        environment["CMUX_SSH_RECONNECT_DELAY_SECONDS"] = "0"

        let result = runProcess(
            executablePath: "/bin/sh",
            arguments: ["-c", startupCommand],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertFalse(
            fileManager.fileExists(atPath: inFlightPath),
            "Successful foreground authentication must remove its owned in-flight marker before releasing the lock"
        )
    }

    func testSSHStartupStopsAtConfiguredReconnectLimitAndWaitsForDismissal() throws {
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

        let startupCommand = try generatedVMSSHInitialStartupCommand(
            replacingSystemSSHWith: fakeSSH
        )
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
            timeout: 1
        )

        XCTAssertTrue(result.timedOut, "closed stdin must not dismiss the terminal failure prompt")
        XCTAssertEqual((try? String(contentsOf: attemptFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines), "3")
        let recordedCalls = (try? String(contentsOf: logFile, encoding: .utf8)) ?? ""
        let sessionEndCalls = recordedCalls
            .split(separator: "\n")
            .filter { $0.contains("ssh-session-end") }
        XCTAssertEqual(sessionEndCalls.count, 1, recordedCalls)
    }

    func testSSHStartupDoesNotRetryNonTransientSSHExitAndWaitsForDismissal() throws {
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

        let startupCommand = try generatedVMSSHInitialStartupCommand(
            replacingSystemSSHWith: fakeSSH
        )
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
            timeout: 1
        )

        XCTAssertTrue(result.timedOut, "closed stdin must not dismiss the terminal failure prompt")
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

        let startupCommand = try generatedVMSSHInitialStartupCommand(
            replacingSystemSSHWith: fakeSSH
        )
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

        let startupCommand = try generatedVMSSHInitialStartupCommand(
            replacingSystemSSHWith: fakeSSH
        )
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

    func testSSHStartupPrintsFinalErrorBannerAndWaitsWhenStderrIsCaptured() throws {
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

        let startupCommand = try generatedVMSSHInitialStartupCommand(
            replacingSystemSSHWith: fakeSSH
        )
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
            timeout: 1
        )

        XCTAssertTrue(result.timedOut, "closed stdin must not dismiss the terminal failure prompt")
        XCTAssertTrue(result.stderr.contains("[cmux] ssh exited with status 1."), result.stderr)
        XCTAssertTrue(result.stderr.contains("[cmux] press Enter to close this pane."), result.stderr)
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

        let startupCommand = try generatedSSHStartupCommand(
            replacingSystemSSHWith: fakeSSH
        )
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
        replacingSystemSSHWith fakeSSH: URL,
        sshOptions: [String] = [
            "ControlMaster no",
            "ControlPath /tmp/cmux-ssh-%C",
        ],
        additionalArguments: [String] = [],
        remoteCommandArguments: [String] = []
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
                        "surface_id": "surface:1",
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
        arguments += additionalArguments
        arguments.append("cmux-macmini")
        if !remoteCommandArguments.isEmpty {
            arguments.append("--")
            arguments += remoteCommandArguments
        }

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
        let startupCommand = try XCTUnwrap(configureParams["terminal_startup_command"] as? String)
        return try rewritingSystemSSH(in: startupCommand, with: fakeSSH)
    }

    private func generatedVMSSHInitialStartupCommand(
        replacingSystemSSHWith fakeSSH: URL
    ) throws -> String {
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
            case "vm.ssh_info":
                let params = payload["params"] as? [String: Any] ?? [:]
                XCTAssertEqual(params["id"] as? String, vmID)
                XCTAssertNil(params["require_daemon"])
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
        let startupCommand = try XCTUnwrap(createParams["initial_command"] as? String)
        return try rewritingSystemSSH(in: startupCommand, with: fakeSSH)
    }

    private func rewritingSystemSSH(
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
            XCTAssertTrue(script.contains(systemSSHPath), script)
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
        guard let prefixRange = startupCommand.range(of: encodedPrefix),
              let suffixRange = startupCommand.range(
                  of: encodedSuffix,
                  range: prefixRange.upperBound..<startupCommand.endIndex
              ) else {
            XCTFail("Generated startup command did not pin \(systemSSHPath): \(startupCommand)")
            return startupCommand
        }
        let encodedRange = prefixRange.upperBound..<suffixRange.lowerBound
        let encodedScript = String(startupCommand[encodedRange])
        let scriptData = try XCTUnwrap(Data(base64Encoded: encodedScript))
        let script = try XCTUnwrap(String(data: scriptData, encoding: .utf8))
        XCTAssertTrue(script.contains(systemSSHPath), script)
        let rewrittenScript = script.replacingOccurrences(of: systemSSHPath, with: fakeSSH.path)
        var rewrittenCommand = startupCommand
        rewrittenCommand.replaceSubrange(
            encodedRange,
            with: Data(rewrittenScript.utf8).base64EncodedString()
        )
        return rewrittenCommand
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
