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
