import XCTest
import Darwin

extension CLINotifyProcessIntegrationRegressionTests {
    struct GenericHookPersistenceScenario {
        let agent: String
        let subcommand: String
        let sessionId: String
        let executable: String
        let launchArguments: [String]
        let extraEnvironment: [String: String]
        let expectedArguments: [String]
        let expectedEnvironment: [String: String]?
    }

    private final class MockSocketFulfillmentGate: @unchecked Sendable {
        private let lock = NSLock()
        private var didFulfill = false

        func fulfill(_ expectation: XCTestExpectation) {
            lock.lock()
            defer { lock.unlock() }
            guard !didFulfill else { return }
            didFulfill = true
            expectation.fulfill()
        }
    }

    func startMockServer(
        listenerFD: Int32,
        state: MockSocketServerState,
        connectionCount: Int = 1,
        fulfillWhen: (@Sendable (String) -> Bool)? = nil,
        handler: @escaping @Sendable (String) -> String
    ) -> XCTestExpectation {
        startMockServerAllowingNoResponse(
            listenerFD: listenerFD,
            state: state,
            connectionCount: connectionCount,
            fulfillWhen: fulfillWhen
        ) { line in
            handler(line)
        }
    }

    func startMockServerAllowingNoResponse(
        listenerFD: Int32,
        state: MockSocketServerState,
        connectionCount: Int = 1,
        fulfillWhen: (@Sendable (String) -> Bool)? = nil,
        handler: @escaping @Sendable (String) -> String?
    ) -> XCTestExpectation {
        let handled = expectation(description: "cli mock socket handled")
        let fulfillmentGate = MockSocketFulfillmentGate()
        for _ in 0..<max(1, connectionCount) {
            DispatchQueue.global(qos: .userInitiated).async {
                func fulfillOnce() {
                    fulfillmentGate.fulfill(handled)
                }

                var clientAddr = sockaddr_un()
                var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
                let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                        Darwin.accept(listenerFD, sockaddrPtr, &clientAddrLen)
                    }
                }
                guard clientFD >= 0 else {
                    fulfillOnce()
                    return
                }
                defer {
                    Darwin.close(clientFD)
                    fulfillOnce()
                }

                var pending = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let count = Darwin.read(clientFD, &buffer, buffer.count)
                    if count < 0 {
                        if errno == EINTR { continue }
                        return
                    }
                    if count == 0 { return }
                    pending.append(buffer, count: count)

                    while let newlineRange = pending.firstRange(of: Data([0x0A])) {
                        let lineData = pending.subdata(in: 0..<newlineRange.lowerBound)
                        pending.removeSubrange(0...newlineRange.lowerBound)
                        guard let line = String(data: lineData, encoding: .utf8) else { continue }
                        state.append(line)
                        if fulfillWhen?(line) == true {
                            fulfillOnce()
                        }
                        guard let responsePayload = handler(line) else { continue }
                        let response = responsePayload + "\n"
                        _ = response.withCString { ptr in
                            Darwin.write(clientFD, ptr, strlen(ptr))
                        }
                    }
                }
            }
        }
        return handled
    }

    func startDetachedMockServer(
        listenerFD: Int32,
        state: MockSocketServerState,
        connectionCount: Int = 1,
        handler: @escaping @Sendable (String) -> String
    ) {
        for _ in 0..<max(1, connectionCount) {
            DispatchQueue.global(qos: .userInitiated).async {
                var clientAddr = sockaddr_un()
                var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
                let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                        Darwin.accept(listenerFD, sockaddrPtr, &clientAddrLen)
                    }
                }
                guard clientFD >= 0 else {
                    return
                }
                defer {
                    Darwin.close(clientFD)
                }

                var pending = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let count = Darwin.read(clientFD, &buffer, buffer.count)
                    if count < 0 {
                        if errno == EINTR { continue }
                        return
                    }
                    if count == 0 { return }
                    pending.append(buffer, count: count)

                    while let newlineRange = pending.firstRange(of: Data([0x0A])) {
                        let lineData = pending.subdata(in: 0..<newlineRange.lowerBound)
                        pending.removeSubrange(0...newlineRange.lowerBound)
                        guard let line = String(data: lineData, encoding: .utf8) else { continue }
                        state.append(line)
                        let response = handler(line) + "\n"
                        _ = response.withCString { ptr in
                            Darwin.write(clientFD, ptr, strlen(ptr))
                        }
                    }
                }
            }
        }
    }

    func startAgentHookMockServer(
        listenerFD: Int32,
        state: MockSocketServerState,
        workspaceId: String,
        surfaceId: String,
        connectionCount: Int
    ) -> XCTestExpectation {
        startMockServer(listenerFD: listenerFD, state: state, connectionCount: connectionCount) { line in
            self.agentHookMockResponse(line: line, workspaceId: workspaceId, surfaceId: surfaceId)
        }
    }

    func startDetachedAgentHookMockServer(
        listenerFD: Int32,
        state: MockSocketServerState,
        workspaceId: String,
        surfaceId: String,
        connectionCount: Int
    ) {
        startDetachedMockServer(listenerFD: listenerFD, state: state, connectionCount: connectionCount) { line in
            self.agentHookMockResponse(line: line, workspaceId: workspaceId, surfaceId: surfaceId)
        }
    }

    func startAgentHookMockServerAccepting(context: ClaudeHookContext, connectionLimit: Int) {
        DispatchQueue.global(qos: .userInitiated).async {
            var accepted = 0
            while accepted < connectionLimit {
                var clientAddr = sockaddr_un()
                var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
                let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                        Darwin.accept(context.listenerFD, sockaddrPtr, &clientAddrLen)
                    }
                }
                if clientFD < 0 {
                    if errno == EINTR { continue }
                    return
                }
                accepted += 1

                DispatchQueue.global(qos: .userInitiated).async {
                    defer { Darwin.close(clientFD) }
                    var pending = Data()
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    while true {
                        let count = Darwin.read(clientFD, &buffer, buffer.count)
                        if count < 0 {
                            if errno == EINTR { continue }
                            return
                        }
                        if count == 0 { return }
                        pending.append(buffer, count: count)
                        while let newlineRange = pending.firstRange(of: Data([0x0A])) {
                            let lineData = pending.subdata(in: 0..<newlineRange.lowerBound)
                            pending.removeSubrange(0...newlineRange.lowerBound)
                            guard let line = String(data: lineData, encoding: .utf8) else { continue }
                            context.state.append(line)
                            let response = self.agentHookMockResponse(line: line, context: context) + "\n"
                            _ = response.withCString { ptr in
                                Darwin.write(clientFD, ptr, strlen(ptr))
                            }
                        }
                    }
                }
            }
        }
    }

    func terminalResolverResponse(id: String, workspaceId: String, surfaceId: String) -> String {
        v2Response(
            id: id,
            ok: true,
            result: [
                "tty_bindings": [],
                "pid_binding": [
                    "workspace_id": workspaceId,
                    "surface_id": surfaceId,
                ],
            ]
        )
    }

    func runGenericHookPersistenceScenario(_ scenario: GenericHookPersistenceScenario) throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("hook-\(scenario.agent)")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-\(scenario.agent)-hook-\(UUID().uuidString)", isDirectory: true)
        let workspace = root.appendingPathComponent("repo", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"

        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line) else {
                return "OK"
            }
            guard let id = payload["id"] as? String, let method = payload["method"] as? String else {
                return self.malformedRequestResponse(id: payload["id"] as? String, raw: line)
            }
            switch method {
            case "surface.list":
                return self.surfaceListResponse(id: id, surfaceId: surfaceId)
            case "system.resolve_terminal":
                return self.terminalResolverResponse(id: id, workspaceId: workspaceId, surfaceId: surfaceId)
            case "surface.resume.set":
                return self.v2Response(id: id, ok: true, result: ["ok": true])
            case "feed.push":
                return self.v2Response(id: id, ok: true, result: [:])
            default:
                return self.v2Response(id: id, ok: false, error: ["code": "unrecognized_method", "message": "unexpected method: \(method)"])
            }
        }

        var environment: [String: String] = [
            "HOME": root.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "PWD": workspace.path,
            "CMUX_SOCKET_PATH": socketPath,
            "CMUX_WORKSPACE_ID": workspaceId,
            "CMUX_SURFACE_ID": surfaceId,
            "CMUX_AGENT_HOOK_STATE_DIR": root.path,
            "CMUX_AGENT_LAUNCH_KIND": scenario.agent,
            "CMUX_AGENT_LAUNCH_EXECUTABLE": scenario.executable,
            "CMUX_AGENT_LAUNCH_ARGV_B64": base64NULSeparated(scenario.launchArguments),
            "CMUX_AGENT_LAUNCH_CWD": workspace.path,
            "CMUX_CLI_SENTRY_DISABLED": "1",
        ]
        for (key, value) in scenario.extraEnvironment {
            environment[key] = value
        }

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", scenario.agent, scenario.subcommand],
            environment: environment,
            standardInput: #"{"session_id":"\#(scenario.sessionId)","cwd":"\#(workspace.path)","hook_event_name":"SessionStart"}"#,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "{}\n")

        let storeURL = root.appendingPathComponent("\(scenario.agent)-hook-sessions.json", isDirectory: false)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: storeURL)) as? [String: Any])
        let sessions = try XCTUnwrap(json["sessions"] as? [String: Any])
        let session = try XCTUnwrap(sessions[scenario.sessionId] as? [String: Any])
        XCTAssertEqual(session["workspaceId"] as? String, workspaceId)
        XCTAssertEqual(session["surfaceId"] as? String, surfaceId)
        XCTAssertEqual(session["cwd"] as? String, workspace.path)

        let launchCommand = try XCTUnwrap(session["launchCommand"] as? [String: Any])
        XCTAssertEqual(launchCommand["launcher"] as? String, scenario.agent)
        XCTAssertEqual(launchCommand["executablePath"] as? String, scenario.executable)
        XCTAssertEqual(launchCommand["arguments"] as? [String], scenario.expectedArguments)
        XCTAssertEqual(launchCommand["workingDirectory"] as? String, workspace.path)
        XCTAssertEqual(launchCommand["environment"] as? [String: String], scenario.expectedEnvironment)

        if scenario.agent == "kiro" {
            let resumeSetRequests = state.commands.compactMap { command -> [String: Any]? in
                guard let payload = self.jsonObject(command),
                      payload["method"] as? String == "surface.resume.set" else {
                    return nil
                }
                return payload["params"] as? [String: Any]
            }
            XCTAssertEqual(resumeSetRequests.count, 1, state.commands.joined(separator: "\n"))
            let params = try XCTUnwrap(resumeSetRequests.first)
            XCTAssertEqual(params["kind"] as? String, "kiro")
            XCTAssertEqual(params["checkpoint_id"] as? String, scenario.sessionId)
            XCTAssertEqual(params["auto_resume"] as? Bool, true)
            XCTAssertEqual(
                params["command"] as? String,
                "cd -- '\(workspace.path)' 2>/dev/null || [ ! -d '\(workspace.path)' ] && '\(scenario.executable)' 'chat' '--resume-id' '\(scenario.sessionId)' '--agent' 'cmux' '--trust-tools' 'fs_read,fs_write'"
            )
            XCTAssertEqual(params["environment"] as? [String: String], scenario.expectedEnvironment)
            XCTAssertFalse(
                state.commands.contains { command in
                    self.jsonObject(command)?["method"] as? String == "surface.resume.clear"
                },
                "Kiro should publish a resume binding instead of clearing it: \(state.commands)"
            )
        }
    }

    func writeCodexHookStore(
        root: URL,
        sessionId: String,
        workspaceId: String,
        surfaceId: String,
        cwd: String,
        transcriptPath: String? = nil,
        launchCommand: [String: Any]?
    ) throws {
        var session: [String: Any] = [
            "sessionId": sessionId,
            "workspaceId": workspaceId,
            "surfaceId": surfaceId,
            "cwd": cwd,
            "startedAt": Date().timeIntervalSince1970,
            "updatedAt": Date().timeIntervalSince1970,
        ]
        if let transcriptPath { session["transcriptPath"] = transcriptPath }
        if let launchCommand { session["launchCommand"] = launchCommand }
        let store: [String: Any] = [
            "version": 1,
            "sessions": [sessionId: session],
        ]
        let data = try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: root.appendingPathComponent("codex-hook-sessions.json"), options: .atomic)
    }

    func assertSSHPTYAttachOmitsSurfaceArgument(
        _ script: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(
            script.contains(#"ssh-pty-attach --wait --workspace "$cmux_ssh_pty_workspace_id" --surface"#),
            script,
            file: file,
            line: line
        )
    }

    private func agentHookMockResponse(line: String, workspaceId: String, surfaceId: String) -> String {
        guard let payload = jsonObject(line) else {
            return "OK"
        }
        guard let id = payload["id"] as? String, let method = payload["method"] as? String else {
            return malformedRequestResponse(id: payload["id"] as? String, raw: line)
        }
        switch method {
        case "surface.list":
            return surfaceListResponse(id: id, surfaceId: surfaceId)
        case "system.resolve_terminal":
            return terminalResolverResponse(id: id, workspaceId: workspaceId, surfaceId: surfaceId)
        case "feed.push":
            return v2Response(id: id, ok: true, result: [:])
        default:
            return v2Response(id: id, ok: false, error: ["code": "unrecognized_method", "message": "unexpected method: \(method)"])
        }
    }

    private func agentHookMockResponse(line: String, context: ClaudeHookContext) -> String {
        guard let payload = jsonObject(line) else {
            return "OK"
        }
        guard let id = payload["id"] as? String, let method = payload["method"] as? String else {
            return malformedRequestResponse(id: payload["id"] as? String, raw: line)
        }
        switch method {
        case "surface.list":
            return surfaceListResponse(id: id, surfaceId: context.surfaceId)
        case "system.resolve_terminal":
            return terminalResolverResponse(id: id, workspaceId: context.workspaceId, surfaceId: context.surfaceId)
        case "feed.push":
            return v2Response(id: id, ok: true, result: [:])
        case "surface.resume.set":
            return v2Response(id: id, ok: true, result: ["resume_binding": [:]])
        case "surface.resume.clear":
            return v2Response(id: id, ok: true, result: ["cleared": true])
        default:
            return v2Response(id: id, ok: false, error: ["code": "unrecognized_method", "message": "unexpected method: \(method)"])
        }
    }
}
