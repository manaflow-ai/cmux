import Darwin
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

        let sentinelArgument = root.appendingPathComponent("sentinel argument", isDirectory: false)

        // A second live child of an app-hosted test process delays Foundation.Process's
        // exit notification for the CLI, even after that CLI has exited successfully.
        // Launch this fixture through a short-lived shell and reap the shell first, so
        // the process whose argv the CLI inspects has been adopted outside the test host.
        let processID = try spawnDetachedArgumentFixture(
            sentinelArgument: sentinelArgument.path,
            pidFile: root.appendingPathComponent("fixture.pid", isDirectory: false)
        )
        defer { kill(processID, SIGKILL) }

        let session = try sessionsListDiagnosticSession(
            launcher: "codex",
            executablePath: "/usr/bin/python3",
            arguments: ["/usr/bin/python3"],
            pid: Int(processID)
        )
        let arguments = try #require(session["stored_pid_arguments"] as? [String])

        #expect(Array(arguments.suffix(3)) == [sentinelArgument.path, "", "resume"])
    }

    private func spawnDetachedArgumentFixture(sentinelArgument: String, pidFile: URL) throws -> pid_t {
        let command = """
        /usr/bin/nohup /usr/bin/python3 -c 'import signal; signal.pause()' "$1" '' resume \
          </dev/null >/dev/null 2>&1 &
        printf '%s\\n' "$!" > "$2"
        """
        let launcherPID = try spawnProcess(
            executablePath: "/bin/sh",
            arguments: [
                "/bin/sh",
                "-c",
                command,
                "cmux-detached-argv-fixture",
                sentinelArgument,
                pidFile.path,
            ]
        )
        var launcherStatus: Int32 = 0
        while waitpid(launcherPID, &launcherStatus, 0) < 0 {
            guard errno == EINTR else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        }

        let rawPID = try String(contentsOf: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let processID = pid_t(rawPID), processID > 0, kill(processID, 0) == 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(ESRCH),
                userInfo: [NSLocalizedDescriptionKey: "Detached argv fixture did not remain alive"]
            )
        }
        return processID
    }

    private func spawnProcess(executablePath: String, arguments: [String]) throws -> pid_t {
        var processID: pid_t = 0
        var argumentPointers = arguments.map { strdup($0) }
        argumentPointers.append(nil)
        defer {
            for pointer in argumentPointers where pointer != nil {
                free(pointer)
            }
        }

        let spawnStatus = executablePath.withCString { executablePointer in
            argumentPointers.withUnsafeMutableBufferPointer { buffer in
                posix_spawn(
                    &processID,
                    executablePointer,
                    nil,
                    nil,
                    buffer.baseAddress,
                    environ
                )
            }
        }
        guard spawnStatus == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(spawnStatus))
        }
        return processID
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
