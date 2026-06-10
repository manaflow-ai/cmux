import Foundation
import XCTest
import Bonsplit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Restorable agent session index and hook store lifecycle
extension AgentHibernationTests {
    func testSessionIndexLoadsAgentLifecycleFromHookStore() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-hibernation-index-\(UUID().uuidString)", isDirectory: true)
        let storeURL = RestorableAgentKind.codex.hookStoreFileURL(homeDirectory: home.path)
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let workspaceId = UUID()
        let panelId = UUID()
        let sessionId = "codex-hibernation-lifecycle"
        let jsonObject: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": workspaceId.uuidString,
                    "surfaceId": panelId.uuidString,
                    "cwd": "/tmp/repo",
                    "agentLifecycle": "idle",
                    "updatedAt": Date().timeIntervalSince1970,
                    "launchCommand": [
                        "launcher": "codex",
                        "executablePath": "/usr/local/bin/codex",
                        "arguments": ["/usr/local/bin/codex"],
                        "workingDirectory": "/tmp/repo",
                    ],
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted])
        try data.write(to: storeURL, options: .atomic)

        let index = RestorableAgentSessionIndex.load(homeDirectory: home.path)
        XCTAssertEqual(index.lifecycle(workspaceId: workspaceId, panelId: panelId), .idle)
        XCTAssertEqual(index.snapshot(workspaceId: workspaceId, panelId: panelId)?.sessionId, sessionId)
    }

    func testSessionIndexUsesLiveHookPIDAsProcessID() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-hibernation-live-hook-pid-\(UUID().uuidString)", isDirectory: true)
        let storeURL = RestorableAgentKind.codex.hookStoreFileURL(homeDirectory: home.path)
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let workspaceId = UUID()
        let panelId = UUID()
        let pid = 12_345
        let sessionId = "codex-live-hook-pid"
        let jsonObject: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": workspaceId.uuidString,
                    "surfaceId": panelId.uuidString,
                    "cwd": "/tmp/repo",
                    "pid": pid,
                    "agentLifecycle": "idle",
                    "updatedAt": Date().timeIntervalSince1970,
                    "launchCommand": [
                        "launcher": "codex",
                        "executablePath": "/bin/sleep",
                        "arguments": ["/bin/sleep", "30"],
                        "workingDirectory": "/tmp/repo",
                    ],
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted])
        try data.write(to: storeURL, options: .atomic)

        let index = RestorableAgentSessionIndex.load(
            homeDirectory: home.path,
            fileManager: .default,
            registry: CmuxVaultAgentRegistry(registrations: []),
            detectedSnapshots: [:],
            processArgumentsProvider: { requestedPID in
                requestedPID == pid
                    ? CmuxTopProcessArguments(
                        arguments: ["/bin/sleep", "30"],
                        environment: [
                            "CMUX_WORKSPACE_ID": workspaceId.uuidString,
                            "CMUX_SURFACE_ID": panelId.uuidString,
                            "CMUX_AGENT_LAUNCH_KIND": RestorableAgentKind.codex.rawValue,
                        ]
                    )
                    : nil
            }
        )

        XCTAssertEqual(index.lifecycle(workspaceId: workspaceId, panelId: panelId), .idle)
        XCTAssertEqual(index.processIDs(workspaceId: workspaceId, panelId: panelId), [pid])
        XCTAssertTrue(index.hasLiveProcess(workspaceId: workspaceId, panelId: panelId))
    }

    func testSessionIndexAcceptsNodeBackedClaudeProcessAsLiveHookPID() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-hibernation-claude-node-pid-\(UUID().uuidString)", isDirectory: true)
        let storeURL = RestorableAgentKind.claude.hookStoreFileURL(homeDirectory: home.path)
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let workspaceId = UUID()
        let panelId = UUID()
        let pid = 23_456
        let sessionId = "claude-node-live-hook-pid"
        let transcriptURL = home
            .appendingPathComponent(".claude/projects/-tmp-repo", isDirectory: true)
            .appendingPathComponent("\(sessionId).jsonl")
        try FileManager.default.createDirectory(
            at: transcriptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try #"{"type":"summary","summary":"Claude session"}"#.write(
            to: transcriptURL,
            atomically: true,
            encoding: .utf8
        )

        let jsonObject: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": workspaceId.uuidString,
                    "surfaceId": panelId.uuidString,
                    "cwd": "/tmp/repo",
                    "transcriptPath": transcriptURL.path,
                    "pid": pid,
                    "agentLifecycle": "idle",
                    "updatedAt": Date().timeIntervalSince1970,
                    "launchCommand": [
                        "launcher": "claude",
                        "executablePath": "/opt/homebrew/bin/claude",
                        "arguments": ["/opt/homebrew/bin/claude"],
                        "workingDirectory": "/tmp/repo",
                    ],
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted])
        try data.write(to: storeURL, options: .atomic)

        let index = RestorableAgentSessionIndex.load(
            homeDirectory: home.path,
            fileManager: .default,
            registry: CmuxVaultAgentRegistry(registrations: []),
            detectedSnapshots: [:],
            processArgumentsProvider: { requestedPID in
                requestedPID == pid
                    ? CmuxTopProcessArguments(
                        arguments: [
                            "/opt/homebrew/Cellar/node/24.0.0/bin/node",
                            "/Users/example/.claude/local/node_modules/@anthropic-ai/claude-code/cli.js",
                        ],
                        environment: [
                            "CMUX_WORKSPACE_ID": workspaceId.uuidString,
                            "CMUX_SURFACE_ID": panelId.uuidString,
                            "CMUX_AGENT_LAUNCH_KIND": RestorableAgentKind.claude.rawValue,
                        ]
                    )
                    : nil
            }
        )

        XCTAssertEqual(index.lifecycle(workspaceId: workspaceId, panelId: panelId), .idle)
        XCTAssertEqual(index.processIDs(workspaceId: workspaceId, panelId: panelId), [pid])
        XCTAssertTrue(index.hasLiveProcess(workspaceId: workspaceId, panelId: panelId))
    }

    func testLiveProcessScopeMatchingAcceptsLegacyEnvironmentKeys() throws {
        let workspaceId = UUID()
        let panelId = UUID()
        let process = CmuxTopProcessArguments(
            arguments: ["/usr/bin/codex"],
            environment: [
                "CMUX_TAB_ID": workspaceId.uuidString,
                "CMUX_PANEL_ID": panelId.uuidString,
            ]
        )

        XCTAssertTrue(process.matchesCMUXScope(workspaceId: workspaceId, surfaceId: panelId))
        XCTAssertFalse(process.matchesCMUXScope(workspaceId: UUID(), surfaceId: panelId))
        XCTAssertFalse(process.matchesCMUXScope(workspaceId: workspaceId, surfaceId: UUID()))
    }

    func testSessionIndexDoesNotDropHookStoreForUnknownAgentLifecycle() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-hibernation-index-\(UUID().uuidString)", isDirectory: true)
        let storeURL = RestorableAgentKind.codex.hookStoreFileURL(homeDirectory: home.path)
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let workspaceId = UUID()
        let panelId = UUID()
        let sessionId = "codex-hibernation-future-lifecycle"
        let jsonObject: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": workspaceId.uuidString,
                    "surfaceId": panelId.uuidString,
                    "cwd": "/tmp/repo",
                    "agentLifecycle": "paused",
                    "updatedAt": Date().timeIntervalSince1970,
                    "launchCommand": [
                        "launcher": "codex",
                        "executablePath": "/usr/local/bin/codex",
                        "arguments": ["/usr/local/bin/codex"],
                        "workingDirectory": "/tmp/repo",
                    ],
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted])
        try data.write(to: storeURL, options: .atomic)

        let index = RestorableAgentSessionIndex.load(homeDirectory: home.path)
        XCTAssertEqual(index.lifecycle(workspaceId: workspaceId, panelId: panelId), .unknown)
        XCTAssertEqual(index.snapshot(workspaceId: workspaceId, panelId: panelId)?.sessionId, sessionId)
    }

    func testProcessDetectedSnapshotPreservesMatchingHookLifecycleWithoutRefreshingActivity() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-hibernation-detected-\(UUID().uuidString)", isDirectory: true)
        let storeURL = RestorableAgentKind.opencode.hookStoreFileURL(homeDirectory: home.path)
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let workspaceId = UUID()
        let panelId = UUID()
        let sessionId = "opencode-detected-lifecycle"
        let hookUpdatedAt: TimeInterval = 123
        let jsonObject: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": workspaceId.uuidString,
                    "surfaceId": panelId.uuidString,
                    "cwd": "/tmp/repo",
                    "agentLifecycle": "idle",
                    "updatedAt": hookUpdatedAt,
                    "launchCommand": [
                        "launcher": "opencode",
                        "executablePath": "/usr/local/bin/opencode",
                        "arguments": ["/usr/local/bin/opencode"],
                        "workingDirectory": "/tmp/repo",
                    ],
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted])
        try data.write(to: storeURL, options: .atomic)

        let key = RestorableAgentSessionIndex.PanelKey(workspaceId: workspaceId, panelId: panelId)
        let detectedSnapshot = SessionRestorableAgentSnapshot(
            kind: .opencode,
            sessionId: sessionId,
            workingDirectory: "/tmp/repo",
            launchCommand: launch(
                "opencode",
                "/opt/homebrew/bin/opencode",
                arguments: ["/opt/homebrew/bin/opencode", "--session", sessionId],
                cwd: "/tmp/repo"
            )
        )

        let index = RestorableAgentSessionIndex.load(
            homeDirectory: home.path,
            fileManager: .default,
            registry: CmuxVaultAgentRegistry(registrations: []),
            detectedSnapshots: [key: (snapshot: detectedSnapshot, updatedAt: 999, processIDs: [123, 456])]
        )

        XCTAssertEqual(index.lifecycle(workspaceId: workspaceId, panelId: panelId), .idle)
        XCTAssertEqual(index.updatedAt(workspaceId: workspaceId, panelId: panelId), hookUpdatedAt)
        XCTAssertEqual(index.processIDs(workspaceId: workspaceId, panelId: panelId), [123, 456])
        XCTAssertTrue(index.hasLiveProcess(workspaceId: workspaceId, panelId: panelId))
        XCTAssertEqual(index.snapshot(workspaceId: workspaceId, panelId: panelId)?.launchCommand?.executablePath, "/opt/homebrew/bin/opencode")
    }

    func testProcessDetectedSnapshotPreservesMatchingHookLifecycleWhenHookPIDIsStale() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-hibernation-stale-pid-\(UUID().uuidString)", isDirectory: true)
        let storeURL = RestorableAgentKind.opencode.hookStoreFileURL(homeDirectory: home.path)
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let workspaceId = UUID()
        let panelId = UUID()
        let sessionId = "opencode-restored-stale-pid"
        let hookUpdatedAt: TimeInterval = 456
        let jsonObject: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": workspaceId.uuidString,
                    "surfaceId": panelId.uuidString,
                    "cwd": "/tmp/repo",
                    "pid": 999_999,
                    "agentLifecycle": "idle",
                    "updatedAt": hookUpdatedAt,
                    "launchCommand": [
                        "launcher": "opencode",
                        "executablePath": "/usr/local/bin/opencode",
                        "arguments": ["/usr/local/bin/opencode"],
                        "workingDirectory": "/tmp/repo",
                    ],
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted])
        try data.write(to: storeURL, options: .atomic)

        let key = RestorableAgentSessionIndex.PanelKey(workspaceId: workspaceId, panelId: panelId)
        let detectedSnapshot = SessionRestorableAgentSnapshot(
            kind: .opencode,
            sessionId: sessionId,
            workingDirectory: "/tmp/repo",
            launchCommand: launch(
                "opencode",
                "/opt/homebrew/bin/opencode",
                arguments: ["/opt/homebrew/bin/opencode", "--session", sessionId],
                cwd: "/tmp/repo"
            )
        )

        let index = RestorableAgentSessionIndex.load(
            homeDirectory: home.path,
            fileManager: .default,
            registry: CmuxVaultAgentRegistry(registrations: []),
            detectedSnapshots: [key: (snapshot: detectedSnapshot, updatedAt: 999, processIDs: [321])]
        )

        XCTAssertEqual(index.lifecycle(workspaceId: workspaceId, panelId: panelId), .idle)
        XCTAssertEqual(index.updatedAt(workspaceId: workspaceId, panelId: panelId), hookUpdatedAt)
        XCTAssertEqual(index.processIDs(workspaceId: workspaceId, panelId: panelId), [321])
        XCTAssertEqual(index.snapshot(workspaceId: workspaceId, panelId: panelId)?.launchCommand?.executablePath, "/opt/homebrew/bin/opencode")
    }

    func testProcessDetectedSnapshotPreservesHookLifecycleWhenRestoredPanelIDsChange() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-hibernation-remapped-panel-\(UUID().uuidString)", isDirectory: true)
        let storeURL = RestorableAgentKind.opencode.hookStoreFileURL(homeDirectory: home.path)
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let oldWorkspaceId = UUID()
        let oldPanelId = UUID()
        let currentWorkspaceId = UUID()
        let currentPanelId = UUID()
        let sessionId = "opencode-restored-remapped-panel"
        let hookUpdatedAt: TimeInterval = 789
        let jsonObject: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": oldWorkspaceId.uuidString,
                    "surfaceId": oldPanelId.uuidString,
                    "cwd": "/tmp/repo",
                    "pid": 999_998,
                    "agentLifecycle": "idle",
                    "updatedAt": hookUpdatedAt,
                    "launchCommand": [
                        "launcher": "opencode",
                        "executablePath": "/usr/local/bin/opencode",
                        "arguments": ["/usr/local/bin/opencode"],
                        "workingDirectory": "/tmp/repo",
                    ],
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted])
        try data.write(to: storeURL, options: .atomic)

        let key = RestorableAgentSessionIndex.PanelKey(workspaceId: currentWorkspaceId, panelId: currentPanelId)
        let detectedSnapshot = SessionRestorableAgentSnapshot(
            kind: .opencode,
            sessionId: sessionId,
            workingDirectory: "/tmp/repo",
            launchCommand: launch(
                "opencode",
                "/opt/homebrew/bin/opencode",
                arguments: ["/opt/homebrew/bin/opencode", "--session", sessionId],
                cwd: "/tmp/repo"
            )
        )

        let index = RestorableAgentSessionIndex.load(
            homeDirectory: home.path,
            fileManager: .default,
            registry: CmuxVaultAgentRegistry(registrations: []),
            detectedSnapshots: [key: (snapshot: detectedSnapshot, updatedAt: 999, processIDs: [654])]
        )

        XCTAssertNil(index.snapshot(workspaceId: oldWorkspaceId, panelId: oldPanelId))
        XCTAssertEqual(index.lifecycle(workspaceId: currentWorkspaceId, panelId: currentPanelId), .idle)
        XCTAssertEqual(index.updatedAt(workspaceId: currentWorkspaceId, panelId: currentPanelId), hookUpdatedAt)
        XCTAssertEqual(index.processIDs(workspaceId: currentWorkspaceId, panelId: currentPanelId), [654])
    }

    func testProcessDetectedOnlySnapshotDoesNotUseScanTimeAsActivity() {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-hibernation-empty-home-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let workspaceId = UUID()
        let panelId = UUID()
        let key = RestorableAgentSessionIndex.PanelKey(workspaceId: workspaceId, panelId: panelId)
        let detectedSnapshot = SessionRestorableAgentSnapshot(
            kind: .opencode,
            sessionId: "opencode-detected-only",
            workingDirectory: "/tmp/repo",
            launchCommand: launch("opencode", "/usr/local/bin/opencode", cwd: "/tmp/repo")
        )

        let index = RestorableAgentSessionIndex.load(
            homeDirectory: home.path,
            fileManager: .default,
            registry: CmuxVaultAgentRegistry(registrations: []),
            detectedSnapshots: [key: (snapshot: detectedSnapshot, updatedAt: 999, processIDs: [789])]
        )

        XCTAssertEqual(index.updatedAt(workspaceId: workspaceId, panelId: panelId), 0)
        XCTAssertNil(index.lifecycle(workspaceId: workspaceId, panelId: panelId))
        XCTAssertEqual(index.processIDs(workspaceId: workspaceId, panelId: panelId), [789])
        XCTAssertTrue(index.hasLiveProcess(workspaceId: workspaceId, panelId: panelId))
    }

}
