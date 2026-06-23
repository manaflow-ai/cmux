import Foundation
import Testing

extension CMUXCLIErrorOutputRegressionTests {
    @Test func testSessionsListDefaultOmitsStaleCodexRowsWithoutTranscript() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sessions-list-\(UUID().uuidString)", isDirectory: true)
        let stateDir = root.appendingPathComponent("state", isDirectory: true)
        let codexHome = root.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let activeSessionId = "019ef6ac-e358-7dd2-902d-8492fa0ba2bb"
        let staleSessionId = "019ef5c3-e0a1-7473-a6bf-48bbcf234de0"
        let store: [String: Any] = [
            "version": 1,
            "activeSessionsByWorkspace": [
                "workspace-active": [
                    "sessionId": activeSessionId,
                    "updatedAt": 1_782_255_000.0
                ]
            ],
            "activeSessionsBySurface": [
                "surface-active": [
                    "sessionId": activeSessionId,
                    "updatedAt": 1_782_255_000.0
                ]
            ],
            "sessions": [
                activeSessionId: [
                    "sessionId": activeSessionId,
                    "workspaceId": "workspace-active",
                    "surfaceId": "surface-active",
                    "cwd": "/tmp/cmux/active",
                    "startedAt": 1_782_254_900.0,
                    "updatedAt": 1_782_255_000.0
                ],
                staleSessionId: [
                    "sessionId": staleSessionId,
                    "workspaceId": "workspace-stale",
                    "surfaceId": "surface-stale",
                    "cwd": "/tmp/cmux/stale",
                    "startedAt": 1_782_254_950.0,
                    "updatedAt": 1_782_255_010.0
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: stateDir.appendingPathComponent("codex-hook-sessions.json"), options: .atomic)

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = stateDir.path
        environment["CODEX_HOME"] = codexHome.path

        let defaultResult = runProcess(
            executablePath: cliPath,
            arguments: ["sessions", "list", "--agent", "codex", "--json"],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(defaultResult.timedOut, defaultResult.stdout)
        XCTAssertEqual(defaultResult.status, 0, defaultResult.stdout)
        let defaultOutputData = try XCTUnwrap(defaultResult.stdout.data(using: .utf8))
        let defaultObject = try XCTUnwrap(JSONSerialization.jsonObject(with: defaultOutputData) as? [String: Any])
        XCTAssertEqual(defaultObject["total_matches"] as? Int, 1)
        let defaultSessions = try XCTUnwrap(defaultObject["sessions"] as? [[String: Any]])
        XCTAssertEqual(defaultSessions.count, 1)
        XCTAssertEqual(defaultSessions.first?["session_id"] as? String, activeSessionId)

        let allResult = runProcess(
            executablePath: cliPath,
            arguments: ["sessions", "list", "--agent", "codex", "--all", "--json"],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(allResult.timedOut, allResult.stdout)
        XCTAssertEqual(allResult.status, 0, allResult.stdout)
        let allOutputData = try XCTUnwrap(allResult.stdout.data(using: .utf8))
        let allObject = try XCTUnwrap(JSONSerialization.jsonObject(with: allOutputData) as? [String: Any])
        XCTAssertEqual(allObject["total_matches"] as? Int, 2)
        let allSessions = try XCTUnwrap(allObject["sessions"] as? [[String: Any]])
        XCTAssertEqual(Set(allSessions.compactMap { $0["session_id"] as? String }), [activeSessionId, staleSessionId])
    }

    @Test func testSessionsListReportsCodexIdsMissingFromCodexStore() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sessions-list-\(UUID().uuidString)", isDirectory: true)
        let stateDir = root.appendingPathComponent("state", isDirectory: true)
        let codexHome = root.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionId = "019ee74a-3c84-7de3-84f1-ece32f4ecfbb"
        let workspaceId = "workspace-debug"
        let surfaceId = "surface-debug"
        let store: [String: Any] = [
            "version": 1,
            "activeSessionsByWorkspace": [
                workspaceId: [
                    "sessionId": sessionId,
                    "updatedAt": 1_781_996_867.0
                ]
            ],
            "activeSessionsBySurface": [
                surfaceId: [
                    "sessionId": sessionId,
                    "updatedAt": 1_781_996_867.0
                ]
            ],
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": workspaceId,
                    "surfaceId": surfaceId,
                    "cwd": "/tmp/cmux/debug",
                    "startedAt": 1_781_996_800.0,
                    "updatedAt": 1_781_996_867.0
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: stateDir.appendingPathComponent("codex-hook-sessions.json"), options: .atomic)

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = stateDir.path
        environment["CODEX_HOME"] = codexHome.path

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["sessions", "list", "--agent", "codex", "--session", sessionId, "--json"],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertEqual(result.status, 0, result.stdout)
        let outputData = try XCTUnwrap(result.stdout.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: outputData) as? [String: Any])
        XCTAssertEqual(object["total_matches"] as? Int, 1)
        let sessions = try XCTUnwrap(object["sessions"] as? [[String: Any]])
        let session = try XCTUnwrap(sessions.first)
        XCTAssertEqual(session["session_id"] as? String, sessionId)
        XCTAssertEqual(session["workspace_id"] as? String, workspaceId)
        XCTAssertEqual(session["surface_id"] as? String, surfaceId)
        XCTAssertEqual(session["active_for_workspace"] as? Bool, true)
        XCTAssertEqual(session["active_for_surface"] as? Bool, true)
        XCTAssertEqual(session["codex_indexed"] as? Bool, false)
        XCTAssertEqual(session["codex_transcript_found"] as? Bool, false)
        XCTAssertEqual(session["session_home"] as? String, codexHome.path)
    }
}
