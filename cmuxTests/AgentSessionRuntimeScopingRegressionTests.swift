import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension CMUXCLIErrorOutputRegressionTests {
    @Test func hibernationMovesTheSessionIntoTheCurrentCmuxRuntime() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-runtime-hibernation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stateURL = root.appendingPathComponent("codex-hook-sessions.json")
        let store: [String: Any] = [
            "version": 2,
            "sessions": [
                "session": [
                    "sessionId": "session",
                    "workspaceId": "workspace",
                    "surfaceId": "surface",
                    "runId": "run",
                    "activeRunId": "run",
                    "restoreAuthority": true,
                    "cmuxRuntime": ["id": "old-runtime"],
                    "runs": [[
                        "runId": "run",
                        "restoreAuthority": true,
                        "cmuxRuntime": ["id": "old-runtime"],
                        "startedAt": 100.0,
                        "updatedAt": 100.0,
                    ]],
                    "startedAt": 100.0,
                    "updatedAt": 100.0,
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: store, options: [.sortedKeys])
            .write(to: stateURL, options: .atomic)

        AgentHookSessionStateWriter(
            homeDirectory: root.path,
            environment: [
                "CMUX_CLAUDE_HOOK_STATE_PATH": stateURL.path,
                "CMUX_RUNTIME_ID": "current-runtime",
                "CMUX_SOCKET_PATH": "/tmp/cmux-current.sock",
                "CMUX_BUNDLE_ID": "com.cmuxterm.current",
            ]
        ).setLifecycleSynchronously(
            kind: .codex,
            sessionId: "session",
            state: .hibernated,
            now: 200
        )

        let saved = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any]
        )
        let sessions = try #require(saved["sessions"] as? [String: Any])
        let record = try #require(sessions["session"] as? [String: Any])
        #expect(record["sessionState"] as? String == "hibernated")
        let recordRuntime = try #require(record["cmuxRuntime"] as? [String: Any])
        #expect(recordRuntime["id"] as? String == "current-runtime")
        let runs = try #require(record["runs"] as? [[String: Any]])
        let runRuntime = try #require(runs.first?["cmuxRuntime"] as? [String: Any])
        #expect(runRuntime["id"] as? String == "current-runtime")
    }

    @Test func agentsTreeDefaultsToTheCallingCmuxRuntimeWhileAllIncludesHistory() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agents-runtime-scope-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        func record(sessionId: String, runId: String, runtimeId: String) -> [String: Any] {
            [
                "sessionId": sessionId,
                "workspaceId": "workspace-\(runtimeId)",
                "surfaceId": "surface-\(runtimeId)",
                "transcriptPath": "/tmp/\(sessionId).jsonl",
                "runId": runId,
                "activeRunId": runId,
                "restoreAuthority": true,
                "cmuxRuntime": [
                    "id": runtimeId,
                    "socketPath": "/tmp/cmux-debug-\(runtimeId).sock",
                    "bundleIdentifier": "com.cmuxterm.app.debug.\(runtimeId)",
                ],
                "runs": [[
                    "runId": runId,
                    "restoreAuthority": true,
                    "cmuxRuntime": [
                        "id": runtimeId,
                        "socketPath": "/tmp/cmux-debug-\(runtimeId).sock",
                        "bundleIdentifier": "com.cmuxterm.app.debug.\(runtimeId)",
                    ],
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
                "current-session": record(
                    sessionId: "current-session",
                    runId: "current-run",
                    runtimeId: "current"
                ),
                "other-session": record(
                    sessionId: "other-session",
                    runId: "other-run",
                    runtimeId: "other"
                ),
            ],
        ]
        try JSONSerialization.data(withJSONObject: store, options: [.sortedKeys])
            .write(to: root.appendingPathComponent("codex-hook-sessions.json"), options: .atomic)

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_RUNTIME_ID"] = "current"

        let scoped = runProcess(
            executablePath: cliPath,
            arguments: ["agents", "tree", "--json"],
            environment: environment,
            timeout: 5
        )
        #expect(!scoped.timedOut, Comment(rawValue: scoped.stdout))
        #expect(scoped.status == 0, Comment(rawValue: scoped.stdout))
        let scopedOutput = try #require(
            JSONSerialization.jsonObject(with: Data(scoped.stdout.utf8)) as? [String: Any]
        )
        let scopedNodes = try #require(scopedOutput["nodes"] as? [[String: Any]])
        #expect(scopedNodes.map { $0["session_id"] as? String } == ["current-session"])

        let filteredList = runProcess(
            executablePath: cliPath,
            arguments: ["agents", "list", "--state", "unknown", "--json"],
            environment: environment,
            timeout: 5
        )
        #expect(!filteredList.timedOut, Comment(rawValue: filteredList.stdout))
        #expect(filteredList.status == 0, Comment(rawValue: filteredList.stdout))
        let filteredOutput = try #require(
            JSONSerialization.jsonObject(with: Data(filteredList.stdout.utf8)) as? [String: Any]
        )
        let filteredSessions = try #require(filteredOutput["sessions"] as? [[String: Any]])
        #expect(filteredSessions.map { $0["session_id"] as? String } == ["current-session"])

        let history = runProcess(
            executablePath: cliPath,
            arguments: ["agents", "tree", "--all", "--json"],
            environment: environment,
            timeout: 5
        )
        #expect(!history.timedOut, Comment(rawValue: history.stdout))
        #expect(history.status == 0, Comment(rawValue: history.stdout))
        let historyOutput = try #require(
            JSONSerialization.jsonObject(with: Data(history.stdout.utf8)) as? [String: Any]
        )
        let historyNodes = try #require(historyOutput["nodes"] as? [[String: Any]])
        #expect(Set(historyNodes.compactMap { $0["session_id"] as? String }) == ["current-session", "other-session"])
    }
}
