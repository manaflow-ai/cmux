import CmuxFoundation
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension CMUXCLIErrorOutputRegressionTests {
    @Test func restoreLoaderFallsBackToLastCompleteRegistrySnapshot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-restore-corrupt-legacy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyURL = root.appendingPathComponent("codex-hook-sessions.json")
        let registryURL = root.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        let sessionID = "restore-last-complete"
        try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "sessions": [sessionID: [
                "sessionId": sessionID,
                "workspaceId": "11111111-1111-1111-1111-111111111111",
                "surfaceId": "22222222-2222-2222-2222-222222222222",
                "startedAt": 100.0,
                "updatedAt": 200.0,
            ]],
        ]).write(to: legacyURL, options: .atomic)
        let environment = ["CMUX_AGENT_SESSION_REGISTRY_PATH": registryURL.path]
        let decoder = JSONDecoder()
        #expect(RestorableAgentHookSessionStoreFile.load(
            provider: "codex",
            legacyURL: legacyURL,
            environment: environment,
            fileManager: .default,
            decoder: decoder
        )?.sessions[sessionID] != nil)

        try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "sessions": [sessionID: "partial-record"],
        ]).write(to: legacyURL, options: .atomic)

        #expect(RestorableAgentHookSessionStoreFile.load(
            provider: "codex",
            legacyURL: legacyURL,
            environment: environment,
            fileManager: .default,
            decoder: decoder
        )?.sessions[sessionID] != nil)
    }

    @Test func restoreLoaderRejectsPartiallyDecodableRegistrySnapshot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-restore-partial-registry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyURL = root.appendingPathComponent("codex-hook-sessions.json")
        let registryURL = root.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        let legacySessionID = "legacy-complete"
        try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "sessions": [legacySessionID: [
                "sessionId": legacySessionID,
                "workspaceId": "11111111-1111-1111-1111-111111111111",
                "surfaceId": "22222222-2222-2222-2222-222222222222",
                "startedAt": 100.0,
                "updatedAt": 200.0,
            ]],
        ]).write(to: legacyURL, options: .atomic)
        let environment = ["CMUX_AGENT_SESSION_REGISTRY_PATH": registryURL.path]
        let decoder = JSONDecoder()
        #expect(RestorableAgentHookSessionStoreFile.load(
            provider: "codex", legacyURL: legacyURL, environment: environment,
            fileManager: .default, decoder: decoder
        )?.sessions[legacySessionID] != nil)

        let registry = CmuxAgentSessionRegistry(url: registryURL)
        let registryOnlySessionID = "registry-only"
        let registryOnlyRecord = try JSONSerialization.data(withJSONObject: [
            "sessionId": registryOnlySessionID,
            "workspaceId": "33333333-3333-3333-3333-333333333333",
            "surfaceId": "44444444-4444-4444-4444-444444444444",
            "startedAt": 300.0,
            "updatedAt": 400.0,
        ])
        try registry.apply(provider: "codex", records: [
            CmuxAgentSessionRegistry.Record(
                provider: "codex", sessionID: registryOnlySessionID,
                updatedAt: 400, json: registryOnlyRecord
            ),
            CmuxAgentSessionRegistry.Record(
                provider: "codex", sessionID: "malformed",
                updatedAt: 500, json: Data("{}".utf8)
            ),
        ])

        let loaded = RestorableAgentHookSessionStoreFile.load(
            provider: "codex", legacyURL: legacyURL, environment: environment,
            fileManager: .default, decoder: decoder
        )
        #expect(loaded?.sessions[legacySessionID] != nil)
        #expect(
            loaded?.sessions[registryOnlySessionID] == nil,
            "One malformed registry record must reject the entire projection instead of returning partial state."
        )
    }

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

    @Test func hibernationRegistryLoadSelectsOpenPanelOwnersAndExactDetections() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-hibernation-registry-projection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registryURL = root.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        let registry = CmuxAgentSessionRegistry(url: registryURL)
        let workspaceID = UUID()
        let panelID = UUID()
        let activeSessionID = "active-owner"
        let detectedSessionID = "detected-session"
        let unrelatedSessionID = "unrelated-history"

        func record(_ sessionID: String, workspaceID: UUID, panelID: UUID) throws
            -> CmuxAgentSessionRegistry.Record {
            CmuxAgentSessionRegistry.Record(
                provider: "codex",
                sessionID: sessionID,
                updatedAt: 100,
                json: try JSONSerialization.data(withJSONObject: [
                    "sessionId": sessionID,
                    "workspaceId": workspaceID.uuidString,
                    "surfaceId": panelID.uuidString,
                    "restoreAuthority": true,
                    "updatedAt": 100.0,
                ], options: [.sortedKeys])
            )
        }
        let slotJSON = try JSONSerialization.data(withJSONObject: [
            "sessionId": activeSessionID,
            "updatedAt": 100.0,
        ], options: [.sortedKeys])
        try registry.apply(
            provider: "codex",
            records: [
                try record(activeSessionID, workspaceID: workspaceID, panelID: panelID),
                try record(detectedSessionID, workspaceID: UUID(), panelID: UUID()),
                try record(unrelatedSessionID, workspaceID: UUID(), panelID: UUID()),
            ],
            activeSlots: [
                .init(
                    provider: "codex",
                    scope: .workspace,
                    scopeID: workspaceID.uuidString,
                    sessionID: activeSessionID,
                    updatedAt: 100,
                    json: slotJSON
                ),
                .init(
                    provider: "codex",
                    scope: .surface,
                    scopeID: panelID.uuidString,
                    sessionID: activeSessionID,
                    updatedAt: 100,
                    json: slotJSON
                ),
            ]
        )

        let result = RestorableAgentSessionIndex.agentRegistryHibernationSnapshots(
            [(.codex, root.appendingPathComponent("codex-hook-sessions.json"))],
            panelKeys: [.init(workspaceId: workspaceID, panelId: panelID)],
            exactSessionIDsByProvider: ["codex": [detectedSessionID]],
            fileManager: .default,
            environment: ["CMUX_AGENT_SESSION_REGISTRY_PATH": registryURL.path]
        )

        #expect(result.failedProviders.isEmpty)
        #expect(Set(result.snapshots["codex"]?.records.map(\.sessionID) ?? []) == [
            activeSessionID, detectedSessionID,
        ])
        #expect(result.snapshots["codex"]?.activeSlots.count == 2)
    }

    @Test func hibernationRegistryLoadFailsClosedPerProviderAtProjectionLimit() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-hibernation-registry-limit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registryURL = root.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        let registry = CmuxAgentSessionRegistry(url: registryURL)
        for sessionID in ["first", "second"] {
            try registry.apply(provider: "codex", records: [.init(
                provider: "codex",
                sessionID: sessionID,
                updatedAt: 100,
                json: try JSONSerialization.data(withJSONObject: [
                    "sessionId": sessionID,
                    "workspaceId": UUID().uuidString,
                    "surfaceId": UUID().uuidString,
                    "updatedAt": 100.0,
                ], options: [.sortedKeys])
            )])
        }

        let result = RestorableAgentSessionIndex.agentRegistryHibernationSnapshots(
            [(.codex, root.appendingPathComponent("codex-hook-sessions.json"))],
            panelKeys: [],
            exactSessionIDsByProvider: ["codex": ["first", "second"]],
            maximumRecords: 1,
            fileManager: .default,
            environment: ["CMUX_AGENT_SESSION_REGISTRY_PATH": registryURL.path]
        )

        #expect(result.failedProviders == ["codex"])
        #expect(result.snapshots["codex"]?.records.isEmpty == true)
        #expect(result.snapshots["codex"]?.activeSlots.isEmpty == true)
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

    @Test func cliRuntimeIdentityIgnoresNewerAppMetadataFields() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "id": "forward-compatible-runtime",
            "socketPath": "/tmp/cmux-forward-compatible.sock",
            "bundleIdentifier": "com.cmuxterm.forward-compatible",
            "processId": 42,
            "processStartSeconds": 1_234,
            "processStartMicroseconds": 567_890,
            "futureRuntimeMetadata": ["generation": 9],
        ], options: [.sortedKeys])

        let runtime = try JSONDecoder().decode(AgentCmuxRuntimeIdentity.self, from: data)

        #expect(runtime == AgentCmuxRuntimeIdentity(
            id: "forward-compatible-runtime",
            socketPath: "/tmp/cmux-forward-compatible.sock",
            bundleIdentifier: "com.cmuxterm.forward-compatible"
        ))
    }
}
