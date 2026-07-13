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
    func repeatedUnavailableCaptureDiscardsPendingHistoryAndClosesOnce() async throws {
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
        #expect(store.restoreFirstRestorableResult { _ in true } == .unavailable)

        await timeoutWaiter.cancelAll()
        timeoutDriver.cancel()
        _ = await timeoutDriver.value
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
}
