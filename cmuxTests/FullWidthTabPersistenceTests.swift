import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class FullWidthTabPersistenceTests: XCTestCase {
    func testSessionPaneLayoutSnapshotPreservesFullWidthTabModeFlag() throws {
        let panelId = UUID()
        let source = SessionPaneLayoutSnapshot(
            panelIds: [panelId],
            selectedPanelId: panelId,
            isFullWidthTabMode: true
        )

        let data = try JSONEncoder().encode(source)
        let decoded = try JSONDecoder().decode(SessionPaneLayoutSnapshot.self, from: data)

        XCTAssertEqual(decoded.panelIds, [panelId])
        XCTAssertEqual(decoded.selectedPanelId, panelId)
        XCTAssertEqual(decoded.isFullWidthTabMode, true)
    }

    func testSessionPaneLayoutSnapshotDecodesLegacyFullWidthTabModeAsNil() throws {
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

        XCTAssertEqual(decoded.panelIds, [panelId])
        XCTAssertEqual(decoded.selectedPanelId, panelId)
        XCTAssertNil(decoded.isFullWidthTabMode)
    }

    @MainActor
    func testWorkspaceSessionSnapshotRestoresFullWidthTabMode() throws {
        let workspace = Workspace()
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let paneId = try XCTUnwrap(workspace.paneId(forPanelId: panelId))

        XCTAssertTrue(workspace.toggleFullWidthTabMode(panelId: panelId))
        XCTAssertTrue(workspace.bonsplitController.isFullWidthTabMode(inPane: paneId))

        let snapshot = workspace.sessionSnapshot(includeScrollback: false)
        guard case .pane(let paneSnapshot) = snapshot.layout else {
            return XCTFail("Expected single-pane layout")
        }
        XCTAssertEqual(paneSnapshot.isFullWidthTabMode, true)

        let restored = Workspace()
        let restoredIds = restored.restoreSessionSnapshot(snapshot)
        let restoredPanelId = try XCTUnwrap(restoredIds[panelId])
        let restoredPaneId = try XCTUnwrap(restored.paneId(forPanelId: restoredPanelId))

        XCTAssertTrue(restored.bonsplitController.isFullWidthTabMode(inPane: restoredPaneId))
    }
}
