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
        let ledgerPath = root.appendingPathComponent("codex-turn-ledger.json")

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let ledgerRecord: [String: Any] = [
            "workspaceID": workspaceId,
            "surfaceID": staleSurfaceId,
            "owner": [:],
            "activeTurnID": "turn-before",
            "activeChildrenByTurn": [:],
            "unknownChildrenByTurn": [:],
            "terminalChildrenByTurn": [:],
            "pendingTurns": [:],
            "settledTurnIDs": [],
            "notifiedTurnIDs": [],
            "updatedAt": 4_000_000_000,
        ]
        try JSONSerialization.data(
            withJSONObject: ["records": ["codex-stale-no-live": ledgerRecord], "surfaceOwners": [:]],
            options: [.prettyPrinted]
        ).write(to: ledgerPath, options: .atomic)

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
        environment["CMUX_CODEX_TURN_LEDGER_PATH"] = ledgerPath.path
        environment.removeValue(forKey: "CMUX_CODEX_PID")

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "prompt-submit"],
            environment: environment,
            standardInput: #"{"session_id":"codex-stale-no-live","turn_id":"turn-after","cwd":"\#(root.path)","hook_event_name":"UserPromptSubmit","prompt":"continue"}"#,
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
        let ledger = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: ledgerPath)) as? [String: Any]
        )
        let record = try XCTUnwrap(
            (ledger["records"] as? [String: Any])?["codex-stale-no-live"] as? [String: Any]
        )
        XCTAssertEqual(
            record["activeTurnID"] as? String,
            "turn-after",
            "An unresolved prompt must still advance an existing Codex turn record"
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
        let parentStopSessionId = "codex-stale-parent-stop"
        let parentStopTurnId = "turn-parent-stop"
        let staleStopSessionId = "codex-stale-old-turn-stop"
        let staleCurrentTurnId = "turn-new"
        let staleIncomingTurnId = "turn-old"
        let ledgerPath = root.appendingPathComponent("codex-turn-ledger.json")

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        // These values are fixture metadata only; keep them independent of the
        // host clock because this test does not exercise freshness boundaries.
        let now: TimeInterval = 4_000_000_000
        let storedSessions = Dictionary(uniqueKeysWithValues: (sessionIds + [parentStopSessionId, staleStopSessionId]).map { sessionId in
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
        let parentStopLedgerRecord: [String: Any] = [
            "workspaceID": workspaceId,
            "surfaceID": staleSurfaceId,
            "owner": [:],
            "activeTurnID": parentStopTurnId,
            "activeChildrenByTurn": [:],
            "unknownChildrenByTurn": [:],
            "terminalChildrenByTurn": [:],
            "pendingTurns": [parentStopTurnId: ["turnID": parentStopTurnId]],
            "settledTurnIDs": [],
            "notifiedTurnIDs": [],
            "updatedAt": now,
        ]
        let staleStopLedgerRecord: [String: Any] = [
            "workspaceID": workspaceId,
            "surfaceID": staleSurfaceId,
            "owner": [:],
            "activeTurnID": staleCurrentTurnId,
            "activeChildrenByTurn": [:],
            "unknownChildrenByTurn": [:],
            "terminalChildrenByTurn": [:],
            "pendingTurns": [staleCurrentTurnId: ["turnID": staleCurrentTurnId]],
            "settledTurnIDs": [],
            "notifiedTurnIDs": [],
            "updatedAt": now,
        ]
        let ledgerObject: [String: Any] = [
            "records": [
                settledSessionId: ledgerRecord,
                parentStopSessionId: parentStopLedgerRecord,
                staleStopSessionId: staleStopLedgerRecord,
            ],
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
        // Keep this deterministic fixture in-process; retry scheduling is
        // covered by the production retry-limit path separately.
        environment["CMUX_CODEX_SETTLED_STOP_RETRY_COUNT"] = "3"
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

        let parentStopResult = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "stop"],
            environment: environment,
            standardInput: #"{"session_id":"\#(parentStopSessionId)","cwd":"\#(root.path)","hook_event_name":"Stop","turn_id":"\#(parentStopTurnId)","last_assistant_message":"done"}"#,
            timeout: 5
        )
        XCTAssertFalse(parentStopResult.timedOut, parentStopResult.stderr)
        XCTAssertEqual(parentStopResult.status, 0, parentStopResult.stderr)
        XCTAssertEqual(parentStopResult.stdout, "{}\n")

        let staleStopResult = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "stop"],
            environment: environment,
            standardInput: #"{"session_id":"\#(staleStopSessionId)","cwd":"\#(root.path)","hook_event_name":"Stop","turn_id":"\#(staleIncomingTurnId)","last_assistant_message":"late"}"#,
            timeout: 5
        )
        XCTAssertFalse(staleStopResult.timedOut, staleStopResult.stderr)
        XCTAssertEqual(staleStopResult.status, 0, staleStopResult.stderr)
        XCTAssertEqual(staleStopResult.stdout, "{}\n")

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
        XCTAssertNil(
            records[sessionIds[0]],
            "An unresolved child start without an existing ledger session must stay diagnostic-only"
        )
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
        let parentStopRecord = try XCTUnwrap(records[parentStopSessionId] as? [String: Any])
        XCTAssertTrue(
            (parentStopRecord["settledTurnIDs"] as? [String])?.contains(parentStopTurnId) == true,
            "An unresolved parent Stop must still settle the ledger by session identity"
        )
        XCTAssertFalse(
            (parentStopRecord["notifiedTurnIDs"] as? [String])?.contains(parentStopTurnId) == true,
            "An unresolved parent Stop must leave notification claiming retryable until a pane is proven"
        )
        let staleStopRecord = try XCTUnwrap(records[staleStopSessionId] as? [String: Any])
        XCTAssertFalse(
            (staleStopRecord["settledTurnIDs"] as? [String])?.contains(staleIncomingTurnId) == true,
            "An unresolved Stop for an older non-pending turn must not settle over the current turn"
        )
        XCTAssertTrue(
            (staleStopRecord["pendingTurns"] as? [String: Any])?[staleCurrentTurnId] != nil,
            "An unresolved stale Stop must preserve the newer pending turn"
        )
        XCTAssertTrue(
            AgentJournalAppendCapture.captures(in: state.commands).contains {
                $0.unattributedReason == "target-unresolved" && $0.surfaceId == nil
            },
            "Fail-closed child lifecycle must leave an unattributed journal diagnostic, saw \(state.commands)"
        )
    }
}
