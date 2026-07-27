import Foundation
import SQLite3
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class RestorableAgentSessionIndexCodexWeakRecordTests: XCTestCase {
    func testCodexWeakEnvironmentOnlyRecordDoesNotOverrideTranscriptBackedSession() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-codex-weak-env-restore-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let repo = root.appendingPathComponent("cmuxterm-hq", isDirectory: true)
        let worktree = repo.appendingPathComponent("worktrees/task-shift-tab-submit-actions", isDirectory: true)
        let goodId = "019ef2bd-e6a3-7272-978e-bb375a60ad81"
        let transcript = root.appendingPathComponent(
            "rollout-2026-07-16T19-29-41-\(goodId).jsonl",
            isDirectory: false
        )
        try fm.createDirectory(at: worktree, withIntermediateDirectories: true)
        try #"{"type":"session_meta","payload":{"id":"\#(goodId)"}}"#
            .write(to: transcript, atomically: true, encoding: .utf8)

        let ws = UUID()
        let panel = UUID()
        let weakId = "019ef6d3-572d-76e3-b5f0-adc4144085fc"
        let missingSourceId = "019ef7f5-c049-7728-82f6-15995b83c40f"
        let nilLaunchId = "019ef91a-6d3d-70e9-bc8b-9a944db28384"
        let weakEnvironmentArgvId = "019ef9f2-5b17-7240-8799-860d1673f7ac"
        let ephemeralReviewId = "019f6dbc-5095-74f3-8035-ab8cdf772bb7"
        try writeHookStore(
            root: root,
            sessions: [
                goodId: codexHookRecord(
                    sessionId: goodId, workspaceId: ws, panelId: panel, cwd: repo.path,
                    transcriptPath: transcript.path, updatedAt: 10,
                    launchCommand: [
                        "launcher": "codex",
                        "executablePath": "/usr/local/bin/codex",
                        "arguments": ["/usr/local/bin/codex", "--yolo"],
                        "workingDirectory": repo.path,
                        "capturedAt": 10,
                        "source": "process",
                    ]
                ),
                weakId: codexHookRecord(
                    sessionId: weakId, workspaceId: ws, panelId: panel, cwd: worktree.path,
                    transcriptPath: nil, updatedAt: 20,
                    launchCommand: [
                        "launcher": "codex",
                        "arguments": [],
                        "workingDirectory": worktree.path,
                        "environment": [
                            "ANTHROPIC_BASE_URL": "http://subrouter-team:31415",
                            "CLAUDE_CONFIG_DIR": root.appendingPathComponent(".codex-accounts/claude/work").path,
                        ],
                        "capturedAt": 20,
                        "source": "environment",
                    ]
                ),
                missingSourceId: codexHookRecord(
                    sessionId: missingSourceId, workspaceId: ws, panelId: panel, cwd: worktree.path,
                    transcriptPath: nil, updatedAt: 5,
                    launchCommand: [
                        "launcher": "codex",
                        "executablePath": "/usr/local/bin/codex",
                        "arguments": ["/usr/local/bin/codex", "--yolo"],
                        "workingDirectory": worktree.path,
                        "capturedAt": 40,
                    ]
                ),
                nilLaunchId: codexHookRecord(
                    sessionId: nilLaunchId, workspaceId: ws, panelId: panel, cwd: worktree.path,
                    transcriptPath: nil, updatedAt: 50,
                    launchCommand: nil
                ),
                weakEnvironmentArgvId: codexHookRecord(
                    sessionId: weakEnvironmentArgvId, workspaceId: ws, panelId: panel, cwd: worktree.path,
                    transcriptPath: nil, updatedAt: 60,
                    launchCommand: [
                        "launcher": "codex",
                        "executablePath": "/usr/local/bin/codex",
                        "arguments": ["/usr/local/bin/codex", "--yolo"],
                        "workingDirectory": worktree.path,
                        "environment": [
                            "ANTHROPIC_BASE_URL": "http://subrouter-team:31415",
                            "CLAUDE_CONFIG_DIR": root.appendingPathComponent(".codex-accounts/claude/work").path,
                        ],
                        "capturedAt": 60,
                        "source": "environment",
                    ]
                ),
                ephemeralReviewId: codexHookRecord(
                    sessionId: ephemeralReviewId, workspaceId: ws, panelId: panel, cwd: worktree.path,
                    transcriptPath: nil, updatedAt: 70,
                    launchCommand: [
                        "launcher": "codex",
                        "arguments": [],
                        "workingDirectory": worktree.path,
                        "capturedAt": 70,
                        "source": "default",
                    ]
                ),
            ]
        )

        let snapshot = try XCTUnwrap(
            RestorableAgentSessionIndex.load(homeDirectory: root.path, fileManager: fm)
                .snapshot(workspaceId: ws, panelId: panel)
        )
        XCTAssertEqual(snapshot.sessionId, goodId)
        XCTAssertEqual(snapshot.workingDirectory, repo.path)
        XCTAssertEqual(snapshot.transcriptPath, transcript.path)
    }

    func testCodexLegacyArgvRecordWithoutProviderEvidenceIsNotRestorable() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-codex-legacy-argv-restore-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let repo = root.appendingPathComponent("cmuxterm-hq", isDirectory: true)
        try fm.createDirectory(at: repo, withIntermediateDirectories: true)

        let ws = UUID()
        let panel = UUID()
        let sessionId = "019ef7f5-c049-7728-82f6-15995b83c40f"
        try writeHookStore(
            root: root,
            sessions: [
                sessionId: codexHookRecord(
                    sessionId: sessionId, workspaceId: ws, panelId: panel, cwd: repo.path,
                    transcriptPath: nil, updatedAt: 10,
                    launchCommand: [
                        "launcher": "codex",
                        "executablePath": "/usr/local/bin/codex",
                        "arguments": ["/usr/local/bin/codex", "--yolo"],
                        "workingDirectory": repo.path,
                        "capturedAt": 10,
                    ]
                ),
            ]
        )

        XCTAssertNil(
            RestorableAgentSessionIndex.load(homeDirectory: root.path, fileManager: fm)
                .snapshot(workspaceId: ws, panelId: panel)
        )
    }

    func testCodexDefaultLaunchRecordIsRestorable() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-codex-default-restore-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let repo = root.appendingPathComponent("cmuxterm-hq", isDirectory: true)
        try fm.createDirectory(at: repo, withIntermediateDirectories: true)

        let ws = UUID()
        let panel = UUID()
        let sessionId = "019efa74-df8b-71ac-a8ec-a9535e8fdcd5"
        let transcript = root.appendingPathComponent("rollout-2026-07-16T19-29-41-\(sessionId).jsonl")
        try #"{"type":"session_meta","payload":{"id":"\#(sessionId)"}}"#
            .write(to: transcript, atomically: true, encoding: .utf8)
        try writeHookStore(
            root: root,
            sessions: [
                sessionId: codexHookRecord(
                    sessionId: sessionId, workspaceId: ws, panelId: panel, cwd: repo.path,
                    transcriptPath: transcript.path, updatedAt: 10,
                    launchCommand: [
                        "launcher": "codex",
                        "arguments": [],
                        "workingDirectory": repo.path,
                        "capturedAt": 10,
                        "source": "default",
                    ]
                ),
            ]
        )

        let snapshot = try XCTUnwrap(
            RestorableAgentSessionIndex.load(homeDirectory: root.path, fileManager: fm)
                .snapshot(workspaceId: ws, panelId: panel)
        )
        XCTAssertEqual(snapshot.sessionId, sessionId)
        XCTAssertEqual(snapshot.workingDirectory, repo.path)
    }

    func testIndexedCodexSubagentRecordRestoresInteractiveParent() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-codex-subagent-root-restore-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let repo = root.appendingPathComponent("cmuxterm-hq", isDirectory: true)
        let parentSessionId = "019f652f-e1c3-7521-859c-5f57e33b4c80"
        let childSessionId = "019f8c3d-72d0-7d91-8714-4bf5e541cb4d"
        let parentRollout = root.appendingPathComponent("rollout-parent-\(parentSessionId).jsonl")
        let childRollout = root.appendingPathComponent("rollout-child-\(childSessionId).jsonl")
        let workspaceId = UUID()
        let panelId = UUID()

        try fm.createDirectory(at: repo, withIntermediateDirectories: true)
        try #"{"type":"session_meta","payload":{"id":"\#(parentSessionId)","source":"cli"}}"#
            .write(to: parentRollout, atomically: true, encoding: .utf8)
        try #"{"type":"session_meta","payload":{"id":"\#(childSessionId)","session_id":"\#(parentSessionId)","parent_thread_id":"\#(parentSessionId)","source":{"subagent":{"thread_spawn":{"parent_thread_id":"\#(parentSessionId)","depth":1}}}}}"#
            .write(to: childRollout, atomically: true, encoding: .utf8)
        try writeCodexThreadIndex(
            root: root,
            threads: [
                (parentSessionId, parentRollout.path, "user"),
                (childSessionId, childRollout.path, "subagent"),
            ]
        )
        try writeHookStore(
            root: root,
            sessions: [
                childSessionId: codexHookRecord(
                    sessionId: childSessionId,
                    workspaceId: workspaceId,
                    panelId: panelId,
                    cwd: repo.path,
                    transcriptPath: childRollout.path,
                    updatedAt: 10,
                    launchCommand: [
                        "launcher": "codex",
                        "arguments": [],
                        "workingDirectory": repo.path,
                        "capturedAt": 10,
                        "source": "default",
                    ]
                ),
            ]
        )

        let snapshot = try XCTUnwrap(
            RestorableAgentSessionIndex.load(homeDirectory: root.path, fileManager: fm)
                .snapshot(workspaceId: workspaceId, panelId: panelId)
        )
        XCTAssertEqual(snapshot.sessionId, parentSessionId)
        XCTAssertEqual(snapshot.transcriptPath, parentRollout.path)
        let resumeCommand = try XCTUnwrap(snapshot.resumeCommand)
        XCTAssertTrue(resumeCommand.contains(parentSessionId), resumeCommand)
        XCTAssertFalse(resumeCommand.contains(childSessionId), resumeCommand)
    }

    private func codexHookRecord(
        sessionId: String,
        workspaceId: UUID,
        panelId: UUID,
        cwd: String,
        transcriptPath: String?,
        updatedAt: TimeInterval,
        launchCommand: [String: Any]?
    ) -> [String: Any] {
        var record: [String: Any] = [
            "sessionId": sessionId,
            "workspaceId": workspaceId.uuidString,
            "surfaceId": panelId.uuidString,
            "cwd": cwd,
            "pid": NSNull(),
            "updatedAt": updatedAt,
        ]
        if let transcriptPath { record["transcriptPath"] = transcriptPath }
        if let launchCommand { record["launchCommand"] = launchCommand }
        return record
    }

    private func writeHookStore(root: URL, sessions: [String: [String: Any]]) throws {
        let stateDir = root.appendingPathComponent(".cmuxterm", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: ["version": 1, "sessions": sessions],
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: stateDir.appendingPathComponent("codex-hook-sessions.json"), options: .atomic)
    }

    private func writeCodexThreadIndex(
        root: URL,
        threads: [(id: String, rolloutPath: String, source: String)]
    ) throws {
        let codexHome = root.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        var database: OpaquePointer?
        guard sqlite3_open(codexHome.appendingPathComponent("state_5.sqlite").path, &database) == SQLITE_OK,
              let database else {
            throw NSError(domain: "CodexThreadIndexFixture", code: 1)
        }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(
            database,
            "CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT NOT NULL, thread_source TEXT)",
            nil,
            nil,
            nil
        ) == SQLITE_OK else {
            throw NSError(domain: "CodexThreadIndexFixture", code: 2)
        }

        let transient = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
        for thread in threads {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                database,
                "INSERT INTO threads (id, rollout_path, thread_source) VALUES (?, ?, ?)",
                -1,
                &statement,
                nil
            ) == SQLITE_OK, let statement else {
                throw NSError(domain: "CodexThreadIndexFixture", code: 3)
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, thread.id, -1, transient)
            sqlite3_bind_text(statement, 2, thread.rolloutPath, -1, transient)
            sqlite3_bind_text(statement, 3, thread.source, -1, transient)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw NSError(domain: "CodexThreadIndexFixture", code: 4)
            }
        }
    }
}
