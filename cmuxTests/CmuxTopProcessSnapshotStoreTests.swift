import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct CmuxTopProcessSnapshotStoreTests {
    @Test
    func concurrentEquivalentRequestsShareOneCapture() async {
#if DEBUG
        let metricsStore = ProcessPerformanceMetrics()
#endif
        let capturer = ControlledProcessSnapshotCapturer()
        let clock = ProcessSnapshotTestClock(now: Date(timeIntervalSince1970: 100))
#if DEBUG
        let store = CmuxTopProcessSnapshotStore(
            now: { await clock.read() },
            capture: { requirements in
                await capturer.capture(requirements: requirements)
            },
            metrics: metricsStore
        )
#else
        let store = CmuxTopProcessSnapshotStore(
            now: { await clock.read() },
            capture: { requirements in
                await capturer.capture(requirements: requirements)
            }
        )
#endif

        let first = Task {
            await store.snapshot(
                requirements: .basic,
                maximumAge: 10,
                consumer: .portScannerPanel
            )
        }
        await capturer.waitForCallCount(1)
        let second = Task {
            await store.snapshot(
                requirements: .basic,
                maximumAge: 10,
                consumer: .portScannerPanel
            )
        }
#if DEBUG
        // Do not release the controlled capture until the second actor request
        // has entered the store. Without this signal the scheduler may run the
        // second task only after completion, turning the intended in-flight
        // reuse assertion into a cache-hit race.
        for _ in 0..<10_000 {
            if metricsStore.snapshot().requestCountsByConsumer[
                ProcessSnapshotConsumer.portScannerPanel.rawValue
            ] == 2 {
                break
            }
            await Task.yield()
        }
        #expect(
            metricsStore.snapshot().requestCountsByConsumer[
                ProcessSnapshotConsumer.portScannerPanel.rawValue
            ] == 2
        )
#endif
        await capturer.releaseNext()

        let firstSnapshot = await first.value
        let secondSnapshot = await second.value
        #expect(firstSnapshot === secondSnapshot)
        #expect(await capturer.callCount() == 1)
        #expect(await capturer.maximumConcurrentCaptures() == 1)
#if DEBUG
        let metrics = metricsStore.snapshot()
        #expect(metrics.processSnapshots.captureStarted == 1)
        #expect(metrics.processSnapshots.captureCompleted == 1)
        #expect(metrics.processSnapshots.maximumInFlight == 1)
        #expect(metrics.processSnapshots.lastGeneration == 1)
        #expect(metrics.requestCountsByConsumer[ProcessSnapshotConsumer.portScannerPanel.rawValue] == 2)
        #expect(metrics.requestCountsByConsumer[ProcessSnapshotConsumer.memoryGuardrail.rawValue] == nil)
        #expect(
            metrics.consumerGenerationReuse[ProcessSnapshotConsumer.portScannerPanel.rawValue]?[1]?.inFlight == 1
        )
        let wireRequestCounts = metrics.foundationObject["request_counts_by_consumer"] as? [String: Int]
        #expect(wireRequestCounts?[ProcessSnapshotConsumer.portScannerPanel.rawValue] == 2)
        #expect(wireRequestCounts?[ProcessSnapshotConsumer.memoryGuardrail.rawValue] == nil)
#endif
    }

    @Test
    func strongerRequestWaitsForAndThenUpgradesWeakerCapture() async {
        let capturer = ControlledProcessSnapshotCapturer()
        let clock = ProcessSnapshotTestClock(now: Date(timeIntervalSince1970: 100))
        let store = CmuxTopProcessSnapshotStore(
            now: { await clock.read() },
            capture: { requirements in
                await capturer.capture(requirements: requirements)
            }
        )

        let basic = Task {
            await store.snapshot(requirements: .basic, maximumAge: 0)
        }
        await capturer.waitForCallCount(1)
        let detailed = Task {
            await store.snapshot(requirements: [.processDetails, .cmuxScope], maximumAge: 0)
        }

        await capturer.releaseNext()
        _ = await basic.value
        await capturer.waitForCallCount(2)
        await capturer.releaseNext()
        let detailedSnapshot = await detailed.value

        #expect(detailedSnapshot.hasCMUXScope)
        #expect(await capturer.capturedRequirements() == [
            .basic,
            [.processDetails, .cmuxScope]
        ])
        #expect(await capturer.maximumConcurrentCaptures() == 1)
    }

    @Test
    func cacheRespectsFreshnessAndCapabilityRequirements() async {
#if DEBUG
        let metricsStore = ProcessPerformanceMetrics()
#endif
        let capturer = ControlledProcessSnapshotCapturer(autoRelease: true)
        let clock = ProcessSnapshotTestClock(now: Date(timeIntervalSince1970: 100))
#if DEBUG
        let store = CmuxTopProcessSnapshotStore(
            now: { await clock.read() },
            capture: { requirements in
                await capturer.capture(requirements: requirements)
            },
            metrics: metricsStore
        )
#else
        let store = CmuxTopProcessSnapshotStore(
            now: { await clock.read() },
            capture: { requirements in
                await capturer.capture(requirements: requirements)
            }
        )
#endif

        let first = await store.snapshot(
            requirements: .basic,
            maximumAge: 3,
            consumer: .processDetectedResume
        )
        await clock.advance(by: 2)
        let cached = await store.snapshot(
            requirements: .basic,
            maximumAge: 3,
            consumer: .processDetectedResume
        )
        let upgraded = await store.snapshot(
            requirements: .processDetails,
            maximumAge: 3,
            consumer: .processDetectedResume
        )
        await clock.advance(by: 4)
        let refreshed = await store.snapshot(
            requirements: .basic,
            maximumAge: 3,
            consumer: .processDetectedResume
        )

        #expect(first === cached)
        #expect(upgraded !== cached)
        #expect(refreshed !== upgraded)
        #expect(await capturer.callCount() == 3)
#if DEBUG
        let metrics = metricsStore.snapshot()
        #expect(
            metrics.consumerGenerationReuse[ProcessSnapshotConsumer.processDetectedResume.rawValue]?[1]?.cache == 1
        )
