import CmuxFoundation
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Agent hook session inspection limits")
struct AgentHookSessionStoreScaleTests {
    @Test("inspection validates record, provider, selection, and legacy byte caps before decode")
    func inspectionStorageCapsAreTyped() throws {
        let mebibyte: Int64 = 1_024 * 1_024
        let cases: [(
            source: AgentHookSessionRegistryBridge.InspectionSourcePreflight,
            expectedScope: AgentHookSessionStoreLoadFailure.Scope,
            expectedObserved: Int64,
            expectedMaximum: Int64
        )] = [
            (
                source(
                    provider: "record",
                    recordBytes: 4 * mebibyte + 1,
                    largestRecordBytes: 4 * mebibyte + 1,
                    legacyBytes: 0
                ),
                .registryRecord,
                4 * mebibyte + 1,
                4 * mebibyte
            ),
            (
                source(
                    provider: "provider",
                    recordBytes: 64 * mebibyte + 1,
                    largestRecordBytes: 1,
                    legacyBytes: 0
                ),
                .registryProvider,
                64 * mebibyte + 1,
                64 * mebibyte
            ),
            (
                source(
                    provider: "legacy",
                    recordBytes: 0,
                    largestRecordBytes: 0,
                    legacyBytes: 64 * mebibyte + 1
                ),
                .legacyFile,
                64 * mebibyte + 1,
                64 * mebibyte
            ),
            (
                source(
                    provider: "combined",
                    recordBytes: 40 * mebibyte,
                    largestRecordBytes: 1,
                    legacyBytes: 25 * mebibyte
                ),
                .providerMaterialization,
                65 * mebibyte,
                64 * mebibyte
            ),
        ]

        for item in cases {
            let failure = try #require(storageFailure(for: [item.source]))
            #expect(failure.code == .storageLimitExceeded)
            #expect(failure.scope == item.expectedScope)
            #expect(failure.observedBytes == item.expectedObserved)
            #expect(failure.maximumBytes == item.expectedMaximum)
            #expect(failure.provider == item.source.provider)
        }

        let aggregateSources = [
            source(
                provider: "first",
                recordBytes: 64 * mebibyte,
                largestRecordBytes: 1,
                legacyBytes: 0
            ),
            source(
                provider: "second",
                recordBytes: 64 * mebibyte,
                largestRecordBytes: 1,
                legacyBytes: 0
            ),
            source(
                provider: "third",
                recordBytes: 1,
                largestRecordBytes: 1,
                legacyBytes: 0
            ),
        ]
        let aggregateFailure = try #require(storageFailure(for: aggregateSources))
        #expect(aggregateFailure.scope == .selectionMaterialization)
        #expect(aggregateFailure.observedBytes == 128 * mebibyte + 1)
        #expect(aggregateFailure.maximumBytes == 128 * mebibyte)
        #expect(aggregateFailure.provider == "third")

        let legacyAggregate = ["first", "second", "third"].map {
            source(
                provider: $0,
                recordBytes: 0,
                largestRecordBytes: 0,
                legacyBytes: 45 * mebibyte
            )
        }
        let legacyAggregateFailure = try #require(storageFailure(for: legacyAggregate))
        #expect(legacyAggregateFailure.scope == .selectionMaterialization)
        #expect(legacyAggregateFailure.observedBytes == 135 * mebibyte)
        #expect(legacyAggregateFailure.maximumBytes == 128 * mebibyte)
        #expect(legacyAggregateFailure.provider == "third")
    }

