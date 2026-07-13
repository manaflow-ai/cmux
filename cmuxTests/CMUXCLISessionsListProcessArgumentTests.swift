import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension CMUXCLIErrorOutputRegressionTests {
    @Test func testSessionsListProcessArgumentsPreservesEmptyElements() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sessions-list-live-argv-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sleeper = root.appendingPathComponent("sleep.sh", isDirectory: false)
        try "#!/bin/sh\nsleep 30\n".write(to: sleeper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sleeper.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [sleeper.path, "", "resume"]
        try process.run()
        defer {
            process.terminate()
            process.waitUntilExit()
        }

        let session = try sessionsListDiagnosticSession(
            launcher: "codex",
            executablePath: "/bin/sh",
            arguments: ["/bin/sh"],
            pid: Int(process.processIdentifier)
        )
        let arguments = try #require(session["stored_pid_arguments"] as? [String])

        #expect(Array(arguments.suffix(3)) == [sleeper.path, "", "resume"])
    }

    @Test func testSessionsListForkStartupInputCountsAsciiSafeNonASCIIQuoting() throws {
        let workingDirectory = "/tmp/cmux/\u{65e5}\u{672c}\u{8a9e}" + String(repeating: "x", count: 250)
        let session = try sessionsListDiagnosticSession(
            launcher: "codex",
            executablePath: "codex",
            arguments: ["codex"],
            workingDirectory: workingDirectory
        )
        #expect(session["fork_supported"] as? Bool == true)
        #expect(session["fork_startup_input_available"] as? Bool == false)
    }

    @Test func testSessionsListClaudeStartupInputCountsAuthPreservationEnvironment() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sessions-list-claude-env-\(UUID().uuidString)", isDirectory: true)
        let transcript = root.appendingPathComponent("claude-session.jsonl", isDirectory: false)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "{\"type\":\"summary\"}\n".write(to: transcript, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let configDir = "/tmp/" + String(repeating: "claude-config-", count: 50)
        let session = try sessionsListDiagnosticSession(
            agent: "claude",
            launcher: "claude",
            executablePath: "claude",
            arguments: ["claude", "--resume", "claude-session"],
            environment: ["CLAUDE_CONFIG_DIR": configDir],
            transcriptPath: transcript.path
        )
        #expect(session["fork_supported"] as? Bool == true)
        #expect(session["fork_startup_input_available"] as? Bool == false)
    }
}
