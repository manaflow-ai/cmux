import XCTest
import Darwin

extension CLINotifyProcessIntegrationRegressionTests {
    func testLegacyCodexHookAliasReturnsJSONWithoutHelpAndPersistsSession() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("legacy-codex")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-legacy-codex-hook-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"

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
            guard let id = payload["id"] as? String, let method = payload["method"] as? String else {
                return self.malformedRequestResponse(id: payload["id"] as? String, raw: line)
            }
            if method == "surface.list" { return self.surfaceListResponse(id: id, surfaceId: surfaceId) }
            return self.v2Response(id: id, ok: false, error: ["code": "unrecognized_method", "message": "unexpected method: \(method)"])
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_AGENT_LAUNCH_KIND"] = "codex"
        environment["CMUX_AGENT_LAUNCH_EXECUTABLE"] = "/usr/local/bin/codex"
        environment["CMUX_AGENT_LAUNCH_ARGV_B64"] = base64NULSeparated(["/usr/local/bin/codex", "--model", "gpt-5.4"])
        environment["CMUX_AGENT_LAUNCH_CWD"] = "/tmp/repo"
        environment["CODEX_HOME"] = root.appendingPathComponent("codex-home", isDirectory: true).path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["codex-hook", "session-start"],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "{}\n")
        XCTAssertFalse(result.stdout.contains("Usage:"), result.stdout)
        XCTAssertFalse(result.stderr.contains("Usage:"), result.stderr)

        let storeURL = root.appendingPathComponent("codex-hook-sessions.json", isDirectory: false)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: storeURL)) as? [String: Any])
        let sessions = try XCTUnwrap(json["sessions"] as? [String: Any])
        let session = try XCTUnwrap(sessions[surfaceId] as? [String: Any])
        XCTAssertEqual(session["workspaceId"] as? String, workspaceId)
        XCTAssertEqual(session["surfaceId"] as? String, surfaceId)
        XCTAssertNotNil(session["launchCommand"] as? [String: Any])
    }

    func testLegacyFeedHookAliasReturnsJSONWithoutHelpOutsideCmuxTerminal() throws {
        let cliPath = try bundledCLIPath()
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = makeSocketPath("legacy-feed")
        environment.removeValue(forKey: "CMUX_WORKSPACE_ID")
        environment.removeValue(forKey: "CMUX_SURFACE_ID")
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["feed-hook", "--source", "codex"],
            environment: environment,
            standardInput: #"{"hook_event_name":"UserPromptSubmit","session_id":"legacy-feed"}"#,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "{}\n")
        XCTAssertFalse(result.stdout.contains("Usage:"), result.stdout)
        XCTAssertFalse(result.stderr.contains("Usage:"), result.stderr)
    }

    func testLegacyFeedHookRoutesThroughLiveAgentPIDInsteadOfAmbientSurface() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("feed-live-pid")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let ambientWorkspaceId = "11111111-1111-1111-1111-111111111111"
        let ambientSurfaceId = "22222222-2222-2222-2222-222222222222"
        let liveWorkspaceId = "33333333-3333-3333-3333-333333333333"
        let liveSurfaceId = "44444444-4444-4444-4444-444444444444"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(
            listenerFD: listenerFD,
            state: state,
            connectionCount: 2,
            fulfillWhen: { $0.contains(#""method":"feed.push""#) }
        ) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return "OK"
            }
            if method == "agent.resolve_delivery_target" {
                return self.v2Response(id: id, ok: true, result: [
                    "workspace_id": liveWorkspaceId,
                    "surface_id": liveSurfaceId,
                    "source": "pid",
                ])
            }
            return self.v2Response(id: id, ok: true, result: [:])
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = ambientWorkspaceId
        environment["CMUX_SURFACE_ID"] = ambientSurfaceId
        environment["CMUX_CODEX_PID"] = "43210"
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        let result = runProcess(
            executablePath: cliPath,
            arguments: ["feed-hook", "--source", "codex"],
            environment: environment,
            standardInput: #"{"hook_event_name":"PermissionRequest","session_id":"feed-live-pid"}"#,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        let event = try feedPushEvent(in: state)
        XCTAssertEqual(event["workspace_id"] as? String, liveWorkspaceId)
        XCTAssertEqual(event["surface_id"] as? String, liveSurfaceId)
        XCTAssertNotEqual(event["surface_id"] as? String, ambientSurfaceId)
    }

    func testLegacyFeedHookOmitsAmbientSurfaceWhenPIDCannotBeValidated() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("feed-pid-fail")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let ambientWorkspaceId = "55555555-5555-5555-5555-555555555555"
        let ambientSurfaceId = "66666666-6666-6666-6666-666666666666"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(
            listenerFD: listenerFD,
            state: state,
            connectionCount: 2,
            fulfillWhen: { $0.contains(#""method":"feed.push""#) }
        ) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return "OK"
            }
            if method == "agent.resolve_delivery_target" {
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "not_found", "message": "no live target"]
                )
            }
            return self.v2Response(id: id, ok: true, result: [:])
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = ambientWorkspaceId
        environment["CMUX_SURFACE_ID"] = ambientSurfaceId
        environment["CMUX_CODEX_PID"] = "43211"
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        let result = runProcess(
            executablePath: cliPath,
            arguments: ["feed-hook", "--source", "codex"],
            environment: environment,
            standardInput: #"{"hook_event_name":"PermissionRequest","session_id":"feed-pid-fail"}"#,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        let event = try feedPushEvent(in: state)
        XCTAssertNil(event["workspace_id"])
        XCTAssertNil(event["surface_id"])
    }

    func testLegacyFeedTelemetryDoesNotProbeLiveAgentTarget() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("feed-telemetry")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(
            listenerFD: listenerFD,
            state: state,
            connectionCount: 2,
            fulfillWhen: { $0.contains(#""method":"feed.push""#) }
        ) { line in
            guard let payload = self.jsonObject(line),
                  let method = payload["method"] as? String else {
                return "OK"
            }
            if method == "agent.resolve_delivery_target",
               let id = payload["id"] as? String {
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "not_found", "message": "no live target"]
                )
            }
            return "OK"
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = "11111111-1111-1111-1111-111111111111"
        environment["CMUX_SURFACE_ID"] = "22222222-2222-2222-2222-222222222222"
        environment["CMUX_CODEX_PID"] = "43212"
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        let result = runProcess(
            executablePath: cliPath,
            arguments: ["feed-hook", "--source", "codex"],
            environment: environment,
            standardInput: #"{"hook_event_name":"PostToolUse","session_id":"feed-telemetry"}"#,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertFalse(
            state.snapshot().contains { $0.contains(#""method":"agent.resolve_delivery_target""#) },
            "Non-mutating Feed telemetry must not enqueue live process inspection"
        )
        let event = try feedPushEvent(in: state)
        XCTAssertNil(event["workspace_id"])
        XCTAssertNil(event["surface_id"])
    }

    func testFeedTargetUsesValidatedSurfaceForRemotePIDNamespace() throws {
        let socketPath = makeSocketPath("feed-remote")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let oldWorkspaceId = "33333333-3333-3333-3333-333333333333"
        let liveWorkspaceId = "44444444-4444-4444-4444-444444444444"
        let surfaceId = "55555555-5555-5555-5555-555555555555"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(
            listenerFD: listenerFD,
            state: state,
            fulfillWhen: { $0.contains(#""method":"agent.resolve_delivery_target""#) }
        ) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String else {
                return "OK"
            }
            return self.v2Response(id: id, ok: true, result: [
                "workspace_id": liveWorkspaceId,
                "surface_id": surfaceId,
                "source": "surface",
            ])
        }

        let client = SocketClient(path: socketPath)
        defer { client.close() }
        try client.connect()
        let target = CMUXCLI(args: []).resolvedFeedDeliveryTarget(
            pid: 43213,
            claimedWorkspaceId: oldWorkspaceId,
            claimedSurfaceId: surfaceId,
            pidNamespaceIsRemote: true,
            client: client,
            responseTimeout: 2
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertEqual(target?.workspaceId, liveWorkspaceId)
        XCTAssertEqual(target?.surfaceId, surfaceId)
        let request = try XCTUnwrap(
            state.snapshot().compactMap(jsonObject).first {
                $0["method"] as? String == "agent.resolve_delivery_target"
            }
        )
        let params = try XCTUnwrap(request["params"] as? [String: Any])
        XCTAssertEqual(params["workspace_id"] as? String, oldWorkspaceId)
        XCTAssertEqual(params["surface_id"] as? String, surfaceId)
        XCTAssertNil(params["pid"])
    }

    private func feedPushEvent(in state: MockSocketServerState) throws -> [String: Any] {
        let line = try XCTUnwrap(state.snapshot().first { $0.contains(#""method":"feed.push""#) })
        let request = try XCTUnwrap(jsonObject(line))
        let params = try XCTUnwrap(request["params"] as? [String: Any])
        return try XCTUnwrap(params["event"] as? [String: Any])
    }
}
