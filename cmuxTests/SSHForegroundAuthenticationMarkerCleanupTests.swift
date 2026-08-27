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
    @Test func restoredAttachSignalTerminatesForegroundAuthenticationProcessTree() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-restored-auth-tree-\(UUID().uuidString)", isDirectory: true)
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
            "while :; do /bin/sleep 30; done",
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
        environment["CMUX_TEST_AUTH_CHILD_PID"] = childPIDFile.path
        environment["CMUX_TEST_AUTH_CHILD_SIGNAL"] = childSignalLog.path

        let command = SSHPTYAttachStartupCommandBuilder.command(
            sessionID: "ssh-test-session",
            foregroundAuth: SSHPTYAttachStartupCommandBuilder.ForegroundAuth(
                destination: "signal-tree.example.test",
                port: nil,
                identityFile: nil,
                sshOptions: ["ControlMaster=no"],
                token: "foreground-auth-token"
            )
        ).replacingOccurrences(of: "/usr/bin/ssh", with: fakeSSH.path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "exec \(command)"]
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        #expect(Self.waitForFile(at: childPIDFile, containing: "\n", timeout: 3))
        let childPID = try #require(Int32(
            String(contentsOf: childPIDFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        defer {
            Darwin.kill(childPID, SIGKILL)
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
        #expect(
            Self.waitForFile(at: childSignalLog, containing: "term", timeout: 3),
            "Direct restored-attach signals must terminate the nested authentication process tree"
        )
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
            )
        ).replacingOccurrences(of: "/usr/bin/ssh", with: fakeSSH.path)
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
            )
        ).replacingOccurrences(of: "/usr/bin/ssh", with: fakeSSH.path)
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
            "printf '%s\\n' attach >> \"${CMUX_TEST_ATTACH_FILE}\"",
            "exit 253",
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
                )
            ).replacingOccurrences(of: "/usr/bin/ssh", with: fakeSSH.path),
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
