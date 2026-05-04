import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class SimulatorSessionPersistenceTests: XCTestCase {
    @MainActor
    func testWorkspaceSessionSnapshotExcludesSimulatorPanelsFromPersistedLayout() throws {
        let workspace = Workspace()
        let paneId = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let initialPanelId = try XCTUnwrap(workspace.focusedPanelId)
        let simulatorPanel = try XCTUnwrap(
            workspace.newSimulatorSurface(
                inPane: paneId,
                preferredUDID: "test-simulator",
                focus: false
            )
        )
        let secondTerminal = try XCTUnwrap(
            workspace.newTerminalSurface(inPane: paneId, focus: false)
        )

        let snapshot = workspace.sessionSnapshot(includeScrollback: false)

        XCTAssertFalse(snapshot.panels.contains { $0.id == simulatorPanel.id })
        XCTAssertTrue(snapshot.panels.contains { $0.id == initialPanelId })
        XCTAssertTrue(snapshot.panels.contains { $0.id == secondTerminal.id })
        guard case .pane(let pane) = snapshot.layout else {
            return XCTFail("Expected a single-pane snapshot")
        }
        XCTAssertFalse(pane.panelIds.contains(simulatorPanel.id))
        XCTAssertTrue(pane.panelIds.contains(initialPanelId))
        XCTAssertTrue(pane.panelIds.contains(secondTerminal.id))
    }
}
