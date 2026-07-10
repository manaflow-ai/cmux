import Foundation
import os
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension SharedLiveAgentIndexLoadCoalescingTests {
    @Test
    func scopedRefreshDoesNotPublishWorkspaceNotification() async {
        let notificationCount = OSAllocatedUnfairLock(initialState: 0)
        let hookDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-shared-index-scoped-publication-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: hookDirectory) }
        let workspaceId = UUID()
        let panelId = UUID()
        let sessionId = "scoped-refresh-session"
        let loadedIndex = Self.index(
            workspaceId: workspaceId,
            panelId: panelId,
            sessionId: sessionId
        )
        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: {
                (
                    index: loadedIndex,
                    liveAgentProcessFingerprint: [],
                    processScopeFingerprint: [],
                    forkValidatedPanels: []
                )
            },
            hookStoreDirectoryProvider: { hookDirectory.path }
        )
        let observer = NotificationCenter.default.addObserver(
            forName: .sharedLiveAgentIndexDidChange,
            object: sharedIndex,
            queue: nil
        ) { _ in
            notificationCount.withLock { $0 += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let scopedIndex = await sharedIndex.scopedIndexCapturedAfterRequest()

        #expect(scopedIndex.snapshot(workspaceId: workspaceId, panelId: panelId)?.sessionId == sessionId)
        #expect(
            notificationCount.withLock { $0 } == 0,
            "A panel-local probe must not invalidate every Workspace through the global notification."
        )

        await sharedIndex.refreshForkAvailabilityNow(workspaceId: workspaceId, panelId: panelId)
        #expect(
            notificationCount.withLock { $0 } == 1,
            "A workspace-published refresh must still notify the global consumer."
        )
    }

    @Test
    func scopedPostBoundaryReadQueuesBehindActiveGeneration() async {
        let firstLoadStarted = DispatchSemaphore(value: 0)
        let releaseFirstLoad = DispatchSemaphore(value: 0)
        let successorLoadStarted = DispatchSemaphore(value: 0)
        let releaseSuccessorLoad = DispatchSemaphore(value: 0)
        let scopedReadReturned = DispatchSemaphore(value: 0)
        defer {
            releaseFirstLoad.signal()
            releaseSuccessorLoad.signal()
        }
        let loadCount = OSAllocatedUnfairLock(initialState: 0)
        let hookDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-shared-index-scoped-boundary-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: hookDirectory) }
        let workspaceId = UUID()
        let panelId = UUID()
        let firstIndex = Self.index(
            workspaceId: workspaceId,
            panelId: panelId,
            sessionId: "pre-boundary-session"
        )
        let successorSessionId = "post-boundary-session"
        let successorIndex = Self.index(
            workspaceId: workspaceId,
            panelId: panelId,
            sessionId: successorSessionId
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
                        index: firstIndex,
                        liveAgentProcessFingerprint: [],
                        processScopeFingerprint: [],
                        forkValidatedPanels: []
                    )
                }
                successorLoadStarted.signal()
                releaseSuccessorLoad.wait()
                return (
                    index: successorIndex,
                    liveAgentProcessFingerprint: [],
                    processScopeFingerprint: [],
                    forkValidatedPanels: []
                )
            },
            hookStoreDirectoryProvider: { hookDirectory.path }
        )

        sharedIndex.scheduleRefreshIfStale()
        #expect(await Self.wait(for: firstLoadStarted))

        let scopedRead = Task { @MainActor in
            let result = await sharedIndex.scopedIndexCapturedAfterRequest()
            scopedReadReturned.signal()
            return result
        }
        let successorStartedInParallel = await Self.wait(for: successorLoadStarted, timeout: 0.2)
        #expect(
            !successorStartedInParallel,
            "A post-boundary scoped read must queue behind the active full load."
        )

        releaseFirstLoad.signal()
        #expect(await Self.wait(for: successorLoadStarted))
        let returnedBeforeSuccessorCompleted = await Self.wait(for: scopedReadReturned, timeout: 0.2)
        #expect(
            !returnedBeforeSuccessorCompleted,
            "A safety read must await the generation that captures after its boundary."
        )

        releaseSuccessorLoad.signal()
        let result = await scopedRead.value
        #expect(result.snapshot(workspaceId: workspaceId, panelId: panelId)?.sessionId == successorSessionId)
        #expect(loadCount.withLock { $0 } == 2)
    }

    @Test
    func staleTolerantReadDoesNotFollowLaterInteractiveSuccessor() async {
        let firstLoadStarted = DispatchSemaphore(value: 0)
        let releaseFirstLoad = DispatchSemaphore(value: 0)
        let successorLoadStarted = DispatchSemaphore(value: 0)
        let releaseSuccessorLoad = DispatchSemaphore(value: 0)
        let readReachedSuspension = DispatchSemaphore(value: 0)
        let readReturned = DispatchSemaphore(value: 0)
        let probeReachedSuspension = DispatchSemaphore(value: 0)
        defer {
            releaseFirstLoad.signal()
            releaseSuccessorLoad.signal()
        }
        let loadCount = OSAllocatedUnfairLock(initialState: 0)
        let hookDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-shared-index-stale-tolerant-read-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: hookDirectory) }
        let workspaceId = UUID()
        let panelId = UUID()
        let joinedSessionId = "joined-background-session"
        let joinedIndex = Self.index(
            workspaceId: workspaceId,
            panelId: panelId,
            sessionId: joinedSessionId
        )
        let successorIndex = Self.index(
            workspaceId: workspaceId,
            panelId: panelId,
            sessionId: "later-interactive-session"
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
                        index: joinedIndex,
                        liveAgentProcessFingerprint: [],
                        processScopeFingerprint: [],
                        forkValidatedPanels: []
                    )
                }
                successorLoadStarted.signal()
                releaseSuccessorLoad.wait()
                return (
                    index: successorIndex,
                    liveAgentProcessFingerprint: [],
                    processScopeFingerprint: [],
                    forkValidatedPanels: []
                )
            },
            hookStoreDirectoryProvider: { hookDirectory.path }
        )

        sharedIndex.scheduleRefreshIfStale()
        #expect(await Self.wait(for: firstLoadStarted))

        let staleTolerantRead = Task { @MainActor in
            Task { @MainActor in readReachedSuspension.signal() }
            let result = await sharedIndex.indexRefreshingIfNeeded()
            readReturned.signal()
            return result
        }
        #expect(await Self.wait(for: readReachedSuspension))

        let interactiveProbe = Task { @MainActor in
            Task { @MainActor in probeReachedSuspension.signal() }
            await sharedIndex.refreshForkAvailabilityNow(workspaceId: workspaceId, panelId: panelId)
        }
        #expect(await Self.wait(for: probeReachedSuspension))

        releaseFirstLoad.signal()
        #expect(await Self.wait(for: successorLoadStarted))
        #expect(
            await Self.wait(for: readReturned, timeout: 1),
            "A stale-tolerant background read must not follow a successor requested after it began waiting."
        )
        let joinedResult = await staleTolerantRead.value
        #expect(joinedResult?.snapshot(workspaceId: workspaceId, panelId: panelId)?.sessionId == joinedSessionId)

        releaseSuccessorLoad.signal()
        await interactiveProbe.value
        #expect(loadCount.withLock { $0 } == 2)
    }
}
