import Foundation
import os
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension ClosedItemHistoryAgentEnrichmentTests {
    @Test
    func timedOutCaptureUsesSuccessorBeforeClosing() async throws {
        let workspaceID = UUID()
        let panelID = UUID()
        let timeoutWaiter = ManualGenerationTimeoutWaiter()
        let firstLoadStarted = DispatchSemaphore(value: 0)
        let firstLoadCompleted = DispatchSemaphore(value: 0)
        let secondLoadStarted = DispatchSemaphore(value: 0)
        let releaseFirstLoad = DispatchSemaphore(value: 0)
        let loadCount = OSAllocatedUnfairLock(initialState: 0)
        let closeCount = OSAllocatedUnfairLock(initialState: 0)
        defer { releaseFirstLoad.signal() }
        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: {
                let invocation = loadCount.withLock { count in
                    count += 1
                    return count
                }
                if invocation == 1 {
                    firstLoadStarted.signal()
                    releaseFirstLoad.wait()
                    firstLoadCompleted.signal()
                    return Self.recoveryLoadResult(index: SharedLiveAgentIndexLoadCoalescingTests.index(
                        workspaceId: workspaceID,
                        panelId: panelID,
                        sessionId: "late-first-load"
                    ))
                }
                secondLoadStarted.signal()
                return Self.recoveryLoadResult(index: .empty)
            },
            generationTimeoutWaiter: {
                await timeoutWaiter.wait()
            },
            hookStoreDirectoryProvider: {
                FileManager.default.temporaryDirectory.path
            }
        )
        let store = ClosedItemHistoryStore(capacity: 10)
        let captureTask = try #require(store.pushPreservingAgentMetadata(
            .panel(ClosedPanelHistoryEntry(
                workspaceId: workspaceID,
                paneId: UUID(),
                tabIndex: 0,
                snapshot: Self.panelSnapshotForRecoveryTest(panelId: panelID)
            )),
            coordinatedBy: sharedIndex
        ))
        let closeID = UUID()
        let closeDeferrer = AgentMetadataCloseDeferrer()
        let closeTask = closeDeferrer.deferClose(id: closeID, until: captureTask) {
            closeCount.withLock { $0 += 1 }
        }

        #expect(await SharedLiveAgentIndexLoadCoalescingTests.wait(for: firstLoadStarted))
        await timeoutWaiter.waitUntilPendingCount(1)
        await timeoutWaiter.fireNext()
        #expect(await SharedLiveAgentIndexLoadCoalescingTests.wait(for: secondLoadStarted))
        await closeTask.value
        #expect(loadCount.withLock { $0 } == 2)
        #expect(closeCount.withLock { $0 } == 1)
        #expect(!closeDeferrer.isDeferringClose(id: closeID))
        #expect(store.canReopen)

        releaseFirstLoad.signal()
        #expect(await SharedLiveAgentIndexLoadCoalescingTests.wait(for: firstLoadCompleted))
        await Task.yield()
        await timeoutWaiter.cancelAll()
        let recordID = try #require(store.menuSnapshot().items.first?.id)
        let record = try #require(store.removeRecord(id: recordID)?.record)
        guard case .panel(let entry) = record.entry else {
            Issue.record("Expected a panel history record")
            return
        }
        #expect(entry.snapshot.terminal?.agent == nil)
    }

    @Test
    func repeatedUnavailableCapturePreservesCoreHistoryAndHonorsExplicitCloseOnce() async throws {
        let timeoutWaiter = ManualGenerationTimeoutWaiter()
        let loadStarted = DispatchSemaphore(value: 0)
        let releaseLoads = DispatchSemaphore(value: 0)
        let timeoutRequestCount = OSAllocatedUnfairLock(initialState: 0)
        let closeCount = OSAllocatedUnfairLock(initialState: 0)
        defer {
            releaseLoads.signal()
            releaseLoads.signal()
        }
        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: {
                loadStarted.signal()
                releaseLoads.wait()
                return (
                    index: .empty,
                    surfaceResumeBindingIndex: .empty,
                    liveAgentProcessFingerprint: [],
                    processScopeFingerprint: [],
                    forkValidatedPanels: []
                )
            },
            generationTimeoutWaiter: {
                timeoutRequestCount.withLock { $0 += 1 }
                return await timeoutWaiter.wait()
            },
            hookStoreDirectoryProvider: {
                FileManager.default.temporaryDirectory.path
            }
        )
        let store = ClosedItemHistoryStore(capacity: 10)
        let captureTask = try #require(store.pushPreservingAgentMetadata(
            .panel(ClosedPanelHistoryEntry(
                workspaceId: UUID(),
                paneId: UUID(),
                tabIndex: 0,
                snapshot: Self.panelSnapshotForRecoveryTest(panelId: UUID())
            )),
            coordinatedBy: sharedIndex
        ))
        let closeID = UUID()
        let closeDeferrer = AgentMetadataCloseDeferrer()
        let closeTask = closeDeferrer.deferClose(id: closeID, until: captureTask) {
            closeCount.withLock { $0 += 1 }
        }
        let timeoutDriver = Task {
            for _ in 0..<2 {
                await timeoutWaiter.waitUntilPendingCount(1)
                await timeoutWaiter.fireNext()
            }
        }

        #expect(await SharedLiveAgentIndexLoadCoalescingTests.wait(for: loadStarted))
        await closeTask.value

        #expect(timeoutRequestCount.withLock { $0 } == 2)
        #expect(closeCount.withLock { $0 } == 1)
        #expect(!closeDeferrer.isDeferringClose(id: closeID))
        var restoredEntry: ClosedItemHistoryEntry?
        let restoreResult = store.restoreFirstRestorableResult { entry in
            restoredEntry = entry
            return true
        }
        #expect(restoreResult == .restored)
        guard case .panel(let restoredPanel)? = restoredEntry else {
            Issue.record("Expected the core panel history record")
            return
        }
        #expect(restoredPanel.snapshot.terminal?.agent == nil)

        await timeoutWaiter.cancelAll()
        timeoutDriver.cancel()
        _ = await timeoutDriver.value
    }

    @Test
    func coldCacheForOrdinaryTerminalCapturesBeforeDecidingNoEnrichmentIsNeeded() async throws {
        let loadCount = OSAllocatedUnfairLock(initialState: 0)
        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: {
                loadCount.withLock { $0 += 1 }
                return Self.recoveryLoadResult(index: .empty)
            },
            hookStoreDirectoryProvider: {
                FileManager.default.temporaryDirectory.path
            }
        )
        let store = ClosedItemHistoryStore(capacity: 10)
        var ordinaryTerminal = Self.panelSnapshotForRecoveryTest(panelId: UUID())
        ordinaryTerminal.terminal?.resumeBinding = nil

        let capture = try #require(store.pushPreservingAgentMetadata(
            .panel(ClosedPanelHistoryEntry(
                workspaceId: UUID(),
                paneId: UUID(),
                tabIndex: 0,
                snapshot: ordinaryTerminal
            )),
            coordinatedBy: sharedIndex
        ))
        await capture.value

        #expect(loadCount.withLock { $0 } == 1)
        #expect(store.canReopen)
        #expect(store.menuSnapshot().totalItemCount == 1)
    }

    private static func panelSnapshotForRecoveryTest(panelId: UUID) -> SessionPanelSnapshot {
        SessionPanelSnapshot(
            id: panelId,
            type: .terminal,
            title: "Agent terminal",
            customTitle: nil,
            directory: nil,
            isPinned: false,
            isManuallyUnread: false,
            listeningPorts: [],
            ttyName: nil,
            terminal: SessionTerminalPanelSnapshot(
                resumeBinding: SurfaceResumeBindingSnapshot(
                    kind: "codex",
                    command: "codex resume candidate",
                    source: "process-detected"
                )
            ),
            browser: nil,
            markdown: nil,
            filePreview: nil,
            rightSidebarTool: nil
        )
    }

    nonisolated private static func recoveryLoadResult(
        index: RestorableAgentSessionIndex
    ) -> SharedLiveAgentIndexLoader.LoadResult {
        (
            index: index,
            surfaceResumeBindingIndex: .empty,
            liveAgentProcessFingerprint: [],
            processScopeFingerprint: [],
            forkValidatedPanels: []
        )
    }
}
