import CmuxFoundation
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension CMUXCLIErrorOutputRegressionTests {
    @Test func corruptLegacyReadFallsBackToLastCompleteRegistrySnapshot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-corrupt-legacy-read-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stateURL = root.appendingPathComponent("codex-hook-sessions.json")
        let registryURL = root.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        let sessionID = "last-complete"
        try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "sessions": [sessionID: [
                "sessionId": sessionID,
                "workspaceId": "workspace",
                "surfaceId": "surface",
                "startedAt": 100.0,
                "updatedAt": 200.0,
            ]],
        ]).write(to: stateURL, options: .atomic)
        let bridge = AgentHookSessionRegistryBridge(
            provider: "codex",
            statePath: stateURL.path,
            environment: ["CMUX_AGENT_SESSION_REGISTRY_PATH": registryURL.path],
            fileManager: .default
        )
        #expect(bridge.load().sessions[sessionID] != nil)

        try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "sessions": [sessionID: "partial-record"],
        ]).write(to: stateURL, options: .atomic)

        #expect(bridge.load().sessions[sessionID] != nil)
    }

    @Test func permissionModeOnlyMutationAdvancesRegistryProjection() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-permission-mode-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stateURL = root.appendingPathComponent("claude-hook-sessions.json")
        let registryURL = root.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        let sessionID = "permission-session"
        try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "sessions": [sessionID: [
                "sessionId": sessionID,
                "workspaceId": "workspace",
                "surfaceId": "surface",
                "startedAt": 100.0,
                "updatedAt": 200.0,
            ]],
        ], options: [.sortedKeys]).write(to: stateURL, options: .atomic)
        let store = ClaudeHookSessionStore(
            processEnv: [
                "CMUX_CLAUDE_HOOK_STATE_PATH": stateURL.path,
                "CMUX_AGENT_SESSION_REGISTRY_PATH": registryURL.path,
            ]
        )

        try store.updateLastPermissionMode(sessionId: sessionID, permissionMode: "plan")

        let saved = try #require(try store.lookup(sessionId: sessionID))
        #expect(saved.lastPermissionMode == "plan")
        #expect(saved.updatedAt > 200)
        let registry = CmuxAgentSessionRegistry(url: registryURL)
        let projected = try #require(registry.snapshot(provider: "claude").records.first)
        let projectedRecord = try JSONDecoder().decode(ClaudeHookSessionRecord.self, from: projected.json)
        #expect(projectedRecord.lastPermissionMode == "plan")
    }

    @Test func futureGenerationRegistryRowRejectsOlderBridgeMutation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-future-writer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let stateURL = root.appendingPathComponent("codex-hook-sessions.json")
        let registryURL = root.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        let sessionID = "future-codex"
        let record: [String: Any] = [
            "sessionId": sessionID,
            "workspaceId": "workspace-a",
            "surfaceId": "surface-a",
            "startedAt": 100.0,
            "updatedAt": 200.0,
        ]
        let recordJSON = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        let registry = CmuxAgentSessionRegistry(url: registryURL)
        try registry.apply(provider: "codex", records: [
            CmuxAgentSessionRegistry.Record(
                provider: "codex",
                sessionID: sessionID,
                updatedAt: 200,
                writerGeneration: CmuxAgentSessionRegistry.currentWriterGeneration + 1,
                json: recordJSON
            ),
        ])
        let bridge = AgentHookSessionRegistryBridge(
            provider: "codex",
            statePath: stateURL.path,
            environment: ["CMUX_AGENT_SESSION_REGISTRY_PATH": registryURL.path],
            fileManager: .default
        )

        #expect(throws: (any Error).self) {
            try bridge.mutate { state in
                state.sessions[sessionID]?.updatedAt = 300
                return true
            }
        }

        let stored = try #require(registry.snapshot(provider: "codex").records.first)
        #expect(stored.updatedAt == 200)
        #expect(stored.writerGeneration == CmuxAgentSessionRegistry.currentWriterGeneration + 1)
        #expect(stored.json == recordJSON)
    }

    @Test func hookMutationPrunesTheInactiveRecordAddedBeyondTheRetentionCap() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-retention-cap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stateURL = root.appendingPathComponent("codex-hook-sessions.json")
        let registryURL = root.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        let registry = CmuxAgentSessionRegistry(url: registryURL)
        let now = Date().timeIntervalSince1970
        let records = try (0..<10_000).map { index in
            let sessionID = "retained-\(index)"
            let updatedAt = now + Double(index) / 100_000
            return CmuxAgentSessionRegistry.Record(
                provider: "codex",
                sessionID: sessionID,
                updatedAt: updatedAt,
                json: try JSONSerialization.data(withJSONObject: [
                    "sessionId": sessionID,
                    "workspaceId": "workspace-\(index)",
                    "surfaceId": "surface-\(index)",
                    "startedAt": now,
                    "updatedAt": updatedAt,
                ], options: [.sortedKeys])
            )
        }
        try registry.apply(provider: "codex", records: records)
        let store = ClaudeHookSessionStore(
            processEnv: [
                "CMUX_CLAUDE_HOOK_STATE_PATH": stateURL.path,
                "CMUX_AGENT_SESSION_REGISTRY_PATH": registryURL.path,
            ],
            agentName: "codex"
        )

        #expect(try store.upsert(
            sessionId: "newest",
            workspaceId: "workspace-new",
            surfaceId: "surface-new",
            cwd: root.path
        ))

        let snapshot = try registry.snapshot(provider: "codex")
        #expect(snapshot.records.count == 10_000)
        #expect(snapshot.records.contains { $0.sessionID == "newest" })
        #expect(!snapshot.records.contains { $0.sessionID == "retained-0" })
    }
}
