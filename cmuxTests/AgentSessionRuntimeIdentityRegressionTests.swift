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
        #expect(
            loaded == nil,
            "One malformed authoritative record must reject the provider instead of reviving stale legacy state."
        )
    }

    @Test func restoreLoaderRejectsStaleLegacyWhenRegistryFileIsCorrupt() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-restore-corrupt-registry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyURL = root.appendingPathComponent("codex-hook-sessions.json")
        let registryURL = root.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        let sessionID = "stale-legacy-session"
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
        try Data("not-a-sqlite-database".utf8).write(to: registryURL, options: .atomic)

        let loaded = RestorableAgentHookSessionStoreFile.load(
            provider: "codex",
            legacyURL: legacyURL,
            environment: ["CMUX_AGENT_SESSION_REGISTRY_PATH": registryURL.path],
            fileManager: .default,
            decoder: JSONDecoder()
        )

        #expect(
            loaded == nil,
            "An existing unreadable registry is authoritative and must not revive stale legacy state."
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
        #expect(result.snapshots["codex"]?.activeSlots.count == 1)
    }

    @Test func hibernationRegistryRefreshPrioritizesKnownRelevantProviders() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-hibernation-refresh-priority-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let registryURL = root.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        let registry = CmuxAgentSessionRegistry(url: registryURL)
        let workspaceID = UUID()
        let panelID = UUID()
        let panelProvider = "zz-panel-relevant"
        let panelSessionID = "panel-owner"
        let exactProvider = "zy-exact-relevant"
        let exactSessionID = "exact-owner"

        func recordJSON(
            sessionID: String,
            workspaceID: UUID,
            panelID: UUID,
            padding: Int = 0
        ) throws -> Data {
            try JSONSerialization.data(withJSONObject: [
                "sessionId": sessionID,
                "workspaceId": workspaceID.uuidString,
                "surfaceId": panelID.uuidString,
                "startedAt": 1.0,
                "updatedAt": 2.0,
                "padding": String(repeating: "x", count: padding),
            ], options: [.sortedKeys])
        }

        func legacyData(
            sessionID: String,
            workspaceID: UUID,
            panelID: UUID,
            padding: Int = 0
        ) throws -> Data {
            let record = try JSONSerialization.jsonObject(with: recordJSON(
                sessionID: sessionID,
                workspaceID: workspaceID,
                panelID: panelID,
                padding: padding
            ))
            return try JSONSerialization.data(withJSONObject: [
                "version": 2,
                "sessions": [sessionID: record],
                "activeSessionsByWorkspace": [:],
                "activeSessionsBySurface": [:],
            ], options: [.sortedKeys])
        }

        let panelRecordJSON = try recordJSON(
            sessionID: panelSessionID,
            workspaceID: workspaceID,
            panelID: panelID
        )
        let panelSlotJSON = try JSONSerialization.data(withJSONObject: [
            "sessionId": panelSessionID,
            "updatedAt": 2.0,
        ], options: [.sortedKeys])
        try registry.apply(
            provider: panelProvider,
            records: [.init(
                provider: panelProvider,
                sessionID: panelSessionID,
                updatedAt: 2,
                json: panelRecordJSON
            )],
            activeSlots: [.init(
                provider: panelProvider,
                scope: .surface,
                scopeID: panelID.uuidString,
                sessionID: panelSessionID,
                updatedAt: 2,
                json: panelSlotJSON
            )]
        )

        let panelLegacy = try legacyData(
            sessionID: panelSessionID,
            workspaceID: workspaceID,
            panelID: panelID,
            padding: 2_048
        )
        let exactLegacy = try legacyData(
            sessionID: exactSessionID,
            workspaceID: UUID(),
            panelID: UUID(),
            padding: 2_048
        )
        let panelURL = root.appendingPathComponent("\(panelProvider)-hook-sessions.json")
        let exactURL = root.appendingPathComponent("\(exactProvider)-hook-sessions.json")
        try panelLegacy.write(to: panelURL, options: .atomic)
        try exactLegacy.write(to: exactURL, options: .atomic)

        let noiseLegacy = try legacyData(
            sessionID: "noise",
            workspaceID: UUID(),
            panelID: UUID()
        )
        var noiseProviders = Set<String>()
        var sources: [(kind: RestorableAgentKind, fileURL: URL)] = []
        for index in 0..<32 {
            let provider = String(format: "aa-noise-%02d", index)
            let url = root.appendingPathComponent("\(provider)-hook-sessions.json")
            try noiseLegacy.write(to: url, options: .atomic)
            sources.append((.custom(provider), url))
            noiseProviders.insert(provider)
        }
        sources.append((.custom(panelProvider), panelURL))
        sources.append((.custom(exactProvider), exactURL))
        #expect(Int64(noiseLegacy.count * 32) >= Int64(panelLegacy.count + exactLegacy.count))

        let result = RestorableAgentSessionIndex.agentRegistryHibernationSnapshots(
            sources,
            panelKeys: [.init(workspaceId: workspaceID, panelId: panelID)],
            exactSessionIDsByProvider: [exactProvider: [exactSessionID]],
            maximumLegacySourceReadBytes: Int64(panelLegacy.count + exactLegacy.count),
            fileManager: .default,
            environment: ["CMUX_AGENT_SESSION_REGISTRY_PATH": registryURL.path]
        )

        #expect(result.failedProviders == noiseProviders)
        #expect(result.snapshots[panelProvider]?.records.map(\.sessionID) == [panelSessionID])
        #expect(result.snapshots[panelProvider]?.activeSlots.map(\.sessionID) == [panelSessionID])
        #expect(result.snapshots[exactProvider]?.records.map(\.sessionID) == [exactSessionID])
        #expect(result.snapshots[exactProvider]?.activeSlots.isEmpty == true)
        #expect(noiseProviders.allSatisfy { result.snapshots[$0]?.records.isEmpty == true })
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

    @Test func hibernationRegistryLoadIgnoresIrrelevantProviderCap() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-hibernation-registry-provider-cap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registryURL = root.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        let registry = CmuxAgentSessionRegistry(url: registryURL)
        let workspaceID = UUID()
        let panelID = UUID()
        let provider = "provider-64"
        let sessionID = "relevant-owner"
        let recordJSON = try JSONSerialization.data(withJSONObject: [
            "sessionId": sessionID,
            "workspaceId": workspaceID.uuidString,
            "surfaceId": panelID.uuidString,
            "updatedAt": 100.0,
        ], options: [.sortedKeys])
        let slotJSON = try JSONSerialization.data(withJSONObject: [
            "sessionId": sessionID,
            "updatedAt": 100.0,
        ], options: [.sortedKeys])
        try registry.apply(
            provider: provider,
            records: [.init(
                provider: provider,
                sessionID: sessionID,
                updatedAt: 100,
                json: recordJSON
            )],
            activeSlots: [.init(
                provider: provider,
                scope: .surface,
                scopeID: panelID.uuidString,
                sessionID: sessionID,
                updatedAt: 100,
                json: slotJSON
            )]
        )
        let sources: [(kind: RestorableAgentKind, fileURL: URL)] = (0..<65).map { index in
            let id = "provider-\(index)"
            return (.custom(id), root.appendingPathComponent("\(id)-hook-sessions.json"))
        }

        let result = RestorableAgentSessionIndex.agentRegistryHibernationSnapshots(
            sources,
            panelKeys: [.init(workspaceId: workspaceID, panelId: panelID)],
            exactSessionIDsByProvider: [:],
            fileManager: .default,
            environment: ["CMUX_AGENT_SESSION_REGISTRY_PATH": registryURL.path]
        )

        #expect(!result.failedProviders.contains(provider))
        #expect(result.snapshots[provider]?.records.map(\.sessionID) == [sessionID])
        #expect(result.snapshots[provider]?.activeSlots.map(\.sessionID) == [sessionID])
    }

    @Test func hibernationRegistrySnapshotDoesNotFallBackAfterMalformedCanonicalProjection() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-hibernation-registry-malformed-provider-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyURL = root.appendingPathComponent("broken-hook-sessions.json")
        try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "sessions": ["stale": [
                "sessionId": "stale",
                "workspaceId": UUID().uuidString,
                "surfaceId": UUID().uuidString,
                "startedAt": 1.0,
                "updatedAt": 1.0,
            ]],
        ], options: [.sortedKeys]).write(to: legacyURL)
        let snapshots = [
            "broken": CmuxAgentSessionRegistry.Snapshot(
                records: [.init(
                    provider: "broken",
                    sessionID: "malformed",
                    updatedAt: 2,
                    json: Data("{}".utf8)
                )],
                activeSlots: []
            ),
        ]

        let state = RestorableAgentSessionIndex.agentHookState(
            kind: .custom("broken"),
            fileURL: legacyURL,
            snapshots: snapshots,
            fileManager: .default,
            decoder: JSONDecoder()
        )

        #expect(state == nil, "A malformed canonical provider must not revive stale sidecar state.")
    }

    @Test func hibernationIndexDoesNotInspectUnrelatedHistoricalProcesses() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-hibernation-index-projection-\(UUID().uuidString)", isDirectory: true)
        let stateDirectory = root.appendingPathComponent(".cmuxterm", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let selectedWorkspaceID = UUID()
        let selectedPanelID = UUID()
        let selectedSessionID = "selected-session"
        let selectedPID = 91_001
        let unrelatedSessionID = "unrelated-session"
        let unrelatedPID = 91_002
        let registry = CmuxAgentSessionRegistry(
            url: stateDirectory.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        )

        func record(
            sessionID: String,
            workspaceID: UUID,
            panelID: UUID,
            pid: Int
        ) throws -> CmuxAgentSessionRegistry.Record {
            let object: [String: Any] = [
                "sessionId": sessionID,
                "workspaceId": workspaceID.uuidString,
                "surfaceId": panelID.uuidString,
                "cwd": root.path,
                "pid": pid,
                "isRestorable": true,
                "restoreAuthority": true,
                "updatedAt": 100.0,
                "launchCommand": [
                    "launcher": "codex",
                    "executablePath": "/usr/local/bin/codex",
                    "arguments": ["/usr/local/bin/codex"],
                    "workingDirectory": root.path,
                    "capturedAt": 100.0,
                    "source": "test",
                ],
            ]
            return .init(
                provider: "codex",
                sessionID: sessionID,
                updatedAt: 100,
                json: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            )
        }

        let slotJSON = try JSONSerialization.data(withJSONObject: [
            "sessionId": selectedSessionID,
            "updatedAt": 100.0,
        ], options: [.sortedKeys])
        try registry.apply(
            provider: "codex",
            records: [
                try record(
                    sessionID: selectedSessionID,
                    workspaceID: selectedWorkspaceID,
                    panelID: selectedPanelID,
                    pid: selectedPID
                ),
                try record(
                    sessionID: unrelatedSessionID,
                    workspaceID: UUID(),
                    panelID: UUID(),
                    pid: unrelatedPID
                ),
            ],
            activeSlots: [
                .init(
                    provider: "codex",
                    scope: .surface,
                    scopeID: selectedPanelID.uuidString,
                    sessionID: selectedSessionID,
                    updatedAt: 100,
                    json: slotJSON
                ),
            ]
        )

        var inspectedProcessIDs = Set<Int>()
        let index = RestorableAgentSessionIndex.load(
            homeDirectory: root.path,
            fileManager: .default,
            registry: CmuxVaultAgentRegistry(registrations: []),
            detectedSnapshots: [:],
            hibernationPanelKeys: [
                .init(workspaceId: selectedWorkspaceID, panelId: selectedPanelID),
            ],
            processArgumentsProvider: { pid in
                inspectedProcessIDs.insert(pid)
                return nil
            }
        )

        #expect(index.exactEntry(
            workspaceId: selectedWorkspaceID,
            panelId: selectedPanelID
        )?.snapshot.sessionId == selectedSessionID)
        #expect(inspectedProcessIDs == [selectedPID])
        #expect(!inspectedProcessIDs.contains(unrelatedPID))
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
