import Darwin
import Dispatch
import XCTest

extension CLINotifyProcessIntegrationRegressionTests {
    func testRelayHookUsesOnlyRelayTTYIdentity() throws {
        let cliPath = try bundledCLIPath()
        let relay = try bindLoopbackTCP()
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-relay-hook-identity-\(UUID().uuidString)", isDirectory: true
        )
        let relayID = "relay-hook-identity"
        let relayToken = String(repeating: "ab", count: 32)
        let ttyName = "ttys-relay-hook"
        let workspaceID = "11111111-1111-1111-1111-111111111111"
        let surfaceID = "22222222-2222-2222-2222-222222222222"
        let staleWorkspaceID = "33333333-3333-3333-3333-333333333333"
        let staleSurfaceID = "44444444-4444-4444-4444-444444444444"
        let remoteAgentPID = 42_424
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(relay.fd)
            try? FileManager.default.removeItem(at: root)
        }

        let resolverHandled = startHookIdentityRelayServer(
            listenerFD: relay.fd,
            state: state,
            relayID: relayID
        ) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else { return "OK" }
            switch method {
            case "system.resolve_terminal":
                return self.v2Response(id: id, ok: true, result: [
                    "tty_bindings": [["workspace_id": workspaceID, "surface_id": surfaceID]],
                    "pid_binding": ["workspace_id": staleWorkspaceID, "surface_id": staleSurfaceID],
                ])
            case "surface.list":
                let workspace = (payload["params"] as? [String: Any])?["workspace_id"] as? String
                return self.surfaceListResponse(id: id, surfaceId: workspace == staleWorkspaceID ? staleSurfaceID : surfaceID)
            case "system.top":
                return self.v2Response(id: id, ok: true, result: ["windows": [["workspaces": [[
                    "id": staleWorkspaceID,
                    "panes": [["surfaces": [[
                        "id": staleSurfaceID,
                        "top_level_pids": [remoteAgentPID],
                        "processes": [],
                    ]]]],
                ]]]]])
            case "surface.resume.set", "surface.resume.clear", "feed.push":
                return self.v2Response(id: id, ok: true, result: [:])
            default:
                return self.v2Response(id: id, ok: true, result: [:])
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = root.path
        environment["PWD"] = root.path
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["CMUX_SOCKET_PATH"] = "127.0.0.1:\(relay.port)"
        environment["CMUX_RELAY_ID"] = relayID
        environment["CMUX_RELAY_TOKEN"] = relayToken
        environment["CMUX_CLI_TTY_NAME"] = ttyName
        environment["CMUX_CODEX_PID"] = String(remoteAgentPID)
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_SUPPRESS_SUBAGENT_NOTIFICATIONS"] = "0"
        environment.removeValue(forKey: "CMUX_AGENT_MANAGED_SUBAGENT")
        environment.removeValue(forKey: "CMUX_WORKSPACE_ID")
        environment.removeValue(forKey: "CMUX_SURFACE_ID")

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "prompt-submit"],
            environment: environment,
            standardInput: #"{"session_id":"relay-session","cwd":"\#(root.path)","hook_event_name":"UserPromptSubmit","prompt":"continue"}"#,
            timeout: 10
        )

        wait(for: [resolverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        let requests = state.snapshot().compactMap { self.jsonObject($0) }
        let resolverParams = try XCTUnwrap(requests.first(where: {
            $0["method"] as? String == "system.resolve_terminal"
        })?["params"] as? [String: Any])
        XCTAssertEqual(resolverParams["tty_name"] as? String, ttyName)
        XCTAssertNil(resolverParams["pid"], "the remote agent PID is meaningless in the relay host namespace")
        XCTAssertFalse(requests.contains { $0["method"] as? String == "system.top" })
        XCTAssertTrue(
            state.snapshot().contains {
                $0.hasPrefix("set_status ") && $0.contains("--tab=\(workspaceID)") && $0.contains("--panel=\(surfaceID)")
            },
            "The relay TTY binding must win over a conflicting pid_binding: \(state.snapshot())"
        )
    }

    func testClaudeRelayHookWithoutTTYBindingFailsClosed() throws {
        let cliPath = try bundledCLIPath()
        let relay = try bindLoopbackTCP()
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-claude-relay-missing-identity-\(UUID().uuidString)", isDirectory: true
        )
        let relayID = "claude-relay-missing-identity"
        let relayToken = String(repeating: "cd", count: 32)
        let ttyName = "ttys-claude-relay-missing"
        let staleWorkspaceID = "33333333-3333-3333-3333-333333333333"
        let staleSurfaceID = "44444444-4444-4444-4444-444444444444"
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(relay.fd)
            try? FileManager.default.removeItem(at: root)
        }

        let resolverHandled = startHookIdentityRelayServer(
            listenerFD: relay.fd,
            state: state,
            relayID: relayID
        ) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else { return "OK" }
            switch method {
            case "system.resolve_terminal":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: ["tty_bindings": [], "pid_binding": NSNull()]
                )
            case "surface.list":
                return self.surfaceListResponse(id: id, surfaceId: staleSurfaceID)
            case "surface.resume.set", "surface.resume.clear", "feed.push":
                return self.v2Response(id: id, ok: true, result: [:])
            default:
                return self.v2Response(id: id, ok: true, result: [:])
            }
        }

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "claude", "notification"],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_SOCKET_PATH": "127.0.0.1:\(relay.port)",
                "CMUX_RELAY_ID": relayID,
                "CMUX_RELAY_TOKEN": relayToken,
                "CMUX_CLI_TTY_NAME": ttyName,
                "CMUX_WORKSPACE_ID": staleWorkspaceID,
                "CMUX_SURFACE_ID": staleSurfaceID,
                "CMUX_CLAUDE_PID": "42424",
                "CMUX_CLAUDE_HOOK_STATE_PATH": root.appendingPathComponent("claude-hook-sessions.json").path,
                "CMUX_CLI_SENTRY_DISABLED": "1",
                "CMUX_CLAUDE_HOOK_SENTRY_DISABLED": "1",
            ],
            standardInput: #"{"session_id":"relay-missing-session","hook_event_name":"Notification","message":"Claude needs input"}"#,
            timeout: 10
        )

        wait(for: [resolverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        let requests = state.snapshot().compactMap { self.jsonObject($0) }
        let resolverParams = try XCTUnwrap(requests.first(where: {
            $0["method"] as? String == "system.resolve_terminal"
        })?["params"] as? [String: Any])
        XCTAssertEqual(resolverParams["tty_name"] as? String, ttyName)
        XCTAssertNil(resolverParams["pid"])
        XCTAssertFalse(
            state.snapshot().contains { command in
                command.hasPrefix("set_status ")
                    || command.hasPrefix("notify_target")
                    || self.jsonObject(command)?["method"] as? String == "surface.resume.set"
                    || self.jsonObject(command)?["method"] as? String == "feed.push"
            },
            "A relay hook without a live TTY binding must not use ambient identity: \(state.snapshot())"
        )
    }

    func testClaudeTargetedResolverFailureWithLocalIdentityFailsClosed() throws {
        let outcome = try runClaudeTargetedResolverScenario(response: .failure)
        XCTAssertFalse(outcome.result.timedOut, outcome.result.stderr)
        XCTAssertEqual(outcome.result.status, 0, outcome.result.stderr)
        XCTAssertFalse(
            outcome.commands.contains { command in
                command.hasPrefix("set_status ")
                    || command.hasPrefix("notify_target")
                    || self.jsonObject(command)?["method"] as? String == "feed.push"
            },
            "A failed identity lookup must not mutate or publish through the ambient target: \(outcome.commands)"
        )
    }

    func testClaudeTargetedResolverMissingRequestedPIDFailsClosed() throws {
        let outcome = try runClaudeTargetedResolverScenario(response: .emptySuccess)
        XCTAssertFalse(outcome.result.timedOut, outcome.result.stderr)
        XCTAssertEqual(outcome.result.status, 0, outcome.result.stderr)
        XCTAssertFalse(
            outcome.commands.contains { command in
                command.hasPrefix("set_status ")
                    || command.hasPrefix("notify_target")
                    || self.jsonObject(command)?["method"] as? String == "feed.push"
            },
            "A requested PID miss must not collapse into ambient routing: \(outcome.commands)"
        )
    }

    func testClaudeTargetedResolverMalformedBindingFailsClosed() throws {
        let outcome = try runClaudeTargetedResolverScenario(response: .malformedSuccess)
        XCTAssertFalse(outcome.result.timedOut, outcome.result.stderr)
        XCTAssertEqual(outcome.result.status, 0, outcome.result.stderr)
        XCTAssertFalse(
            outcome.commands.contains { command in
                command.hasPrefix("set_status ")
                    || command.hasPrefix("notify_target")
                    || self.jsonObject(command)?["method"] as? String == "feed.push"
            },
            "A malformed identity result must not collapse into a valid empty response: \(outcome.commands)"
        )
    }

    private enum TargetedResolverResponse: Sendable {
        case failure
        case emptySuccess
        case malformedSuccess
    }

    private func runClaudeTargetedResolverScenario(
        response: TargetedResolverResponse
    ) throws -> (
        result: ProcessRunResult,
        commands: [String],
        workspaceId: String,
        surfaceId: String
    ) {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("claude-targeted-resolver")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-claude-targeted-resolver-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "targeted-resolver-session"
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let stateURL = root.appendingPathComponent("claude-hook-sessions.json")
        let serverHandled = startMockServer(listenerFD: listenerFD, state: state, connectionCount: 2) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return "OK"
            }
            switch method {
            case "system.resolve_terminal":
                switch response {
                case .failure:
                    return self.v2Response(
                        id: id,
                        ok: false,
                        error: ["code": "unavailable", "message": "resolver unavailable"]
                    )
                case .emptySuccess:
                    return self.v2Response(
                        id: id,
                        ok: true,
                        result: ["tty_bindings": [], "pid_binding": NSNull()]
                    )
                case .malformedSuccess:
                    return self.v2Response(
                        id: id,
                        ok: true,
                        result: [
                            "tty_bindings": [["workspace_id": workspaceId]],
                            "pid_binding": NSNull(),
                        ]
                    )
                }
            case "surface.list":
                return self.surfaceListResponse(id: id, surfaceId: surfaceId)
            case "feed.push":
                return self.v2Response(id: id, ok: true, result: [:])
            default:
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unrecognized_method", "message": "unexpected method: \(method)"]
                )
            }
        }

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "claude", "notification"],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_WORKSPACE_ID": workspaceId,
                "CMUX_SURFACE_ID": surfaceId,
                "CMUX_CLI_TTY_NAME": "remote-or-stale-tty",
                "CMUX_CLAUDE_PID": "42424",
                "CMUX_CLAUDE_HOOK_STATE_PATH": stateURL.path,
                "CMUX_CLI_SENTRY_DISABLED": "1",
                "CMUX_CLAUDE_HOOK_SENTRY_DISABLED": "1",
            ],
            standardInput: #"{"session_id":"\#(sessionId)","hook_event_name":"Notification","message":"Claude needs your input"}"#,
            timeout: 5
        )
        wait(for: [serverHandled], timeout: 5)
        return (result, state.snapshot(), workspaceId, surfaceId)
    }

    private func startHookIdentityRelayServer(
        listenerFD: Int32,
        state: MockSocketServerState,
        relayID: String,
        handler: @escaping @Sendable (String) -> String
    ) -> XCTestExpectation {
        let handled = expectation(description: "relay resolver handled")
        DispatchQueue.global(qos: .userInitiated).async {
            var didFulfill = false

            func writeLine(_ line: String, to fd: Int32) -> Bool {
                let data = Data((line + "\n").utf8)
                return data.withUnsafeBytes { rawBuffer in
                    guard let base = rawBuffer.baseAddress else { return false }
                    var offset = 0
                    while offset < rawBuffer.count {
                        let count = Darwin.write(fd, base.advanced(by: offset), rawBuffer.count - offset)
                        if count > 0 { offset += count }
                        else if count < 0, errno == EINTR { continue }
                        else { return false }
                    }
                    return true
                }
            }

            func readLine(from fd: Int32) -> String? {
                var data = Data()
                var byte: UInt8 = 0
                while true {
                    let count = Darwin.read(fd, &byte, 1)
                    if count == 1 {
                        if byte == 0x0A { return String(data: data, encoding: .utf8) }
                        data.append(byte)
                    } else if count < 0, errno == EINTR { continue }
                    else { return nil }
                }
            }

            while true {
                var address = sockaddr_in()
                var addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
                let clientFD = withUnsafeMutablePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.accept(listenerFD, $0, &addressLength)
                    }
                }
                guard clientFD >= 0 else { return }
                guard writeLine(
                    #"{"protocol":"cmux-relay-auth","version":1,"relay_id":"\#(relayID)","nonce":"test-nonce"}"#,
                    to: clientFD
                ), readLine(from: clientFD) != nil,
                writeLine(#"{"ok":true}"#, to: clientFD),
                let command = readLine(from: clientFD) else {
                    Darwin.close(clientFD)
                    continue
                }
                state.append(command)
                if !didFulfill, command.contains(#""method":"system.resolve_terminal""#) {
                    didFulfill = true
                    handled.fulfill()
                }
                _ = writeLine(handler(command), to: clientFD)
                Darwin.close(clientFD)
            }
        }
        return handled
    }

}
