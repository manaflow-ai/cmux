import Darwin
import Foundation
@preconcurrency import XCTest

// Stays on XCTest deliberately: this extends the existing bundled-CLI socket
// harness (`CLINotifyProcessIntegrationRegressionTests`), whose process runner
// and mock server lifecycle are shared with the surrounding integration suite.
extension CLINotifyProcessIntegrationRegressionTests {
    /// Regression for https://github.com/manaflow-ai/cmux/issues/11189: when
    /// the ambient surface is stale and the live resolver cannot prove a pane,
    /// a generic hook must no-op instead of using the workspace's focused tab.
    func testCodexPromptSubmitWithStaleSurfaceAndNoLiveEvidenceFailsClosed() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("codex-stale-no-live")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-stale-no-live-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let staleSurfaceId = "22222222-2222-2222-2222-222222222222"
        let focusedSurfaceId = "33333333-3333-3333-3333-333333333333"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line) else {
                return line.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{")
                    ? self.malformedRequestResponse(raw: line)
                    : "OK"
            }
            guard let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(id: payload["id"] as? String, raw: line)
            }
            switch method {
            case "agent.resolve_delivery_target":
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "method_not_found", "message": "Legacy app without live resolver"]
                )
            case "system.top":
                return self.v2Response(id: id, ok: true, result: ["windows": []])
            case "surface.list":
                let params = payload["params"] as? [String: Any] ?? [:]
                guard params["workspace_id"] as? String == workspaceId else {
                    return self.v2Response(
                        id: id,
                        ok: false,
                        error: ["code": "not_found", "message": "Workspace not found"]
                    )
                }
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "surfaces": [
                            [
                                "id": focusedSurfaceId,
                                "ref": "surface:1",
                                "focused": true,
                            ],
                        ],
                    ]
                )
            case "workspace.current":
                return self.v2Response(id: id, ok: true, result: ["workspace_id": workspaceId])
            case "feed.push":
                return self.v2Response(id: id, ok: true, result: [:])
            case "agent_journal_append":
                return "OK 1"
            default:
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unrecognized_method", "message": "unexpected method: \(method)"]
                )
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = staleSurfaceId
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CODEX_HOME"] = root.appendingPathComponent("codex-home", isDirectory: true).path
        environment.removeValue(forKey: "CMUX_CODEX_PID")

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "prompt-submit"],
            environment: environment,
            standardInput: #"{"session_id":"codex-stale-no-live","cwd":"\#(root.path)","hook_event_name":"UserPromptSubmit","prompt":"continue"}"#,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "{}\n")
        XCTAssertFalse(
            state.commands.contains { $0.contains("notify_target_async") || $0.contains("set_status codex") },
            "A stale surface with no live proof must not mutate the focused pane, saw \(state.commands)"
        )
        XCTAssertTrue(
            AgentJournalAppendCapture.captures(in: state.commands).contains {
                $0.unattributedReason == "target-unresolved" && $0.surfaceId == nil
            },
            "Fail-closed target resolution must leave an unattributed journal diagnostic, saw \(state.commands)"
        )
    }

    /// A rejected generic target must not be reintroduced by the Codex child
    /// lifecycle adapter after `resolveAgentHookTarget` returns nil.
    func testCodexSubagentLifecycleDoesNotReuseRejectedMappedSurface() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("codex-stale-subagent")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-stale-subagent-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let staleSurfaceId = "22222222-2222-2222-2222-222222222222"
        let focusedSurfaceId = "33333333-3333-3333-3333-333333333333"
        let sessionIds = ["codex-stale-subagent-start", "codex-stale-subagent-stop"]
        let settledSessionId = sessionIds[1]
        let settledTurnId = "turn-1"
        let ledgerPath = root.appendingPathComponent("codex-turn-ledger.json")

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let now = Date().timeIntervalSince1970
        let storedSessions = Dictionary(uniqueKeysWithValues: sessionIds.map { sessionId in
            (
                sessionId,
                [
                    "sessionId": sessionId,
                    "workspaceId": workspaceId,
                    "surfaceId": staleSurfaceId,
                    "cwd": root.path,
                    "startedAt": now,
                    "updatedAt": now,
                ] as [String: Any]
            )
        })
        let storeObject: [String: Any] = ["version": 1, "sessions": storedSessions]
        try JSONSerialization.data(withJSONObject: storeObject, options: [.prettyPrinted])
            .write(to: root.appendingPathComponent("codex-hook-sessions.json"), options: .atomic)
        let ledgerRecord: [String: Any] = [
            "workspaceID": workspaceId,
            "surfaceID": staleSurfaceId,
            "owner": [:],
            "activeTurnID": settledTurnId,
            "activeChildrenByTurn": [settledTurnId: ["child-1"]],
            "unknownChildrenByTurn": [:],
            "terminalChildrenByTurn": [:],
            "pendingTurns": [settledTurnId: ["turnID": settledTurnId]],
            "settledTurnIDs": [],
            "notifiedTurnIDs": [],
            "updatedAt": now,
        ]
        let ledgerObject: [String: Any] = [
            "records": [settledSessionId: ledgerRecord],
            "surfaceOwners": [:],
        ]
        try JSONSerialization.data(withJSONObject: ledgerObject, options: [.prettyPrinted])
            .write(to: ledgerPath, options: .atomic)

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line) else {
                return "OK"
            }
            guard let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(id: payload["id"] as? String, raw: line)
            }
            switch method {
            case "agent.resolve_delivery_target":
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "method_not_found", "message": "Legacy app without live resolver"]
                )
            case "system.top":
                return self.v2Response(id: id, ok: true, result: ["windows": []])
            case "surface.list":
                let params = payload["params"] as? [String: Any] ?? [:]
                guard params["workspace_id"] as? String == workspaceId else {
                    return self.v2Response(
                        id: id,
                        ok: false,
                        error: ["code": "not_found", "message": "Workspace not found"]
                    )
                }
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "surfaces": [["id": focusedSurfaceId, "ref": "surface:1", "focused": true]],
                    ]
                )
            case "workspace.current", "feed.push":
                return self.v2Response(id: id, ok: true, result: ["workspace_id": workspaceId])
            case "agent_journal_append":
                return "OK 1"
            default:
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unrecognized_method", "message": "unexpected method: \(method)"]
                )
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = staleSurfaceId
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CODEX_HOME"] = root.appendingPathComponent("codex-home", isDirectory: true).path
        environment["CMUX_CODEX_TURN_LEDGER_PATH"] = ledgerPath.path
        environment.removeValue(forKey: "CMUX_CODEX_PID")

        for (index, subcommand) in ["subagent-start", "subagent-stop"].enumerated() {
            let result = runProcess(
                executablePath: cliPath,
                arguments: ["hooks", "codex", subcommand],
                environment: environment,
                standardInput: #"{"session_id":"\#(sessionIds[index])","cwd":"\#(root.path)","hook_event_name":"\#(index == 0 ? "SubagentStart" : "SubagentStop")","agent_id":"child-\#(index)","turn_id":"turn-\#(index)"}"#,
                timeout: 5
            )
            XCTAssertFalse(result.timedOut, result.stderr)
            XCTAssertEqual(result.status, 0, result.stderr)
            XCTAssertEqual(result.stdout, "{}\n")
        }

        wait(for: [serverHandled], timeout: 5)
        let journalCommands = state.commands.filter { $0.contains("agent_journal_append") }
        XCTAssertFalse(
            journalCommands.contains { $0.contains(staleSurfaceId) || $0.contains(focusedSurfaceId) },
            "Rejected child targets must not journal activity under either stale or focused surface, saw \(journalCommands)"
        )
        XCTAssertFalse(
            state.commands.contains { $0.contains("notify_target_async") },
            "Rejected child targets must not trigger a settled-stop notification, saw \(state.commands)"
        )
        XCTAssertFalse(
            state.commands.contains { $0.contains(#""method":"feed.push""#) },
            "Rejected child targets must not emit Feed activity under a stale ambient workspace, saw \(state.commands)"
        )
        let ledgerData = try Data(contentsOf: ledgerPath)
        let ledger = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: ledgerData) as? [String: Any]
        )
        let records = try XCTUnwrap(ledger["records"] as? [String: Any])
        let settledRecord = try XCTUnwrap(records[settledSessionId] as? [String: Any])
        let activeChildren = (settledRecord["activeChildrenByTurn"] as? [String: [String]]) ?? [:]
        XCTAssertTrue(
            activeChildren[settledTurnId]?.isEmpty != false,
            "An unresolved SubagentStop must still remove the durable child"
        )
        XCTAssertTrue(
            (settledRecord["settledTurnIDs"] as? [String])?.contains(settledTurnId) == true,
            "An unresolved SubagentStop must still settle the pending turn by session identity"
        )
        XCTAssertTrue(
            AgentJournalAppendCapture.captures(in: state.commands).contains {
                $0.unattributedReason == "target-unresolved" && $0.surfaceId == nil
            },
            "Fail-closed child lifecycle must leave an unattributed journal diagnostic, saw \(state.commands)"
        )
    }
}
