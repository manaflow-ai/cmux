import Foundation
import XCTest
import Darwin

extension CLINotifyProcessIntegrationRegressionTests {
    /// A weak, nonempty Codex argv must neither replace `--yolo` nor prevent repairing a legacy
    /// binding from the rollout context immediately preceding its capture.
    func testCodexHookPreservesOrRepairsStoredYoloLaunch() throws {
        let cliPath = try bundledCLIPath()
        let executable = "/Users/example/.bun/bin/codex"
        let scenarios: [(name: String, storedArguments: [String], hasRollout: Bool)] = [
            ("rich", [executable, "--yolo"], false),
            ("legacy-bare", [executable], true),
        ]

        for (index, scenario) in scenarios.enumerated() {
            let socketPath = makeSocketPath("codex-yolo-\(scenario.name)")
            let listenerFD = try bindUnixSocket(at: socketPath)
            let state = MockSocketServerState()
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-codex-yolo-\(UUID().uuidString)", isDirectory: true)
            let workspaceId = "11111111-1111-1111-1111-111111111111"
            let surfaceId = "22222222-2222-2222-2222-222222222222"
            let sessionId = "codex-yolo-\(scenario.name)-session"
            let ttyName = "ttys30\(index + 3)"
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer {
                Darwin.close(listenerFD)
                unlink(socketPath)
                try? FileManager.default.removeItem(at: root)
            }

            let now = Date().timeIntervalSince1970
            let transcriptURL = root.appendingPathComponent("rollout.jsonl")
            if scenario.hasRollout {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let timestamp = formatter.string(from: Date(timeIntervalSince1970: now - 120))
                let line = #"{"timestamp":"\#(timestamp)","type":"turn_context","payload":{"approval_policy":"never","sandbox_policy":{"type":"danger-full-access"}}}"#
                try (line + "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)
            }
            var record: [String: Any] = [
                "sessionId": sessionId, "workspaceId": workspaceId, "surfaceId": surfaceId,
                "cwd": root.path, "startedAt": now - 300, "updatedAt": now,
                "launchCommand": [
                    "launcher": "codex", "executablePath": executable,
                    "arguments": scenario.storedArguments, "workingDirectory": root.path,
                    "capturedAt": now - 60, "source": "environment",
                ],
            ]
            if scenario.hasRollout { record["transcriptPath"] = transcriptURL.path }
            let storeURL = root.appendingPathComponent("codex-hook-sessions.json")
            try JSONSerialization.data(
                withJSONObject: ["version": 1, "sessions": [sessionId: record]],
                options: [.prettyPrinted]
            ).write(to: storeURL, options: .atomic)

            let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
                guard let payload = self.jsonObject(line) else { return "OK" }
                guard let id = payload["id"] as? String, let method = payload["method"] as? String else {
                    return self.malformedRequestResponse(id: payload["id"] as? String, raw: line)
                }
                switch method {
                case "surface.list": return self.surfaceListResponse(id: id, surfaceId: surfaceId)
                case "debug.terminals":
                    return self.v2Response(id: id, ok: true, result: [
                        "terminals": [["tty": ttyName, "workspace_id": workspaceId, "surface_id": surfaceId]],
                    ])
                case "surface.resume.set": return self.v2Response(id: id, ok: true, result: ["ok": true])
                case "feed.push": return self.v2Response(id: id, ok: true, result: [:])
                default:
                    return self.v2Response(id: id, ok: false, error: [
                        "code": "unrecognized_method", "message": "unexpected method: \(method)",
                    ])
                }
            }

            var environment = ProcessInfo.processInfo.environment
            environment["HOME"] = root.path
            environment["CMUX_SOCKET_PATH"] = socketPath
            environment["CMUX_WORKSPACE_ID"] = workspaceId
            environment["CMUX_SURFACE_ID"] = surfaceId
            environment["CMUX_CLI_TTY_NAME"] = ttyName
            environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
            environment["CMUX_AGENT_LAUNCH_KIND"] = "codex"
            environment["CMUX_AGENT_LAUNCH_EXECUTABLE"] = executable
            environment["CMUX_AGENT_LAUNCH_ARGV_B64"] = base64NULSeparated([executable])
            environment["CMUX_AGENT_LAUNCH_CWD"] = root.path
            environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

            let result = runProcess(
                executablePath: cliPath,
                arguments: ["hooks", "codex", "prompt-submit"],
                environment: environment,
                standardInput: #"{"session_id":"\#(sessionId)","cwd":"\#(root.path)","hook_event_name":"UserPromptSubmit","prompt":"continue"}"#,
                timeout: 5
            )
            wait(for: [serverHandled], timeout: 5)
            XCTAssertFalse(result.timedOut, "\(scenario.name): \(result.stderr)")
            XCTAssertEqual(result.status, 0, "\(scenario.name): \(result.stderr)")

            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: storeURL)) as? [String: Any])
            let sessions = try XCTUnwrap(json["sessions"] as? [String: Any])
            let persisted = try XCTUnwrap(sessions[sessionId] as? [String: Any])
            let launchCommand = try XCTUnwrap(persisted["launchCommand"] as? [String: Any])
            XCTAssertEqual(launchCommand["arguments"] as? [String], [executable, "--yolo"], scenario.name)

            let commands = state.snapshot()
            let resumeParams = commands.compactMap { command -> [String: Any]? in
                guard let payload = self.jsonObject(command),
                      payload["method"] as? String == "surface.resume.set" else { return nil }
                return payload["params"] as? [String: Any]
            }.last
            let command = try XCTUnwrap(resumeParams?["command"] as? String, commands.joined(separator: "\n"))
            XCTAssertTrue(command.contains("'--yolo'"), "\(scenario.name): \(command)")
        }
    }
}
