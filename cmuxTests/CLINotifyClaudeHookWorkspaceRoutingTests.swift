// Regression tests for Claude hook workspace routing: notifications, status, and summary
// route to the originating workspace, never the focused tab.
// https://github.com/manaflow-ai/cmux/pull/7228

import XCTest
import Darwin

extension CLINotifyProcessIntegrationRegressionTests {
    /// A resumed/stale session whose recorded workspace no longer exists must fall
    /// back to the LIVE `CMUX_WORKSPACE_ID`, never to the currently-focused tab.
    /// Regression for cross-workspace notification/status/summary bleed: the hook
    /// used to skip the env fallback and route to `workspace.current`.
    func testClaudeNotificationFallsBackToLiveWorkspaceInsteadOfFocusedTab() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("claude-misroute-fallback")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-claude-misroute-fallback-\(UUID().uuidString)", isDirectory: true)
        let staleWorkspaceId = "11111111-1111-1111-1111-111111111111"
        let liveWorkspaceId = "22222222-2222-2222-2222-222222222222"
        let liveSurfaceId = "33333333-3333-3333-3333-333333333333"
        let focusedWorkspaceId = "99999999-9999-9999-9999-999999999999"
        let sessionId = "resumed-session"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let now = Date().timeIntervalSince1970
        let store: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": staleWorkspaceId,
                    "surfaceId": "44444444-4444-4444-4444-444444444444",
                    "cwd": root.path,
                    "startedAt": now,
                    "updatedAt": now,
                ],
            ],
        ]
        let stateURL = root.appendingPathComponent("claude-hook-sessions.json")
        try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted]).write(to: stateURL, options: .atomic)

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line) else { return "OK" }
            guard let id = payload["id"] as? String, let method = payload["method"] as? String else {
                return self.malformedRequestResponse(id: payload["id"] as? String, raw: line)
            }
            switch method {
            case "surface.list":
                let ws = (payload["params"] as? [String: Any])?["workspace_id"] as? String
                if ws == liveWorkspaceId { return self.surfaceListResponse(id: id, surfaceId: liveSurfaceId) }
                if ws == focusedWorkspaceId { return self.surfaceListResponse(id: id, surfaceId: "88888888-8888-8888-8888-888888888888") }
                // The stale (recorded) workspace fails resolution here.
                return self.v2Response(id: id, ok: false, error: ["code": "not_found", "message": "workspace not found"])
            case "debug.terminals":
                return self.v2Response(id: id, ok: true, result: ["terminals": []])
            case "workspace.current":
                return self.v2Response(id: id, ok: true, result: ["workspace_id": focusedWorkspaceId])
            case "feed.push":
                return self.v2Response(id: id, ok: true, result: [:])
            default:
                return self.v2Response(id: id, ok: false, error: ["code": "unrecognized_method", "message": "unexpected method: \(method)"])
            }
        }

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "claude", "notification"],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_WORKSPACE_ID": liveWorkspaceId,
                "CMUX_SURFACE_ID": liveSurfaceId,
                "CMUX_CLAUDE_HOOK_STATE_PATH": stateURL.path,
                "CMUX_CLI_SENTRY_DISABLED": "1",
                "CMUX_CLAUDE_HOOK_SENTRY_DISABLED": "1",
            ],
            standardInput: #"{"session_id":"\#(sessionId)","hook_event_name":"Notification","message":"Claude needs your input"}"#,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(
            state.commands.contains {
                $0.hasPrefix("set_status claude_code Needs input ") && $0.contains("--tab=\(liveWorkspaceId)")
            },
            "Expected notification to route to the live CMUX_WORKSPACE_ID, saw \(state.commands)"
        )
        // Scope these to the actual routing commands (set_status / notify_target):
        // state.commands also captures the resolver's own surface.list validation
        // calls, whose JSON carries the candidate workspace id and would otherwise
        // false-match a broad `contains`.
        func routesTo(_ workspaceId: String) -> Bool {
            state.commands.contains {
                ($0.hasPrefix("set_status ") || $0.hasPrefix("notify_target")) && $0.contains(workspaceId)
            }
        }
        XCTAssertFalse(
            routesTo(focusedWorkspaceId),
            "Notification must not fall back to the focused workspace, saw \(state.commands)"
        )
        XCTAssertFalse(
            routesTo(staleWorkspaceId),
            "Notification must not route to the stale recorded workspace, saw \(state.commands)"
        )
    }

    /// When the caller cannot be positively identified (recorded + live workspace
    /// both gone) and the TTY matches more than one workspace, the hook must no-op
    /// rather than guess a workspace by first-match.
    func testClaudeNotificationDoesNotGuessOnAmbiguousTTY() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("claude-ambiguous-tty")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-claude-ambiguous-tty-\(UUID().uuidString)", isDirectory: true)
        let staleWorkspaceId = "11111111-1111-1111-1111-111111111111"
        let ttyWorkspaceA = "22222222-2222-2222-2222-222222222222"
        let ttyWorkspaceB = "33333333-3333-3333-3333-333333333333"
        let focusedWorkspaceId = "99999999-9999-9999-9999-999999999999"
        let ttyName = "ttys-shared-collision"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        // connectionCount 2: the deferred feed telemetry (the pre-fix regression this
        // test guards against) arrives on a second socket connection, which must be
        // accepted and drained for the feed.push absence assertion to be falsifiable.
        let serverHandled = startMockServer(listenerFD: listenerFD, state: state, connectionCount: 2) { line in
            guard let payload = self.jsonObject(line) else { return "OK" }
            guard let id = payload["id"] as? String, let method = payload["method"] as? String else {
                return self.malformedRequestResponse(id: payload["id"] as? String, raw: line)
            }
            switch method {
            case "surface.list":
                let ws = (payload["params"] as? [String: Any])?["workspace_id"] as? String
                if ws == ttyWorkspaceA { return self.surfaceListResponse(id: id, surfaceId: "55555555-5555-5555-5555-555555555555") }
                if ws == ttyWorkspaceB { return self.surfaceListResponse(id: id, surfaceId: "66666666-6666-6666-6666-666666666666") }
                if ws == focusedWorkspaceId { return self.surfaceListResponse(id: id, surfaceId: "44444444-4444-4444-4444-444444444444") }
                return self.v2Response(id: id, ok: false, error: ["code": "not_found", "message": "workspace not found"])
            case "debug.terminals":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: ["terminals": [
                        ["tty": ttyName, "workspace_id": ttyWorkspaceA, "surface_id": "55555555-5555-5555-5555-555555555555"],
                        ["tty": ttyName, "workspace_id": ttyWorkspaceB, "surface_id": "66666666-6666-6666-6666-666666666666"],
                    ]]
                )
            case "workspace.current":
                return self.v2Response(id: id, ok: true, result: ["workspace_id": focusedWorkspaceId])
            case "feed.push":
                return self.v2Response(id: id, ok: true, result: [:])
            default:
                return self.v2Response(id: id, ok: false, error: ["code": "unrecognized_method", "message": "unexpected method: \(method)"])
            }
        }

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "claude", "notification"],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_WORKSPACE_ID": staleWorkspaceId,
                "CMUX_SURFACE_ID": "77777777-7777-7777-7777-777777777777",
                "CMUX_CLI_TTY_NAME": ttyName,
                "CMUX_CLAUDE_HOOK_STATE_PATH": root.appendingPathComponent("claude-hook-sessions.json").path,
                "CMUX_CLI_SENTRY_DISABLED": "1",
                "CMUX_CLAUDE_HOOK_SENTRY_DISABLED": "1",
            ],
            standardInput: #"{"session_id":"orphan-ambiguous","hook_event_name":"Notification","message":"Claude needs your input"}"#,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        // Scope to routing commands so the resolver's own surface.list validation
        // calls (whose JSON carries a candidate workspace id) can't false-match.
        for candidate in [ttyWorkspaceA, ttyWorkspaceB, focusedWorkspaceId] {
            XCTAssertFalse(
                state.commands.contains {
                    ($0.hasPrefix("set_status ") || $0.hasPrefix("notify_target")) && $0.contains(candidate)
                },
                "Ambiguous-TTY notification must not guess workspace \(candidate), saw \(state.commands)"
            )
        }
        // The telemetry connection is drained on its own accept thread; give a
        // regression a bounded window to land in state.commands so the pre-fix
        // failure is deterministic (the CLI process has already exited here, so any
        // feed.push frame is in flight at most a scheduling delay away).
        let feedDeadline = Date().addingTimeInterval(1.0)
        while Date() < feedDeadline, !state.commands.contains(where: { $0.contains("feed.push") }) {
            usleep(50_000)
        }
        XCTAssertFalse(
            state.commands.contains { $0.contains("feed.push") },
            "Unresolved notification must not push a feed event, saw \(state.commands)"
        )
    }

    /// An explicit workspace handle ref must resolve strictly to that workspace,
    /// never no-op as an invalid non-UUID or fall back to the focused workspace.
    func testClaudeNotificationHonorsExplicitWorkspaceHandleRef() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("claude-explicit-workspace-ref")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-claude-explicit-workspace-ref-\(UUID().uuidString)", isDirectory: true)
        let windowId = "11111111-1111-1111-1111-111111111111"
        let targetWorkspaceId = "22222222-2222-2222-2222-222222222222"
        let targetSurfaceId = "33333333-3333-3333-3333-333333333333"
        let focusedWorkspaceId = "99999999-9999-9999-9999-999999999999"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line) else { return "OK" }
            guard let id = payload["id"] as? String, let method = payload["method"] as? String else {
                return self.malformedRequestResponse(id: payload["id"] as? String, raw: line)
            }
            switch method {
            case "window.list":
                return self.v2Response(id: id, ok: true, result: ["windows": [["id": windowId]]])
            case "workspace.list":
                let requestedWindowId = (payload["params"] as? [String: Any])?["window_id"] as? String
                if requestedWindowId == windowId {
                    return self.v2Response(
                        id: id,
                        ok: true,
                        result: ["workspaces": [["id": targetWorkspaceId, "ref": "workspace:1"]]]
                    )
                }
                return self.v2Response(id: id, ok: false, error: ["code": "not_found", "message": "window not found"])
            case "surface.list":
                let ws = (payload["params"] as? [String: Any])?["workspace_id"] as? String
                if ws == targetWorkspaceId {
                    return self.surfaceListResponse(id: id, surfaceId: targetSurfaceId)
                }
                return self.v2Response(id: id, ok: false, error: ["code": "not_found", "message": "workspace not found"])
            case "debug.terminals":
                return self.v2Response(id: id, ok: true, result: ["terminals": []])
            case "workspace.current":
                return self.v2Response(id: id, ok: true, result: ["workspace_id": focusedWorkspaceId])
            case "feed.push":
                return self.v2Response(id: id, ok: true, result: [:])
            default:
                return self.v2Response(id: id, ok: false, error: ["code": "unrecognized_method", "message": "unexpected method: \(method)"])
            }
        }

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "claude", "notification", "--workspace", "workspace:1"],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_CLAUDE_HOOK_STATE_PATH": root.appendingPathComponent("claude-hook-sessions.json").path,
                "CMUX_CLI_SENTRY_DISABLED": "1",
                "CMUX_CLAUDE_HOOK_SENTRY_DISABLED": "1",
            ],
            standardInput: #"{"session_id":"explicit-ref","hook_event_name":"Notification","message":"Claude needs your input"}"#,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(
            state.commands.contains {
                $0.hasPrefix("set_status claude_code Needs input ") && $0.contains("--tab=\(targetWorkspaceId)")
            },
            "Expected notification to route to explicit workspace ref, saw \(state.commands)"
        )
        XCTAssertFalse(
            state.commands.contains {
                ($0.hasPrefix("set_status ") || $0.hasPrefix("notify_target")) && $0.contains(focusedWorkspaceId)
            },
            "Explicit workspace ref must not fall back to the focused workspace, saw \(state.commands)"
        )
    }

    /// A polluted `activeSessionsByWorkspace` entry (a session registered as active
    /// for a workspace that is not its own) must be self-healed on the next hook.
    func testClaudeHookSelfHealsCrossWorkspaceActivePointer() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("claude-selfheal")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-claude-selfheal-\(UUID().uuidString)", isDirectory: true)
        let ownWorkspaceId = "11111111-1111-1111-1111-111111111111"
        let ownSurfaceId = "22222222-2222-2222-2222-222222222222"
        let pollutedWorkspaceId = "33333333-3333-3333-3333-333333333333"
        let sessionId = "own-session"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let now = Date().timeIntervalSince1970
        let store: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": ownWorkspaceId,
                    "surfaceId": ownSurfaceId,
                    "cwd": root.path,
                    "startedAt": now,
                    "updatedAt": now,
                ],
            ],
            "activeSessionsByWorkspace": [
                ownWorkspaceId: ["sessionId": sessionId, "updatedAt": now],
                // Pollution: our session is registered as active for a workspace it
                // does not belong to (from the pre-fix focused/TTY misroute).
                pollutedWorkspaceId: ["sessionId": sessionId, "updatedAt": now],
            ],
        ]
        let stateURL = root.appendingPathComponent("claude-hook-sessions.json")
        try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted]).write(to: stateURL, options: .atomic)

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line) else { return "OK" }
            guard let id = payload["id"] as? String, let method = payload["method"] as? String else {
                return self.malformedRequestResponse(id: payload["id"] as? String, raw: line)
            }
            switch method {
            case "surface.list":
                return self.surfaceListResponse(id: id, surfaceId: ownSurfaceId)
            case "debug.terminals":
                return self.v2Response(id: id, ok: true, result: ["terminals": []])
            case "workspace.current":
                return self.v2Response(id: id, ok: true, result: ["workspace_id": ownWorkspaceId])
            case "feed.push":
                return self.v2Response(id: id, ok: true, result: [:])
            default:
                return self.v2Response(id: id, ok: false, error: ["code": "unrecognized_method", "message": "unexpected method: \(method)"])
            }
        }

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "claude", "notification"],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_WORKSPACE_ID": ownWorkspaceId,
                "CMUX_SURFACE_ID": ownSurfaceId,
                "CMUX_CLAUDE_HOOK_STATE_PATH": stateURL.path,
                "CMUX_CLI_SENTRY_DISABLED": "1",
                "CMUX_CLAUDE_HOOK_SENTRY_DISABLED": "1",
            ],
            standardInput: #"{"session_id":"\#(sessionId)","hook_event_name":"Notification","message":"Claude needs your input"}"#,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        let savedState = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
        let activeSessions = try XCTUnwrap(savedState["activeSessionsByWorkspace"] as? [String: Any])
        XCTAssertNotNil(activeSessions[ownWorkspaceId], "Expected the session's own active pointer to remain")
        XCTAssertNil(
            activeSessions[pollutedWorkspaceId],
            "Expected the cross-workspace active pointer to be self-healed, saw \(activeSessions.keys)"
        )
    }
}
