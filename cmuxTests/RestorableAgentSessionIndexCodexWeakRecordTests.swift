import Foundation
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
        let transcript = root.appendingPathComponent("codex-transcript.jsonl", isDirectory: false)
        try fm.createDirectory(at: worktree, withIntermediateDirectories: true)
        try #"{"type":"event_msg","payload":{"type":"task_complete"}}"#
            .write(to: transcript, atomically: true, encoding: .utf8)

        let ws = UUID()
        let panel = UUID()
        let goodId = "019ef2bd-e6a3-7272-978e-bb375a60ad81"
        let weakId = "019ef6d3-572d-76e3-b5f0-adc4144085fc"
        let missingSourceId = "019ef7f5-c049-7728-82f6-15995b83c40f"
        let nilLaunchId = "019ef91a-6d3d-70e9-bc8b-9a944db28384"
        let weakEnvironmentArgvId = "019ef9f2-5b17-7240-8799-860d1673f7ac"
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
            ]
        )

        let snapshot = try XCTUnwrap(
            RestorableAgentSessionIndex.load(homeDirectory: root.path, fileManager: fm)
                .snapshot(workspaceId: ws, panelId: panel)
        )
        XCTAssertEqual(snapshot.sessionId, goodId)
        XCTAssertEqual(snapshot.workingDirectory, repo.path)
    }

    func testCodexLegacyArgvRecordWithoutSourceIsRestorable() throws {
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

        let snapshot = try XCTUnwrap(
            RestorableAgentSessionIndex.load(homeDirectory: root.path, fileManager: fm)
                .snapshot(workspaceId: ws, panelId: panel)
        )
        XCTAssertEqual(snapshot.sessionId, sessionId)
        XCTAssertEqual(snapshot.workingDirectory, repo.path)
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
        try writeHookStore(
            root: root,
            sessions: [
                sessionId: codexHookRecord(
                    sessionId: sessionId, workspaceId: ws, panelId: panel, cwd: repo.path,
                    transcriptPath: nil, updatedAt: 10,
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
}
