import XCTest
import Darwin
import Foundation

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// `cmux session-priority`: `status` prints one line per workspace from `session_priority.status`;
/// `difficulty` and `manual` send `session_priority.set` for the chosen workspace. Bad arguments
/// are refused before the app is contacted.
extension CLINotifyProcessIntegrationRegressionTests {
    func testSessionPriorityStatusCallsTheSocket() throws {
        let workspaceId = UUID().uuidString
        let result = try runSessionPriorityCLI(
            name: "session-priority-status",
            arguments: ["session-priority"],
            respond: { method, id in
                method == "session_priority.status"
                    ? self.v2Response(id: id, ok: true, result: [
                        "window_id": UUID().uuidString, "enabled": true, "urgent_count": 1,
                        "workspaces": [[
                            "workspace_id": workspaceId, "enabled": true, "tier": "urgent",
                            "difficulty": "hard", "difficulty_source": "override", "manual": false,
                            "target": ["effort": "high", "model": "opus"],
                            "panes": [["surface_id": UUID().uuidString, "state": "applying"]],
                        ]],
                    ])
                    : nil
            }
        )
        XCTAssertEqual(result.process.status, 0, result.process.stderr)
        XCTAssertTrue(result.commands.compactMap(jsonObject).contains {
            $0["method"] as? String == "session_priority.status"
        }, "\(result.commands)")
        let lines = result.process.stdout.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first, "session priority: on, urgent: 1", result.process.stdout)
        let line = try XCTUnwrap(lines.dropFirst().first, result.process.stdout)
        XCTAssertTrue(line.hasPrefix("1. \(workspaceId)"), line)
        XCTAssertTrue(line.contains("urgent"), line)
        XCTAssertTrue(line.contains("hard(override)"), line)
        XCTAssertTrue(line.contains("high / opus"), line)
        XCTAssertTrue(line.contains("[applying]"), line)
    }

    func testSessionPriorityDifficultySendsTheWorkspace() throws {
        let workspaceId = UUID().uuidString
        let result = try runSessionPriorityCLI(
            name: "session-priority-difficulty",
            arguments: ["session-priority", "difficulty", "hard", "--workspace", workspaceId],
            respond: { method, id in
                method == "session_priority.set"
                    ? self.v2Response(id: id, ok: true, result: ["workspace_id": workspaceId, "difficulty": "hard"])
                    : nil
            }
        )
        XCTAssertEqual(result.process.status, 0, result.process.stderr)
        let request = try XCTUnwrap(result.commands.compactMap(jsonObject).first {
            $0["method"] as? String == "session_priority.set"
        }, "\(result.commands)")
        let params = try XCTUnwrap(request["params"] as? [String: Any])
        XCTAssertEqual(params["workspace_id"] as? String, workspaceId)
        XCTAssertEqual(params["difficulty"] as? String, "hard")
        XCTAssertEqual(
            result.process.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            "OK \(workspaceId) difficulty hard"
        )
    }

    func testSessionPriorityManualOffSendsFalse() throws {
        let workspaceId = UUID().uuidString
        let result = try runSessionPriorityCLI(
            name: "session-priority-manual",
            arguments: ["session-priority", "manual", "off", "--workspace", workspaceId],
            respond: { method, id in
                method == "session_priority.set"
                    ? self.v2Response(id: id, ok: true, result: ["workspace_id": workspaceId, "manual": false])
                    : nil
            }
        )
        XCTAssertEqual(result.process.status, 0, result.process.stderr)
        let request = try XCTUnwrap(result.commands.compactMap(jsonObject).first {
            $0["method"] as? String == "session_priority.set"
        }, "\(result.commands)")
        let params = try XCTUnwrap(request["params"] as? [String: Any])
        XCTAssertEqual(params["manual"] as? Bool, false)
        XCTAssertNil(params["difficulty"])
        XCTAssertTrue(result.process.stdout.contains("manual off"), result.process.stdout)
    }

    func testSessionPriorityRejectsUnknownDifficultyBeforeContactingTheApp() throws {
        let result = try runSessionPriorityCLI(
            name: "session-priority-invalid",
            arguments: ["session-priority", "difficulty", "impossible"],
            respond: { _, _ in nil },
            expectsConnection: false
        )
        XCTAssertNotEqual(result.process.status, 0)
        XCTAssertTrue(result.process.stderr.contains("easy"), result.process.stderr)
        XCTAssertTrue(result.commands.isEmpty, "\(result.commands)")
    }

    private func runSessionPriorityCLI(
        name: String,
        arguments: [String],
        respond: @escaping (_ method: String, _ id: String) -> String?,
        expectsConnection: Bool = true
    ) throws -> (process: ProcessRunResult, commands: [String]) {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath(name)
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
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
            return respond(method, id) ?? self.v2Response(
                id: id,
                ok: false,
                error: ["code": "unexpected", "message": "Unexpected method \(method)"]
            )
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_WORKSPACE_ID"] = nil
        environment["CMUX_SURFACE_ID"] = nil
        let result = runProcess(
            executablePath: cliPath,
            arguments: arguments,
            environment: environment,
            timeout: 5
        )
        if !expectsConnection { serverHandled.isInverted = true }
        wait(for: [serverHandled], timeout: expectsConnection ? 5 : 0.3)
        XCTAssertFalse(result.timedOut, result.stderr)
        return (result, state.commands)
    }
}
