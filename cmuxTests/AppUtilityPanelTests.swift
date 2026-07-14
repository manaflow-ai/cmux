import CmuxWorkspaces
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class AppUtilityPanelTests: XCTestCase {
    func testOpenOrFocusAppUtilitySurfaceReusesExistingKind() {
        let workspace = Workspace()
        guard let paneId = workspace.bonsplitController.focusedPaneId else {
            XCTFail("Expected focused pane")
            return
        }

        guard let firstPanel = workspace.openOrFocusAppUtilitySurface(
            inPane: paneId,
            kind: .settings,
            focus: true
        ) else {
            XCTFail("Expected Settings utility surface to be created")
            return
        }
        guard let secondPanel = workspace.openOrFocusAppUtilitySurface(
            inPane: paneId,
            kind: .settings,
            focus: true
        ) else {
            XCTFail("Expected existing Settings utility surface to be focused")
            return
        }

        XCTAssertEqual(firstPanel.id, secondPanel.id)
        XCTAssertEqual(
            workspace.panels.values.compactMap { $0 as? AppUtilityPanel }.filter { $0.kind == .settings }.count,
            1
        )
        XCTAssertEqual(workspace.focusedPanelId, firstPanel.id)
        XCTAssertEqual(
            workspace.surfaceIdFromPanelId(firstPanel.id).flatMap { workspace.bonsplitController.tab($0)?.kind },
            SurfaceKind.appUtility.rawValue
        )
    }

    func testAppUtilityKindsCreateIndependentSurfaces() {
        let workspace = Workspace()
        guard let paneId = workspace.bonsplitController.focusedPaneId,
              let originalFocusedPanelId = workspace.focusedPanelId else {
            XCTFail("Expected focused pane and panel")
            return
        }

        guard let settingsPanel = workspace.openOrFocusAppUtilitySurface(
            inPane: paneId,
            kind: .settings,
            focus: false
        ), let mobilePanel = workspace.openOrFocusAppUtilitySurface(
            inPane: paneId,
            kind: .mobilePairing,
            focus: false
        ) else {
            XCTFail("Expected both utility surfaces to be created")
            return
        }

        XCTAssertNotEqual(settingsPanel.id, mobilePanel.id)
        XCTAssertEqual(settingsPanel.displayTitle, "Settings")
        XCTAssertEqual(mobilePanel.displayTitle, "Pair iPhone")
        XCTAssertEqual(workspace.focusedPanelId, originalFocusedPanelId)
    }
}
