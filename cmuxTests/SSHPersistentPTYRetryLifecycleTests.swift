import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct SSHPersistentPTYRetryLifecycleTests {
    @Test func establishedBridgeResetsExponentialBackoff() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-established-bridge-backoff-\(UUID().uuidString)", isDirectory: true)
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
            "    case \"$count\" in 1|3) exit 255 ;; 2) exit 254 ;; *) exit 253 ;; esac", "    ;;",
            "  *) exit 0 ;;", "esac",
        ])
        try Self.writeShellFile(at: fakeSleep, lines: [
            "#!/bin/sh", "printf '%s\\n' \"$1\" >> \"${CMUX_TEST_SLEEP_LOG}\"",
        ])
        for executable in [fakeCLI, fakeSleep] {
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(root.path):\(environment["PATH"] ?? "/usr/bin:/bin")"
        environment["CMUX_BUNDLED_CLI_PATH"] = fakeCLI.path
        environment["CMUX_SOCKET_PATH"] = "/tmp/cmux-debug-test.sock"
        environment["CMUX_WORKSPACE_ID"] = "11111111-1111-1111-1111-111111111111"
        environment["CMUX_SURFACE_ID"] = "22222222-2222-2222-2222-222222222222"
        environment["CMUX_TEST_ATTEMPT_FILE"] = attemptFile.path
        environment["CMUX_TEST_SLEEP_LOG"] = sleepLog.path
        environment["CMUX_SSH_RECONNECT_DELAY_SECONDS"] = "2"
        environment["CMUX_SSH_RECONNECT_MAX_DELAY_SECONDS"] = "5"

        let result = Self.runShell(
            SSHPTYAttachStartupCommandBuilder.command(sessionID: "ssh-test-session"),
            environment: environment
        )

        #expect(result.status == 253, Comment(rawValue: result.stderr))
        #expect(try String(contentsOf: attemptFile, encoding: .utf8) == "4")
        #expect(try String(contentsOf: sleepLog, encoding: .utf8) == "2\n2\n4\n")
    }

    private static func writeShellFile(at url: URL, lines: [String]) throws {
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private static func runShell(_ command: String, environment: [String: String]) -> (status: Int32, stderr: String) {
        let process = Process()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe
        do { try process.run() } catch { return (-1, String(describing: error)) }
        process.waitUntilExit()
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, stderr)
    }
}
