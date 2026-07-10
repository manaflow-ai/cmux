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
    func indexRefreshingIfNeededAwaitsColdLoadWithoutStartingAnotherScan() async {
        let loadStarted = DispatchSemaphore(value: 0)
        let releaseLoad = DispatchSemaphore(value: 0)
        let readReturned = DispatchSemaphore(value: 0)
        defer { releaseLoad.signal() }
        let loadCount = OSAllocatedUnfairLock(initialState: 0)
        let hookDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-shared-index-cold-read-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: hookDirectory) }
        let workspaceId = UUID()
        let panelId = UUID()
        let sessionId = "cold-index-session"
        let loadedIndex = Self.index(
            workspaceId: workspaceId,
            panelId: panelId,
            sessionId: sessionId
        )
        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: {
                loadCount.withLock { $0 += 1 }
                loadStarted.signal()
                releaseLoad.wait()
                return (
                    index: loadedIndex,
                    liveAgentProcessFingerprint: [],
                    processScopeFingerprint: [],
                    forkValidatedPanels: []
                )
            },
            hookStoreDirectoryProvider: { hookDirectory.path }
        )

        let read = Task { @MainActor in
            let index = await sharedIndex.indexRefreshingIfNeeded()
            readReturned.signal()
            return index?.snapshot(workspaceId: workspaceId, panelId: panelId)
        }
        #expect(await Self.wait(for: loadStarted))
        let returnedBeforeLoadCompleted = await Self.wait(for: readReturned, timeout: 0.2)
        #expect(
            !returnedBeforeLoadCompleted,
            "A cold cache read must await the shared load instead of skipping this evaluation."
        )

        releaseLoad.signal()
        #expect(await Self.wait(for: readReturned))
        let snapshot = await read.value
        #expect(snapshot?.sessionId == sessionId)
        #expect(loadCount.withLock { $0 } == 1)
    }

    @Test
    func watcherSetupDoesNotStartParallelLoadDuringForkRefresh() async {
        let firstLoadStarted = DispatchSemaphore(value: 0)
        let parallelLoadStarted = DispatchSemaphore(value: 0)
        let releaseLoads = DispatchSemaphore(value: 0)
        defer {
            releaseLoads.signal()
            releaseLoads.signal()
        }
        let loadCount = OSAllocatedUnfairLock(initialState: 0)
        let hookDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-shared-index-watcher-singleflight-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: hookDirectory) }
        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: {
                let invocation = loadCount.withLock { count in
                    count += 1
                    return count
                }
                if invocation == 1 {
                    firstLoadStarted.signal()
                } else {
                    parallelLoadStarted.signal()
                }
                releaseLoads.wait()
                return Self.emptyLoadResult
            },
            hookStoreDirectoryProvider: { hookDirectory.path }
        )

        let forkRefresh = Task { @MainActor in
            await sharedIndex.refreshForkAvailabilityNow(workspaceId: UUID(), panelId: UUID())
        }
        #expect(await Self.wait(for: firstLoadStarted))

        _ = sharedIndex.currentIndexSchedulingRefresh()
        let startedParallelLoad = await Self.wait(for: parallelLoadStarted, timeout: 0.2)
        #expect(
            !startedParallelLoad,
            "First-time watcher setup must join the active fork refresh instead of starting a parallel scan."
        )

        releaseLoads.signal()
        releaseLoads.signal()
        await forkRefresh.value
        _ = await sharedIndex.indexRefreshingIfNeeded()
        #expect(loadCount.withLock { $0 } == 1)
    }

    @Test
    func lateForkAvailabilityRefreshesShareOneSuccessorLoad() async {
        let firstLoadStarted = DispatchSemaphore(value: 0)
        let releaseFirstLoad = DispatchSemaphore(value: 0)
        let successorLoadStarted = DispatchSemaphore(value: 0)
        let releaseSuccessorLoad = DispatchSemaphore(value: 0)
        defer {
            releaseFirstLoad.signal()
            releaseSuccessorLoad.signal()
        }
        let loadCount = OSAllocatedUnfairLock(initialState: 0)
        let hookDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-shared-index-concurrent-refresh-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: hookDirectory) }
        let firstWorkspaceId = UUID()
        let firstPanelId = UUID()
        let lateWorkspaceId = UUID()
        let latePanelId = UUID()
        let latePanelKey = RestorableAgentSessionIndex.PanelKey(
            workspaceId: lateWorkspaceId,
            panelId: latePanelId
        )
        let staleIndex = Self.index(
            workspaceId: lateWorkspaceId,
            panelId: latePanelId,
            sessionId: "stale-interactive-session"
        )
        let lateSessionId = "late-interactive-session"
        let lateIndex = Self.index(
            workspaceId: lateWorkspaceId,
            panelId: latePanelId,
            sessionId: lateSessionId
        )
        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: {
                let invocation = loadCount.withLock { count in
                    count += 1
                    return count
                }
                if invocation == 1 {
                    firstLoadStarted.signal()
                    releaseFirstLoad.wait()
                    return (
                        index: staleIndex,
                        liveAgentProcessFingerprint: [],
                        processScopeFingerprint: [],
                        forkValidatedPanels: [latePanelKey]
                    )
                }
                successorLoadStarted.signal()
                releaseSuccessorLoad.wait()
                return (
                    index: lateIndex,
                    liveAgentProcessFingerprint: [],
                    processScopeFingerprint: [],
                    forkValidatedPanels: [latePanelKey]
                )
            },
            hookStoreDirectoryProvider: { hookDirectory.path }
        )

        let firstRefresh = Task { @MainActor in
            await sharedIndex.refreshForkAvailabilityNow(workspaceId: firstWorkspaceId, panelId: firstPanelId)
        }
        #expect(await Self.wait(for: firstLoadStarted))

        let secondRefreshReachedSuspension = DispatchSemaphore(value: 0)
        let secondRefresh = Task { @MainActor in
            Task { @MainActor in
                secondRefreshReachedSuspension.signal()
            }
            await sharedIndex.refreshForkAvailabilityNow(workspaceId: lateWorkspaceId, panelId: latePanelId)
            return sharedIndex.index?.snapshot(workspaceId: lateWorkspaceId, panelId: latePanelId)
        }
        #expect(await Self.wait(for: secondRefreshReachedSuspension))

        let thirdRefreshReachedSuspension = DispatchSemaphore(value: 0)
        let thirdRefresh = Task { @MainActor in
            Task { @MainActor in
                thirdRefreshReachedSuspension.signal()
            }
            await sharedIndex.refreshForkAvailabilityNow(workspaceId: lateWorkspaceId, panelId: latePanelId)
            return sharedIndex.index?.snapshot(workspaceId: lateWorkspaceId, panelId: latePanelId)
        }
        #expect(await Self.wait(for: thirdRefreshReachedSuspension))

        releaseFirstLoad.signal()
        await firstRefresh.value
        #expect(await Self.wait(for: successorLoadStarted))
        #expect(
            !sharedIndex.prepareForkAvailabilityProbe(workspaceId: lateWorkspaceId, panelId: latePanelId),
            "A late panel must remain unavailable while its successor generation is still loading."
        )
        #expect(
            sharedIndex.snapshotForForkAvailability(workspaceId: lateWorkspaceId, panelId: latePanelId) == nil,
            "The predecessor's stale result must not become actionable before the successor finishes."
        )

        releaseSuccessorLoad.signal()
        let secondSnapshot = await secondRefresh.value
        let thirdSnapshot = await thirdRefresh.value
        #expect(secondSnapshot?.sessionId == lateSessionId)
        #expect(thirdSnapshot?.sessionId == lateSessionId)
        #expect(loadCount.withLock { $0 } == 2)
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

    @Test
    func forkAvailabilitySuccessorCachesFreshMissingResult() async {
        let firstLoadStarted = DispatchSemaphore(value: 0)
        let releaseFirstLoad = DispatchSemaphore(value: 0)
        let refreshReachedSuspension = DispatchSemaphore(value: 0)
        defer { releaseFirstLoad.signal() }
        let loadCount = OSAllocatedUnfairLock(initialState: 0)
        let hookDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-shared-index-missing-successor-\(UUID().uuidString)", isDirectory: true)
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
            hookStoreDirectoryProvider: { hookDirectory.path },
            dateProvider: { Date(timeIntervalSince1970: 100) }
        )
        let workspaceId = UUID()
        let panelId = UUID()

        sharedIndex.scheduleRefreshIfStale()
        #expect(await Self.wait(for: firstLoadStarted))

        let refresh = Task { @MainActor in
            Task { @MainActor in
                refreshReachedSuspension.signal()
            }
            await sharedIndex.refreshForkAvailabilityNow(workspaceId: workspaceId, panelId: panelId)
        }
        #expect(await Self.wait(for: refreshReachedSuspension))
        releaseFirstLoad.signal()
        await refresh.value

        #expect(loadCount.withLock { $0 } == 2)
        #expect(
            sharedIndex.prepareForkAvailabilityProbe(workspaceId: workspaceId, panelId: panelId),
            "A fresh missing result must suppress a redundant third full index load."
        )
        #expect(loadCount.withLock { $0 } == 2)
    }

    nonisolated private static var emptyLoadResult: SharedLiveAgentIndexLoader.LoadResult {
        (
            index: .empty,
            liveAgentProcessFingerprint: [],
            processScopeFingerprint: [],
            forkValidatedPanels: []
        )
    }

    nonisolated static func index(
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

    nonisolated static func wait(
        for semaphore: DispatchSemaphore,
        timeout: TimeInterval = 10
    ) async -> Bool {
        await Task.detached {
            semaphore.wait(timeout: .now() + timeout) == .success
        }.value
    }
}
