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
struct SSHForegroundAuthenticationMarkerCleanupTests {
    @Test func installsAttachSignalTrapsAfterAuthenticationCleanupFunction() throws {
        let command = SSHPTYAttachStartupCommandBuilder.command(
            sessionID: "ssh-test-session",
            foregroundAuth: SSHPTYAttachStartupCommandBuilder.ForegroundAuth(
                destination: "ordering.example.test",
                port: nil,
                identityFile: nil,
                sshOptions: [],
                token: "foreground-auth-token"
            )
        )
        let decodedCommand = command.replacingOccurrences(of: "'\"'\"'", with: "'")
        let cleanupDefinition = try #require(
            decodedCommand.range(of: "cmux_ssh_attach_remove_auth_group_dir()")
        )
        let firstSignalTrap = try #require(
            decodedCommand.range(of: "trap 'cmux_ssh_attach_signal_exit 129 HUP' HUP")
        )

        #expect(cleanupDefinition.lowerBound < firstSignalTrap.lowerBound)
    }

    @Test func attachSignalUsesBoundedAuthenticationProcessWait() {
        let command = SSHPTYAttachStartupCommandBuilder.command(
            sessionID: "ssh-test-session",
            foregroundAuth: SSHPTYAttachStartupCommandBuilder.ForegroundAuth(
                destination: "bounded-wait.example.test",
                port: nil,
                identityFile: nil,
                sshOptions: [],
                token: "foreground-auth-token"
            )
        )
        let decodedCommand = command.replacingOccurrences(of: "'\"'\"'", with: "'")

        #expect(
            decodedCommand.contains(
                "cmux_ssh_wait_for_auth_process_exit \"$cmux_ssh_attach_auth_pid\""
            )
        )
        #expect(
            !decodedCommand.contains(
                "wait \"$cmux_ssh_attach_auth_pid\" 2>/dev/null || true"
            )
        )
    }

    @Test func restoredAttachSignalTerminatesForegroundAuthenticationProcessTree() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-restored-auth-tree-\(UUID().uuidString)", isDirectory: true)
        let fakeCLI = root.appendingPathComponent("cmux")
        let fakeSSH = root.appendingPathComponent("ssh")
        let authRootPIDFile = root.appendingPathComponent("auth-root-pid")
        let authDescendantPIDFile = root.appendingPathComponent("auth-descendant-pid")

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try Self.writeShellFile(at: fakeCLI, lines: ["#!/bin/sh", "exit 0"])
        try Self.writeShellFile(at: fakeSSH, lines: [
            "#!/bin/sh",
            "trap '' HUP INT TERM",
            "/bin/sleep 30 &",
            "cmux_test_auth_descendant=$!",
            "printf '%s\\n' \"$$\" > \"${CMUX_TEST_AUTH_ROOT_PID:?}\"",
            "printf '%s\\n' \"$cmux_test_auth_descendant\" > \"${CMUX_TEST_AUTH_DESCENDANT_PID:?}\"",
            "wait \"$cmux_test_auth_descendant\"",
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
        environment["CMUX_TEST_AUTH_ROOT_PID"] = authRootPIDFile.path
        environment["CMUX_TEST_AUTH_DESCENDANT_PID"] = authDescendantPIDFile.path

        let command = SSHPTYAttachStartupCommandBuilder.command(
            sessionID: "ssh-test-session",
            foregroundAuth: SSHPTYAttachStartupCommandBuilder.ForegroundAuth(
                destination: "signal-tree.example.test",
                port: nil,
                identityFile: nil,
                sshOptions: ["ControlMaster=no"],
                token: "foreground-auth-token"
            ),
            sshExecutable: fakeSSH.path
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "exec \(command)"]
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        #expect(Self.waitForFile(at: authRootPIDFile, containing: "\n", timeout: 3))
        #expect(Self.waitForFile(at: authDescendantPIDFile, containing: "\n", timeout: 3))
        let authRootPID = try #require(Int32(
            String(contentsOf: authRootPIDFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        let authDescendantPID = try #require(Int32(
            String(contentsOf: authDescendantPIDFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        defer {
            Darwin.kill(authRootPID, SIGKILL)
            Darwin.kill(authDescendantPID, SIGKILL)
        }
        Darwin.kill(process.processIdentifier, SIGINT)

        let exitDeadline = Date().addingTimeInterval(3)
        while process.isRunning, Date() < exitDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        let exited = !process.isRunning
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()

        #expect(exited)
        if exited {
            #expect(process.terminationStatus == 130)
        }
        #expect(Self.waitForProcessExit(authRootPID, timeout: 3))
        #expect(Self.waitForProcessExit(authDescendantPID, timeout: 3))
    }

    @Test func restoredAttachRetriesInitialForegroundAuthenticationFailure() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-restored-auth-retry-\(UUID().uuidString)", isDirectory: true)
        let fakeCLI = root.appendingPathComponent("cmux")
        let fakeSSH = root.appendingPathComponent("ssh")
        let fakeSleep = root.appendingPathComponent("sleep")
        let attemptFile = root.appendingPathComponent("ssh-attempts.txt")
        let attachFile = root.appendingPathComponent("attach-attempts.txt")
        let sleepFile = root.appendingPathComponent("sleep-delays.txt")

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try Self.writeShellFile(at: fakeCLI, lines: [
            "#!/bin/sh",
            "case \" $* \" in",
            "  *\" ssh-pty-attach \"*) printf '%s\\n' attach >> \"${CMUX_TEST_ATTACH_FILE}\"; exit 253 ;;",
            "  *) exit 0 ;;",
            "esac",
        ])
        try Self.writeShellFile(at: fakeSSH, lines: [
            "#!/bin/sh",
            "count=$(cat \"${CMUX_TEST_ATTEMPT_FILE}\" 2>/dev/null || printf 0)",
            "count=$((count + 1))",
            "printf '%s' \"$count\" > \"${CMUX_TEST_ATTEMPT_FILE}\"",
            "if [ \"$count\" -eq 1 ]; then",
            "  printf '%s\\n' 'ssh: connect to host boot-retry.example.test port 22: Network is unreachable' >&2",
            "  exit 255",
            "fi",
            "exit 0",
        ])
        try Self.writeShellFile(at: fakeSleep, lines: [
            "#!/bin/sh",
            "printf '%s\\n' \"$1\" >> \"${CMUX_TEST_SLEEP_FILE}\"",
        ])
        for executable in [fakeCLI, fakeSSH, fakeSleep] {
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(root.path):\(environment["PATH"] ?? "/usr/bin:/bin")"
        environment["CMUX_BUNDLED_CLI_PATH"] = fakeCLI.path
        environment["CMUX_SOCKET_PATH"] = "/tmp/cmux-debug-test.sock"
        environment["CMUX_WORKSPACE_ID"] = "11111111-1111-1111-1111-111111111111"
        environment["CMUX_SURFACE_ID"] = "22222222-2222-2222-2222-222222222222"
        environment["CMUX_TEST_ATTEMPT_FILE"] = attemptFile.path
        environment["CMUX_TEST_ATTACH_FILE"] = attachFile.path
        environment["CMUX_TEST_SLEEP_FILE"] = sleepFile.path
        environment["CMUX_SSH_RECONNECT_LIMIT"] = "2"
        environment["CMUX_SSH_RECONNECT_DELAY_SECONDS"] = "2"
        environment["CMUX_SSH_RECONNECT_MAX_DELAY_SECONDS"] = "2"

        let command = SSHPTYAttachStartupCommandBuilder.command(
            sessionID: "ssh-test-session",
            foregroundAuth: SSHPTYAttachStartupCommandBuilder.ForegroundAuth(
                destination: "boot-retry.example.test",
                port: nil,
                identityFile: nil,
                sshOptions: ["ControlMaster=no"],
                token: "foreground-auth-token"
            ),
            sshExecutable: fakeSSH.path
        )
        let result = try Self.runProcess(command: command, environment: environment)

        #expect(result.status == 253, Comment(rawValue: result.stderr))
        #expect(try String(contentsOf: attemptFile, encoding: .utf8) == "2")
        #expect(try String(contentsOf: attachFile, encoding: .utf8) == "attach\n")
        #expect(try String(contentsOf: sleepFile, encoding: .utf8) == "2\n")
    }

    @Test func restoredAttachRemovesForegroundAuthInflightMarkerAfterSuccess() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-restored-auth-\(UUID().uuidString)", isDirectory: true)
        let fakeCLI = root.appendingPathComponent("cmux")
        let fakeSSH = root.appendingPathComponent("ssh")
        let foregroundAuthPayloadLog =
            root.appendingPathComponent("foreground-auth-payload.json")
        let socketHash = UUID().uuidString
            .replacingOccurrences(of: "-", with: "")
            .lowercased() + "01234567"
        let destination = "cleanup-\(socketHash.prefix(8)).example.test"
        let controlPath = "/tmp/cmux-ssh-\(getuid())-\(socketHash)"
        let sshOptions = [
            "ControlMaster=auto",
            "ControlPersist=600",
            "ControlPath=\(controlPath)",
        ]
        let lockPath = try #require(SSHConnectionSharingOptions().foregroundAuthenticationLockPath(
            destination: destination,
            port: 2222,
            options: sshOptions
        ))
        let inFlightPath = lockPath + ".inflight"
        let resolvedAuthenticationLockPath = try #require(
            SSHConnectionSharingOptions()
                .resolvedControlMasterAuthenticationLockPath(
                    controlPath: controlPath
                )
        )

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: root)
            unlink(lockPath)
            unlink(inFlightPath)
            unlink(resolvedAuthenticationLockPath)
        }

        try Self.writeShellFile(at: fakeCLI, lines: [
            "#!/bin/sh",
            "case \" $* \" in",
            "  *\" workspace.remote.foreground_auth_ready \"*)",
            "    for argument in \"$@\"; do cmux_test_last_argument=\"$argument\"; done",
            "    printf '%s\\n' \"$cmux_test_last_argument\" > \"$CMUX_TEST_AUTH_PAYLOAD_LOG\"",
            "    /bin/zsh -fc 'zmodload zsh/system || exit 2; : >> \"$CMUX_TEST_RESOLVED_AUTH_LOCK\" || exit 2; if zsystem flock -t 0 -e -f cmux_test_lock_fd \"$CMUX_TEST_RESOLVED_AUTH_LOCK\"; then exit 1; fi; exit 0'",
            "    exit $?",
            "    ;;",
            "  *\" ssh-pty-attach \"*) exit 253 ;;",
            "  *) exit 0 ;;",
            "esac",
        ])
        try Self.writeShellFile(at: fakeSSH, lines: [
            "#!/bin/sh",
            "previous_arg=",
            "for arg in \"$@\"; do",
            "  if [ \"$arg\" = '-G' ]; then printf 'controlpath %s\\n' \"${CMUX_TEST_CONTROL_PATH}\"; exit 0; fi",
            "  if [ \"$previous_arg\" = '-O' ] && [ \"$arg\" = 'check' ]; then exit 0; fi",
            "  previous_arg=\"$arg\"",
            "done",
            "exit 0",
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
        environment["CMUX_TEST_CONTROL_PATH"] = controlPath
        environment["CMUX_TEST_AUTH_PAYLOAD_LOG"] =
            foregroundAuthPayloadLog.path
        environment["CMUX_TEST_RESOLVED_AUTH_LOCK"] =
            resolvedAuthenticationLockPath

        let command = SSHPTYAttachStartupCommandBuilder.command(
            sessionID: "ssh-test-session",
            foregroundAuth: SSHPTYAttachStartupCommandBuilder.ForegroundAuth(
                destination: destination,
                port: 2222,
                identityFile: nil,
                sshOptions: sshOptions,
                token: "foreground-auth-token"
            ),
            sshExecutable: fakeSSH.path
        )
        let result = try Self.runProcess(command: command, environment: environment)

        #expect(result.status == 253, Comment(rawValue: result.stderr))
        #expect(
            !fileManager.fileExists(atPath: inFlightPath),
            "Successful restored authentication must remove its owned in-flight marker before releasing the lock"
        )
        let payloadData = try Data(contentsOf: foregroundAuthPayloadLog)
        let payload = try #require(
            JSONSerialization.jsonObject(with: payloadData) as? [String: String]
        )
        #expect(payload["control_path"] == controlPath)
    }

    @Test func restoredAttachStopsAtForegroundAuthenticationFailureLimit() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-restored-auth-limit-\(UUID().uuidString)", isDirectory: true)
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
            "  *\" ssh-pty-attach \"*) printf '%s\\n' attach >> \"${CMUX_TEST_ATTACH_FILE}\"; exit 253 ;;",
            "  *) exit 0 ;;",
            "esac",
        ])
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

        let result = try Self.runProcess(
            command: SSHPTYAttachStartupCommandBuilder.command(
                sessionID: "ssh-test-session",
                foregroundAuth: SSHPTYAttachStartupCommandBuilder.ForegroundAuth(
                    destination: "boot-retry.example.test",
                    port: nil,
                    identityFile: nil,
                    sshOptions: ["ControlMaster=no"],
                    token: "foreground-auth-token"
                ),
                sshExecutable: fakeSSH.path
            ),
            environment: environment
        )

        #expect(result.status == 255, Comment(rawValue: result.stderr))
        #expect(try String(contentsOf: attemptFile, encoding: .utf8) == "20")
        #expect(!fileManager.fileExists(atPath: attachFile.path))
    }

    private static func writeShellFile(at url: URL, lines: [String]) throws {
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private static func waitForFile(
        at url: URL,
        containing expectedContents: String,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let contents = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            if contents.contains(expectedContents) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return false
    }

    private static func waitForProcessExit(_ processID: Int32, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            errno = 0
            if Darwin.kill(processID, 0) == -1, errno == ESRCH {
                return true
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        errno = 0
        return Darwin.kill(processID, 0) == -1 && errno == ESRCH
    }

    private static func runProcess(
        command: String,
        environment: [String: String]
    ) throws -> (status: Int32, stderr: String) {
        let process = Process()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe
        try process.run()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        return (process.terminationStatus, stderr)
    }
}
