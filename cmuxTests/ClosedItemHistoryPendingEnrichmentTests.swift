import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct ClosedItemHistoryPendingEnrichmentTests {
    @Test
    func persistedCoreRecordSurvivesStoreReloadWhilePending() async throws {
        let workspaceId = UUID()
        let panelId = UUID()
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-pending-history-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("history.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ClosedItemHistoryStore(
            fileURL: fileURL,
            loadPersisted: false,
            persistsRecordsSynchronously: true
        )
        let capture = try #require(store.pushPreservingAgentMetadata(
            Self.entry(workspaceId: workspaceId, panelId: panelId),
            coordinatedBy: Self.blockedIndex(
                workspaceId: workspaceId,
                panelId: panelId,
                sessionId: "persisted-session",
                started: started,
                release: release
            )
        ))

        #expect(await SharedLiveAgentIndexLoadCoalescingTests.wait(for: started))
        #expect(!store.canReopen)
        #expect(store.menuSnapshot().totalItemCount == 0)
        let reloaded = ClosedItemHistoryStore(
            fileURL: fileURL,
            loadsPersistedRecordsSynchronously: true
        )
        #expect(reloaded.canReopen)
        #expect(reloaded.menuSnapshot().totalItemCount == 1)
        var restoredSessionID: String?
        #expect(!reloaded.restoreFirstRestorable { entry in
            restoredSessionID = Self.sessionID(from: entry)
            return false
        })
        #expect(restoredSessionID == nil)

        release.signal()
        await capture.value
        #expect(store.canReopen)
    }

    @Test
    func clearingHistoryWhilePendingDoesNotResurrectRecord() async throws {
        let workspaceId = UUID()
        let panelId = UUID()
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let store = ClosedItemHistoryStore()
        let capture = try #require(store.pushPreservingAgentMetadata(
            Self.entry(workspaceId: workspaceId, panelId: panelId),
            coordinatedBy: Self.blockedIndex(
                workspaceId: workspaceId,
                panelId: panelId,
                sessionId: "cleared-session",
                started: started,
                release: release
            )
        ))
        #expect(await SharedLiveAgentIndexLoadCoalescingTests.wait(for: started))

        store.removeAll()
        release.signal()
        await capture.value

        #expect(!store.canReopen)
        #expect(store.menuSnapshot().totalItemCount == 0)
    }

    @Test
    func newestPendingRecordBlocksGenericReopenUntilReady() async throws {
        let workspaceId = UUID()
        let panelId = UUID()
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let store = ClosedItemHistoryStore()
        store.push(ClosedItemHistoryRecord(
            closedAt: Date(timeIntervalSince1970: 1),
            entry: Self.entry(workspaceId: UUID(), panelId: UUID())
        ))
        let capture = try #require(store.pushPreservingAgentMetadata(
            Self.entry(workspaceId: workspaceId, panelId: panelId),
            coordinatedBy: Self.blockedIndex(
                workspaceId: workspaceId,
                panelId: panelId,
                sessionId: "newest-session",
                started: started,
                release: release
            )
        ))
        #expect(await SharedLiveAgentIndexLoadCoalescingTests.wait(for: started))
        var restoreCalls = 0
        #expect(!store.canReopen)
        #expect(!store.restoreFirstRestorable { _ in
            restoreCalls += 1
            return true
        })
        #expect(restoreCalls == 0)

        release.signal()
        await capture.value
        var restoredSessionID: String?
        #expect(store.restoreFirstRestorable { entry in
            restoredSessionID = Self.sessionID(from: entry)
            return true
        })
        #expect(restoredSessionID == "newest-session")
    }

    @Test
    func equalTimestampOrderingBlocksOnlyWhenNewestRecordIsPending() {
        let timestamp = Date(timeIntervalSince1970: 42)
        let olderPending = ClosedItemHistoryRecord(
            closedAt: timestamp,
            entry: Self.entry(workspaceId: UUID(), panelId: UUID())
        )
        let newerReady = ClosedItemHistoryRecord(
            closedAt: timestamp,
            entry: Self.entry(workspaceId: UUID(), panelId: UUID())
        )
        let store = ClosedItemHistoryStore()
        store.pushPendingEnrichment(olderPending)
        store.push(newerReady)
        var attemptedPanelIDs: [UUID] = []
        #expect(store.canReopen)
        #expect(!store.restoreFirstRestorable { entry in
            attemptedPanelIDs.append(Self.panelID(from: entry))
            return false
        })
        #expect(attemptedPanelIDs == [Self.panelID(from: newerReady.entry)])

        let pendingNewestStore = ClosedItemHistoryStore()
        pendingNewestStore.push(newerReady)
        pendingNewestStore.pushPendingEnrichment(olderPending)
        #expect(!pendingNewestStore.canReopen)
        #expect(!pendingNewestStore.restoreFirstRestorable { _ in
            Issue.record("A newest pending record must block generic restore")
            return true
        })
    }

    @Test
    func menuCountRemainsExactWhenPendingRecordsAreRemoved() {
        let pendingWorkspaceId = UUID()
        let readyWorkspaceId = UUID()
        let pendingRecord = ClosedItemHistoryRecord(
            entry: Self.entry(workspaceId: pendingWorkspaceId, panelId: UUID())
        )
        let readyRecord = ClosedItemHistoryRecord(
            entry: Self.entry(workspaceId: readyWorkspaceId, panelId: UUID())
        )
        let replacementRecord = ClosedItemHistoryRecord(
            entry: Self.entry(workspaceId: readyWorkspaceId, panelId: UUID())
        )

        let capacityStore = ClosedItemHistoryStore(capacity: 2)
        capacityStore.pushPendingEnrichment(pendingRecord)
        capacityStore.push(readyRecord)
        capacityStore.insert(replacementRecord, at: 1)
        let capacitySnapshot = capacityStore.menuSnapshot(maxItemCount: 10)
        #expect(capacitySnapshot.totalItemCount == 2)
        #expect(capacitySnapshot.items.map(\.id) == [readyRecord.id, replacementRecord.id])

        let removalStore = ClosedItemHistoryStore()
        removalStore.pushPendingEnrichment(pendingRecord)
        removalStore.push(readyRecord)
        removalStore.removePanelRecords(forWorkspaceIds: [pendingWorkspaceId])
        let removalSnapshot = removalStore.menuSnapshot(maxItemCount: 10)
        #expect(removalSnapshot.totalItemCount == 1)
        #expect(removalSnapshot.items.map(\.id) == [readyRecord.id])
    }

    @Test
    func remapDuringPendingCaptureIsPreservedByEnrichment() async throws {
        let oldWorkspaceId = UUID()
        let newWorkspaceId = UUID()
        let panelId = UUID()
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let store = ClosedItemHistoryStore()
        let capture = try #require(store.pushPreservingAgentMetadata(
            Self.entry(workspaceId: oldWorkspaceId, panelId: panelId),
            coordinatedBy: Self.blockedIndex(
                workspaceId: oldWorkspaceId,
                panelId: panelId,
                sessionId: "remapped-session",
                started: started,
                release: release
            )
        ))
        #expect(await SharedLiveAgentIndexLoadCoalescingTests.wait(for: started))
        store.remapPanelWorkspaceIds(from: oldWorkspaceId, to: newWorkspaceId)

        release.signal()
        await capture.value
        let recordID = try #require(store.menuSnapshot().items.first?.id)
        let record = try #require(store.removeRecord(id: recordID)?.record)
        guard case .panel(let panelEntry) = record.entry else {
            Issue.record("Expected a panel record")
            return
        }
        #expect(panelEntry.workspaceId == newWorkspaceId)
        #expect(panelEntry.snapshot.terminal?.agent?.sessionId == "remapped-session")
    }

    private static func blockedIndex(
        workspaceId: UUID,
        panelId: UUID,
        sessionId: String,
        started: DispatchSemaphore,
        release: DispatchSemaphore
    ) -> SharedLiveAgentIndex {
        let index = SharedLiveAgentIndexLoadCoalescingTests.index(
            workspaceId: workspaceId,
            panelId: panelId,
            sessionId: sessionId
        )
        let hookDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-pending-index-\(UUID().uuidString)", isDirectory: true)
        return SharedLiveAgentIndex(
            indexLoader: {
                started.signal()
                release.wait()
                return (
                    index: index,
                    surfaceResumeBindingIndex: .empty,
                    liveAgentProcessFingerprint: [],
                    processScopeFingerprint: [],
                    forkValidatedPanels: []
                )
            },
            hookStoreDirectoryProvider: { hookDirectory.path }
        )
    }

    private static func entry(workspaceId: UUID, panelId: UUID) -> ClosedItemHistoryEntry {
        .panel(ClosedPanelHistoryEntry(
            workspaceId: workspaceId,
            paneId: UUID(),
            tabIndex: 0,
            snapshot: SessionPanelSnapshot(
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
        ))
    }

    private static func sessionID(from entry: ClosedItemHistoryEntry) -> String? {
        guard case .panel(let panelEntry) = entry else { return nil }
        return panelEntry.snapshot.terminal?.agent?.sessionId
    }

    private static func panelID(from entry: ClosedItemHistoryEntry) -> UUID {
        guard case .panel(let panelEntry) = entry else { return UUID() }
        return panelEntry.snapshot.id
    }
}
