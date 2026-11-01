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
/// are refused with no command sent to the app.
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

    /// The payload carries `workspace_ref` next to `workspace_id`; the lines print the one
    /// `--id-format` asks for, refs by default.
    func testSessionPriorityPrintsTheWorkspaceInTheRequestedIdFormat() throws {
        let workspaceId = UUID().uuidString
        let workspace: [String: Any] = [
            "workspace_id": workspaceId, "workspace_ref": "workspace:3", "tier": "urgent",
            "difficulty": "hard", "difficulty_source": "override", "target": NSNull(), "panes": [],
        ]
        func status(_ name: String, _ arguments: [String]) throws -> String? {
            let result = try runSessionPriorityCLI(name: name, arguments: arguments, respond: { method, id in
                method == "session_priority.status"
                    ? self.v2Response(id: id, ok: true, result: [
                        "window_id": NSNull(), "enabled": true, "urgent_count": 1, "workspaces": [workspace],
                    ])
                    : nil
            })
            XCTAssertEqual(result.process.status, 0, result.process.stderr)
            return result.process.stdout.split(separator: "\n").map(String.init).dropFirst().first
        }

        XCTAssertEqual(try status("session-priority-refs", ["session-priority"]), "1. workspace:3  urgent  hard(override)")
        XCTAssertEqual(
            try status("session-priority-uuids", ["session-priority", "--id-format", "uuids"]),
            "1. \(workspaceId)  urgent  hard(override)"
        )

        let set = try runSessionPriorityCLI(
            name: "session-priority-set-ref",
            arguments: ["session-priority", "difficulty", "hard", "--workspace", workspaceId],
            respond: { method, id in
                method == "session_priority.set"
                    ? self.v2Response(id: id, ok: true, result: workspace)
                    : nil
            }
        )
        XCTAssertEqual(set.process.status, 0, set.process.stderr)
        XCTAssertEqual(
            set.process.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            "OK workspace:3 difficulty hard"
        )
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
            respond: { _, _ in nil }
        )
        XCTAssertNotEqual(result.process.status, 0)
        XCTAssertTrue(result.process.stderr.contains("easy"), result.process.stderr)
        XCTAssertTrue(result.commands.isEmpty, "\(result.commands)")
    }

    func testSessionPriorityManualOnSendsTrueAndPrintsLiteralOn() throws {
        let workspaceId = UUID().uuidString
        let result = try runSessionPriorityCLI(
            name: "session-priority-manual-on",
            arguments: ["session-priority", "manual", "on", "--workspace", workspaceId],
            respond: { method, id in
                method == "session_priority.set"
                    ? self.v2Response(id: id, ok: true, result: ["workspace_id": workspaceId, "manual": true])
                    : nil
            }
        )
        XCTAssertEqual(result.process.status, 0, result.process.stderr)
        let request = try XCTUnwrap(result.commands.compactMap(jsonObject).first {
            $0["method"] as? String == "session_priority.set"
        }, "\(result.commands)")
        let params = try XCTUnwrap(request["params"] as? [String: Any])
        XCTAssertEqual(params["manual"] as? Bool, true)
        XCTAssertEqual(
            result.process.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            "OK \(workspaceId) manual on"
        )
    }

    func testSessionPriorityRejectsInvalidManualValueBeforeContactingTheApp() throws {
        let result = try runSessionPriorityCLI(
            name: "session-priority-invalid-manual",
            arguments: ["session-priority", "manual", "maybe"],
            respond: { _, _ in nil }
        )
        XCTAssertNotEqual(result.process.status, 0)
        XCTAssertTrue(result.process.stderr.contains("maybe"), result.process.stderr)
        XCTAssertTrue(result.commands.isEmpty, "\(result.commands)")
    }

    func testSessionPriorityRejectsUnknownSubcommand() throws {
        let result = try runSessionPriorityCLI(
            name: "session-priority-unknown",
            arguments: ["session-priority", "frobnicate"],
            respond: { _, _ in nil }
        )
        XCTAssertNotEqual(result.process.status, 0)
        XCTAssertTrue(result.process.stderr.contains("frobnicate"), result.process.stderr)
        XCTAssertTrue(result.commands.isEmpty, "\(result.commands)")
    }

    func testSessionPriorityStatusJSONPassesThePayloadThrough() throws {
        let windowId = UUID().uuidString
        let result = try runSessionPriorityCLI(
            name: "session-priority-json",
            arguments: ["session-priority", "status", "--json"],
            respond: { method, id in
                method == "session_priority.status"
                    ? self.v2Response(id: id, ok: true, result: [
                        "window_id": windowId, "enabled": false, "urgent_count": 0,
                        "workspaces": [],
                    ])
                    : nil
            }
        )
        XCTAssertEqual(result.process.status, 0, result.process.stderr)
        let payload = try XCTUnwrap(jsonObject(result.process.stdout), result.process.stdout)
        XCTAssertEqual(payload["window_id"] as? String, windowId)
        XCTAssertEqual(payload["enabled"] as? Bool, false)
        XCTAssertEqual(payload["urgent_count"] as? Int, 0)
        XCTAssertFalse(result.process.stdout.contains("session priority:"), result.process.stdout)
    }

    func testSessionPriorityStatusPrintsOffHeaderAndHandlesNullTargetAndNoPanes() throws {
        let workspaceId = UUID().uuidString
        let result = try runSessionPriorityCLI(
            name: "session-priority-off",
            arguments: ["session-priority", "status"],
            respond: { method, id in
                method == "session_priority.status"
                    ? self.v2Response(id: id, ok: true, result: [
                        "window_id": NSNull(), "enabled": false, "urgent_count": 0,
                        "workspaces": [[
                            "workspace_id": workspaceId, "tier": NSNull(),
                            "difficulty": "normal", "difficulty_source": "default",
                            "target": NSNull(), "panes": [],
                        ]],
                    ])
                    : nil
            }
        )
        XCTAssertEqual(result.process.status, 0, result.process.stderr)
        let lines = result.process.stdout.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first, "session priority: off, urgent: 0", result.process.stdout)
        XCTAssertEqual(lines.dropFirst().first, "1. \(workspaceId)  -  normal(default)", result.process.stdout)
        XCTAssertEqual(lines.count, 2, result.process.stdout)
    }

    private func runSessionPriorityCLI(
        name: String,
        arguments: [String],
        respond: @escaping (_ method: String, _ id: String) -> String?
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
        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        return (result, state.commands)
    }
}
