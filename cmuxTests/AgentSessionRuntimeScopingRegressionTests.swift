import CmuxFoundation
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
                "foregroundState": "completed",
                "workloads": [[
                    "id": "monitor-\(runtimeId)",
                    "kind": "monitor",
                    "phase": "watching",
                    "keepsSessionBusy": true,
                    "startedAt": 100.0,
                    "updatedAt": 200.0,
                ]],
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

        for filter in [
            ["--state", "monitoring"],
            ["--activity", "busy"],
            ["--work-kind", "monitor"],
        ] {
            let filteredList = runProcess(
                executablePath: cliPath,
                arguments: ["agents", "list"] + filter + ["--json"],
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
        }

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

    @Test func agentsDefaultViewsExcludeEndedRunsFromTheCurrentRuntime() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agents-live-default-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let runtime: [String: Any] = ["id": "current-runtime"]
        func record(
            sessionId: String,
            runId: String,
            foregroundState: String,
            endedAt: TimeInterval? = nil
        ) -> [String: Any] {
            var run: [String: Any] = [
                "runId": runId,
                "restoreAuthority": true,
                "cmuxRuntime": runtime,
                "startedAt": 100.0,
                "updatedAt": 200.0,
            ]
            run["endedAt"] = endedAt
            var result: [String: Any] = [
                "sessionId": sessionId,
                "workspaceId": "workspace",
                "surfaceId": "surface-\(sessionId)",
                "runId": runId,
                "activeRunId": runId,
                "restoreAuthority": true,
                "foregroundState": foregroundState,
                "cmuxRuntime": runtime,
                "runs": [run],
                "startedAt": 100.0,
                "updatedAt": 200.0,
            ]
            result["completedAt"] = endedAt
            return result
        }

        let codexStore: [String: Any] = [
            "version": 2,
            "sessions": [
                "ended-root": record(
                    sessionId: "ended-root",
                    runId: "ended-root-run",
                    foregroundState: "completed",
                    endedAt: 150
                ),
                "ended-child": record(
                    sessionId: "ended-child",
                    runId: "ended-child-run",
                    foregroundState: "completed",
                    endedAt: 160
                ),
                "live-codex": record(
                    sessionId: "live-codex",
                    runId: "live-codex-run",
                    foregroundState: "idle"
                ),
            ],
        ]
        let claudeStore: [String: Any] = [
            "version": 2,
            "sessions": [
                "live-claude": record(
                    sessionId: "live-claude",
                    runId: "live-claude-run",
                    foregroundState: "working"
                ),
            ],
        ]
        try JSONSerialization.data(withJSONObject: codexStore, options: [.sortedKeys])
            .write(to: root.appendingPathComponent("codex-hook-sessions.json"), options: .atomic)
        try JSONSerialization.data(withJSONObject: claudeStore, options: [.sortedKeys])
            .write(to: root.appendingPathComponent("claude-hook-sessions.json"), options: .atomic)

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_RUNTIME_ID"] = "current-runtime"

        for command in [["agents", "tree", "--json"], ["agents", "list", "--json"]] {
            let result = runProcess(
                executablePath: cliPath,
                arguments: command,
                environment: environment,
                timeout: 5
            )
            #expect(!result.timedOut, Comment(rawValue: result.stdout))
            #expect(result.status == 0, Comment(rawValue: result.stdout))
            let output = try #require(
                JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
            )
            let rows = (output["nodes"] as? [[String: Any]]) ?? (output["sessions"] as? [[String: Any]])
            let sessionIds = Set(try #require(rows).compactMap { $0["session_id"] as? String })
            #expect(sessionIds == ["live-claude", "live-codex"], Comment(rawValue: result.stdout))
        }

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
        #expect(Set(historyNodes.compactMap { $0["session_id"] as? String }) == [
            "ended-root", "ended-child", "live-claude", "live-codex",
        ])
    }

    @Test func agentsTreeKeepsDistinctSessionsThatShareAProcessGeneration() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agents-shared-process-run-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        func writeStore(provider: String, sessionId: String) throws {
            let runtime: [String: Any] = ["id": "current-runtime"]
            let store: [String: Any] = [
                "version": 2,
                "sessions": [
                    sessionId: [
                        "sessionId": sessionId,
                        "workspaceId": "workspace",
                        "surfaceId": "surface-\(provider)",
                        "runId": "pid:4242@100",
                        "activeRunId": "pid:4242@100",
                        "restoreAuthority": true,
                        "cmuxRuntime": runtime,
                        "runs": [[
                            "runId": "pid:4242@100",
                            "pid": 4242,
                            "processStartedAt": 100.0,
                            "restoreAuthority": true,
                            "cmuxRuntime": runtime,
                            "startedAt": 100.0,
                            "updatedAt": 200.0,
                        ]],
                        "startedAt": 100.0,
                        "updatedAt": 200.0,
                    ],
                ],
            ]
            try JSONSerialization.data(withJSONObject: store, options: [.sortedKeys])
                .write(to: root.appendingPathComponent("\(provider)-hook-sessions.json"), options: .atomic)
        }
        try writeStore(provider: "codex", sessionId: "codex-session")
        try writeStore(provider: "kimi", sessionId: "kimi-session")

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_RUNTIME_ID"] = "current-runtime"
        let result = runProcess(
            executablePath: cliPath,
            arguments: ["agents", "tree", "--json"],
            environment: environment,
            timeout: 5
        )

        #expect(!result.timedOut, Comment(rawValue: result.stdout))
        #expect(result.status == 0, Comment(rawValue: result.stdout))
        let output = try #require(
            JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        )
        let nodes = try #require(output["nodes"] as? [[String: Any]])
        #expect(Set(nodes.compactMap { $0["session_id"] as? String }) == ["codex-session", "kimi-session"])
    }

    @Test func agentsTreeNestsAChildThatSortsBeforeItsParent() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agents-child-before-parent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let runtime: [String: Any] = ["id": "current-runtime"]
        func writeStore(
            provider: String,
            sessionId: String,
            runId: String,
            parentRunId: String? = nil,
            parentSessionId: String? = nil,
            relationship: String? = nil,
            restoreAuthority: Bool,
            startedAt: TimeInterval
        ) throws {
            var run: [String: Any] = [
                "runId": runId,
                "restoreAuthority": restoreAuthority,
                "cmuxRuntime": runtime,
                "startedAt": startedAt,
                "updatedAt": 300.0,
            ]
            run["parentRunId"] = parentRunId
            run["parentSessionId"] = parentSessionId
            run["relationship"] = relationship
            let store: [String: Any] = [
                "version": 2,
                "sessions": [
                    sessionId: [
                        "sessionId": sessionId,
                        "workspaceId": "workspace",
                        "surfaceId": "surface",
                        "runId": runId,
                        "activeRunId": runId,
                        "restoreAuthority": restoreAuthority,
                        "cmuxRuntime": runtime,
                        "runs": [run],
                        "startedAt": startedAt,
                        "updatedAt": 300.0,
                    ],
                ],
            ]
            try JSONSerialization.data(withJSONObject: store, options: [.sortedKeys])
                .write(to: root.appendingPathComponent("\(provider)-hook-sessions.json"), options: .atomic)
        }

        // The child deliberately sorts before its parent in the flat node list.
        // Root selection must use composite graph identity so rendering still
        // starts at the parent and preserves the edge.
        try writeStore(
            provider: "claude",
            sessionId: "child-session",
            runId: "child-run",
            parentRunId: "parent-run",
            parentSessionId: "parent-session",
            relationship: "spawned",
            restoreAuthority: false,
            startedAt: 100.0
        )
        try writeStore(
            provider: "codex",
            sessionId: "parent-session",
            runId: "parent-run",
            restoreAuthority: true,
            startedAt: 200.0
        )

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_RUNTIME_ID"] = "current-runtime"
        let result = runProcess(
            executablePath: cliPath,
            arguments: ["agents", "tree"],
            environment: environment,
            timeout: 5
        )

        #expect(!result.timedOut, Comment(rawValue: result.stdout))
        #expect(result.status == 0, Comment(rawValue: result.stdout))
        let lines = result.stdout.split(separator: "\n").map(String.init)
        #expect(lines.count == 2, Comment(rawValue: result.stdout))
        #expect(lines.first?.hasPrefix("codex parent-session") == true, Comment(rawValue: result.stdout))
        #expect(lines.last?.hasPrefix("└── claude child-session") == true, Comment(rawValue: result.stdout))
    }

}
