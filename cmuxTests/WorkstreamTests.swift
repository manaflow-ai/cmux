import Foundation
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
