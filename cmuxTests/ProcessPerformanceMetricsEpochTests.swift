import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

#if DEBUG
@Suite
struct ProcessPerformanceMetricsEpochTests {
    @Test
    func completionsFromBeforeResetDoNotEnterTheNewMeasurementEpoch() {
        let metricsStore = ProcessPerformanceMetrics()
        let processToken = metricsStore.processSnapshotCaptureStarted(
            generation: 1,
            requirementsRawValue: 0
        )
        let lsofToken = metricsStore.lsofStarted(pidCount: 3)
        let operationToken = metricsStore.operationStarted(.portFilter, inputCount: 3)

        metricsStore.reset()
        metricsStore.processSnapshotCaptureCompleted(
            processToken,
            generation: 1,
            processCount: 3
        )
        metricsStore.recordLsofReuse(.cache, token: lsofToken)
        metricsStore.recordLsofCoalescedRequest(token: lsofToken)
        metricsStore.lsofCompleted(lsofToken)
        metricsStore.operationCompleted(operationToken, outputCount: 2)

        let metrics = metricsStore.snapshot()
        #expect(metrics.processSnapshots.captureStarted == 0)
        #expect(metrics.processSnapshots.captureCompleted == 0)
        #expect(metrics.processSnapshots.inFlight == 0)
        #expect(metrics.generations.isEmpty)
        #expect(metrics.requestCountsByConsumer.isEmpty)
        #expect(metrics.lsof.started == 0)
        #expect(metrics.lsof.completed == 0)
        #expect(metrics.lsof.inFlight == 0)
        #expect(metrics.lsof.coalescedRequests == 0)
        #expect(metrics.lsof.reuse == ProcessPerformanceReuseMetrics())
        #expect(metrics.operations.isEmpty)
    }
}
#endif
