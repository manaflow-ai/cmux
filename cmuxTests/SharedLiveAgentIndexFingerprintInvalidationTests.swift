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
    func expiredCacheIsRejectedWhenRefreshIsUnavailable(joinExistingRefresh: Bool) async {
        var now = Date()
        let hookDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-expired-index-unavailable-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: hookDirectory) }
        let cachedResult: SharedLiveAgentIndex.LoadResult = (
            index: .empty,
            surfaceResumeBindingIndex: .empty,
            liveAgentProcessFingerprint: [],
            processScopeFingerprint: [],
            forkValidatedPanels: []
        )
        let sharedIndex = SharedLiveAgentIndex(
            processScopeFingerprintProvider: { [] },
            hookStoreDirectoryProvider: { hookDirectory.path },
            dateProvider: { now }
        )

        sharedIndex.latestCompletedLoadResult = cachedResult
        sharedIndex.latestCompletedAt = now
        now = now.addingTimeInterval(61)

        if joinExistingRefresh {
            let generationID = UUID()
            sharedIndex.refreshGenerationsByID[generationID] = .init(
                id: generationID,
                ordinal: 1,
                phase: .capturing,
                publication: .scoped,
                validationPanelsByPanelID: [:]
            )
            sharedIndex.refreshTasksByID[generationID] = Task { nil }
            sharedIndex.refreshTailID = generationID
        } else {
            for ordinal in 1 ... SharedLiveAgentIndex.maximumConcurrentPhysicalLoads {
                let generationID = UUID()
                sharedIndex.refreshGenerationsByID[generationID] = .init(
                    id: generationID,
                    ordinal: UInt64(ordinal),
                    phase: .capturing,
                    publication: .scoped,
                    validationPanelsByPanelID: [:]
                )
            }
        }

        let refreshed = await sharedIndex.resumeIndexesRefreshingIfNeeded(maximumAge: 60)

        #expect(
            refreshed == nil,
            "An unavailable refresh must not revive an index older than the requested maximum age."
        )
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
