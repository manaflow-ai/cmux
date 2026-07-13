import Dispatch
import Foundation
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
