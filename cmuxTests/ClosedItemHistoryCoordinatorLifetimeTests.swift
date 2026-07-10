import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
struct ClosedItemHistoryCoordinatorLifetimeTests {
    @Test
    func returnedCaptureRetainsInjectedCoordinatorUntilLoadCompletes() async throws {
        let loadStarted = DispatchSemaphore(value: 0)
        let releaseLoad = DispatchSemaphore(value: 0)
        defer { releaseLoad.signal() }
        let store = ClosedItemHistoryStore()
        let captureTask: Task<Void, Never>?
        do {
            let coordinator = SharedLiveAgentIndex(
                indexLoader: {
                    loadStarted.signal()
                    releaseLoad.wait()
                    return (
                        index: .empty,
                        surfaceResumeBindingIndex: .empty,
                        liveAgentProcessFingerprint: [],
                        processScopeFingerprint: [],
                        forkValidatedPanels: []
                    )
                },
                hookStoreDirectoryProvider: {
                    FileManager.default.temporaryDirectory.path
                }
            )
            captureTask = store.pushPreservingAgentMetadata(
                Self.entry(),
                coordinatedBy: coordinator
            )
        }
        let captureTask = try #require(captureTask)

        #expect(
            await SharedLiveAgentIndexLoadCoalescingTests.wait(
                for: loadStarted,
                timeout: 2
            ),
            "The returned capture must retain its injected coordinator until loading starts."
        )
        releaseLoad.signal()
        await captureTask.value
        #expect(store.canReopen)
    }

    private static func entry() -> ClosedItemHistoryEntry {
        .panel(ClosedPanelHistoryEntry(
            workspaceId: UUID(),
            paneId: UUID(),
            tabIndex: 0,
            snapshot: SessionPanelSnapshot(
                id: UUID(),
                type: .terminal,
                title: "Agent terminal",
                customTitle: nil,
                directory: nil,
                isPinned: false,
                isManuallyUnread: false,
                listeningPorts: [],
                ttyName: nil,
                terminal: SessionTerminalPanelSnapshot(),
                browser: nil,
                markdown: nil,
                filePreview: nil,
                rightSidebarTool: nil
            )
        ))
    }
}
