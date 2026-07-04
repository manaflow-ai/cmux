import Foundation
import Combine
import Testing

import CmuxFoundation
import CmuxWorkspaces

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Workstreams (drill-in)")
struct WorkstreamTests {
    private func makeTabManager(workspaceCount: Int = 3) -> TabManager {
        let manager = TabManager()
        while manager.tabs.count < workspaceCount {
            manager.addWorkspace(autoWelcomeIfNeeded: false)
        }
        return manager
    }

    private final class DetachedSurfaceTestPanel: Panel {
        let objectWillChange = ObservableObjectPublisher()
        let id: UUID
        let panelType: PanelType = .terminal
        let displayTitle = "Detached"
        let displayIcon: String? = "terminal.fill"
        let isDirty = false

        init(id: UUID = UUID()) {
            self.id = id
        }

        func close() {}
        func focus() {}
        func unfocus() {}
        func triggerFlash(reason: WorkspaceAttentionFlashReason) {}
    }

    private func makeDetachedSurfaceTransfer(sourceWorkspaceId: UUID) -> Workspace.DetachedSurfaceTransfer {
        let panel = DetachedSurfaceTestPanel()
        return Workspace.DetachedSurfaceTransfer(
            sourceWorkspaceId: sourceWorkspaceId,
            panelId: panel.id,
            panel: panel,
            title: panel.displayTitle,
            icon: panel.displayIcon,
            iconImageData: nil,
            kind: "terminal",
            isLoading: false,
            isPinned: false,
            directory: nil,
            directoryDisplayLabel: nil,
            ttyName: nil,
            cachedTitle: nil,
            customTitle: nil,
            customTitleSource: nil,
            manuallyUnread: false,
            restoredUnreadIndicator: nil,
            restorableAgent: nil,
            restorableAgentResumeState: nil,
            restoredResumeSessionWorkingDirectory: nil,
            resumeBinding: nil,
            agentRuntime: nil,
            isRemoteTerminal: false,
            remoteRelayPort: nil,
            remotePTYSessionID: nil,
            remoteCleanupConfiguration: nil
        )
    }

    // MARK: - TabManager integration

    @Test func createAssignsMembersAndAutoNames() throws {
        let manager = makeTabManager()
        let members = [manager.tabs[0].id, manager.tabs[2].id]
        let id = manager.createWorkstream(name: "", memberWorkspaceIds: members)
        let workstream = try #require(manager.workstreams.first { $0.id == id })
        // Localized auto-name resolves to "Workstream 1" in the test bundle.
        #expect(workstream.name == "Workstream 1")
        #expect(manager.tabs[0].workstreamId == id)
        #expect(manager.tabs[1].workstreamId == nil)
        #expect(manager.tabs[2].workstreamId == id)
    }

    @Test func deleteKeepsWorkspacesAndExitsDrillIn() throws {
        let manager = makeTabManager()
        let id = manager.createWorkstream(name: "WS", memberWorkspaceIds: [manager.tabs[0].id])
        manager.enterWorkstream(id: id)
        #expect(manager.drilledInWorkstreamId == id)
        let count = manager.tabs.count
        let released = manager.deleteWorkstream(id: id)
        #expect(released == 1)
        #expect(manager.tabs.count == count) // nothing closed
        #expect(manager.workstreams.isEmpty)
        #expect(manager.drilledInWorkstreamId == nil)
        #expect(manager.tabs[0].workstreamId == nil)
    }

    @Test func addRemoveAndMove() throws {
        let manager = makeTabManager()
        let a = manager.createWorkstream(name: "A")
        let b = manager.createWorkstream(name: "B")
        manager.addWorkspaceToWorkstream(workspaceId: manager.tabs[0].id, workstreamId: a)
        #expect(manager.tabs[0].workstreamId == a)
        manager.removeWorkspaceFromWorkstream(workspaceId: manager.tabs[0].id)
        #expect(manager.tabs[0].workstreamId == nil)
        manager.moveWorkstream(id: b, toIndex: 0)
        #expect(manager.workstreams.map(\.id) == [b, a])
    }

