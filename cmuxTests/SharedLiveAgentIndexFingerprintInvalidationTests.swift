import Foundation
import os
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct SharedLiveAgentIndexFingerprintInvalidationTests {
    @Test(arguments: [false, true])
    func expiredCacheIsRejectedWhenRefreshTimesOut(joinExistingRefresh: Bool) async {
        let timeoutWaiter = ManualGenerationTimeoutWaiter()
        let secondLoadStarted = DispatchSemaphore(value: 0)
        let releaseSecondLoad = DispatchSemaphore(value: 0)
        defer { releaseSecondLoad.signal() }
        let loadCount = OSAllocatedUnfairLock(initialState: 0)
        var now = Date()
        let hookDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-expired-index-timeout-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: hookDirectory) }
        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: {
                let invocation = loadCount.withLock { count in
                    count += 1
                    return count
                }
                if invocation == 2 {
                    secondLoadStarted.signal()
                    releaseSecondLoad.wait()
                }
                return (
                    index: .empty,
                    surfaceResumeBindingIndex: .empty,
                    liveAgentProcessFingerprint: [],
                    processScopeFingerprint: [],
                    forkValidatedPanels: []
                )
            },
            processScopeFingerprintProvider: { [] },
            generationTimeoutWaiter: { await timeoutWaiter.wait() },
            hookStoreDirectoryProvider: { hookDirectory.path },
            dateProvider: { now }
        )

        #expect(await sharedIndex.resumeIndexesRefreshingIfNeeded(maximumAge: 60) != nil)
        await timeoutWaiter.waitUntilPendingCount(1)
        now = now.addingTimeInterval(61)

        if joinExistingRefresh {
            sharedIndex.scheduleRefreshIfStale()
            #expect(await SharedLiveAgentIndexLoadCoalescingTests.wait(for: secondLoadStarted))
        }
        let refresh = Task { @MainActor in
            await sharedIndex.resumeIndexesRefreshingIfNeeded(maximumAge: 60)
        }
        if !joinExistingRefresh {
            #expect(await SharedLiveAgentIndexLoadCoalescingTests.wait(for: secondLoadStarted))
        }
        await timeoutWaiter.waitUntilPendingCount(2)
        await timeoutWaiter.fireLast()

        #expect(
            await refresh.value == nil,
            "A timed-out refresh must not revive an index older than the requested maximum age."
        )

        releaseSecondLoad.signal()
        await timeoutWaiter.cancelAll()
    }

    @Test
    func timedOutCaptureDoesNotReturnFingerprintMismatchedCache() async {
        let timeoutWaiter = ManualGenerationTimeoutWaiter()
        let secondLoadStarted = DispatchSemaphore(value: 0)
        let releaseSecondLoad = DispatchSemaphore(value: 0)
        defer { releaseSecondLoad.signal() }
        let loadCount = OSAllocatedUnfairLock(initialState: 0)
        let processScopeFingerprint = OSAllocatedUnfairLock(initialState: Set(["scope-a"]))
        let hookDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-fingerprint-invalidation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: hookDirectory) }
        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: {
                let invocation = loadCount.withLock { count in
                    count += 1
                    return count
                }
                if invocation == 2 {
                    secondLoadStarted.signal()
                    releaseSecondLoad.wait()
                }
                return (
                    index: .empty,
                    surfaceResumeBindingIndex: .empty,
                    liveAgentProcessFingerprint: [],
                    processScopeFingerprint: processScopeFingerprint.withLock { $0 },
                    forkValidatedPanels: []
                )
            },
            processScopeFingerprintProvider: { processScopeFingerprint.withLock { $0 } },
            generationTimeoutWaiter: { await timeoutWaiter.wait() },
            hookStoreDirectoryProvider: { hookDirectory.path }
        )

        let initial = await sharedIndex.resumeIndexesRefreshingIfNeeded()
        #expect(initial != nil)
        await timeoutWaiter.waitUntilPendingCount(1)

        processScopeFingerprint.withLock { $0 = ["scope-b"] }
        let refresh = Task { @MainActor in
            await sharedIndex.resumeIndexesRefreshingIfNeeded()
        }
        #expect(await SharedLiveAgentIndexLoadCoalescingTests.wait(for: secondLoadStarted))
        await timeoutWaiter.waitUntilPendingCount(2)
        await timeoutWaiter.fireLast()

        let refreshed = await refresh.value
        #expect(
            refreshed.map { _ in true } == nil,
            "An unavailable replacement capture must not revive the cache whose fingerprint just mismatched."
        )
        #expect(
            sharedIndex.cachedResumeIndexes().map { _ in true } == nil,
            "Fingerprint-invalidated indexes must not remain available to synchronous termination consumers."
        )

        releaseSecondLoad.signal()
        await timeoutWaiter.cancelAll()
    }
}
