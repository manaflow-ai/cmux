import CmuxFoundation
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension CMUXCLIErrorOutputRegressionTests {
    @Test func appRestoreLoaderHonorsExplicitAgentRegistryPath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-explicit-registry-\(UUID().uuidString)", isDirectory: true)
        let legacyDirectory = root.appendingPathComponent("legacy", isDirectory: true)
        let registryURL = root.appendingPathComponent("custom-agent-sessions.sqlite3")
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionID = "configured-registry-session"
        let record: [String: Any] = [
            "sessionId": sessionID,
            "workspaceId": "workspace",
            "surfaceId": "surface",
            "startedAt": 100.0,
            "updatedAt": 200.0,
        ]
        try CmuxAgentSessionRegistry(url: registryURL).apply(provider: "codex", records: [
            CmuxAgentSessionRegistry.Record(
                provider: "codex",
                sessionID: sessionID,
                updatedAt: 200,
                json: try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            ),
        ])

        let snapshots = RestorableAgentSessionIndex.agentRegistrySnapshots(
            [(.codex, legacyDirectory.appendingPathComponent("codex-hook-sessions.json"))],
            fileManager: .default,
            environment: ["CMUX_AGENT_SESSION_REGISTRY_PATH": registryURL.path]
        )

        #expect(snapshots?["codex"]?.records.contains { $0.sessionID == sessionID } == true)
    }

    @Test func agentHookRuntimeIdentityPrefersTheConnectedSocketOverMissingOrStaleEnvironment() throws {
        let socketCapabilities: [String: Any] = [
            "runtime_id": "socket-runtime",
            "socket_path": "/tmp/cmux-debug-current.sock",
            "bundle_identifier": "com.cmuxterm.current",
        ]

        let missing = try #require(AgentCmuxRuntimeIdentity.resolve(
            environment: [:],
            socketCapabilities: socketCapabilities
        ))
        #expect(missing.id == "socket-runtime")
        #expect(missing.socketPath == "/tmp/cmux-debug-current.sock")
        #expect(missing.bundleIdentifier == "com.cmuxterm.current")

        let stale = try #require(AgentCmuxRuntimeIdentity.resolve(
            environment: [
                "CMUX_RUNTIME_ID": "stale-runtime",
                "CMUX_SOCKET_PATH": "/tmp/cmux-debug-current.sock",
                "CMUX_BUNDLE_ID": "com.cmuxterm.stale",
            ],
            socketCapabilities: socketCapabilities
        ))
        #expect(stale == missing)

        let storeEnvironment = stale.applying(to: [:])
        #expect(storeEnvironment["CMUX_RUNTIME_ID"] == "socket-runtime")
        #expect(storeEnvironment["CMUX_SOCKET_PATH"] == "/tmp/cmux-debug-current.sock")
        #expect(storeEnvironment["CMUX_BUNDLE_ID"] == "com.cmuxterm.current")

        let legacy = try #require(AgentCmuxRuntimeIdentity.resolve(
            environment: ["CMUX_RUNTIME_ID": "legacy-runtime"],
            socketCapabilities: [:]
        ))
        #expect(legacy.id == "legacy-runtime")
    }
}
