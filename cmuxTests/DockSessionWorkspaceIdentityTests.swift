import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Dock session workspace identity", .serialized)
@MainActor
struct DockSessionWorkspaceIdentityTests {
    @Test(
        "Duplicate legacy source IDs resolve to the Dock owner or first persisted source",
        arguments: [0, 1, 2], [false, true]
    )
    func duplicateSourceIDs(ownerIndex: Int, excludeOriginalID: Bool) throws {
        let duplicateID = UUID()
        var workspaces = [
            Self.workspace(id: duplicateID, title: "First"),
            Self.workspace(id: duplicateID, title: "Second"),
            Self.workspace(id: UUID(), title: "Other")
        ]
        let panel = Self.terminal()
        workspaces[ownerIndex].dock = Self.dock(panel: panel, sourceID: duplicateID)
        let snapshot = SessionTabManagerSnapshot(selectedWorkspaceIndex: 0, workspaces: workspaces)
        let manager = TabManager(autoWelcomeIfNeeded: false)
        defer { manager.closeWorkspacesForTesting() }
        manager.restoreSessionSnapshot(
            snapshot,
            excludingWorkspaceIds: excludeOriginalID ? [duplicateID] : []
        )
        #expect(Set(manager.tabs.map(\.id)).count == 3)
        #expect(manager.tabs[1].id != duplicateID)
        if excludeOriginalID { #expect(manager.tabs[0].id != duplicateID) }

        manager.restoreWorkspaceDockSessionSnapshots(from: snapshot, excludingStableIdentities: [])

        let dock = try #require(manager.tabs[ownerIndex].dockSplit)
        let restoredPanel = try #require(dock.panels.values.first as? TerminalPanel)
        let transfer = try #require(dock.detachedSurfaceTransfersByPanelId[restoredPanel.id])
        let expectedSource = manager.tabs[ownerIndex == 1 ? 1 : 0]
        #expect(transfer.sourceWorkspaceId == expectedSource.id)
        #expect(restoredPanel.stableSurfaceIdentity.id == panel.stableSurfaceId)
        #expect(dock.panels.count == 1)

        // The next save must carry the unique live identity, never the colliding legacy ID.
        let savedDock = dock.sessionSnapshot(includeScrollback: false)
        #expect(savedDock.sourceWorkspaceIdsByPanelId?[restoredPanel.id] == expectedSource.id)
    }

    @Test("A legacy unique source ID still resolves across workspaces after reminting")
    func uniqueCrossWorkspaceSourceID() throws {
        let sourceID = UUID()
        let panel = Self.terminal()
        var destination = Self.workspace(id: UUID(), title: "Destination")
        destination.dock = Self.dock(panel: panel, sourceID: sourceID)
        let snapshot = SessionTabManagerSnapshot(
            selectedWorkspaceIndex: 1,
            workspaces: [Self.workspace(id: sourceID, title: "Source"), destination]
        )
        let manager = TabManager(autoWelcomeIfNeeded: false)
        defer { manager.closeWorkspacesForTesting() }
        manager.restoreSessionSnapshot(snapshot, excludingWorkspaceIds: [sourceID])
        #expect(manager.tabs[0].id != sourceID)

        manager.restoreWorkspaceDockSessionSnapshots(from: snapshot, excludingStableIdentities: [])

        let dock = try #require(manager.tabs[1].dockSplit)
        let restoredID = try #require(dock.panels.keys.first)
        #expect(dock.detachedSurfaceTransfersByPanelId[restoredID]?.sourceWorkspaceId == manager.tabs[0].id)
        #expect(dock.panels.count == 1)
    }

    private static func workspace(id: UUID, title: String) -> SessionWorkspaceSnapshot {
        let panel = terminal()
        return SessionWorkspaceSnapshot(
            workspaceId: id,
            processTitle: title,
            customTitle: title,
            customDescription: nil,
            customColor: nil,
            isPinned: false,
            terminalScrollBarHidden: nil,
            currentDirectory: "/tmp",
            focusedPanelId: panel.id,
            layout: .pane(SessionPaneLayoutSnapshot(panelIds: [panel.id], selectedPanelId: panel.id)),
            panels: [panel],
            statusEntries: [],
            logEntries: [],
            progress: nil,
            gitBranch: nil,
            remote: nil
        )
    }

    private static func terminal() -> SessionPanelSnapshot {
        SessionPanelSnapshot(
            id: UUID(),
            stableSurfaceId: UUID(),
            type: .terminal,
            title: "Saved task",
            customTitle: nil,
            directory: "/tmp",
            isPinned: false,
            isManuallyUnread: false,
            listeningPorts: [],
            ttyName: nil,
            terminal: SessionTerminalPanelSnapshot(workingDirectory: "/tmp"),
            browser: nil,
            markdown: nil,
            filePreview: nil,
            rightSidebarTool: nil
        )
    }

    private static func dock(panel: SessionPanelSnapshot, sourceID: UUID) -> SessionSplitContainerSnapshot {
        SessionSplitContainerSnapshot(
            focusedPanelId: panel.id,
            layout: .pane(SessionPaneLayoutSnapshot(panelIds: [panel.id], selectedPanelId: panel.id)),
            panels: [panel],
            sourceWorkspaceIdsByPanelId: [panel.id: sourceID]
        )
    }
}