    @Test func detachClearsWorkstreamMembership() throws {
        // Cross-window move: a detached workspace must drop its workstreamId so
        // the destination window (no matching Workstream) still shows it.
        let manager = makeTabManager()
        let memberId = manager.tabs[0].id
        let id = manager.createWorkstream(name: "WS", memberWorkspaceIds: [memberId])
        #expect(manager.tabs.first { $0.id == memberId }?.workstreamId == id)
        let removed = try #require(manager.detachWorkspace(tabId: memberId))
        #expect(removed.workstreamId == nil)
    }

    @Test func newWorkspaceWhileDrilledInJoinsWorkstream() throws {
        // A workspace created while drilled into a workstream must inherit it.
        // Otherwise it gets workstreamId == nil, fails the drill-in filter
        // (workstreamId == drilledInWorkstreamId), and is focused-but-invisible.
        let manager = makeTabManager()
        let id = manager.createWorkstream(name: "WS")
        manager.drilledInWorkstreamId = id
        let created = manager.addWorkspace(autoWelcomeIfNeeded: false)
        #expect(created.workstreamId == id)
        // It is visible under the current drill-in filter.
        let visible = manager.tabs.filter { $0.workstreamId == manager.drilledInWorkstreamId }
        #expect(visible.contains { $0.id == created.id })
    }

    @Test func attachingWorkspaceWhileDrilledInJoinsWorkstream() throws {
        let source = makeTabManager()
        let destination = makeTabManager()
        let workstreamId = destination.createWorkstream(name: "Destination")
        destination.enterWorkstream(id: workstreamId)
        let movedId = source.tabs[0].id
        let moved = try #require(source.detachWorkspace(tabId: movedId))

        destination.attachWorkspace(moved)

        let attached = try #require(destination.tabs.first { $0.id == movedId })
        #expect(attached.workstreamId == workstreamId)
        let visible = destination.tabs.filter { $0.workstreamId == destination.drilledInWorkstreamId }
        #expect(visible.contains { $0.id == movedId })
    }

    @Test func detachedSurfaceWorkspaceWhileDrilledInJoinsWorkstream() throws {
        let manager = makeTabManager()
        let workstreamId = manager.createWorkstream(name: "WS")
        manager.enterWorkstream(id: workstreamId)
        let transfer = makeDetachedSurfaceTransfer(sourceWorkspaceId: manager.tabs[0].id)

        let created = try #require(manager.addWorkspace(fromDetachedSurface: transfer, select: true))

        #expect(created.workstreamId == workstreamId)
        let visible = manager.tabs.filter { $0.workstreamId == manager.drilledInWorkstreamId }
        #expect(visible.contains { $0.id == created.id })
    }

