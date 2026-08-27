import Foundation
import CMUXAgentLaunch
import SQLite3
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct RestorableAgentSessionIndexCodexWeakRecordTests {
    @Test
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

        let snapshot = try #require(
            RestorableAgentSessionIndex.load(homeDirectory: root.path, fileManager: fm)
                .snapshot(workspaceId: ws, panelId: panel)
        )
        #expect(snapshot.sessionId == goodId)
        #expect(snapshot.workingDirectory == repo.path)
    }

    @Test
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

        let index = RestorableAgentSessionIndex.load(homeDirectory: root.path, fileManager: fm)
        let snapshot = try #require(
            index.snapshot(workspaceId: ws, panelId: panel)
        )
        #expect(snapshot.sessionId == sessionId)
        #expect(snapshot.workingDirectory == repo.path)
    }

    @Test
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

        let snapshot = try #require(
            RestorableAgentSessionIndex.load(homeDirectory: root.path, fileManager: fm)
                .snapshot(workspaceId: ws, panelId: panel)
        )
        #expect(snapshot.sessionId == sessionId)
        #expect(snapshot.workingDirectory == repo.path)
    }

    @Test
    func testCodexRestorableChildWithoutDurableCheckpointDoesNotReplaceParent() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-codex-child-without-rollout-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        let codexHome = root.appendingPathComponent(".codex", isDirectory: true)
        try fm.createDirectory(at: repo, withIntermediateDirectories: true)
        try fm.createDirectory(
            at: codexHome.appendingPathComponent("sessions/2026/08/26", isDirectory: true),
            withIntermediateDirectories: true
        )

        let parentID = "019ff98a-d827-7831-960d-fd9bdf7d54e2"
        let childID = "01a03bc1-7649-7ec3-bdf7-03acf979e086"
        let reviewID = "019ff9a7-d827-7831-960d-fd9bdf7d54e2"
        let parentRollout = codexHome
            .appendingPathComponent("sessions/2026/08/26/rollout-\(parentID).jsonl")
        let reviewRollout = codexHome
            .appendingPathComponent("sessions/2026/08/26/rollout-\(reviewID).jsonl")
        let parentMetadata: [String: Any] = [
            "type": "session_meta",
            "payload": [
                "id": parentID,
                "cwd": repo.path,
                "source": "cli",
                "originator": "codex-tui",
            ],
        ]
        let parentMetadataLine = try JSONSerialization.data(
            withJSONObject: parentMetadata,
            options: [.sortedKeys]
        )
        let parentTranscript = String(decoding: parentMetadataLine, as: UTF8.self)
            + "\n"
            + #"{"type":"event_msg","payload":{"message":"codex thread: 01a03bc1-7649-7ec3-bdf7-03acf979e086"}}"#
            + "\n"
        try parentTranscript.write(to: parentRollout, atomically: true, encoding: .utf8)
        let reviewMetadata: [String: Any] = [
            "type": "session_meta",
            "payload": [
                "id": reviewID,
                "cwd": repo.path,
                "source": ["review": ["parent_thread_id": parentID]],
                "originator": "codex_exec",
            ],
        ]
        try JSONSerialization.data(withJSONObject: reviewMetadata, options: [.sortedKeys])
            .write(to: reviewRollout, options: .atomic)
        try createCodexStateDatabase(at: codexHome.appendingPathComponent("state_5.sqlite"))
        try insertCodexThread(
            at: codexHome.appendingPathComponent("state_5.sqlite"),
            sessionID: parentID,
            rolloutPath: parentRollout.path,
            source: "cli"
        )
        try insertCodexThread(
            at: codexHome.appendingPathComponent("state_5.sqlite"),
            sessionID: reviewID,
            rolloutPath: reviewRollout.path,
            source: "review"
        )

        let ws = UUID()
        let panel = UUID()
        try writeHookStore(
            root: root,
            sessions: [
                parentID: codexHookRecord(
                    sessionId: parentID,
                    workspaceId: ws,
                    panelId: panel,
                    cwd: repo.path,
                    transcriptPath: parentRollout.path,
                    updatedAt: 10,
                    isRestorable: true,
                    launchCommand: [
                        "launcher": "codex",
                        "executablePath": "/usr/local/bin/codex",
                        "arguments": ["/usr/local/bin/codex"],
                        "workingDirectory": repo.path,
                        "environment": ["CODEX_HOME": codexHome.path],
                        "capturedAt": 10,
                        "source": "process",
                    ]
                ),
                // The only trace of this review child is the parent transcript;
                // its requested id is absent from both the index and rollouts.
                childID: codexHookRecord(
                    sessionId: childID,
                    workspaceId: ws,
                    panelId: panel,
                    cwd: repo.path,
                    transcriptPath: parentRollout.path,
                    updatedAt: 20,
                    isRestorable: true,
                    launchCommand: [
                        "launcher": "codex",
                        "executablePath": "/usr/local/bin/codex",
                        "arguments": ["/usr/local/bin/codex"],
                        "workingDirectory": repo.path,
                        "environment": ["CODEX_HOME": codexHome.path],
                        "capturedAt": 20,
                        "source": "environment",
                    ]
                ),
                // A durable review rollout is still not allowed to claim the
                // interactive surface that belongs to the TUI parent.
                reviewID: codexHookRecord(
                    sessionId: reviewID,
                    workspaceId: ws,
                    panelId: panel,
                    cwd: repo.path,
                    transcriptPath: reviewRollout.path,
                    updatedAt: 30,
                    isRestorable: true,
                    launchCommand: [
                        "launcher": "codex",
                        "executablePath": "/usr/local/bin/codex",
                        "arguments": ["/usr/local/bin/codex"],
                        "workingDirectory": repo.path,
                        "environment": ["CODEX_HOME": codexHome.path],
                        "capturedAt": 30,
                        "source": "environment",
                    ]
                ),
            ]
        )

        let snapshot = try #require(
            RestorableAgentSessionIndex.load(homeDirectory: root.path, fileManager: fm)
                .snapshot(workspaceId: ws, panelId: panel)
        )
        #expect(
            snapshot.sessionId == parentID,
            "missing and durable review children must not replace the durable interactive parent"
        )
    }

    @Test
    func testCodexNilHookRecordUsesDurableProvenanceBeforeChoosingSurfaceOwner() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-codex-nil-hook-provenance-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        let codexHome = root.appendingPathComponent(".codex", isDirectory: true)
        try fm.createDirectory(at: repo, withIntermediateDirectories: true)
        try fm.createDirectory(
            at: codexHome.appendingPathComponent("sessions/2026/08/26", isDirectory: true),
            withIntermediateDirectories: true
        )

        let parentID = "019ff98a-d827-7831-960d-fd9bdf7d54e2"
        let childID = "019ff9a1-cbe1-7231-9478-0c55a8c44560"
        let parentRollout = try writeCodexRollout(
            codexHome: codexHome,
            sessionID: parentID,
            source: "cli",
            originator: "codex-tui",
            cwd: repo.path
        )
        let childRollout = try writeCodexRollout(
            codexHome: codexHome,
            sessionID: childID,
            source: "review",
            originator: "codex_exec",
            cwd: repo.path
        )
        let databaseURL = codexHome.appendingPathComponent("state_5.sqlite")
        try createCodexStateDatabase(at: databaseURL)
        try insertCodexThread(
            at: databaseURL,
            sessionID: parentID,
            rolloutPath: parentRollout.path,
            source: "cli"
        )
        try insertCodexThread(
            at: databaseURL,
            sessionID: childID,
            rolloutPath: childRollout.path,
            source: "review"
        )

        let ws = UUID()
        let panel = UUID()
        let launchCommand: [String: Any] = [
            "launcher": "codex",
            "arguments": ["/usr/local/bin/codex"],
            "workingDirectory": repo.path,
            "environment": ["CODEX_HOME": codexHome.path],
            "source": "environment",
        ]
        try writeHookStore(
            root: root,
            sessions: [
                parentID: codexHookRecord(
                    sessionId: parentID,
                    workspaceId: ws,
                    panelId: panel,
                    cwd: repo.path,
                    transcriptPath: parentRollout.path,
                    updatedAt: 10,
                    launchCommand: launchCommand
                ),
                childID: codexHookRecord(
                    sessionId: childID,
                    workspaceId: ws,
                    panelId: panel,
                    cwd: repo.path,
                    transcriptPath: childRollout.path,
                    updatedAt: 20,
                    launchCommand: launchCommand
                ),
            ]
        )

        let index = RestorableAgentSessionIndex.load(homeDirectory: root.path, fileManager: fm)
        let snapshot = try #require(
            index.snapshot(workspaceId: ws, panelId: panel)
        )
        #expect(
            snapshot.sessionId == parentID,
            "a nil normal hook record for a review child must not replace the TUI parent"
        )
        #expect(!index.isComplete(forPanelId: panel))
    }

    @Test
    func testCodexOversizedStoreKeepsUnrelatedOwnerComplete() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-codex-oversized-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        let codexHome = root.appendingPathComponent(".codex", isDirectory: true)
        try fm.createDirectory(at: repo, withIntermediateDirectories: true)
        try fm.createDirectory(
            at: codexHome.appendingPathComponent("sessions/2026/08/26", isDirectory: true),
            withIntermediateDirectories: true
        )

        let ownerID = "019ff9b0-cbe1-7231-9478-0c55a8c44560"
        let ownerWorkspace = UUID()
        let ownerPanel = UUID()
        let ownerRollout = try writeCodexRollout(
            codexHome: codexHome,
            sessionID: ownerID,
            source: "cli",
            originator: "codex-tui",
            cwd: repo.path
        )
        let databaseURL = codexHome.appendingPathComponent("state_5.sqlite")
        try createCodexStateDatabase(at: databaseURL)
        try insertCodexThread(
            at: databaseURL,
            sessionID: ownerID,
            rolloutPath: ownerRollout.path,
            source: "cli"
        )

        var sessions: [String: [String: Any]] = [
            ownerID: codexHookRecord(
                sessionId: ownerID,
                workspaceId: ownerWorkspace,
                panelId: ownerPanel,
                cwd: repo.path,
                transcriptPath: ownerRollout.path,
                updatedAt: 10_000,
                launchCommand: [
                    "launcher": "codex",
                    "arguments": ["/usr/local/bin/codex"],
                    "workingDirectory": repo.path,
                    "environment": ["CODEX_HOME": codexHome.path],
                    "source": "environment",
                ]
            ),
        ]
        let retainedNoiseCount = CodexSessionResumeVerificationLimits.maximumBatchRequests
        for index in 0..<retainedNoiseCount {
            let sessionID = "noise-\(index)"
            sessions[sessionID] = codexHookRecord(
                sessionId: sessionID,
                workspaceId: ownerWorkspace,
                panelId: UUID(),
                cwd: repo.path,
                transcriptPath: nil,
                updatedAt: TimeInterval(index + 1),
                pid: 10_000 + index,
                agentLifecycle: "running",
                launchCommand: nil
            )
        }
        let omittedWorkspace = ownerWorkspace
        let omittedPanelA = UUID()
        let omittedPanelB = UUID()
        sessions["omitted-a"] = codexHookRecord(
            sessionId: "omitted-a",
            workspaceId: omittedWorkspace,
            panelId: omittedPanelA,
            cwd: repo.path,
            transcriptPath: nil,
            updatedAt: -1,
            launchCommand: nil
        )
        sessions["omitted-b"] = codexHookRecord(
            sessionId: "omitted-b",
            workspaceId: omittedWorkspace,
            panelId: omittedPanelB,
            cwd: repo.path,
            transcriptPath: nil,
            updatedAt: -2,
            launchCommand: nil
        )
        try writeHookStore(root: root, sessions: sessions)

        let index = RestorableAgentSessionIndex.load(homeDirectory: root.path, fileManager: fm)
        #expect(index.isComplete)
        #expect(index.isComplete(forWorkspaceId: ownerWorkspace, panelId: ownerPanel, kind: "codex"))
        #expect(!index.isComplete(forPanelId: omittedPanelA, kind: "codex"))
        #expect(!index.isComplete(forPanelId: omittedPanelB, kind: "codex"))
        #expect(index.isComplete(forPanelId: UUID(), kind: "claude"))
        let snapshot = try #require(
            index.snapshot(workspaceId: ownerWorkspace, panelId: ownerPanel)
        )
        #expect(snapshot.sessionId == ownerID)
    }

    private func codexHookRecord(
        sessionId: String,
        workspaceId: UUID,
        panelId: UUID,
        cwd: String,
        transcriptPath: String?,
        updatedAt: TimeInterval,
        pid: Int? = nil,
        agentLifecycle: String? = nil,
        isRestorable: Bool? = nil,
        launchCommand: [String: Any]?
    ) -> [String: Any] {
        var record: [String: Any] = [
            "sessionId": sessionId,
            "workspaceId": workspaceId.uuidString,
            "surfaceId": panelId.uuidString,
            "cwd": cwd,
            "updatedAt": updatedAt,
        ]
        if let pid {
            record["pid"] = pid
        } else {
            record["pid"] = NSNull()
        }
        if let agentLifecycle {
            record["agentLifecycle"] = agentLifecycle
        }
        if let transcriptPath { record["transcriptPath"] = transcriptPath }
        if let isRestorable { record["isRestorable"] = isRestorable }
        if let launchCommand { record["launchCommand"] = launchCommand }
        return record
    }

    private func writeCodexRollout(
        codexHome: URL,
        sessionID: String,
        source: String,
        originator: String,
        cwd: String
    ) throws -> URL {
        let path = codexHome
            .appendingPathComponent("sessions/2026/08/26/rollout-\(sessionID).jsonl")
        let metadata: [String: Any] = [
            "type": "session_meta",
            "payload": [
                "id": sessionID,
                "cwd": cwd,
                "source": source,
                "originator": originator,
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
        try data.write(to: path, options: .atomic)
        return path
    }

    private func createCodexStateDatabase(at url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            sqlite3_close(database)
            throw NSError(domain: "CodexIndexFixture", code: 1)
        }
        defer { sqlite3_close(database) }
        let schema = "CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT NOT NULL, source TEXT, thread_source TEXT)"
        guard sqlite3_exec(database, schema, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "CodexIndexFixture", code: 2)
        }
    }

    private func insertCodexThread(
        at url: URL,
        sessionID: String,
        rolloutPath: String,
        source: String
    ) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            sqlite3_close(database)
            throw NSError(domain: "CodexIndexFixture", code: 3)
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "INSERT INTO threads (id, rollout_path, source, thread_source) VALUES (?, ?, ?, ?)",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            throw NSError(domain: "CodexIndexFixture", code: 4)
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(statement, 1, sessionID, -1, transient) == SQLITE_OK,
              sqlite3_bind_text(statement, 2, rolloutPath, -1, transient) == SQLITE_OK,
              sqlite3_bind_text(statement, 3, source, -1, transient) == SQLITE_OK,
              sqlite3_bind_text(statement, 4, source, -1, transient) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_DONE else {
            throw NSError(domain: "CodexIndexFixture", code: 5)
        }
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