    @Test("aggregate sidecar cap stops before reading the overflowing source")
    func aggregateSidecarCapPrecedesAdmissionReads() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-preflight-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let registryURL = root.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        let registry = CmuxAgentSessionRegistry(url: registryURL)
        let sidecar = try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "sessions": [
                "session": [
                    "sessionId": "session",
                    "runs": [["runId": "run"]],
                ],
            ],
        ], options: [.sortedKeys])
        let sources = try ["a", "b", "c"].map { provider in
            let source = CmuxAgentSessionRegistry.LegacySource(
                provider: provider,
                url: root.appendingPathComponent("\(provider).json")
            )
            try sidecar.write(to: source.url, options: .atomic)
            return source
        }
        var admittedProviders: [String] = []
        var failure: AgentHookSessionStoreLoadFailure?
        do {
            _ = try AgentHookSessionRegistryBridge.preflightInspectionSources(
                sources,
                registry: registry,
                registryPath: registryURL.path,
                fileManager: .default,
                maximumLegacyGraphNodes: 20_000,
                limits: .init(
                    recordBytes: 1_024 * 1_024,
                    providerBytes: 1_024 * 1_024,
                    selectionBytes: Int64(sidecar.count * 2),
                    legacyFileBytes: 1_024 * 1_024
                ),
                admissionLoader: { source, stamp, remainingGraphNodes in
                    admittedProviders.append(source.provider)
                    return try registry.hookLegacySourceAdmission(
                        source: source,
                        expectedStamp: stamp,
                        maximumGraphNodes: remainingGraphNodes
                    )
                }
            )
        } catch let error as AgentHookSessionStoreLoadFailure {
            failure = error
        }

        let captured = try #require(failure)
        #expect(captured.scope == .selectionMaterialization)
        #expect(captured.provider == "c")
        #expect(captured.observedBytes == Int64(sidecar.count * 3))
        #expect(captured.maximumBytes == Int64(sidecar.count * 2))
        #expect(admittedProviders == ["a", "b"])
    }

    @Test("sidecar admission retries one descriptor revision without mixing bytes")
    func sidecarAdmissionRetriesOneRevision() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-revision-retry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let registryURL = root.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        let registry = CmuxAgentSessionRegistry(url: registryURL)
        let source = CmuxAgentSessionRegistry.LegacySource(
            provider: "codex",
            url: root.appendingPathComponent("codex.json")
        )
        let first = try inspectionSidecar(sessionID: "a")
        let second = try inspectionSidecar(sessionID: "b")
        #expect(first.count == second.count)
        try writeRevision(first, to: source.url, modifiedAt: 100)
        var attempts = 0

        let preflight = try AgentHookSessionRegistryBridge.preflightInspectionSources(
            [source],
            registry: registry,
            registryPath: registryURL.path,
            fileManager: .default,
            maximumLegacyGraphNodes: 20_000,
            admissionLoader: { source, stamp, remainingGraphNodes in
                attempts += 1
                if attempts == 1 {
                    try writeRevision(second, to: source.url, modifiedAt: 101)
                }
                return try registry.hookLegacySourceAdmission(
                    source: source,
                    expectedStamp: stamp,
                    maximumGraphNodes: remainingGraphNodes
                )
            }
        )
        #expect(attempts == 2)
        #expect(preflight.warnings.isEmpty)
        #expect(preflight.admissions.count == 1)

        let snapshot = try #require(registry.snapshotsImportingAdmittedLegacy(
            sources: [source],
            admissions: preflight.admissions
        )[source.provider])
        #expect(snapshot.records.map(\.sessionID) == ["b"])
    }

    @Test("continuously changing sidecars warn on valid canonical fallback and fail legacy-only")
    func unstableSidecarFallbackIsExplicitAndLossless() throws {
        func exercise(hasCanonical: Bool) throws -> (
            result: AgentHookSessionRegistryBridge.InspectionPreflightResult?,
            failure: AgentHookSessionStoreLoadFailure?,
            registry: CmuxAgentSessionRegistry,
            source: CmuxAgentSessionRegistry.LegacySource,
            root: URL
        ) {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "cmux-agent-unstable-\(UUID().uuidString)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let registryURL = root.appendingPathComponent(CmuxAgentSessionRegistry.filename)
            let registry = CmuxAgentSessionRegistry(url: registryURL)
            let source = CmuxAgentSessionRegistry.LegacySource(
                provider: "codex",
                url: root.appendingPathComponent("codex.json")
            )
            if hasCanonical {
                let rootObject = try #require(
                    try JSONSerialization.jsonObject(
                        with: inspectionSidecar(sessionID: "canonical")
                    ) as? [String: Any]
                )
                let sessions = try #require(rootObject["sessions"] as? [String: Any])
                let object = try #require(sessions["canonical"] as? [String: Any])
                try registry.apply(provider: source.provider, records: [
                    CmuxAgentSessionRegistry.Record(
                        provider: source.provider,
                        sessionID: "canonical",
                        updatedAt: 1,
                        json: try JSONSerialization.data(
                            withJSONObject: object,
                            options: [.sortedKeys]
                        )
                    ),
                ])
            }
            try writeRevision(
                inspectionSidecar(sessionID: "a"),
                to: source.url,
                modifiedAt: 200
            )
            var revision = 200.0
            var result: AgentHookSessionRegistryBridge.InspectionPreflightResult?
            var failure: AgentHookSessionStoreLoadFailure?
            do {
                result = try AgentHookSessionRegistryBridge.preflightInspectionSources(
                    [source],
                    registry: registry,
                    registryPath: registryURL.path,
                    fileManager: .default,
                    maximumLegacyGraphNodes: 20_000,
                    admissionLoader: { source, stamp, remainingGraphNodes in
                        revision += 1
                        let sessionID = Int(revision).isMultiple(of: 2) ? "b" : "c"
                        try writeRevision(
                            inspectionSidecar(sessionID: sessionID),
                            to: source.url,
                            modifiedAt: revision
                        )
                        return try registry.hookLegacySourceAdmission(
                            source: source,
                            expectedStamp: stamp,
                            maximumGraphNodes: remainingGraphNodes
                        )
                    }
                )
            } catch let error as AgentHookSessionStoreLoadFailure {
                failure = error
            }
            return (result, failure, registry, source, root)
        }

        let canonical = try exercise(hasCanonical: true)
        defer { try? FileManager.default.removeItem(at: canonical.root) }
        let canonicalResult = try #require(canonical.result)
        #expect(canonical.failure?.code == nil)
        #expect(canonicalResult.admissions.isEmpty)
        #expect(canonicalResult.warnings == [AgentHookSessionStoreLoadWarning(
            provider: "codex",
            path: canonical.source.url.path,
            code: .legacySourceImportFailed,
            fallback: .registry
        )])
        let canonicalSnapshot = try #require(
            canonical.registry.snapshotsImportingAdmittedLegacy(
                sources: [canonical.source],
                admissions: canonicalResult.admissions
            )[canonical.source.provider]
        )
        #expect(canonicalSnapshot.records.map(\.sessionID) == ["canonical"])

        let legacyOnly = try exercise(hasCanonical: false)
        defer { try? FileManager.default.removeItem(at: legacyOnly.root) }
        #expect(legacyOnly.result?.warnings.count == nil)
        #expect(legacyOnly.failure?.code == .legacySourceImportFailed)
        #expect(try legacyOnly.registry.snapshot(provider: "codex").records.isEmpty)
    }

    private func source(
        provider: String,
        recordBytes: Int64,
        largestRecordBytes: Int64,
        legacyBytes: Int64
    ) -> AgentHookSessionRegistryBridge.InspectionSourcePreflight {
        AgentHookSessionRegistryBridge.InspectionSourcePreflight(
            provider: provider,
            registryPath: "/registry.sqlite3",
            legacyPath: "/\(provider).json",
            metrics: CmuxAgentSessionRegistry.HookStorageMetrics(
                recordCount: largestRecordBytes == 0 ? 0 : 1,
                recordBytes: recordBytes,
                activeSlotBytes: 0,
                largestRecordSessionID: largestRecordBytes == 0 ? nil : "session",
                largestRecordBytes: largestRecordBytes
            ),
            legacyBytes: legacyBytes
        )
    }

    private func inspectionSidecar(sessionID: String) throws -> Data {
        let runID = "run-\(sessionID)"
        return try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "sessions": [
                sessionID: [
                    "sessionId": sessionID,
                    "workspaceId": "workspace-\(sessionID)",
                    "surfaceId": "surface-\(sessionID)",
                    "runId": runID,
                    "activeRunId": runID,
                    "restoreAuthority": false,
                    "sessionState": "ended",
                    "foregroundState": "completed",
                    "startedAt": 1.0,
                    "updatedAt": 1.0,
                    "completedAt": 1.0,
                    "runs": [[
                        "runId": runID,
                        "restoreAuthority": false,
                        "startedAt": 1.0,
                        "updatedAt": 1.0,
                        "endedAt": 1.0,
                    ]],
                ],
            ],
        ], options: [.sortedKeys])
    }

    private func writeRevision(
        _ data: Data,
        to url: URL,
        modifiedAt: TimeInterval
    ) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: modifiedAt)],
            ofItemAtPath: url.path
        )
    }

    private func storageFailure(
        for sources: [AgentHookSessionRegistryBridge.InspectionSourcePreflight]
    ) -> AgentHookSessionStoreLoadFailure? {
        do {
            try AgentHookSessionRegistryBridge.validateInspectionStorage(sources)
            return nil
        } catch let failure as AgentHookSessionStoreLoadFailure {
            return failure
        } catch {
            return nil
        }
    }
}