    @Test func workspaceGroupVisibleMemberIdsStayInsideWorkstreamScope() throws {
        let manager = makeTabManager()
        let firstChildId = manager.tabs[0].id
        let hiddenChildId = manager.tabs[1].id
        let groupId = try #require(manager.createWorkspaceGroup(
            name: "G",
            childWorkspaceIds: [firstChildId, hiddenChildId]
        ))
        let group = try #require(manager.workspaceGroups.first { $0.id == groupId })
        let visibleWorkstreamId = manager.createWorkstream(
            name: "Visible",
            memberWorkspaceIds: [group.anchorWorkspaceId, firstChildId]
        )
        let hiddenWorkstreamId = manager.createWorkstream(
            name: "Hidden",
            memberWorkspaceIds: [hiddenChildId]
        )

        let visibleMemberIds = manager.workspaceGroupMemberIds(
            groupId: groupId,
            visibleInWorkstreamId: visibleWorkstreamId
        )

        #expect(Set(visibleMemberIds) == Set([group.anchorWorkspaceId, firstChildId]))
        #expect(!visibleMemberIds.contains(hiddenChildId))
        #expect(manager.tabs.first { $0.id == hiddenChildId }?.workstreamId == hiddenWorkstreamId)
    }

    @Test func enterWorkstreamPrunesHiddenSidebarSelection() throws {
        let manager = makeTabManager()
        let visibleId = manager.tabs[0].id
        let hiddenId = manager.tabs[1].id
        let workstreamId = manager.createWorkstream(name: "WS", memberWorkspaceIds: [visibleId])
        manager.setSidebarSelectedWorkspaceIds([visibleId, hiddenId])

        manager.enterWorkstream(id: workstreamId)

        #expect(manager.sidebarSelectedWorkspaceIds == [visibleId])
    }

    @Test func exitWorkstreamPrunesDrilledInSidebarSelection() throws {
        let manager = makeTabManager()
        let drilledInId = manager.tabs[0].id
        let topLevelId = manager.tabs[1].id
        let workstreamId = manager.createWorkstream(name: "WS", memberWorkspaceIds: [drilledInId])
        manager.enterWorkstream(id: workstreamId)
        manager.setSidebarSelectedWorkspaceIds([drilledInId, topLevelId])

        manager.exitWorkstreamDrillIn()

        #expect(manager.sidebarSelectedWorkspaceIds == [topLevelId])
    }

    @Test func scopedWorkspaceGroupDeleteClearsLastHoldoutGroup() throws {
        let manager = makeTabManager(workspaceCount: 1)
        let originalId = manager.tabs[0].id
        let groupId = try #require(manager.createWorkspaceGroup(name: "G"))
        let originalWorkspace = try #require(manager.tabs.first { $0.id == originalId })
        manager.closeWorkspace(originalWorkspace)
        #expect(manager.tabs.count == 1)
        #expect(manager.workspaceGroups.contains { $0.id == groupId })

        let closed = manager.deleteWorkspaceGroupMembers(groupId: groupId, visibleInWorkstreamId: nil)

        #expect(closed == 0)
        #expect(manager.tabs.count == 1)
        #expect(manager.tabs[0].groupId == nil)
        #expect(!manager.workspaceGroups.contains { $0.id == groupId })
    }

    @Test func closingSelectedWorkspaceWhileDrilledInSelectsScopedNeighbor() throws {
        let manager = makeTabManager(workspaceCount: 4)
        let closing = manager.tabs[1]
        let scopedNeighbor = manager.tabs[3]
        let workstreamId = manager.createWorkstream(
            name: "WS",
            memberWorkspaceIds: [closing.id, scopedNeighbor.id]
        )
        manager.enterWorkstream(id: workstreamId)
        manager.selectWorkspace(closing)

        manager.closeWorkspace(closing)

        #expect(manager.drilledInWorkstreamId == workstreamId)
        #expect(manager.selectedTabId == scopedNeighbor.id)
    }

    @Test func closingLastSelectedWorkspaceInDrillInExitsToTopLevel() throws {
        let manager = makeTabManager()
        let closing = manager.tabs[1]
        let workstreamId = manager.createWorkstream(name: "WS", memberWorkspaceIds: [closing.id])
        manager.enterWorkstream(id: workstreamId)
        manager.selectWorkspace(closing)

        manager.closeWorkspace(closing)

        #expect(manager.drilledInWorkstreamId == nil)
        let selected = try #require(manager.selectedWorkspace)
        #expect(selected.workstreamId == nil)
    }

    @Test func sidebarScopedCloseTargetsStayInsideWorkstreamScope() throws {
        let manager = makeTabManager(workspaceCount: 4)
        let firstScopedId = manager.tabs[1].id
        let hiddenId = manager.tabs[2].id
        let secondScopedId = manager.tabs[3].id
        let workstreamId = manager.createWorkstream(
            name: "WS",
            memberWorkspaceIds: [firstScopedId, secondScopedId]
        )
        manager.enterWorkstream(id: workstreamId)

        #expect(manager.workspaceIdsForClosingSidebarRowsBelow(tabId: firstScopedId) == [secondScopedId])
        #expect(manager.workspaceIdsForClosingSidebarRowsAbove(tabId: secondScopedId) == [firstScopedId])
        #expect(manager.workspaceIdsForClosingOtherSidebarRows(keeping: [firstScopedId]) == [secondScopedId])
        #expect(!manager.sidebarScopedWorkspaceRowIds().contains(hiddenId))
    }

    @Test func sidebarScopedMoveSkipsHiddenWorkspaces() throws {
        let manager = makeTabManager(workspaceCount: 4)
        let firstScopedId = manager.tabs[1].id
        let hiddenId = manager.tabs[2].id
        let secondScopedId = manager.tabs[3].id
        let workstreamId = manager.createWorkstream(
            name: "WS",
            memberWorkspaceIds: [firstScopedId, secondScopedId]
        )
        manager.enterWorkstream(id: workstreamId)

        #expect(manager.moveWorkspaceInSidebarScope(tabId: firstScopedId, by: 1))

        #expect(manager.sidebarScopedWorkspaceRowIds() == [secondScopedId, firstScopedId])
        #expect(manager.tabs.contains { $0.id == hiddenId })
    }

    @Test func restoringClosedWorkspaceReconcilesDrillInToRestoredWorkstream() throws {
        let manager = makeTabManager()
        let restoredWorkstream = manager.createWorkstream(name: "Restored")
        let otherWorkstream = manager.createWorkstream(name: "Other")
        manager.drilledInWorkstreamId = otherWorkstream
        var snapshot = manager.tabs[0].sessionSnapshot(includeScrollback: false)
        snapshot.workstreamId = restoredWorkstream

        #expect(manager.restoreClosedWorkspace(ClosedWorkspaceHistoryEntry(
            workspaceId: manager.tabs[0].id,
            windowId: nil,
            workspaceIndex: 0,
            snapshot: snapshot
        )))

        let restoredWorkspace = try #require(manager.selectedWorkspace)
        #expect(restoredWorkspace.workstreamId == restoredWorkstream)
        #expect(manager.drilledInWorkstreamId == restoredWorkstream)
        let visible = manager.tabs.filter { $0.workstreamId == manager.drilledInWorkstreamId }
        #expect(visible.contains { $0.id == restoredWorkspace.id })
    }

    // MARK: - Persistence round-trip

    @Test func sessionSnapshotRoundtripPreservesWorkstreams() throws {
        let manager = makeTabManager()
        let memberIndex = 0
        let memberId = manager.tabs[memberIndex].id
        let a = manager.createWorkstream(name: "Checkout", memberWorkspaceIds: [memberId])
        let b = manager.createWorkstream(name: "Billing")
        manager.moveWorkstream(id: b, toIndex: 0) // order: [b, a]
        manager.enterWorkstream(id: a)

        let snapshot = manager.sessionSnapshot(includeScrollback: false)
        let persisted = try #require(snapshot.workstreams)
        #expect(persisted.map(\.id) == [b, a])
        #expect(snapshot.drilledInWorkstreamId == a)
        // Membership rides on the workspace snapshot.
        let memberSnapshot = try #require(snapshot.workspaces.first { $0.workspaceId == memberId })
        #expect(memberSnapshot.workstreamId == a)

        let restored = TabManager()
        restored.restoreSessionSnapshot(snapshot)
        #expect(restored.workstreams.map(\.id) == [b, a])
        #expect(restored.workstreams.first { $0.id == a }?.name == "Checkout")
        #expect(restored.drilledInWorkstreamId == a)
        // The restored member reconnects by stable workstream id.
        #expect(restored.memberCountForWorkstreamTesting(a) == 1)
    }

    @Test func restoreClearsDanglingDrillInState() throws {
        // A snapshot can carry a drill-in pointer to a workstream that no longer
        // resolves (manual edit / partial restore); normalize must clear it.
        let manager = makeTabManager()
        var snapshot = manager.sessionSnapshot(includeScrollback: false)
        snapshot.drilledInWorkstreamId = UUID() // ghost
        let restored = TabManager()
        restored.restoreSessionSnapshot(snapshot)
        #expect(restored.drilledInWorkstreamId == nil)
    }

    @Test func zeroRegressionWhenNoWorkstreams() throws {
        // No workstreams → snapshot omits the array and nil drill-in, and a
        // round-trip leaves a clean top-level state.
        let manager = makeTabManager()
        let snapshot = manager.sessionSnapshot(includeScrollback: false)
        #expect(snapshot.workstreams == nil)
        #expect(snapshot.drilledInWorkstreamId == nil)
        let restored = TabManager()
        restored.restoreSessionSnapshot(snapshot)
        #expect(restored.workstreams.isEmpty)
        #expect(restored.drilledInWorkstreamId == nil)
    }

    @Test func sessionAutosaveFingerprintTracksWorkstreamState() throws {
        let manager = makeTabManager()
        let baseline = manager.sessionAutosaveFingerprint()
        let id = manager.createWorkstream(name: "WS")
        let afterCreate = manager.sessionAutosaveFingerprint()
        #expect(afterCreate != baseline)

        manager.addWorkspaceToWorkstream(workspaceId: manager.tabs[0].id, workstreamId: id)
        let afterMembership = manager.sessionAutosaveFingerprint()
        #expect(afterMembership != afterCreate)

        manager.enterWorkstream(id: id)
        let afterDrillIn = manager.sessionAutosaveFingerprint()
        #expect(afterDrillIn != afterMembership)

        manager.renameWorkstream(id: id, name: "Renamed")
        #expect(manager.sessionAutosaveFingerprint() != afterDrillIn)
    }

    // MARK: - Rollup render model

    @Test func rowSnapshotsComputeRollup() throws {
        let manager = makeTabManager(workspaceCount: 3)
        let a = manager.createWorkstream(name: "Alpha", memberWorkspaceIds: [manager.tabs[0].id, manager.tabs[1].id])
        let b = manager.createWorkstream(name: "Beta")
        let selectedId = manager.tabs[1].id

        let unread: (UUID) -> Int = { id in id == manager.tabs[0].id ? 4 : 0 }
        let rows = SidebarWorkstreamRenderModel.rowSnapshots(
            workstreams: manager.workstreams,
            tabs: manager.tabs,
            selectedWorkspaceId: selectedId,
            unreadCount: unread
        )
        let rowA = try #require(rows.first { $0.id == a })
        let rowB = try #require(rows.first { $0.id == b })
        #expect(rowA.workspaceCount == 2)
        #expect(rowA.unreadCount == 4)
        #expect(rowA.containsSelectedWorkspace == true) // tabs[1] selected
        #expect(rowB.workspaceCount == 0)
        #expect(rowB.containsSelectedWorkspace == false)
        #expect(rowA.iconSymbol == SidebarWorkstreamRenderModel.defaultIconSymbol)
    }

    @Test func rowSnapshotsEmptyWithoutWorkstreams() {
        let manager = makeTabManager()
        let rows = SidebarWorkstreamRenderModel.rowSnapshots(
            workstreams: manager.workstreams,
            tabs: manager.tabs,
            selectedWorkspaceId: nil,
            unreadCount: { _ in 0 }
        )
        #expect(rows.isEmpty)
    }
}

// Small testing accessor so the round-trip test can assert membership without
// reaching into the model's internals from the test file.
extension TabManager {
    func memberCountForWorkstreamTesting(_ id: UUID) -> Int {
        tabs.reduce(into: 0) { $0 += ($1.workstreamId == id ? 1 : 0) }
    }
}
