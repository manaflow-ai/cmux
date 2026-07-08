import Darwin
import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// Stays on XCTest deliberately: this extends the existing XCTest socket harness
// (`CLINotifyProcessIntegrationRegressionTests`: bundled-CLI process runner, mock
// unix-socket server, XCTestExpectation-based server waits). Porting only these
// assertions to Swift Testing would fork that harness across frameworks.
extension CLINotifyProcessIntegrationRegressionTests {
    func testClaudeSecondLevelForkSessionStartKeepsForkParentBoundUntilPromptMintsChild() throws {
        let context = try makeForkOfForkContext(name: "claude-fork-of-fork")
        defer { context.cleanup() }

        let forkParentSessionId = "fork-parent-session"
        let forkParentSurfaceId = "99999999-9999-9999-9999-999999999999"
        let childSessionId = "child-fork-session"
        try seedForkOfForkHookStore(
            context: context,
            sessionId: forkParentSessionId,
            surfaceId: forkParentSurfaceId,
            activeTurnId: "fork-parent-turn"
        )

        // One detached server pool covers both CLI invocations. Starting a second
        // expectation-backed server on the same listener would race its accept
        // workers against the first call's leftover workers and time out.
        startForkOfForkSurfaceServer(
            context: context,
            surfaceIds: [forkParentSurfaceId, context.surfaceId],
            connectionCount: 16
        )

        let start = runForkOfForkHook(
            context: context,
            arguments: ["hooks", "claude", "session-start"],
            standardInput: #"{"session_id":"\#(forkParentSessionId)","source":"resume","cwd":"\#(context.root.path)","hook_event_name":"SessionStart"}"#,
            extraEnvironment: forkOfForkLaunchEnvironment(context: context, parentSessionId: forkParentSessionId)
        )
        XCTAssertFalse(start.timedOut, start.stderr)
        XCTAssertEqual(start.status, 0, start.stderr)

        var forkParentRecord = try readForkOfForkHookSession(forkParentSessionId, context: context)
        XCTAssertEqual(
            forkParentRecord["surfaceId"] as? String,
            forkParentSurfaceId,
            "Second-level fork SessionStart reports session B and must not move B from pane 2 to the new fork pane"
        )

        let prompt = runForkOfForkHook(
            context: context,
            arguments: ["hooks", "claude", "prompt-submit"],
            standardInput: #"{"session_id":"\#(childSessionId)","turn_id":"child-fork-turn","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit","prompt":"diverge again"}"#,
            extraEnvironment: forkOfForkLaunchEnvironment(context: context, parentSessionId: forkParentSessionId)
        )
        XCTAssertFalse(prompt.timedOut, prompt.stderr)
        XCTAssertEqual(prompt.status, 0, prompt.stderr)

        forkParentRecord = try readForkOfForkHookSession(forkParentSessionId, context: context)
        XCTAssertEqual(forkParentRecord["surfaceId"] as? String, forkParentSurfaceId)
        let childRecord = try readForkOfForkHookSession(childSessionId, context: context)
        XCTAssertEqual(childRecord["surfaceId"] as? String, context.surfaceId)
        XCTAssertEqual(childRecord["isRestorable"] as? Bool, true)

        let savedState = try readForkOfForkHookStore(context: context)
        let activeBySurface = try XCTUnwrap(savedState["activeSessionsBySurface"] as? [String: Any])
        let forkPaneActive = try XCTUnwrap(activeBySurface[context.surfaceId] as? [String: Any])
        XCTAssertEqual(forkPaneActive["sessionId"] as? String, childSessionId)
        XCTAssertEqual(forkPaneActive["turnId"] as? String, "child-fork-turn")
    }

    private struct ForkOfForkContext {
        let cliPath: String
        let socketPath: String
        let listenerFD: Int32
        let state: MockSocketServerState
        let root: URL
        let workspaceId: String
        let surfaceId: String

