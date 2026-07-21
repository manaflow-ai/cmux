import Foundation
import Testing
import CmuxTerminalCore
@testable import CmuxTerminal

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Terminal font zoom session persistence")
struct TerminalFontZoomSessionPersistenceTests {
    @Test("restored terminal zoom survives the next session capture")
    func restoredZoomSurvivesRecapture() throws {
        let workspace = Workspace()
        let panelID = try #require(workspace.focusedPanelId)
        let snapshot = workspace.sessionSnapshot(includeScrollback: false)

        let zoomedSnapshot = try snapshotBySettingTerminalFontSize(
            5.5,
            panelID: panelID,
            in: snapshot
        )
        let restoredWorkspace = Workspace()
        let restoredPanelIDs = restoredWorkspace.restoreSessionSnapshot(zoomedSnapshot)
        let restoredPanelID = restoredPanelIDs[panelID] ?? panelID
        let restoredPanel = try #require(
            restoredWorkspace.panels[restoredPanelID] as? TerminalPanel
        )
        let restoredLineage = try #require(
            restoredPanel.surface.fontSizeLineageSnapshot()
        )

        #expect(restoredLineage.basePoints == 5.5)
        #expect(restoredLineage.isExplicitOverride)

        let recapturedSnapshot = restoredWorkspace.sessionSnapshot(includeScrollback: false)
        let recapturedFontSize = try terminalFontSize(
            panelID: restoredPanelID,
            in: recapturedSnapshot
        )

        #expect(recapturedFontSize == 5.5)

        let inheritedConfig = try #require(
            TabManager().inheritedTerminalConfigForNewWorkspace(workspace: restoredWorkspace)
        )
        #expect(inheritedConfig.fontSize == 5.5)
        #expect(inheritedConfig.fontSizeLineage?.isExplicitOverride == true)
    }

    @Test("unzoomed terminal keeps following config across session restore")
    func unzoomedTerminalDoesNotPersistFontSize() throws {
        let workspace = Workspace()
        let panelID = try #require(workspace.focusedPanelId)

        let initialSnapshot = workspace.sessionSnapshot(includeScrollback: false)
        #expect(try optionalTerminalFontSize(panelID: panelID, in: initialSnapshot) == nil)

        let restoredWorkspace = Workspace()
        let restoredPanelIDs = restoredWorkspace.restoreSessionSnapshot(initialSnapshot)
        let restoredPanelID = restoredPanelIDs[panelID] ?? panelID
        let recapturedSnapshot = restoredWorkspace.sessionSnapshot(includeScrollback: false)

        #expect(
            try optionalTerminalFontSize(panelID: restoredPanelID, in: recapturedSnapshot) == nil
        )
    }

    @Test("cleared zoom follows current config when the runtime is recreated")
    func clearedZoomDoesNotSeedRuntimeRecreation() {
        var restoredTemplate = CmuxSurfaceConfigTemplate()
        restoredTemplate.setFontSize(5.5, isExplicitOverride: true)
        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: restoredTemplate,
            runtimeSpawnPolicy: .pacedSessionRestore
        )

        let resetLineage = TerminalFontSizeLineage(
            basePoints: 12,
            isExplicitOverride: false
        )
        surface.recordCurrentFontSizeLineage(resetLineage)

        #expect(surface.fontSizeLineageSnapshot() == resetLineage)
        #expect(surface.runtimeCreationConfigTemplate().fontSizeLineage == nil)
    }

    @Test("closing the remembered zoom source discards its explicit lineage")
    func closingZoomSourceClearsWorkspaceFallback() throws {
        let workspace = Workspace()
        let panelID = try #require(workspace.focusedPanelId)
        let snapshot = try snapshotBySettingTerminalFontSize(
            5.5,
            panelID: panelID,
            in: workspace.sessionSnapshot(includeScrollback: false)
        )
        let restoredWorkspace = Workspace()
        let restoredPanelIDs = restoredWorkspace.restoreSessionSnapshot(snapshot)
        let restoredPanelID = restoredPanelIDs[panelID] ?? panelID
        let paneID = try #require(restoredWorkspace.bonsplitController.focusedPaneId)
        _ = try #require(
            restoredWorkspace.newBrowserSurface(
                inPane: paneID,
                url: URL(string: "about:blank"),
                focus: false,
                creationPolicy: .restoration
            )
        )

        #expect(
            TabManager().inheritedTerminalConfigForNewWorkspace(
                workspace: restoredWorkspace
            )?.fontSizeLineage?.isExplicitOverride == true
        )
        #expect(restoredWorkspace.closePanel(restoredPanelID, force: true))
        #expect(
            TabManager().inheritedTerminalConfigForNewWorkspace(
                workspace: restoredWorkspace
            ) == nil
        )
    }

    private func snapshotBySettingTerminalFontSize(
        _ fontSize: Double,
        panelID: UUID,
        in snapshot: SessionWorkspaceSnapshot
    ) throws -> SessionWorkspaceSnapshot {
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any]
        )
        var panels = try #require(object["panels"] as? [[String: Any]])
        let panelIndex = try #require(panels.firstIndex { $0["id"] as? String == panelID.uuidString })
        var terminal = try #require(panels[panelIndex]["terminal"] as? [String: Any])
        terminal["fontSize"] = fontSize
        panels[panelIndex]["terminal"] = terminal
        object["panels"] = panels

        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(SessionWorkspaceSnapshot.self, from: data)
    }

    private func terminalFontSize(
        panelID: UUID,
        in snapshot: SessionWorkspaceSnapshot
    ) throws -> Double {
        let fontSize = try optionalTerminalFontSize(panelID: panelID, in: snapshot)
        return try #require(fontSize)
    }

    private func optionalTerminalFontSize(
        panelID: UUID,
        in snapshot: SessionWorkspaceSnapshot
    ) throws -> Double? {
        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any]
        )
        let panels = try #require(object["panels"] as? [[String: Any]])
        let panel = try #require(panels.first { $0["id"] as? String == panelID.uuidString })
        let terminal = try #require(panel["terminal"] as? [String: Any])
        return terminal["fontSize"] as? Double
    }
}
