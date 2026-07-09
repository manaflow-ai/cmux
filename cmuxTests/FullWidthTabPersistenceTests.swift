import Foundation
import Testing
import CmuxWorkspaces

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct FullWidthTabPersistenceTests {
    @Test func sessionPaneLayoutSnapshotPreservesFullWidthTabModeFlag() throws {
        let panelId = UUID()
        let source = SessionPaneLayoutSnapshot(
            panelIds: [panelId],
            selectedPanelId: panelId,
            isFullWidthTabMode: true
        )

        let data = try JSONEncoder().encode(source)
        let decoded = try JSONDecoder().decode(SessionPaneLayoutSnapshot.self, from: data)

        #expect(decoded.panelIds == [panelId])
        #expect(decoded.selectedPanelId == panelId)
        #expect(decoded.isFullWidthTabMode == true)
    }

    @Test func sessionPaneLayoutSnapshotDecodesLegacyFullWidthTabModeAsNil() throws {
        let panelId = UUID()
        let json = """
        {
          "panelIds": ["\(panelId.uuidString)"],
          "selectedPanelId": "\(panelId.uuidString)"
        }
        """

        let decoded = try JSONDecoder().decode(
            SessionPaneLayoutSnapshot.self,
            from: Data(json.utf8)
        )

        #expect(decoded.panelIds == [panelId])
        #expect(decoded.selectedPanelId == panelId)
        #expect(decoded.isFullWidthTabMode == nil)
    }

    @MainActor
    @Test func workspaceSessionSnapshotRestoresFullWidthTabMode() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let paneId = try #require(workspace.paneId(forPanelId: panelId))

        #expect(workspace.toggleFullWidthTabMode(panelId: panelId))
        #expect(workspace.bonsplitController.isFullWidthTabMode(inPane: paneId))

        let snapshot = workspace.sessionSnapshot(includeScrollback: false)
        let paneSnapshot = try #require({
            if case .pane(let paneSnapshot) = snapshot.layout {
                return paneSnapshot
            }
            return nil
        }())
        #expect(paneSnapshot.isFullWidthTabMode == true)

        let restored = Workspace()
        let restoredIds = restored.restoreSessionSnapshot(snapshot)
        let restoredPanelId = try #require(restoredIds[panelId])
        let restoredPaneId = try #require(restored.paneId(forPanelId: restoredPanelId))

        #expect(restored.bonsplitController.isFullWidthTabMode(inPane: restoredPaneId))
    }
}
