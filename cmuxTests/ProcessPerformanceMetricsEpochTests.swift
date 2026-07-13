import Darwin
import Foundation
import Testing
import os

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct ProcessPerformanceMetricsEpochTests {
    @Test
    func disabledCollectionDoesNotAccumulateUntilExplicitReset() {
        let metricsStore = ProcessPerformanceMetrics(enabled: false)
        let token = metricsStore.processSnapshotCaptureStarted(
            generation: 1,
            requirementsRawValue: 0
        )
        metricsStore.processSnapshotCaptureCompleted(token, generation: 1, processCount: 3)

        #expect(metricsStore.snapshot().enabled == false)
        #expect(metricsStore.snapshot().processSnapshots.captureStarted == 0)
        #expect(metricsStore.snapshot().foundationObject["schema_version"] as? Int == 3)
        #expect(metricsStore.snapshot().foundationObject["enabled"] as? Bool == false)

        metricsStore.reset(enable: true)
        let enabledToken = metricsStore.processSnapshotCaptureStarted(
            generation: 2,
            requirementsRawValue: 0
        )
        metricsStore.processSnapshotCaptureCompleted(enabledToken, generation: 2, processCount: 3)

        #expect(metricsStore.snapshot().enabled == true)
        #expect(metricsStore.snapshot().processSnapshots.captureStarted == 1)

        metricsStore.disable()
        #expect(metricsStore.snapshot().enabled == false)
    }

    @Test
    func monotonicMeasurementEpochDistinguishesResetsInTheSameWallClockMillisecond() {
        let metricsStore = ProcessPerformanceMetrics(
            enabled: false,
            unixMilliseconds: { 1_752_345_678_901 }
        )

        metricsStore.reset(enable: true)
        let first = metricsStore.snapshot()
        metricsStore.reset(enable: true)
        let second = metricsStore.snapshot()

        #expect(first.resetAtUnixMilliseconds == second.resetAtUnixMilliseconds)
        #expect(first.measurementEpoch == 1)
        #expect(second.measurementEpoch == 2)
        #expect(first.foundationObject["measurement_epoch"] as? UInt64 == 1)
        #expect(second.foundationObject["measurement_epoch"] as? UInt64 == 2)
    }

    @Test
    func measurementEpochWrapSkipsReservedZero() {
        #expect(ProcessPerformanceMetrics.nextMeasurementEpoch(after: .max) == 1)
    }

    @Test
    func completionsFromBeforeResetDoNotEnterTheNewMeasurementEpoch() {
        let metricsStore = ProcessPerformanceMetrics(enabled: true)
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

    @Test
    func disabledFastPathDoesNotReadClockAcrossRecorderSurface() {
        let clockReads = OSAllocatedUnfairLock(initialState: 0)
        let metricsStore = ProcessPerformanceMetrics(
            enabled: false,
            monotonicNanoseconds: {
                clockReads.withLock { reads in
                    reads += 1
                    return UInt64(reads)
                }
            }
        )

        for generation in 1...10_000 {
            let capture = metricsStore.processSnapshotCaptureStarted(
                generation: UInt64(generation),
                requirementsRawValue: 3
            )
            metricsStore.recordProcessSnapshotRequest(consumer: .systemTop)
            metricsStore.recordProcessSnapshotReuse(
                consumer: .systemTop,
                generation: UInt64(generation),
                source: .cache,
                token: capture
            )
            metricsStore.processSnapshotCaptureCompleted(
                capture,
                generation: UInt64(generation),
                processCount: 3
            )
            let lsof = metricsStore.lsofStarted(pidCount: 3)
            metricsStore.recordLsofReuse(.cache, token: lsof)
            metricsStore.recordLsofCoalescedRequest(token: lsof)
            metricsStore.lsofCompleted(lsof)
            let operation = metricsStore.operationStarted(.portFilter, inputCount: 3)
            metricsStore.operationCompleted(operation, outputCount: 1)
            metricsStore.recordStaleRejection(.portPanelRevision)
        }

        #expect(clockReads.withLock { $0 } == 0)
        #expect(metricsStore.snapshot().processSnapshots.captureStarted == 0)
        #expect(metricsStore.snapshot().lsof.started == 0)
        #expect(metricsStore.snapshot().operations.isEmpty)
    }
}
