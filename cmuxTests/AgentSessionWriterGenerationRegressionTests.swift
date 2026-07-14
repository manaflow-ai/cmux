import CmuxFoundation
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension CMUXCLIErrorOutputRegressionTests {
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
}
