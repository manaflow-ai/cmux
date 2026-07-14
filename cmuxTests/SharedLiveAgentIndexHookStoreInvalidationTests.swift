import Dispatch
import Foundation
import os
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Shared live-agent hook-store invalidation", .serialized)
struct SharedLiveAgentIndexHookStoreInvalidationTests {
    @Test
    func completedWorkspaceRefreshRateLimitsPendingHookChange() async {
        let firstStarted = DispatchSemaphore(value: 0)
        let firstPublished = DispatchSemaphore(value: 0)
        let successorStarted = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let releaseSuccessor = DispatchSemaphore(value: 0)
        defer {
            releaseFirst.signal()
            releaseSuccessor.signal()
        }
        let loadCount = OSAllocatedUnfairLock(initialState: 0)
        let now = Date(timeIntervalSince1970: 100)
        let hookDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-hook-change-rate-limit-\(UUID().uuidString)", isDirectory: true)
        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: {
                let invocation = loadCount.withLock { count in
                    count += 1
                    return count
                }
                (invocation == 1 ? firstStarted : successorStarted).signal()
                (invocation == 1 ? releaseFirst : releaseSuccessor).wait()
                return (
                    index: SharedLiveAgentIndexLoadCoalescingTests.index(
                        workspaceId: UUID(),
                        panelId: UUID(),
                        sessionId: "rate-limited-drain-\(invocation)"
                    ),
                    surfaceResumeBindingIndex: .empty,
                    liveAgentProcessFingerprint: [],
                    processScopeFingerprint: [],
                    forkValidatedPanels: []
                )
            },
            hookStoreDirectoryProvider: { hookDirectory.path },
            dateProvider: { now }
        )
        let observer = NotificationCenter.default.addObserver(
            forName: .sharedLiveAgentIndexDidChange,
            object: sharedIndex,
            queue: nil
        ) { _ in
            firstPublished.signal()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        sharedIndex.startBackgroundRefresh()
        #expect(await SharedLiveAgentIndexLoadCoalescingTests.wait(for: firstStarted))

        sharedIndex.handleHookStoreChange()
        #expect(sharedIndex.changePending)

        releaseFirst.signal()
        #expect(await SharedLiveAgentIndexLoadCoalescingTests.wait(for: firstPublished))
        #expect(
            !(await SharedLiveAgentIndexLoadCoalescingTests.wait(for: successorStarted, timeout: 0.2)),
            "A hook-store change drained after publication must retain the event reload interval."
        )
        #expect(loadCount.withLock { $0 } == 1)
    }

    @Test
    func hookStoreChangeRevokesWarmCacheBeforeDebouncedRefresh() async {
        let workspaceId = UUID()
        let panelId = UUID()
        let loadStarted = DispatchSemaphore(value: 0)
        let releaseLoad = DispatchSemaphore(value: 0)
        let readCompleted = DispatchSemaphore(value: 0)
        defer { releaseLoad.signal() }
        let now = Date()
        let hookDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-hook-change-warm-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: hookDirectory) }
        let cachedResult: SharedLiveAgentIndex.LoadResult = (
            index: SharedLiveAgentIndexLoadCoalescingTests.index(
                workspaceId: workspaceId,
                panelId: panelId,
                sessionId: "stale-session"
            ),
            surfaceResumeBindingIndex: .empty,
            liveAgentProcessFingerprint: [],
            processScopeFingerprint: ["scope"],
            forkValidatedPanels: []
        )
        let refreshedResult: SharedLiveAgentIndex.LoadResult = (
            index: SharedLiveAgentIndexLoadCoalescingTests.index(
                workspaceId: workspaceId,
                panelId: panelId,
                sessionId: "fresh-session"
            ),
            surfaceResumeBindingIndex: .empty,
            liveAgentProcessFingerprint: [],
            processScopeFingerprint: ["scope"],
            forkValidatedPanels: []
        )
        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: {
                loadStarted.signal()
                releaseLoad.wait()
                return refreshedResult
            },
            processScopeFingerprintProvider: { ["scope"] },
            hookStoreDirectoryProvider: { hookDirectory.path },
            dateProvider: { now }
        )
        sharedIndex.applyReloadedResult(
            cachedResult,
            validationPanelsByPanelID: [:],
            generationID: UUID()
        )
        sharedIndex.latestCompletedLoadResult = cachedResult
        sharedIndex.latestCompletedAt = now

        sharedIndex.handleHookStoreChange()

        #expect(
            sharedIndex.cachedResumeIndexes() == nil,
            "A known hook-store change must immediately revoke warm resume authority."
        )
        let read = Task { @MainActor in
            let result = await sharedIndex.resumeIndexesRefreshingIfNeeded(maximumAge: 60)
            readCompleted.signal()
            return result
        }
        #expect(await SharedLiveAgentIndexLoadCoalescingTests.wait(for: loadStarted, timeout: 0.2))
        #expect(
            !(await SharedLiveAgentIndexLoadCoalescingTests.wait(for: readCompleted, timeout: 0.2)),
            "A post-event read must await fresh filesystem authority."
        )

        releaseLoad.signal()
        let result = await read.value
        #expect(
            result?.restorableAgentIndex.snapshot(workspaceId: workspaceId, panelId: panelId)?.sessionId
                == "fresh-session"
        )
    }
}
