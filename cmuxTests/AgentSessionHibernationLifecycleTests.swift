import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension AgentHibernationTests {
    @MainActor
    @Test
    func testRootExitInvalidatesInMemoryRestoreOwnerBeforeQueuedPersistence() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let binding = SurfaceResumeBindingSnapshot(
            name: "Codex",
            kind: "codex",
            command: "codex resume root-session",
            cwd: "/tmp/repo",
            checkpointId: "root-session",
            source: "agent-hook",
            updatedAt: 10
        )
        workspace.surfaceResumeBindingsByPanelId[panelId] = binding

        workspace.markAgentRootExitLocally(panelId: panelId, binding: binding)

        expectNil(workspace.surfaceResumeBinding(panelId: panelId))
        expectEqual(workspace.restoredAgentResumeStatesByPanelId[panelId], .completedAgentExit)
    }

    @MainActor
    @Test
    func testPromptIdleClearsDeadAgentPIDWithoutResumeBinding() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        workspace.recordAgentPID(
            key: "codex.dead-without-binding",
            pid: 999_999,
            panelId: panelId,
            refreshPorts: false
        )

        workspace.updatePanelShellActivityState(panelId: panelId, state: .commandRunning)
        workspace.updatePanelShellActivityState(panelId: panelId, state: .promptIdle)

        expectNil(workspace.agentPIDs["codex.dead-without-binding"])
    }

    @Test
    func testPassiveMonitorPreventsHibernationEvenWhenProviderLifecycleSaysIdle() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-hibernation-monitor-\(UUID().uuidString)", isDirectory: true)
        let storeURL = RestorableAgentKind.codex.hookStoreFileURL(homeDirectory: home.path)
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let workspaceId = UUID()
        let panelId = UUID()
        let sessionId = "codex-passive-monitor"
        let jsonObject: [String: Any] = [
            "version": 2,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": workspaceId.uuidString,
                    "surfaceId": panelId.uuidString,
                    "cwd": "/tmp/repo",
                    "agentLifecycle": "idle",
                    "updatedAt": Date().timeIntervalSince1970,
                    "workloads": [[
                        "id": "monitor-1",
                        "kind": "monitor",
                        "phase": "watching",
                        "keepsSessionBusy": true,
                        "startedAt": Date().timeIntervalSince1970,
                        "updatedAt": Date().timeIntervalSince1970,
                    ]],
                    "launchCommand": [
                        "launcher": "codex",
                        "executablePath": "/usr/local/bin/codex",
                        "arguments": ["/usr/local/bin/codex"],
                        "workingDirectory": "/tmp/repo",
                    ],
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted])
            .write(to: storeURL, options: .atomic)

        let index = RestorableAgentSessionIndex.load(homeDirectory: home.path)
        expectEqual(index.lifecycle(workspaceId: workspaceId, panelId: panelId), .running)
    }

    @Test
    func testObservedRootExitCompletesHookRecordAndCancelsOwnedWork() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-observed-exit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.appendingPathComponent("codex-hook-sessions.json")
        let sessionId = "root-exit-session"
        let jsonObject: [String: Any] = [
            "version": 2,
            "sessions": [sessionId: [
                "sessionId": sessionId,
                "workspaceId": UUID().uuidString,
                "surfaceId": UUID().uuidString,
                "activeRunId": "run-1",
                "restoreAuthority": true,
                "startedAt": 1.0,
                "updatedAt": 2.0,
                "runs": [[
                    "runId": "run-1",
                    "restoreAuthority": true,
                    "startedAt": 1.0,
                    "updatedAt": 2.0,
                ]],
                "workloads": [[
                    "id": "monitor-1",
                    "kind": "monitor",
                    "phase": "watching",
                    "keepsSessionBusy": true,
                    "startedAt": 1.0,
                    "updatedAt": 2.0,
                ]],
            ]],
            "activeSessionsByWorkspace": ["workspace": ["sessionId": sessionId, "updatedAt": 2.0]],
            "activeSessionsBySurface": ["surface": ["sessionId": sessionId, "updatedAt": 2.0]],
        ]
        try JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted])
            .write(to: storeURL, options: .atomic)

        AgentHookSessionStateWriter(
            homeDirectory: root.path,
            environment: ["CMUX_AGENT_HOOK_STATE_DIR": root.path]
        ).completeSynchronously(kind: .codex, sessionId: sessionId, now: 10.0)

        let saved = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: storeURL)) as? [String: Any]
        )
        let sessions = try #require(saved["sessions"] as? [String: Any])
        let record = try #require(sessions[sessionId] as? [String: Any])
        expectEqual(record["completedAt"] as? Double, 10.0)
        expectEqual(record["restoreAuthority"] as? Bool, false)
        expectNil(record["activeRunId"])
        let workloads = try #require(record["workloads"] as? [[String: Any]])
        expectEqual(workloads.first?["phase"] as? String, "cancelled")
        expectEqual(workloads.first?["endReason"] as? String, "root_exited")
        expectTrue((saved["activeSessionsByWorkspace"] as? [String: Any])?.isEmpty == true)
        expectTrue((saved["activeSessionsBySurface"] as? [String: Any])?.isEmpty == true)
    }

    @Test
    func testHibernationAndRestoreTransitionsAreDurableAgentStates() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-hibernation-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.appendingPathComponent("codex-hook-sessions.json")
        let sessionId = "hibernated-session"
        try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "sessions": [sessionId: [
                "sessionId": sessionId,
                "workspaceId": UUID().uuidString,
                "surfaceId": UUID().uuidString,
                "restoreAuthority": true,
                "startedAt": 1.0,
                "updatedAt": 2.0,
            ]],
        ], options: []).write(to: storeURL, options: .atomic)
        let writer = AgentHookSessionStateWriter(
            homeDirectory: root.path,
            environment: ["CMUX_AGENT_HOOK_STATE_DIR": root.path]
        )

        writer.setLifecycleSynchronously(
            kind: .codex,
            sessionId: sessionId,
            state: .hibernated,
            now: 3.0
        )
        var saved = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: storeURL)) as? [String: Any]
        )
        var sessions = try #require(saved["sessions"] as? [String: Any])
        var record = try #require(sessions[sessionId] as? [String: Any])
        expectEqual(record["sessionState"] as? String, "hibernated")

        writer.setLifecycleSynchronously(
            kind: .codex,
            sessionId: sessionId,
            state: .restoring,
            now: 4.0
        )
        saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: storeURL)) as? [String: Any])
        sessions = try #require(saved["sessions"] as? [String: Any])
        record = try #require(sessions[sessionId] as? [String: Any])
        expectEqual(record["sessionState"] as? String, "restoring")
        expectEqual(record["restoreAuthority"] as? Bool, true)
    }

    @Test
    func testLifecycleAndRootExitWritesKeepHookStorePrivate() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-store-permissions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.appendingPathComponent("codex-hook-sessions.json")
        let sessionId = "private-session"
        try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "sessions": [sessionId: [
                "sessionId": sessionId,
                "workspaceId": "workspace",
                "surfaceId": "surface",
                "restoreAuthority": true,
                "startedAt": 1.0,
                "updatedAt": 2.0,
            ]],
        ], options: []).write(to: storeURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: storeURL.path
        )
        let writer = AgentHookSessionStateWriter(
            homeDirectory: root.path,
            environment: ["CMUX_AGENT_HOOK_STATE_DIR": root.path]
        )

        writer.setLifecycleSynchronously(
            kind: .codex,
            sessionId: sessionId,
            state: .hibernated,
            now: 3
        )
        var attributes = try FileManager.default.attributesOfItem(atPath: storeURL.path)
        var permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        expectEqual(permissions.intValue & 0o777, 0o600)

        writer.completeSynchronously(kind: .codex, sessionId: sessionId, now: 4)
        attributes = try FileManager.default.attributesOfItem(atPath: storeURL.path)
        permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        expectEqual(permissions.intValue & 0o777, 0o600)
    }

}
