import Foundation
import Testing

extension CMUXCLIErrorOutputRegressionTests {
    private func withAutoNamingSessionStore<T>(_ body: (ClaudeHookSessionStore) throws -> T) throws -> T {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-auto-naming-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("sessions.json", isDirectory: false).path
        let store = ClaudeHookSessionStore(processEnv: ["CMUX_CLAUDE_HOOK_STATE_PATH": path])
        return try body(store)
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

    @Test func staleAutoNamingPassCannotFinishOverNewerPass() throws {
        let engine = AutoNamingEngine()
        let config = engine.config
        try withAutoNamingSessionStore { store in
            let sessionId = "session-\(UUID().uuidString)"
            let first = try store.beginAutoNaming(
                sessionId: sessionId,
                workspaceId: "workspace",
                surfaceId: "surface",
                transcriptLineCount: 100,
                now: Date(timeIntervalSince1970: 1_000),
                engine: engine
            )
            let second = try store.beginAutoNaming(
                sessionId: sessionId,
                workspaceId: "workspace",
                surfaceId: "surface",
                transcriptLineCount: 200,
                now: Date(timeIntervalSince1970: 1_000 + config.inFlightExpiry + 1),
                engine: engine
            )

            #expect(first.passId != nil)
            #expect(second.passId != nil)
            #expect(first.passId != second.passId)
            let staleFinished = try store.finishAutoNaming(
                sessionId: sessionId,
                passId: first.passId,
                appliedTitle: "Old title",
                baselineLineCount: 100,
                now: Date(timeIntervalSince1970: 2_000)
            )
            #expect(!staleFinished)
            let freshFinished = try store.finishAutoNaming(
                sessionId: sessionId,
                passId: second.passId,
                appliedTitle: "New title",
                baselineLineCount: 200,
                now: Date(timeIntervalSince1970: 2_001)
            )
            #expect(freshFinished)
            let record = try #require(store.lookup(sessionId: sessionId))
            #expect(record.autoNameLastTitle == "New title")
            #expect(record.autoNameLastLineCount == 200)
        }
    }

    @Test func hookMessageCacheDedupesByContentAndStaysBounded() throws {
        try withAutoNamingSessionStore { store in
            let sessionId = "session-\(UUID().uuidString)"
            let duplicateMessages = [
                AutoNamingTranscriptMessage(role: "user", text: "Fix login"),
                AutoNamingTranscriptMessage(role: "assistant", text: "I will inspect auth."),
                AutoNamingTranscriptMessage(role: "user", text: "Fix login"),
            ]
            _ = try store.recordPromptSubmit(
                sessionId: sessionId,
                workspaceId: "workspace",
                surfaceId: "surface",
                cwd: nil,
                pid: nil,
                launchCommand: nil,
                autoNameMessages: duplicateMessages
            )
            _ = try store.recordPromptSubmit(
                sessionId: sessionId,
                workspaceId: "workspace",
                surfaceId: "surface",
                cwd: nil,
                pid: nil,
                launchCommand: nil,
                autoNameMessages: duplicateMessages
            )
            var snapshot = try store.autoNamingRecentMessagesSnapshot(sessionId: sessionId)
            #expect(snapshot.messages == Array(duplicateMessages.prefix(2)))
            #expect(snapshot.totalMessageCount == 6)

            let uniqueMessages = (0..<30).map {
                AutoNamingTranscriptMessage(role: "user", text: "Unique request \($0)")
            }
            _ = try store.recordPromptSubmit(
                sessionId: sessionId,
                workspaceId: "workspace",
                surfaceId: "surface",
                cwd: nil,
                pid: nil,
                launchCommand: nil,
                autoNameMessages: uniqueMessages
            )
            snapshot = try store.autoNamingRecentMessagesSnapshot(sessionId: sessionId)
            #expect(snapshot.messages.count == 24)
            #expect(snapshot.totalMessageCount == 36)
            #expect(snapshot.messages.last?.text == "Unique request 29")
        }
    }
}
