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
struct SharedLiveAgentIndexLoadCoalescingTests {
    @Test
    func concurrentForkAvailabilityRefreshesShareOneCompleteIndexLoad() async {
        let firstLoadStarted = DispatchSemaphore(value: 0)
        let releaseFirstLoad = DispatchSemaphore(value: 0)
        defer {
            releaseFirstLoad.signal()
            releaseFirstLoad.signal()
        }
        let loadCount = OSAllocatedUnfairLock(initialState: 0)
        let hookDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-shared-index-concurrent-refresh-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: hookDirectory) }
        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: {
                let invocation = loadCount.withLock { count in
                    count += 1
                    return count
                }
                if invocation == 1 {
                    firstLoadStarted.signal()
                    releaseFirstLoad.wait()
                }
                return Self.emptyLoadResult
            },
            hookStoreDirectoryProvider: { hookDirectory.path }
        )
        let workspaceId = UUID()
        let panelId = UUID()

        let firstRefresh = Task { @MainActor in
            await sharedIndex.refreshForkAvailabilityNow(workspaceId: workspaceId, panelId: panelId)
        }
        #expect(await Self.wait(for: firstLoadStarted))

        let secondRefreshReachedSuspension = DispatchSemaphore(value: 0)
        let secondRefresh = Task { @MainActor in
            Task { @MainActor in
                secondRefreshReachedSuspension.signal()
            }
            await sharedIndex.refreshForkAvailabilityNow(workspaceId: workspaceId, panelId: panelId)
        }
        #expect(await Self.wait(for: secondRefreshReachedSuspension))

        releaseFirstLoad.signal()
        await firstRefresh.value
        await secondRefresh.value
        #expect(loadCount.withLock { $0 } == 1)
    }

    @Test
    func forkAvailabilityRefreshQueuesOneSuccessorAfterAnExistingBackgroundReload() async {
        let loadStarted = DispatchSemaphore(value: 0)
        let releaseLoad = DispatchSemaphore(value: 0)
        let refreshReturned = DispatchSemaphore(value: 0)
        defer { releaseLoad.signal() }
        let loadCount = OSAllocatedUnfairLock(initialState: 0)
        let hookDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-shared-index-join-refresh-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: hookDirectory) }
        let workspaceId = UUID()
        let panelId = UUID()
        let sessionId = "appeared-after-background-capture"
        let refreshedIndex = Self.index(
            workspaceId: workspaceId,
            panelId: panelId,
            sessionId: sessionId
        )
        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: {
                let invocation = loadCount.withLock { count in
                    count += 1
                    return count
                }
                if invocation == 1 {
                    loadStarted.signal()
                    releaseLoad.wait()
                    return Self.emptyLoadResult
                }
                return (
                    index: refreshedIndex,
                    liveAgentProcessFingerprint: [],
                    processScopeFingerprint: [],
                    forkValidatedPanels: []
                )
            },
            hookStoreDirectoryProvider: { hookDirectory.path }
        )

        sharedIndex.scheduleRefreshIfStale()
        #expect(await Self.wait(for: loadStarted))

        let refresh = Task { @MainActor in
            await sharedIndex.refreshForkAvailabilityNow(workspaceId: workspaceId, panelId: panelId)
            let snapshot = sharedIndex.index?.snapshot(workspaceId: workspaceId, panelId: panelId)
            refreshReturned.signal()
            return snapshot
        }
        let returnedBeforeExistingReloadFinished = await Self.wait(
            for: refreshReturned,
            timeout: 1
        )
        #expect(
            !returnedBeforeExistingReloadFinished,
            "A fork probe must wait for a post-request process capture instead of accepting older state."
        )

        releaseLoad.signal()
        #expect(await Self.wait(for: refreshReturned))
        let snapshot = await refresh.value
        #expect(snapshot?.sessionId == sessionId)
        #expect(
            loadCount.withLock { $0 } == 2,
            "Concurrent interactive probes should share one successor after the background load."
        )
    }

    nonisolated private static var emptyLoadResult: SharedLiveAgentIndexLoader.LoadResult {
        (
            index: .empty,
            liveAgentProcessFingerprint: [],
            processScopeFingerprint: [],
            forkValidatedPanels: []
        )
    }

    nonisolated private static func index(
        workspaceId: UUID,
        panelId: UUID,
        sessionId: String
    ) -> RestorableAgentSessionIndex {
        let key = RestorableAgentSessionIndex.PanelKey(workspaceId: workspaceId, panelId: panelId)
        let detected: RestorableAgentSessionIndex.ProcessDetectedSnapshotEntry = (
            snapshot: SessionRestorableAgentSnapshot(
                kind: .codex,
                sessionId: sessionId,
                workingDirectory: "/tmp/cmux-shared-index-fixture",
                launchCommand: nil
            ),
            updatedAt: 42,
            processIDs: [8_801],
            agentProcessIDs: [8_801],
            sessionIDSource: .explicit
        )
        return RestorableAgentSessionIndex.load(
            homeDirectory: "/tmp/cmux-shared-index-fixture-missing-home",
            fileManager: .default,
            registry: CmuxVaultAgentRegistry(registrations: []),
            detectedSnapshots: [key: detected],
            processArgumentsProvider: { _ in nil },
            processIdentityProvider: { _ in nil }
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
