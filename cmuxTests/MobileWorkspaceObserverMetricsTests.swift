import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct MobileWorkspaceObserverMetricsTests {
    @Test func runtimeMetricsExposeAggregateReleaseSafeProofAndResetEpoch() throws {
        let metrics = MobileWorkspaceObserverMetrics(enabled: true)

        metrics.recordInvalidationSubmitted(.workspaceGraph)
        metrics.recordInvalidationSubmitted(.workspace)
        metrics.recordInvalidationSubmitted(.workspace)
        metrics.recordInvalidationSubmitted(.preview)
        metrics.recordInvalidationSubmitted(.summary)

        let batchToken = metrics.batchDrainStarted(invalidationCount: 4)
        metrics.operationCompleted(batchToken)
        let graphToken = metrics.fullGraphRebuildStarted()
        metrics.operationCompleted(graphToken, workspacesRehashed: 5)
        let incrementalToken = metrics.incrementalRefreshStarted()
        metrics.operationCompleted(incrementalToken, workspacesRehashed: 2)
        let previewToken = metrics.previewSignaturesStarted()
        metrics.operationCompleted(previewToken)
        let summaryToken = metrics.summaryHashStarted()
        metrics.operationCompleted(summaryToken)
        metrics.recordEmit()
        metrics.recordSkip()

        let snapshot = metrics.snapshot()
        #expect(snapshot.schemaVersion == 1)
        #expect(snapshot.enabled)
        #expect(snapshot.invalidationsSubmitted == [
            "workspace_graph": 1,
            "workspace": 2,
            "preview": 1,
            "summary": 1,
        ])
        #expect(snapshot.batchDrains == 1)
        #expect(snapshot.invalidationsDrained == 4)
        #expect(snapshot.workspacesRehashed == 7)
        #expect(snapshot.fullGraphRebuilds == 1)
        #expect(snapshot.emits == 1)
        #expect(snapshot.skips == 1)
        #expect(snapshot.batchDrainDuration.count == 1)
        #expect(snapshot.fullGraphRebuildDuration.count == 1)
        #expect(snapshot.incrementalRefreshDuration.count == 1)
        #expect(snapshot.previewSignaturesDuration.count == 1)
        #expect(snapshot.summaryHashDuration.count == 1)
        #expect(snapshot.foundationObject["schema_version"] as? Int == 1)
        let durations = try #require(snapshot.foundationObject["duration_ms"] as? [String: Any])
        #expect(Set(durations.keys) == [
            "batch_drain",
            "full_graph_rebuild",
            "incremental_refresh",
            "preview_signatures",
            "summary_hash",
        ])

        let staleToken = metrics.fullGraphRebuildStarted()
        metrics.reset(enable: true)
        metrics.operationCompleted(staleToken, workspacesRehashed: 99)

        let resetSnapshot = metrics.snapshot()
        #expect(resetSnapshot.enabled)
        #expect(Set(resetSnapshot.invalidationsSubmitted.values) == [0])
        #expect(resetSnapshot.batchDrains == 0)
        #expect(resetSnapshot.invalidationsDrained == 0)
        #expect(resetSnapshot.workspacesRehashed == 0)
        #expect(resetSnapshot.fullGraphRebuilds == 0)
        #expect(resetSnapshot.emits == 0)
        #expect(resetSnapshot.skips == 0)
        #expect(resetSnapshot.fullGraphRebuildDuration.count == 0)
    }

    @Test func runtimeMetricsDisabledLifecycleDoesNotAccumulate() {
        // The process-wide store uses this default in Debug and Release. The
        // diagnostics owner must opt in with reset(enable: true).
        let metrics = MobileWorkspaceObserverMetrics()

        metrics.recordInvalidationSubmitted(.workspace)
        #expect(metrics.batchDrainStarted(invalidationCount: 1) == nil)
        #expect(metrics.fullGraphRebuildStarted() == nil)
        #expect(metrics.incrementalRefreshStarted() == nil)
        #expect(metrics.previewSignaturesStarted() == nil)
        #expect(metrics.summaryHashStarted() == nil)
        metrics.recordEmit()
        metrics.recordSkip()

        let disabledSnapshot = metrics.snapshot()
        #expect(!disabledSnapshot.enabled)
        #expect(Set(disabledSnapshot.invalidationsSubmitted.values) == [0])
        #expect(disabledSnapshot.batchDrains == 0)
        #expect(disabledSnapshot.fullGraphRebuilds == 0)
        #expect(disabledSnapshot.emits == 0)
        #expect(disabledSnapshot.skips == 0)
        #expect(disabledSnapshot.summaryHashDuration.count == 0)
        #expect(disabledSnapshot.foundationObject["enabled"] as? Bool == false)

        metrics.reset(enable: true)
        metrics.recordInvalidationSubmitted(.summary)
        metrics.recordEmit()
        #expect(metrics.snapshot().enabled)
        #expect(metrics.snapshot().invalidationsSubmitted["summary"] == 1)
        #expect(metrics.snapshot().emits == 1)

        metrics.disable()
        metrics.recordInvalidationSubmitted(.summary)
        metrics.recordEmit()
        let stoppedSnapshot = metrics.snapshot()
        #expect(!stoppedSnapshot.enabled)
        #expect(stoppedSnapshot.invalidationsSubmitted["summary"] == 1)
        #expect(stoppedSnapshot.emits == 1)
    }
}
