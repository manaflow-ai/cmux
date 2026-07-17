import Foundation
import XCTest
import Darwin

extension CLINotifyProcessIntegrationRegressionTests {
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
