import CmuxFoundation
import Foundation
import XCTest
import Darwin

extension CLINotifyProcessIntegrationRegressionTests {
    func testAgentsListIncludesLiveProcessOnlyAgentsAndJoinsDurableSessions() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agents-live-list-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let socketPath = makeSocketPath("agent-live-list")
        let listenerFD = try bindUnixSocket(at: socketPath)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let runtimeID = "target-runtime"
        let durableWorkspaceID = UUID()
        let durableSurfaceID = UUID()
        let durableSessionID = "durable-codex-session"
        let durablePID = getpid()
        var processInfo = kinfo_proc()
        var processInfoSize = MemoryLayout<kinfo_proc>.stride
        var processMIB: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, durablePID]
        let processInfoResult = sysctl(
            &processMIB,
            u_int(processMIB.count),
            &processInfo,
            &processInfoSize,
            nil,
            0
        )
        XCTAssertEqual(processInfoResult, 0)
        let durableStartSeconds = Int64(processInfo.kp_proc.p_un.__p_starttime.tv_sec)
        let durableStartMicroseconds = Int64(processInfo.kp_proc.p_un.__p_starttime.tv_usec)
        let durableStartedAt = TimeInterval(durableStartSeconds)
            + TimeInterval(durableStartMicroseconds) / 1_000_000
        try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "sessions": [durableSessionID: [
                "sessionId": durableSessionID,
                "workspaceId": durableWorkspaceID.uuidString,
                "surfaceId": durableSurfaceID.uuidString,
                "runId": "durable-codex-run",
                "activeRunId": "durable-codex-run",
                "restoreAuthority": true,
                "cmuxRuntime": ["id": runtimeID],
                "runs": [[
                    "runId": "durable-codex-run",
                    "pid": durablePID,
                    "processStartedAt": durableStartedAt,
                    "restoreAuthority": true,
                    "cmuxRuntime": ["id": runtimeID],
                    "startedAt": 100.0,
                    "updatedAt": 200.0,
                ]],
                "startedAt": 100.0,
                "updatedAt": 200.0,
            ]],
            "activeSessionsByWorkspace": [durableWorkspaceID.uuidString: [
                "sessionId": durableSessionID,
                "updatedAt": 200.0,
            ]],
            "activeSessionsBySurface": [durableSurfaceID.uuidString: [
                "sessionId": durableSessionID,
                "updatedAt": 200.0,
            ]],
        ], options: [.sortedKeys]).write(
            to: root.appendingPathComponent("codex-hook-sessions.json"),
            options: .atomic
        )

        func observation(
            workspaceID: UUID,
            surfaceID: UUID,
            familyID: String,
            provider: String,
            lifecycleAuthoritative: Bool,
            state: CmuxAgentObservedState,
            pid: Int32,
            startSeconds: Int64,
            startMicroseconds: Int64,
            cwd: String
        ) -> CmuxAgentTerminalObservation {
            CmuxAgentTerminalObservation(
                runtimeID: runtimeID,
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                surfaceGeneration: 1,
                revision: 1,
                familyID: familyID,
                sessionProviderID: provider,
                lifecycleAuthoritative: lifecycleAuthoritative,
                state: state,
                pid: pid,
                processStartSeconds: startSeconds,
                processStartMicroseconds: startMicroseconds,
                cwd: cwd,
                publishedAt: 300.0 + Double(pid)
            )
        }

        let observations = [
            observation(
                workspaceID: durableWorkspaceID,
                surfaceID: durableSurfaceID,
                familyID: "codex",
                provider: "codex",
                lifecycleAuthoritative: false,
                state: .blocked,
                pid: durablePID,
                startSeconds: durableStartSeconds,
                startMicroseconds: durableStartMicroseconds,
                cwd: "/tmp/durable"
            ),
            observation(
                workspaceID: UUID(),
                surfaceID: UUID(),
                familyID: "codex",
                provider: "codex",
                lifecycleAuthoritative: false,
                state: .working,
                pid: 202,
                startSeconds: 200,
                startMicroseconds: 2,
                cwd: "/tmp/codex-exec"
            ),
            observation(
                workspaceID: UUID(),
                surfaceID: UUID(),
                familyID: "claude-code",
                provider: "claude",
                lifecycleAuthoritative: false,
                state: .idle,
                pid: 303,
                startSeconds: 300,
                startMicroseconds: 3,
                cwd: "/tmp/claude-print"
            ),
            observation(
                workspaceID: UUID(),
                surfaceID: UUID(),
                familyID: "kimi",
                provider: "kimi",
                lifecycleAuthoritative: true,
                state: .blocked,
                pid: 404,
                startSeconds: 400,
                startMicroseconds: 4,
                cwd: "/tmp/kimi"
            ),
            observation(
                workspaceID: UUID(),
                surfaceID: UUID(),
                familyID: "devin",
                provider: "devin",
                lifecycleAuthoritative: false,
                state: .working,
                pid: 505,
                startSeconds: 500,
                startMicroseconds: 5,
                cwd: "/tmp/devin"
            ),
        ]
        let observationsData = try JSONEncoder().encode(observations)

        let state = MockSocketServerState()
        let serverHandled = startMockServer(
            listenerFD: listenerFD,
            state: state,
            connectionCount: 5
        ) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            switch method {
            case "system.capabilities":
                return self.v2Response(id: id, ok: true, result: [
                    "runtime_id": runtimeID,
                    "socket_path": socketPath,
                    "bundle_identifier": "com.cmuxterm.app.debug.target",
                    "methods": ["agents.observations"],
                ])
            case "agents.observations":
                let observationObjects = (try? JSONSerialization.jsonObject(with: observationsData)) as? [Any] ?? []
                return self.v2Response(id: id, ok: true, result: [
                    "runtime_id": runtimeID,
                    "observations": observationObjects,
                ])
            default:
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unknown_method", "message": method]
                )
            }
        }

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_SOCKET_PATH"] = socketPath

        let fullList = runProcess(
            executablePath: cliPath,
            arguments: ["agents", "list", "--json", "--state-dir", root.path],
            environment: environment,
            timeout: 5
        )
        XCTAssertEqual(fullList.status, 0, fullList.stderr)
        let fullPayload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(fullList.stdout.utf8)) as? [String: Any]
        )
        let rows = try XCTUnwrap(fullPayload["sessions"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 5, fullList.stdout)
        let durable = try XCTUnwrap(rows.first { $0["session_id"] as? String == durableSessionID })
        XCTAssertEqual(durable["identity_source"] as? String, "hook_session")
        XCTAssertEqual(durable["effective_state"] as? String, "needs_input")
        XCTAssertEqual(durable["state_source"] as? String, "terminal")
        XCTAssertEqual(rows.filter { $0["pid"] as? Int32 == durablePID || $0["pid"] as? Int == Int(durablePID) }.count, 1)

        let processRows = rows.filter { $0["identity_source"] as? String == "terminal_process" }
        XCTAssertEqual(
            Set(processRows.compactMap { $0["agent"] as? String }),
            ["claude", "codex", "devin", "kimi"]
        )
        XCTAssertTrue(processRows.allSatisfy {
            $0.keys.contains("session_id") && $0["session_id"] is NSNull
        })
        XCTAssertTrue(processRows.allSatisfy { $0["restore_authority"] as? Bool == false })
        XCTAssertTrue(processRows.allSatisfy { $0["is_restorable"] as? Bool == false })
        XCTAssertEqual(
            processRows.first { $0["pid"] as? Int == 202 }?["effective_state"] as? String,
            "working"
        )
        XCTAssertEqual(
            processRows.first { $0["pid"] as? Int == 404 }?["effective_state"] as? String,
            "needs_input"
        )

        let sessionFiltered = runProcess(
            executablePath: cliPath,
            arguments: [
                "agents", "list", "--session", durableSessionID,
                "--json", "--state-dir", root.path,
            ],
            environment: environment,
            timeout: 5
        )
        XCTAssertEqual(sessionFiltered.status, 0, sessionFiltered.stderr)
        let sessionPayload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(sessionFiltered.stdout.utf8)) as? [String: Any]
        )
        let sessionRows = try XCTUnwrap(sessionPayload["sessions"] as? [[String: Any]])
        XCTAssertEqual(sessionRows.count, 1)
        XCTAssertEqual(sessionRows.first?["session_id"] as? String, durableSessionID)

        let claudeFiltered = runProcess(
            executablePath: cliPath,
            arguments: ["agents", "list", "--agent", "claude", "--json", "--state-dir", root.path],
            environment: environment,
            timeout: 5
        )
        XCTAssertEqual(claudeFiltered.status, 0, claudeFiltered.stderr)
        let claudePayload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(claudeFiltered.stdout.utf8)) as? [String: Any]
        )
        let claudeRows = try XCTUnwrap(claudePayload["sessions"] as? [[String: Any]])
        XCTAssertEqual(claudeRows.count, 1)
        XCTAssertEqual(claudeRows.first?["pid"] as? Int, 303)

        let devinFiltered = runProcess(
            executablePath: cliPath,
            arguments: ["agents", "list", "--agent", "devin", "--json", "--state-dir", root.path],
            environment: environment,
            timeout: 5
        )
        XCTAssertEqual(devinFiltered.status, 0, devinFiltered.stderr)
        let devinPayload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(devinFiltered.stdout.utf8)) as? [String: Any]
        )
        let devinRows = try XCTUnwrap(devinPayload["sessions"] as? [[String: Any]])
        XCTAssertEqual(devinRows.count, 1)
        XCTAssertEqual(devinRows.first?["pid"] as? Int, 505)

        let kimiText = runProcess(
            executablePath: cliPath,
            arguments: ["agents", "list", "--agent", "kimi", "--state-dir", root.path],
            environment: environment,
            timeout: 5
        )
        XCTAssertEqual(kimiText.status, 0, kimiText.stderr)
        XCTAssertTrue(kimiText.stdout.contains("kimi pid 404"), kimiText.stdout)
        XCTAssertFalse(kimiText.stdout.contains("kimi unknown"), kimiText.stdout)

        wait(for: [serverHandled], timeout: 1)

        var offlineEnvironment = environment
        offlineEnvironment.removeValue(forKey: "CMUX_SOCKET_PATH")
        let offline = runProcess(
            executablePath: cliPath,
            arguments: ["agents", "list", "--json", "--state-dir", root.path],
            environment: offlineEnvironment,
            timeout: 5
        )
        XCTAssertEqual(offline.status, 0, offline.stderr)
        let offlinePayload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(offline.stdout.utf8)) as? [String: Any]
        )
        let offlineRows = try XCTUnwrap(offlinePayload["sessions"] as? [[String: Any]])
        XCTAssertEqual(offlineRows.count, 1)
        XCTAssertEqual(offlineRows.first?["session_id"] as? String, durableSessionID)
    }

    func testAmbientSocketScopesAgentsTreeToTheConnectedRuntime() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agents-ambient-socket-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let socketPath = makeSocketPath("agent-ambient-runtime")
        let listenerFD = try bindUnixSocket(at: socketPath)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }
        func record(_ sessionID: String, _ runtimeID: String) -> [String: Any] {
            [
                "sessionId": sessionID, "workspaceId": "workspace-\(runtimeID)",
                "surfaceId": "surface-\(runtimeID)", "runId": "run-\(runtimeID)",
                "activeRunId": "run-\(runtimeID)", "restoreAuthority": true,
                "cmuxRuntime": ["id": runtimeID],
                "runs": [[
                    "runId": "run-\(runtimeID)", "restoreAuthority": true,
                    "cmuxRuntime": ["id": runtimeID], "startedAt": 100.0, "updatedAt": 200.0,
                ]],
                "startedAt": 100.0, "updatedAt": 200.0,
            ]
        }
        try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "sessions": [
                "current-session": record("current-session", "target-runtime"),
                "other-session": record("other-session", "other-runtime"),
            ],
        ], options: [.sortedKeys]).write(
            to: root.appendingPathComponent("codex-hook-sessions.json"), options: .atomic
        )
        let state = MockSocketServerState()
        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  payload["method"] as? String == "system.capabilities" else {
                return self.malformedRequestResponse(raw: line)
            }
            return self.v2Response(id: id, ok: true, result: [
                "runtime_id": "target-runtime",
                "socket_path": socketPath,
                "bundle_identifier": "com.cmuxterm.app.debug.target",
            ])
        }
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_SOCKET_PATH"] = socketPath
        let result = runProcess(
            executablePath: cliPath,
            arguments: ["agents", "tree", "--json", "--state-dir", root.path],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 1)
        XCTAssertEqual(result.status, 0, result.stderr)
        let output = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        )
        let nodes = try XCTUnwrap(output["nodes"] as? [[String: Any]])
        XCTAssertEqual(nodes.compactMap { $0["session_id"] as? String }, ["current-session"])
    }

    func testExplicitSocketScopesAgentsTreeToTheTargetRuntime() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agents-explicit-socket-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let socketPath = makeSocketPath("agent-runtime")
        let listenerFD = try bindUnixSocket(at: socketPath)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        func record(sessionId: String, runtimeId: String) -> [String: Any] {
            [
                "sessionId": sessionId,
                "workspaceId": "workspace-\(runtimeId)",
                "surfaceId": "surface-\(runtimeId)",
                "runId": "run-\(runtimeId)",
                "activeRunId": "run-\(runtimeId)",
                "restoreAuthority": true,
                "cmuxRuntime": ["id": runtimeId],
                "runs": [[
                    "runId": "run-\(runtimeId)",
                    "restoreAuthority": true,
                    "cmuxRuntime": ["id": runtimeId],
                    "startedAt": 100.0,
                    "updatedAt": 200.0,
                ]],
                "startedAt": 100.0,
                "updatedAt": 200.0,
            ]
        }
        let store: [String: Any] = [
            "version": 2,
            "sessions": [
                "current-session": record(sessionId: "current-session", runtimeId: "target-runtime"),
                "other-session": record(sessionId: "other-session", runtimeId: "other-runtime"),
            ],
        ]
        try JSONSerialization.data(withJSONObject: store, options: [.sortedKeys])
            .write(to: root.appendingPathComponent("codex-hook-sessions.json"), options: .atomic)

        let state = MockSocketServerState()
        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  payload["method"] as? String == "system.capabilities" else {
                return self.malformedRequestResponse(raw: line)
            }
            return self.v2Response(
                id: id,
                ok: true,
                result: [
                    "runtime_id": "target-runtime",
                    "socket_path": socketPath,
                    "bundle_identifier": "com.cmuxterm.app.debug.target",
                ]
            )
        }

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "--socket", socketPath,
                "agents", "tree", "--json", "--state-dir", root.path,
            ],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 1)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        let output = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        )
        let nodes = try XCTUnwrap(output["nodes"] as? [[String: Any]])
        XCTAssertEqual(nodes.compactMap { $0["session_id"] as? String }, ["current-session"])
    }
}
