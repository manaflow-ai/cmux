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
struct ClosedItemHistoryAgentEnrichmentTests {
    @Test
    func coldHistoryCaptureStartsOffMainAndClosesAfterEnrichment() async throws {
        let workspaceId = UUID()
        let panelId = UUID()
        let loadedIndex = SharedLiveAgentIndexLoadCoalescingTests.index(
            workspaceId: workspaceId,
            panelId: panelId,
            sessionId: "cold-close-session"
        )
        let loadStarted = DispatchSemaphore(value: 0)
        let releaseLoad = DispatchSemaphore(value: 0)
        let state = OSAllocatedUnfairLock(initialState: (
            loadStarted: false,
            closeCount: 0,
            observedOpenDuringLoad: false
        ))
        defer { releaseLoad.signal() }
        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: {
                state.withLock { $0.loadStarted = true }
                loadStarted.signal()
                releaseLoad.wait()
                state.withLock { $0.observedOpenDuringLoad = $0.closeCount == 0 }
                return (
                    index: loadedIndex,
                    surfaceResumeBindingIndex: .empty,
                    liveAgentProcessFingerprint: [],
                    processScopeFingerprint: [],
                    forkValidatedPanels: []
                )
            },
            hookStoreDirectoryProvider: { Self.temporaryDirectory.path }
        )
        let store = ClosedItemHistoryStore(capacity: 10)
        let enrichment = try #require(store.pushPreservingAgentMetadata(
            .panel(ClosedPanelHistoryEntry(
                workspaceId: workspaceId,
                paneId: UUID(),
                tabIndex: 0,
                snapshot: Self.panelSnapshot(panelId: panelId)
            )),
            coordinatedBy: sharedIndex
        ))
        let closeDeferrer = AgentMetadataCloseDeferrer()
        let closeTask = closeDeferrer.deferClose(id: panelId, until: enrichment) {
            state.withLock { $0.closeCount += 1 }
        }

        #expect(!state.withLock { $0.loadStarted })
        #expect(state.withLock { $0.closeCount } == 0)
        #expect(!store.canReopen)
        #expect(store.menuSnapshot().totalItemCount == 0)
        #expect(!store.restoreFirstRestorable { _ in true })
        #expect(await SharedLiveAgentIndexLoadCoalescingTests.wait(for: loadStarted))
        #expect(state.withLock { $0.closeCount } == 0)
        #expect(store.menuSnapshot().totalItemCount == 0)
        releaseLoad.signal()
        await closeTask.value

        #expect(store.canReopen)
        let recordId = try #require(store.menuSnapshot().items.first?.id)
        let record = try #require(store.removeRecord(id: recordId)?.record)
        guard case .panel(let entry) = record.entry else {
            Issue.record("Expected a panel history record")
            return
        }
        #expect(state.withLock { $0.observedOpenDuringLoad })
        #expect(state.withLock { $0.closeCount } == 1)
        #expect(entry.snapshot.terminal?.agent?.sessionId == "cold-close-session")
        #expect(entry.snapshot.terminal?.wasAgentRunning == true)
    }

    @Test
    func warmHistoryCaptureReplacesStaleCachedAgentMetadata() async throws {
        let workspaceId = UUID()
        let panelId = UUID()
        let staleIndex = SharedLiveAgentIndexLoadCoalescingTests.index(
            workspaceId: workspaceId,
            panelId: panelId,
            sessionId: "stale-close-session"
        )
        let freshIndex = SharedLiveAgentIndexLoadCoalescingTests.index(
            workspaceId: workspaceId,
            panelId: panelId,
            sessionId: "fresh-close-session"
        )
        let loadStarted = DispatchSemaphore(value: 0)
        let releaseLoad = DispatchSemaphore(value: 0)
        defer { releaseLoad.signal() }
        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: {
                loadStarted.signal()
                releaseLoad.wait()
                return Self.loadResult(index: freshIndex)
            },
            hookStoreDirectoryProvider: { Self.temporaryDirectory.path }
        )
        sharedIndex.latestCompletedLoadResult = Self.loadResult(index: staleIndex)
        let store = ClosedItemHistoryStore(capacity: 10)
        let capture = try #require(store.pushPreservingAgentMetadata(
            .panel(ClosedPanelHistoryEntry(
                workspaceId: workspaceId,
                paneId: UUID(),
                tabIndex: 0,
                snapshot: Self.panelSnapshot(panelId: panelId)
            )),
            coordinatedBy: sharedIndex
        ))

        #expect(await SharedLiveAgentIndexLoadCoalescingTests.wait(for: loadStarted))
        #expect(!store.canReopen)
        releaseLoad.signal()
        await capture.value

        let recordId = try #require(store.menuSnapshot().items.first?.id)
        let record = try #require(store.removeRecord(id: recordId)?.record)
        guard case .panel(let entry) = record.entry else {
            Issue.record("Expected a panel history record")
            return
        }
        #expect(entry.snapshot.terminal?.agent?.sessionId == "fresh-close-session")
    }

    @Test
    func timedOutCaptureClosesOnceEvenWhenLoaderFinishesLate() async throws {
        let timeoutGate = AsyncGate()
        let loadStarted = DispatchSemaphore(value: 0)
        let loadCompleted = DispatchSemaphore(value: 0)
        let releaseLoad = DispatchSemaphore(value: 0)
        let closeCount = OSAllocatedUnfairLock(initialState: 0)
        defer { releaseLoad.signal() }
        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: {
                loadStarted.signal()
                releaseLoad.wait()
                loadCompleted.signal()
                return Self.emptyLoadResult
            },
            generationTimeoutWaiter: {
                await timeoutGate.wait()
                return true
            },
            hookStoreDirectoryProvider: { Self.temporaryDirectory.path }
        )
        let store = ClosedItemHistoryStore(capacity: 10)
        let captureTask = try #require(store.pushPreservingAgentMetadata(
            .panel(ClosedPanelHistoryEntry(
                workspaceId: UUID(),
                paneId: UUID(),
                tabIndex: 0,
                snapshot: Self.panelSnapshot(panelId: UUID())
            )),
            coordinatedBy: sharedIndex
        ))
        let closeTask = AgentMetadataCloseDeferrer().deferClose(
            id: UUID(),
            until: captureTask
        ) {
            closeCount.withLock { $0 += 1 }
        }

        #expect(await SharedLiveAgentIndexLoadCoalescingTests.wait(for: loadStarted))
        #expect(closeCount.withLock { $0 } == 0)
        #expect(!store.canReopen)
        await timeoutGate.open()
        await closeTask.value
        #expect(closeCount.withLock { $0 } == 1)
        #expect(store.canReopen)

        releaseLoad.signal()
        #expect(await SharedLiveAgentIndexLoadCoalescingTests.wait(for: loadCompleted))
        await Task.yield()
        #expect(closeCount.withLock { $0 } == 1)
    }

    @Test
    func newerCaptureReplacesOlderDeferredClose() async {
        let panelId = UUID()
        let firstGate = AsyncGate()
        let secondGate = AsyncGate()
        let closeCount = OSAllocatedUnfairLock(initialState: 0)
        let deferrer = AgentMetadataCloseDeferrer()
        let firstCapture = Task { await firstGate.wait() }
        let secondCapture = Task { await secondGate.wait() }
        let firstClose = deferrer.deferClose(id: panelId, until: firstCapture) {
            closeCount.withLock { $0 += 1 }
        }
        let secondClose = deferrer.deferClose(id: panelId, until: secondCapture) {
            closeCount.withLock { $0 += 1 }
        }

        await firstGate.open()
        await firstClose.value
        #expect(closeCount.withLock { $0 } == 0)
        await secondGate.open()
        await secondClose.value
        #expect(closeCount.withLock { $0 } == 1)
    }

    @Test
    func deferredTerminalCloseRetiresPortalBeforeRuntimeTeardown() async throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.terminalPanel(for: panelId))
        let captureGate = AsyncGate()
        let captureTask = Task { await captureGate.wait() }
        defer { panel.close() }
        panel.hostedView.setVisibleInUI(true)

        let closeTask = try #require(workspace.deferPanelCloseUntilAgentMetadataCaptured(
            panelId: panelId,
            captureTask: captureTask
        ))

        #expect(!panel.hostedView.debugPortalVisibleInUI)
        #expect(!panel.didTeardownRuntimeForClose)
        await captureGate.open()
        await closeTask.value
        #expect(panel.didTeardownRuntimeForClose)
        panel.close()
        #expect(panel.didTeardownRuntimeForClose)
    }

    @Test
    func entriesWithoutMissingTerminalAgentMetadataBypassCapture() async {
        let loadCount = OSAllocatedUnfairLock(initialState: 0)
        let releaseLoad = DispatchSemaphore(value: 0)
        defer { releaseLoad.signal() }
        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: {
                loadCount.withLock { $0 += 1 }
                releaseLoad.wait()
                return Self.emptyLoadResult
            },
            hookStoreDirectoryProvider: { Self.temporaryDirectory.path }
        )
        let store = ClosedItemHistoryStore(capacity: 10)
        let workspaceId = UUID()
        let browserPanelId = UUID()
        let browserEntry = ClosedItemHistoryEntry.panel(ClosedPanelHistoryEntry(
            workspaceId: workspaceId,
            paneId: UUID(),
            tabIndex: 0,
            snapshot: SessionPanelSnapshot(
                id: browserPanelId,
                type: .browser,
                title: "Browser",
                customTitle: nil,
                directory: nil,
                isPinned: false,
                isManuallyUnread: false,
                listeningPorts: [],
                ttyName: nil,
                terminal: nil,
                browser: nil,
                markdown: nil,
                filePreview: nil,
                rightSidebarTool: nil
            )
        ))
        let enrichedPanelId = UUID()
        var enrichedPanel = Self.panelSnapshot(panelId: enrichedPanelId)
        enrichedPanel.terminal?.agent = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "already-captured",
            workingDirectory: "/tmp/already-captured",
            launchCommand: nil
        )
        let enrichedEntry = ClosedItemHistoryEntry.panel(ClosedPanelHistoryEntry(
            workspaceId: workspaceId,
            paneId: UUID(),
            tabIndex: 1,
            snapshot: enrichedPanel
        ))

        let browserCapture: Task<Void, Never>? = store.pushPreservingAgentMetadata(
            browserEntry,
            coordinatedBy: sharedIndex
        )
        let enrichedCapture: Task<Void, Never>? = store.pushPreservingAgentMetadata(
            enrichedEntry,
            coordinatedBy: sharedIndex
        )

        #expect(browserCapture == nil)
        #expect(enrichedCapture == nil)
        #expect(store.canReopen)
        #expect(store.menuSnapshot().items.map(\.title) == ["Agent terminal", "Browser"])
        await Task.yield()
        #expect(loadCount.withLock { $0 } == 0)

        releaseLoad.signal()
        await browserCapture?.value
        await enrichedCapture?.value
    }

    @Test
    func ordinaryTerminalWithoutAgentEvidenceBypassesCapture() async {
        let loadCount = OSAllocatedUnfairLock(initialState: 0)
        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: {
                loadCount.withLock { $0 += 1 }
                return Self.emptyLoadResult
            },
            hookStoreDirectoryProvider: { Self.temporaryDirectory.path }
        )
        let store = ClosedItemHistoryStore(capacity: 10)
        var ordinaryTerminal = Self.panelSnapshot(panelId: UUID())
        ordinaryTerminal.terminal?.resumeBinding = nil

        let capture = store.pushPreservingAgentMetadata(
            .panel(ClosedPanelHistoryEntry(
                workspaceId: UUID(),
                paneId: UUID(),
                tabIndex: 0,
                snapshot: ordinaryTerminal
            )),
            coordinatedBy: sharedIndex
        )

        await capture?.value
        #expect(capture == nil)
        #expect(loadCount.withLock { $0 } == 0)
        #expect(store.canReopen)
        #expect(store.menuSnapshot().totalItemCount == 1)
    }

    @Test
    func panelWorkspaceAndWindowEntriesUseTheSameEnrichment() throws {
        let workspaceId = UUID()
        let panelId = UUID()
        let index = SharedLiveAgentIndexLoadCoalescingTests.index(
            workspaceId: workspaceId,
            panelId: panelId,
            sessionId: "shared-history-session"
        )
        let panel = Self.panelSnapshot(panelId: panelId)
        let workspace = Self.workspaceSnapshot(
            workspaceId: workspaceId,
            panel: panel
        )
        let window = SessionWindowSnapshot(
            frame: nil,
            display: nil,
            tabManager: SessionTabManagerSnapshot(
                selectedWorkspaceIndex: 0,
                workspaces: [workspace]
            ),
            sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: nil)
        )

        let entries: [ClosedItemHistoryEntry] = [
            .panel(ClosedPanelHistoryEntry(
                workspaceId: workspaceId,
                paneId: UUID(),
                tabIndex: 0,
                snapshot: panel
            )),
            .workspace(ClosedWorkspaceHistoryEntry(
                workspaceId: workspaceId,
                windowId: nil,
                workspaceIndex: 0,
                snapshot: workspace
            )),
            .window(ClosedWindowHistoryEntry(snapshot: window)),
        ]

        let sessionIds = entries.map { entry -> String? in
            switch entry.enrichingAgentMetadata(from: index) {
            case .panel(let panelEntry):
                panelEntry.snapshot.terminal?.agent?.sessionId
            case .workspace(let workspaceEntry):
                workspaceEntry.snapshot.panels.first?.terminal?.agent?.sessionId
            case .window(let windowEntry):
                windowEntry.snapshot.tabManager.workspaces.first?
                    .panels.first?.terminal?.agent?.sessionId
            }
        }
        #expect(sessionIds == [
            "shared-history-session",
            "shared-history-session",
            "shared-history-session",
        ])
    }

    private static var temporaryDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-history-enrichment-\(UUID().uuidString)", isDirectory: true)
    }

    nonisolated private static var emptyLoadResult: SharedLiveAgentIndexLoader.LoadResult {
        (
            index: .empty,
            surfaceResumeBindingIndex: .empty,
            liveAgentProcessFingerprint: [],
            processScopeFingerprint: [],
            forkValidatedPanels: []
        )
    }

    nonisolated private static func loadResult(
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

    private actor AsyncGate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }

        func open() {
            isOpen = true
            let waiters = self.waiters
            self.waiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    private static func panelSnapshot(panelId: UUID) -> SessionPanelSnapshot {
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

    private static func workspaceSnapshot(
        workspaceId: UUID,
        panel: SessionPanelSnapshot
    ) -> SessionWorkspaceSnapshot {
        SessionWorkspaceSnapshot(
            workspaceId: workspaceId,
            processTitle: "Agent workspace",
            customTitle: nil,
            customDescription: nil,
            customColor: nil,
            isPinned: false,
            terminalScrollBarHidden: nil,
            currentDirectory: NSHomeDirectory(),
            focusedPanelId: panel.id,
            layout: .pane(SessionPaneLayoutSnapshot(
                panelIds: [panel.id],
                selectedPanelId: panel.id
            )),
            panels: [panel],
            statusEntries: [],
            logEntries: [],
            progress: nil,
            gitBranch: nil,
            remote: nil
        )
    }
}
