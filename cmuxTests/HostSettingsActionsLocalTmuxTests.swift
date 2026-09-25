import CmuxSettingsUI
import CmuxFoundation
import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Local tmux session-list decoder")
struct HostSettingsActionsLocalTmuxTests {
    private struct TimedOutRunner: CommandRunning {
        func run(directory: String, executable: String, arguments: [String], timeout: TimeInterval?) async -> CommandResult {
            #expect(timeout != nil && timeout! > 0 && timeout! <= 30)
            return CommandResult(stdout: nil, stderr: nil, exitStatus: nil, timedOut: true, executionError: nil)
        }
    }

    @Test("Settings CLI requests have a finite deadline and report timeout failure")
    func timeoutReportsActionFailure() async throws {
        do {
            _ = try await HostSettingsActions.runLocalTmuxCLI(
                executableURL: URL(fileURLWithPath: "/fixture/cmux"),
                arguments: ["local-tmux", "list", "--json"],
                runner: TimedOutRunner()
            )
            Issue.record("Timed out CLI request succeeded")
        } catch let error as LocalTmuxSettingsActionError {
            guard case .commandFailed = error else {
                Issue.record("Unexpected timeout error: \(error)")
                return
            }
        }
    }

    @Test("Cancellation reaches the local tmux CLI", .timeLimit(.minutes(1)))
    func cancellationStopsCLI() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let completion = directory.appendingPathComponent("completed")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await HostSettingsActions.runLocalTmuxCLI(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "sleep 1; touch \"$1\"", "fixture", completion.path]
            )
        }
        do {
            _ = try await task.value
            Issue.record("Cancelled CLI request succeeded")
        } catch is CancellationError {
            #expect(!FileManager.default.fileExists(atPath: completion.path))
        }
    }

    @Test("Cancellation reaps a running local tmux CLI", .timeLimit(.minutes(1)))
    func cancellationReapsRunningCLI() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ready = directory.appendingPathComponent("ready")
        let watcher = FileWatcher(path: ready.path)
        var events = watcher.events.makeAsyncIterator()
        let task = Task {
            try await HostSettingsActions.runLocalTmuxCLI(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "echo $$ > \"$1.tmp\"; mv \"$1.tmp\" \"$1\"; exec /bin/sleep 60", "fixture", ready.path]
            )
        }
        defer { task.cancel() }
        while !FileManager.default.fileExists(atPath: ready.path) {
            _ = try #require(await events.next())
        }
        let pid = try #require(Int32(String(contentsOf: ready, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancelled running CLI succeeded")
        } catch is CancellationError {
            let killResult = kill(pid, 0)
            let killErrno = errno
            #expect(killResult == -1)
            #expect(killErrno == ESRCH)
        }
        await watcher.stop()
    }

    /// Decodes authoritative CLI rows and preserves live-first display ordering.
    @Test func decodesAuthoritativeSessionListAndOrdersLiveFirst() throws {
        let managedID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let payload: [String: Any] = [
            "sessions": [
                [
                    "id": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
                    "session_name": "stale",
                    "cwd": "/tmp/stale",
                    "managed": true,
                    "live": false,
                ],
                [
                    "id": managedID.uuidString,
                    "session_name": "work",
                    "cwd": "/Users/test/src/work",
                    "clients": 2,
                    "managed": true,
                    "live": true,
                ],
                [
                    "id": NSNull(),
                    "session_name": "manual",
                    "clients": 0,
                    "managed": false,
                    "live": true,
                ],
            ],
            "count": 3,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)

        let sessions = try LocalTmuxSessionListDecoder().decode(data)

        #expect(sessions.map(\.name) == ["manual", "work", "stale"])
        #expect(sessions[0].id == "tmux:manual")
        #expect(sessions[0].logicalID == nil)
        #expect(sessions[0].isManaged == false)
        #expect(sessions[1].logicalID == managedID)
        #expect(sessions[1].clientCount == 2)
        #expect(sessions[1].cwd == "/Users/test/src/work")
        #expect(sessions[2].isLive == false)
        #expect(sessions[2].clientCount == 0)
    }

    /// Rejects malformed required lifecycle fields, identifiers, and client counts off-main.
    @Test func rejectsMalformedSessionRows() throws {
        let malformedRows: [[String: Any]] = [
            [
                "id": NSNull(),
                "session_name": "missing-live",
                "managed": false,
            ],
            [
                "id": "not-a-uuid",
                "session_name": "managed-bad-id",
                "clients": 1,
                "managed": true,
                "live": true,
            ],
            [
                "id": NSNull(),
                "session_name": "bad-clients",
                "clients": "two",
                "managed": false,
                "live": true,
            ],
        ]

        for row in malformedRows {
            let data = try JSONSerialization.data(withJSONObject: ["sessions": [row]])
            #expect(throws: Error.self) {
                _ = try LocalTmuxSessionListDecoder().decode(data)
            }
        }
    }

    /// Rejects payloads that omit the authoritative session list.
    @Test func rejectsMalformedSessionListPayload() {
        let data = Data(#"{"count": 1}"#.utf8)

        #expect(throws: Error.self) {
            _ = try LocalTmuxSessionListDecoder().decode(data)
        }
    }
    @Test("Starting persistence pins the workspace captured with its directory")
    func startArgumentsKeepCapturedWorkspaceIdentity() {
        let workspaceID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let arguments = HostSettingsActions.localTmuxStartArguments(
            name: "work", workspaceID: workspaceID, cwd: "/selected/project",
            socketPath: "/tmp/selected.sock"
        )
        #expect(arguments.contains("--workspace"))
        if let index = arguments.firstIndex(of: "--workspace") {
            #expect(arguments[index + 1] == workspaceID.uuidString)
        }
        if let index = arguments.firstIndex(of: "--cwd") {
            #expect(arguments[index + 1] == "/selected/project")
        }
    }

}
