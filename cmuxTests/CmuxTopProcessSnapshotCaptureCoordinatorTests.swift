import Foundation
import os
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct CmuxTopProcessSnapshotCaptureCoordinatorTests {
    @Test
    func overlappingCompatibleRequestsShareOnePhysicalCapture() async {
        let firstCaptureStarted = DispatchSemaphore(value: 0)
        let releaseFirstCapture = DispatchSemaphore(value: 0)
        let secondRequestStarted = DispatchSemaphore(value: 0)
        let duplicateCaptureStarted = DispatchSemaphore(value: 0)
        defer {
            releaseFirstCapture.signal()
            releaseFirstCapture.signal()
        }
        let captureCount = OSAllocatedUnfairLock(initialState: 0)
        let sampledAt = Date(timeIntervalSince1970: 1_000)
        let coordinator = CmuxTopProcessSnapshotCaptureCoordinator(
            captureProvider: { includeProcessDetails, includeCMUXScope in
                let invocation = captureCount.withLock { count in
                    count += 1
                    return count
                }
                if invocation == 1 {
                    firstCaptureStarted.signal()
                    releaseFirstCapture.wait()
                } else {
                    duplicateCaptureStarted.signal()
                }
                return Self.snapshot(
                    sampledAt: sampledAt,
                    includeProcessDetails: includeProcessDetails,
                    includeCMUXScope: includeCMUXScope
                )
            },
            nowProvider: { sampledAt }
        )

        let firstRequest = Task.detached {
            coordinator.captureCached(
                includeProcessDetails: true,
                includeCMUXScope: true,
                maximumAge: 5
            )
        }
        let firstDidStart = await Self.wait(for: firstCaptureStarted)
        #expect(firstDidStart)
        guard firstDidStart else { return }

        let secondRequest = Task.detached {
            secondRequestStarted.signal()
            return coordinator.captureCached(
                includeProcessDetails: true,
                includeCMUXScope: true,
                maximumAge: 5
            )
        }
        let secondDidStart = await Self.wait(for: secondRequestStarted)
        #expect(secondDidStart)
        guard secondDidStart else { return }

        let duplicateStartedWhileFirstWasBlocked = await Self.wait(
            for: duplicateCaptureStarted,
            timeout: 0.1
        )
        #expect(!duplicateStartedWhileFirstWasBlocked)
        releaseFirstCapture.signal()

        let first = await firstRequest.value
        let second = await secondRequest.value
        #expect(first === second)
        #expect(captureCount.withLock { $0 } == 1)
    }

    @Test
    func strongerRequestsWaitAndShareOneSuccessorCapture() async {
        let weakCaptureStarted = DispatchSemaphore(value: 0)
        let releaseWeakCapture = DispatchSemaphore(value: 0)
        let strongCaptureStarted = DispatchSemaphore(value: 0)
        let releaseStrongCapture = DispatchSemaphore(value: 0)
        let strongRequestStarted = DispatchSemaphore(value: 0)
        defer {
            releaseWeakCapture.signal()
            releaseStrongCapture.signal()
            releaseStrongCapture.signal()
        }
        let stats = OSAllocatedUnfairLock(
            initialState: (captureCount: 0, activeCount: 0, maximumActiveCount: 0)
        )
        let sampledAt = Date(timeIntervalSince1970: 2_000)
        let coordinator = CmuxTopProcessSnapshotCaptureCoordinator(
            captureProvider: { includeProcessDetails, includeCMUXScope in
                let invocation = stats.withLock { stats in
                    stats.captureCount += 1
                    stats.activeCount += 1
                    stats.maximumActiveCount = max(stats.maximumActiveCount, stats.activeCount)
                    return stats.captureCount
                }
                defer { stats.withLock { $0.activeCount -= 1 } }
                if invocation == 1 {
                    weakCaptureStarted.signal()
                    releaseWeakCapture.wait()
                } else {
                    strongCaptureStarted.signal()
                    releaseStrongCapture.wait()
                }
                return Self.snapshot(
                    sampledAt: sampledAt,
                    includeProcessDetails: includeProcessDetails,
                    includeCMUXScope: includeCMUXScope
                )
            },
            nowProvider: { sampledAt }
        )

        let weakRequest = Task.detached {
            coordinator.captureCached(
                includeProcessDetails: false,
                includeCMUXScope: false,
                maximumAge: 5
            )
        }
        let weakDidStart = await Self.wait(for: weakCaptureStarted)
        #expect(weakDidStart)
        guard weakDidStart else { return }

        let firstStrongRequest = Task.detached {
            strongRequestStarted.signal()
            return coordinator.captureCached(
                includeProcessDetails: true,
                includeCMUXScope: true,
                maximumAge: 5
            )
        }
        let secondStrongRequest = Task.detached {
            strongRequestStarted.signal()
            return coordinator.captureCached(
                includeProcessDetails: true,
                includeCMUXScope: true,
                maximumAge: 5
            )
        }
        #expect(await Self.wait(for: strongRequestStarted))
        #expect(await Self.wait(for: strongRequestStarted))

        let strongStartedBeforeWeakFinished = await Self.wait(
            for: strongCaptureStarted,
            timeout: 0.1
        )
        #expect(!strongStartedBeforeWeakFinished)
        releaseWeakCapture.signal()
        let strongDidStart = await Self.wait(for: strongCaptureStarted)
        #expect(strongDidStart)
        guard strongDidStart else { return }
        releaseStrongCapture.signal()

        let weak = await weakRequest.value
        let firstStrong = await firstStrongRequest.value
        let secondStrong = await secondStrongRequest.value
        let finalStats = stats.withLock { $0 }
        #expect(weak !== firstStrong)
        #expect(firstStrong === secondStrong)
        #expect(finalStats.captureCount == 2)
        #expect(finalStats.maximumActiveCount == 1)
    }

    @Test
    func cachedCaptureUsesSnapshotAgeForReuseAndExpiry() {
        let now = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 3_000))
        let captureCount = OSAllocatedUnfairLock(initialState: 0)
        let coordinator = CmuxTopProcessSnapshotCaptureCoordinator(
            captureProvider: { includeProcessDetails, includeCMUXScope in
                captureCount.withLock { $0 += 1 }
                return Self.snapshot(
                    sampledAt: now.withLock { $0 },
                    includeProcessDetails: includeProcessDetails,
                    includeCMUXScope: includeCMUXScope
                )
            },
            nowProvider: { now.withLock { $0 } }
        )

        let first = coordinator.captureCached(
            includeProcessDetails: true,
            includeCMUXScope: true,
            maximumAge: 5
        )
        now.withLock { $0 = Date(timeIntervalSince1970: 3_004.9) }
        let reused = coordinator.captureCached(
            includeProcessDetails: true,
            includeCMUXScope: true,
            maximumAge: 5
        )
        now.withLock { $0 = Date(timeIntervalSince1970: 3_005.1) }
        let expired = coordinator.captureCached(
            includeProcessDetails: true,
            includeCMUXScope: true,
            maximumAge: 5
        )

        #expect(first === reused)
        #expect(first !== expired)
        #expect(captureCount.withLock { $0 } == 2)
    }

    @Test
    func coordinatedFreshCaptureRejectsACompatibleCachedSnapshot() {
        let now = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 4_000))
        let captureCount = OSAllocatedUnfairLock(initialState: 0)
        let coordinator = CmuxTopProcessSnapshotCaptureCoordinator(
            captureProvider: { includeProcessDetails, includeCMUXScope in
                captureCount.withLock { $0 += 1 }
                return Self.snapshot(
                    sampledAt: now.withLock { $0 },
                    includeProcessDetails: includeProcessDetails,
                    includeCMUXScope: includeCMUXScope
                )
            },
            nowProvider: { now.withLock { $0 } }
        )

        let cached = coordinator.captureCached(
            includeProcessDetails: true,
            includeCMUXScope: true,
            maximumAge: 5
        )
        let fresh = coordinator.captureCoordinatedFresh(
            includeProcessDetails: true,
            includeCMUXScope: true
        )
        let cachedAfterFresh = coordinator.captureCached(
            includeProcessDetails: true,
            includeCMUXScope: true,
            maximumAge: 5
        )

        #expect(cached !== fresh)
        #expect(fresh === cachedAfterFresh)
        #expect(captureCount.withLock { $0 } == 2)
    }

    @Test
    func coordinatedFreshCaptureWaitsBehindAnOlderInFlightCapture() async {
        let firstCaptureStarted = DispatchSemaphore(value: 0)
        let releaseFirstCapture = DispatchSemaphore(value: 0)
        let freshRequestStarted = DispatchSemaphore(value: 0)
        let freshCaptureStarted = DispatchSemaphore(value: 0)
        let releaseFreshCapture = DispatchSemaphore(value: 0)
        defer {
            releaseFirstCapture.signal()
            releaseFreshCapture.signal()
        }
        let stats = OSAllocatedUnfairLock(
            initialState: (captureCount: 0, activeCount: 0, maximumActiveCount: 0)
        )
        let sampledAt = Date(timeIntervalSince1970: 5_000)
        let coordinator = CmuxTopProcessSnapshotCaptureCoordinator(
            captureProvider: { includeProcessDetails, includeCMUXScope in
                let invocation = stats.withLock { stats in
                    stats.captureCount += 1
                    stats.activeCount += 1
                    stats.maximumActiveCount = max(stats.maximumActiveCount, stats.activeCount)
                    return stats.captureCount
                }
                defer { stats.withLock { $0.activeCount -= 1 } }
                if invocation == 1 {
                    firstCaptureStarted.signal()
                    releaseFirstCapture.wait()
                } else {
                    freshCaptureStarted.signal()
                    releaseFreshCapture.wait()
                }
                return Self.snapshot(
                    sampledAt: sampledAt,
                    includeProcessDetails: includeProcessDetails,
                    includeCMUXScope: includeCMUXScope
                )
            },
            nowProvider: { sampledAt }
        )

        let cachedRequest = Task.detached {
            coordinator.captureCached(
                includeProcessDetails: true,
                includeCMUXScope: true,
                maximumAge: 5
            )
        }
        let firstDidStart = await Self.wait(for: firstCaptureStarted)
        #expect(firstDidStart)
        guard firstDidStart else { return }

        let freshRequest = Task.detached {
            freshRequestStarted.signal()
            return coordinator.captureCoordinatedFresh(
                includeProcessDetails: true,
                includeCMUXScope: true
            )
        }
        #expect(await Self.wait(for: freshRequestStarted))
        let freshStartedBeforeFirstFinished = await Self.wait(
            for: freshCaptureStarted,
            timeout: 0.1
        )
        #expect(!freshStartedBeforeFirstFinished)

        releaseFirstCapture.signal()
        let freshDidStart = await Self.wait(for: freshCaptureStarted)
        #expect(freshDidStart)
        guard freshDidStart else { return }
        releaseFreshCapture.signal()

        let cached = await cachedRequest.value
        let fresh = await freshRequest.value
        let finalStats = stats.withLock { $0 }
        #expect(cached !== fresh)
        #expect(finalStats.captureCount == 2)
        #expect(finalStats.maximumActiveCount == 1)
    }

    nonisolated private static func snapshot(
        sampledAt: Date,
        includeProcessDetails: Bool,
        includeCMUXScope: Bool
    ) -> CmuxTopProcessSnapshot {
        CmuxTopProcessSnapshot(
            processes: [],
            sampledAt: sampledAt,
            includesProcessDetails: includeProcessDetails,
            includesCMUXScope: includeCMUXScope
        )
    }

    nonisolated private static func wait(
        for semaphore: DispatchSemaphore,
        timeout: TimeInterval = 10
    ) async -> Bool {
        await Task.detached {
            semaphore.wait(timeout: .now() + timeout) == .success
        }.value
    }
}