#endif
    }

    @Test
    func staleCompletionCannotClearNewInFlightCaptureOrCache() async {
        let capturer = ControlledProcessSnapshotCapturer()
        let clock = SnapshotCompletionBarrierClock(
            now: Date(timeIntervalSince1970: 100),
            blockedReadNumbers: [3, 4]
        )
        let completions = SnapshotTaskCompletionCounter()
        let store = CmuxTopProcessSnapshotStore(
            now: { await clock.read() },
            capture: { requirements in
                await capturer.capture(requirements: requirements)
            }
        )

        let first = Task {
            let snapshot = await store.snapshot(requirements: .basic, maximumAge: 0)
            await completions.record()
            return snapshot
        }
        await capturer.waitForCallCount(1)
        let second = Task {
            let snapshot = await store.snapshot(requirements: .basic, maximumAge: 0)
            await completions.record()
            return snapshot
        }

        await capturer.releaseNext()
        await clock.waitForReadCount(4)
        await clock.resumeRead(3)
        await completions.waitForCount(1)

        await clock.advance(by: 1)
        let refreshed = Task {
            await store.snapshot(requirements: .basic, maximumAge: 0)
        }
        await capturer.waitForCallCount(2)

        await clock.resumeRead(4)
        await completions.waitForCount(2)
        await clock.advance(by: 1)
        let joined = Task {
            await store.snapshot(requirements: .basic, maximumAge: 0)
        }
        await clock.waitForReadCount(6)
        for _ in 0..<10_000 {
            if await capturer.callCount() >= 3 { break }
            await Task.yield()
        }

        await capturer.releaseAll()
        let refreshedSnapshot = await refreshed.value
        let joinedSnapshot = await joined.value
        let cachedSnapshot = await store.snapshot(requirements: .basic, maximumAge: 10)
        _ = await first.value
        _ = await second.value

        #expect(refreshedSnapshot === joinedSnapshot)
        #expect(cachedSnapshot === refreshedSnapshot)
        #expect(await capturer.callCount() == 2)
        #expect(await capturer.maximumConcurrentCaptures() == 1)
    }

#if DEBUG
    @Test
    func cacheReuseFromBeforeResetDoesNotEnterNewMetricsEpoch() async {
        let metricsStore = ProcessPerformanceMetrics()
        let capturer = ControlledProcessSnapshotCapturer(autoRelease: true)
        let clock = ProcessSnapshotTestClock(now: Date(timeIntervalSince1970: 100))
        let store = CmuxTopProcessSnapshotStore(
            now: { await clock.read() },
            capture: { requirements in
                await capturer.capture(requirements: requirements)
            },
            metrics: metricsStore
        )

        let captured = await store.snapshot(
            requirements: .basic,
            maximumAge: 10,
            consumer: .portScannerPanel
        )
        metricsStore.reset()
        let reused = await store.snapshot(
            requirements: .basic,
            maximumAge: 10,
            consumer: .portScannerPanel
        )

        let metrics = metricsStore.snapshot()
        #expect(captured === reused)
        #expect(metrics.processSnapshots.captureStarted == 0)
        #expect(metrics.processSnapshots.captureCompleted == 0)
        #expect(metrics.consumerGenerationReuse.isEmpty)
    }

    @Test
    func inFlightReuseFromBeforeResetDoesNotEnterNewMetricsEpoch() async {
        let metricsStore = ProcessPerformanceMetrics()
        let capturer = ControlledProcessSnapshotCapturer()
        let clock = ProcessSnapshotTestClock(now: Date(timeIntervalSince1970: 100))
        let store = CmuxTopProcessSnapshotStore(
            now: { await clock.read() },
            capture: { requirements in
                await capturer.capture(requirements: requirements)
            },
            metrics: metricsStore
        )

        let first = Task {
            await store.snapshot(
                requirements: .basic,
                maximumAge: 10,
                consumer: .portScannerPanel
            )
        }
        await capturer.waitForCallCount(1)
        metricsStore.reset()
        let reused = Task {
            await store.snapshot(
                requirements: .basic,
                maximumAge: 10,
                consumer: .portScannerPanel
            )
        }
        await capturer.releaseNext()

        let firstSnapshot = await first.value
        let reusedSnapshot = await reused.value
        #expect(firstSnapshot === reusedSnapshot)
        let metrics = metricsStore.snapshot()
        #expect(metrics.processSnapshots.captureStarted == 0)
        #expect(metrics.processSnapshots.captureCompleted == 0)
        #expect(metrics.consumerGenerationReuse.isEmpty)
    }
#endif
}
