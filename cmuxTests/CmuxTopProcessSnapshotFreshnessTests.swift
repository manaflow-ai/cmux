import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension CmuxTopProcessSnapshotStoreTests {
    @Test
    func captureBoundaryRejectsCachedSnapshotStartedBeforeRequest() async {
        let capturer = ControlledProcessSnapshotCapturer(autoRelease: true)
        let clock = ProcessSnapshotTestClock(now: Date(timeIntervalSince1970: 100))
        let store = CmuxTopProcessSnapshotStore(
            now: { await clock.read() },
            capture: { requirements in
                await capturer.capture(requirements: requirements)
            }
        )

        let cached = await store.snapshot(requirements: .basic, maximumAge: 10)
        await clock.advance(by: 1)
        let requestBoundary = await clock.read()
        let authoritative = await store.snapshot(
            requirements: .basic,
            maximumAge: 10,
            minimumCaptureStartedAt: requestBoundary
        )

        #expect(authoritative !== cached)
        #expect(await capturer.callCount() == 2)
    }

    @Test
    func captureBoundaryRejectsInFlightSnapshotStartedBeforeRequest() async {
        let metricsStore = ProcessPerformanceMetrics(enabled: true)
        let capturer = ControlledProcessSnapshotCapturer()
        let clock = ProcessSnapshotTestClock(now: Date(timeIntervalSince1970: 100))
        let store = CmuxTopProcessSnapshotStore(
            now: { await clock.read() },
            capture: { requirements in
                await capturer.capture(requirements: requirements)
            },
            metrics: metricsStore
        )

        let older = Task {
            await store.snapshot(
                requirements: .basic,
                maximumAge: 10,
                consumer: .processDetectedResume
            )
        }
        await capturer.waitForCallCount(1)
        await clock.advance(by: 1)
        let requestBoundary = await clock.read()
        let authoritative = Task {
            await store.snapshot(
                requirements: .basic,
                maximumAge: 10,
                minimumCaptureStartedAt: requestBoundary,
                consumer: .processDetectedResume
            )
        }
        for _ in 0..<10_000 {
            if metricsStore.snapshot().requestCountsByConsumer[
                ProcessSnapshotConsumer.processDetectedResume.rawValue
            ] == 2 {
                break
            }
            await Task.yield()
        }

        await capturer.releaseNext()
        await capturer.waitForCallCount(2)
        await capturer.releaseNext()
        let olderSnapshot = await older.value
        let authoritativeSnapshot = await authoritative.value

        #expect(authoritativeSnapshot !== olderSnapshot)
        #expect(await capturer.callCount() == 2)
        #expect(await capturer.maximumConcurrentCaptures() == 1)
    }
}