        func cleanup() {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func makeForkOfForkContext(name: String) throws -> ForkOfForkContext {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-\(name)-\(UUID().uuidString)", isDirectory: true)
        let socketPath = makeSocketPath(String(name.prefix(6)))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return ForkOfForkContext(
            cliPath: try bundledCLIPath(),
            socketPath: socketPath,
            listenerFD: try bindUnixSocket(at: socketPath),
            state: MockSocketServerState(),
            root: root,
            workspaceId: "11111111-1111-1111-1111-111111111111",
            surfaceId: "22222222-2222-2222-2222-222222222222"
        )
    }

    private func seedForkOfForkHookStore(
        context: ForkOfForkContext,
        sessionId: String,
        surfaceId: String,
        activeTurnId: String
    ) throws {
        let now = Date().timeIntervalSince1970
        let active: [String: Any] = ["sessionId": sessionId, "turnId": activeTurnId, "updatedAt": now]
        let store: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": context.workspaceId,
                    "surfaceId": surfaceId,
                    "cwd": context.root.path,
                    "agentLifecycle": "running",
                    "startedAt": now,
                    "updatedAt": now,
                ],
            ],
            "activeSessionsByWorkspace": [context.workspaceId: active],
            "activeSessionsBySurface": [surfaceId: active],
        ]
        let data = try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted])
        try data.write(to: context.root.appendingPathComponent("claude-hook-sessions.json"), options: .atomic)
    }

    private func startForkOfForkSurfaceServer(
        context: ForkOfForkContext,
        surfaceIds: [String],
        connectionCount: Int
    ) {
        startDetachedMockServer(listenerFD: context.listenerFD, state: context.state, connectionCount: connectionCount) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            switch method {
            case "surface.list":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "surfaces": surfaceIds.enumerated().map { index, surfaceId in
                            ["id": surfaceId, "ref": "surface:\(index + 1)", "focused": index == 0] as [String: Any]
                        },
                    ]
                )
            case "feed.push":
                return self.v2Response(id: id, ok: true, result: [:])
            case "surface.resume.set":
                return self.v2Response(id: id, ok: true, result: ["resume_binding": [:]])
            case "surface.resume.clear":
                return self.v2Response(id: id, ok: true, result: ["cleared": true])
            default:
                return self.v2Response(id: id, ok: false, error: ["code": "unrecognized_method", "message": method])
            }
        }
    }

    private func runForkOfForkHook(
        context: ForkOfForkContext,
        arguments: [String],
        standardInput: String,
        extraEnvironment: [String: String]
    ) -> ProcessRunResult {
        var environment = [
            "HOME": context.root.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "CMUX_SOCKET_PATH": context.socketPath,
            "CMUX_WORKSPACE_ID": context.workspaceId,
            "CMUX_SURFACE_ID": context.surfaceId,
            "CMUX_CLAUDE_HOOK_STATE_PATH": context.root.appendingPathComponent("claude-hook-sessions.json").path,
            "CMUX_CLI_SENTRY_DISABLED": "1",
            "CMUX_CLAUDE_HOOK_SENTRY_DISABLED": "1",
        ]
        for (key, value) in extraEnvironment {
            environment[key] = value
        }

        return runProcess(
            executablePath: context.cliPath,
            arguments: arguments,
            environment: environment,
            standardInput: standardInput,
            timeout: 5
        )
    }

    private func forkOfForkLaunchEnvironment(
        context: ForkOfForkContext,
        parentSessionId: String
    ) -> [String: String] {
        [
            "CMUX_AGENT_LAUNCH_KIND": "claude",
            "CMUX_AGENT_LAUNCH_EXECUTABLE": "/usr/local/bin/claude",
            "CMUX_AGENT_LAUNCH_CWD": context.root.path,
            "CMUX_AGENT_LAUNCH_ARGV_B64": base64NULSeparated([
                "/usr/local/bin/claude",
                "--resume",
                parentSessionId,
                "--fork-session",
            ]),
        ]
    }

    private func readForkOfForkHookSession(_ sessionId: String, context: ForkOfForkContext) throws -> [String: Any] {
        let state = try readForkOfForkHookStore(context: context)
        let sessions = try XCTUnwrap(state["sessions"] as? [String: Any])
        return try XCTUnwrap(sessions[sessionId] as? [String: Any])
    }

    private func readForkOfForkHookStore(context: ForkOfForkContext) throws -> [String: Any] {
        let stateURL = context.root.appendingPathComponent("claude-hook-sessions.json")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
    }
}
