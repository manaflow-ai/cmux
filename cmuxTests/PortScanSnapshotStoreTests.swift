import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct PortScanSnapshotStoreTests {
    @Test
    func concurrentCoveredRequestsShareOneLibprocCapture() async {
        let metricsStore = ProcessPerformanceMetrics(enabled: true)
        let capturer = ControlledPortScanCapturer()
        let clock = PortScanTestClock(now: Date(timeIntervalSince1970: 100))
        let store = PortScanSnapshotStore(
            now: { await clock.read() },
            capture: { pids in await capturer.capture(pids: pids) },
            metrics: metricsStore
        )

        let first = Task {
            await store.snapshot(pids: [10, 20], maximumAge: 2)
        }
        await capturer.waitForCallCount(1)
        let covered = Task {
            await store.snapshot(pids: [20], maximumAge: 2)
        }
        #expect(await waitForMetrics {
            let reuse = metricsStore.snapshot().lsof.reuse
            return reuse.cache + reuse.inFlight == 1
        })
        await capturer.releaseNext()

        let firstResult = await first.value
        let coveredResult = await covered.value
        #expect(firstResult == [10: [1_010], 20: [1_020]])
        #expect(coveredResult == firstResult)
        #expect(await capturer.callCount() == 1)
        #expect(await capturer.maximumConcurrentCaptures() == 1)
        let metrics = metricsStore.snapshot()
        #expect(metrics.lsof.started == 1)
        #expect(metrics.lsof.completed == 1)
        #expect(metrics.lsof.maximumInFlight == 1)
        #expect(metrics.lsof.reuse.cache + metrics.lsof.reuse.inFlight == 1)
        let wireLsof = metrics.foundationObject["lsof"] as? [String: Any]
        #expect(wireLsof?["backend"] as? String == "libproc")
        #expect(wireLsof?["process_launches"] as? Int == 0)
    }

    @Test
    func uncoveredRequestsCoalesceIntoOneBoundedFollowup() async {
        let metricsStore = ProcessPerformanceMetrics(enabled: true)
        let capturer = ControlledPortScanCapturer()
        let clock = PortScanTestClock(now: Date(timeIntervalSince1970: 100))
        let store = PortScanSnapshotStore(
            now: { await clock.read() },
            capture: { pids in await capturer.capture(pids: pids) },
            metrics: metricsStore
        )

        let first = Task {
            await store.snapshot(pids: [10], maximumAge: 2)
        }
        await capturer.waitForCallCount(1)
        let second = Task {
            await store.snapshot(pids: [20], maximumAge: 2)
        }
        let third = Task {
            await store.snapshot(pids: [30], maximumAge: 2)
        }
        #expect(await waitForMetrics {
            metricsStore.snapshot().lsof.coalescedRequests == 2
        })

        await capturer.releaseNext()
        await capturer.waitForCallCount(2)
        #expect(await capturer.capturedPIDRequests() == [[10], [20, 30]])
        #expect(await capturer.maximumConcurrentCaptures() == 1)
        await capturer.releaseNext()

        #expect(await first.value == [10: [1_010]])
        #expect(await second.value == [20: [1_020], 30: [1_030]])
        #expect(await third.value == [20: [1_020], 30: [1_030]])
        #expect(await capturer.callCount() == 2)
        #expect(await capturer.maximumConcurrentCaptures() == 1)
    }

    @Test
    func freshSupersetCacheServesSubsetsAndExpiryRefreshesListeners() async {
        let metricsStore = ProcessPerformanceMetrics(enabled: true)
        let capturer = ControlledPortScanCapturer(autoRelease: true)
        let clock = PortScanTestClock(now: Date(timeIntervalSince1970: 100))
        let store = PortScanSnapshotStore(
            now: { await clock.read() },
            capture: { pids in await capturer.capture(pids: pids) },
            metrics: metricsStore
        )

        let first = await store.snapshot(pids: [10, 20], maximumAge: 2)
        let cached = await store.snapshot(pids: [20], maximumAge: 2)
        await clock.advance(by: 3)
        let refreshed = await store.snapshot(pids: [20], maximumAge: 2)

        #expect(first == [10: [1_010], 20: [1_020]])
        #expect(cached == first)
        #expect(refreshed == [20: [1_020]])
        #expect(await capturer.callCount() == 2)
        #expect(await capturer.capturedPIDRequests() == [[10, 20], [20]])
        let metrics = metricsStore.snapshot()
        #expect(metrics.lsof.reuse.cache == 1)
    }

    @Test
    func staleCompletionCannotClearNewInFlightCaptureOrCache() async {
        let capturer = ControlledPortScanCapturer(resultIncludesCaptureOrdinal: true)
        let clock = SnapshotCompletionBarrierClock(
            now: Date(timeIntervalSince1970: 100),
            blockedReadNumbers: [3, 4]
        )
        let completions = SnapshotTaskCompletionCounter()
        let store = PortScanSnapshotStore(
            now: { await clock.read() },
            capture: { pids in await capturer.capture(pids: pids) }
        )

        let first = Task {
            let snapshot = await store.snapshot(pids: [10], maximumAge: 0)
            await completions.record()
            return snapshot
        }
        await capturer.waitForCallCount(1)
        let second = Task {
            let snapshot = await store.snapshot(pids: [10], maximumAge: 0)
            await completions.record()
            return snapshot
        }

        await capturer.releaseNext()
        await clock.waitForReadCount(4)
        await clock.resumeRead(3)
        await completions.waitForCount(1)

        await clock.advance(by: 1)
        let refreshed = Task {
            await store.snapshot(pids: [20], maximumAge: 0)
        }
        await capturer.waitForCallCount(2)

        await clock.resumeRead(4)
        await completions.waitForCount(2)
        await clock.advance(by: 1)
        let joined = Task {
            await store.snapshot(pids: [20], maximumAge: 0)
        }
        await clock.waitForReadCount(6)
        for _ in 0..<10_000 {
            if await capturer.callCount() >= 3 { break }
            await Task.yield()
        }

        await capturer.releaseAll()
        let refreshedSnapshot = await refreshed.value
        let joinedSnapshot = await joined.value
        let cachedSnapshot = await store.snapshot(pids: [20], maximumAge: 10)
        _ = await first.value
        _ = await second.value

        #expect(refreshedSnapshot == [20: [20_020]])
        #expect(joinedSnapshot == refreshedSnapshot)
        #expect(cachedSnapshot == refreshedSnapshot)
        #expect(await capturer.callCount() == 2)
        #expect(await capturer.maximumConcurrentCaptures() == 1)
    }

    private func waitForMetrics(
        _ predicate: @escaping @Sendable () -> Bool
    ) async -> Bool {
        for _ in 0..<10_000 {
            if predicate() { return true }
            await Task.yield()
        }
        return predicate()
    }

    @Test
    func captureProofSurfacesSubprocessBackendAndLaunchCount() async {
        let metricsStore = ProcessPerformanceMetrics(enabled: true)
        let store = PortScanSnapshotStore(
            captureWithProof: { pids in
                (
                    Dictionary(uniqueKeysWithValues: pids.map { ($0, Set([8_000 + $0])) }),
                    ProcessPerformanceCaptureProof(backend: .subprocess, processLaunchCount: 1)
                )
            },
            metrics: metricsStore
        )

        _ = await store.snapshot(pids: [42], maximumAge: 0)
        let metrics = metricsStore.snapshot()
        let wireLsof = metrics.foundationObject["lsof"] as? [String: Any]

        #expect(metrics.lsof.backendCounts == ["subprocess": 1])
        #expect(metrics.lsof.processLaunches == 1)
        #expect(wireLsof?["backend"] as? String == "subprocess")
        #expect(wireLsof?["process_launches"] as? Int == 1)
    }

    @Test
    func performanceExerciseUsesTwoRealSnapshotRequests() async {
        let metricsStore = ProcessPerformanceMetrics(enabled: true)
        let capturer = ControlledPortScanCapturer(autoRelease: true)
        let store = PortScanSnapshotStore(
            capture: { pids in await capturer.capture(pids: pids) },
            metrics: metricsStore
        )

        _ = await store.snapshot(pids: [42], maximumAge: 10)
        metricsStore.reset(enable: true)
        let exercise = await store.performanceMetricsExercise(pids: [42])
        let metrics = metricsStore.snapshot()

        #expect(exercise?.proof == .libproc)
        #expect(exercise?.sharedResult == true)
        #expect(metrics.lsof.started == 1)
        #expect(metrics.lsof.completed == 1)
        #expect(metrics.lsof.reuse.inFlight == 1)
        #expect(await capturer.callCount() == 2)
    }

    @Test
    func cancellingPerformanceExerciseUnblocksNormalConsumers() async {
        let metricsStore = ProcessPerformanceMetrics(enabled: false)
        metricsStore.reset(enable: true)
        let capturer = ControlledPortScanCapturer()
        let store = PortScanSnapshotStore(
            capture: { pids in await capturer.capture(pids: pids) },
            metrics: metricsStore
        )
        let exercise = Task { await store.performanceMetricsExercise(pids: [42]) }
        await capturer.waitForCallCount(1)
        #expect(await waitForMetrics {
            metricsStore.snapshot().lsof.reuse.inFlight == 1
        })

        exercise.cancel()
        let normal = Task {
            await store.snapshot(pids: [42], maximumAge: 10)
        }
        await capturer.releaseNext()

        let cancelledExercise = await exercise.value
        #expect(cancelledExercise?.proof == nil)
        #expect(await normal.value == [42: [1_042]])
        #expect(metricsStore.snapshot().lsof.completed == 1)
    }
}
