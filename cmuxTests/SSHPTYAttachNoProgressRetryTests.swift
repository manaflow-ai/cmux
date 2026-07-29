import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct SSHPTYAttachNoProgressRetryTests {
    private struct ProcessResult {
        let status: Int32
        let stderr: String
        let timedOut: Bool
    }

    @Test("Repeated zero-progress bridge closures stop after the health budget")
    func repeatedZeroProgressClosuresStop() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-pty-no-progress-\(UUID().uuidString)", isDirectory: true)
        let fakeCLI = root.appendingPathComponent("cmux")
        let fakeSleep = root.appendingPathComponent("sleep")
        let attemptFile = root.appendingPathComponent("attempts")
        let policyLog = root.appendingPathComponent("policy-log")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try Self.writeShellFile(at: fakeCLI, lines: [
            "#!/bin/sh",
            "case \" $* \" in",
            "  *\" ssh-pty-attach \"*)",
            "    count=$(cat \"$CMUX_TEST_ATTEMPT_FILE\" 2>/dev/null || printf 0)",
            "    count=$((count + 1))",
            "    printf '%s' \"$count\" > \"$CMUX_TEST_ATTEMPT_FILE\"",
            "    printf '%s/%s\\n' \"${CMUX_SSH_PTY_ATTACH_NO_PROGRESS_RETRY:-missing}\" \"${CMUX_SSH_PTY_ATTACH_NO_PROGRESS_LIMIT:-missing}\" >> \"$CMUX_TEST_POLICY_LOG\"",
            "    exit 252",
            "    ;;",
            "  *) exit 0 ;;",
            "esac",
        ])
        try Self.writeShellFile(at: fakeSleep, lines: ["#!/bin/sh", "exit 0"])
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
        environment["CMUX_TEST_POLICY_LOG"] = policyLog.path
        environment["CMUX_SSH_PTY_NO_PROGRESS_RETRY_LIMIT"] = "3"
        environment["CMUX_SSH_RECONNECT_DELAY_SECONDS"] = "1"
        environment["CMUX_SSH_RECONNECT_MAX_DELAY_SECONDS"] = "1"

        let result = Self.run(
            command: SSHPTYAttachStartupCommandBuilder.command(sessionID: "ssh-test-session"),
            environment: environment
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 1, Comment(rawValue: result.stderr))
        #expect(try String(contentsOf: attemptFile, encoding: .utf8) == "3")
        #expect(
            try String(contentsOf: policyLog, encoding: .utf8) == """
            0/3
            1/3
            2/3

            """
        )
        #expect(result.stderr.contains("made no progress after 3 attempts"), Comment(rawValue: result.stderr))
    }

    private static func writeShellFile(at url: URL, lines: [String]) throws {
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private static func run(command: String, environment: [String: String]) -> ProcessResult {
        let process = Process()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe
        do {
            try process.run()
        } catch {
            return ProcessResult(status: -1, stderr: String(describing: error), timedOut: false)
        }

        let exited = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            exited.signal()
        }
        let timedOut = exited.wait(timeout: .now() + 5) == .timedOut
        if timedOut {
            process.terminate()
            _ = exited.wait(timeout: .now() + 1)
        }
        let stderr = String(
            data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        return ProcessResult(status: process.terminationStatus, stderr: stderr, timedOut: timedOut)
    }
}
