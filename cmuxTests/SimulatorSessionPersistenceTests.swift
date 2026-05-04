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

    @MainActor
    func testWorkspaceSessionSnapshotDoesNotPersistDanglingSimulatorSelection() throws {
        let workspace = Workspace()
        let paneId = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let initialPanelId = try XCTUnwrap(workspace.focusedPanelId)
        let simulatorPanel = try XCTUnwrap(
            workspace.newSimulatorSurface(
                inPane: paneId,
                preferredUDID: "selected-simulator",
                focus: true
            )
        )

        let snapshot = workspace.sessionSnapshot(includeScrollback: false)

        guard case .pane(let pane) = snapshot.layout else {
            return XCTFail("Expected a single-pane snapshot")
        }
        XCTAssertFalse(pane.panelIds.contains(simulatorPanel.id))
        XCTAssertTrue(pane.panelIds.contains(initialPanelId))
        if let selectedPanelId = pane.selectedPanelId {
            XCTAssertTrue(pane.panelIds.contains(selectedPanelId))
        }
    }
}

final class SimulatorServiceUDIDTests: XCTestCase {
    func testUDIDMatchingNormalizesCase() {
        let canonical = "A73B3AF0-8C9F-4A8B-A89A-4F4E10AF6821"

        XCTAssertTrue(SimulatorService.udidsMatch(canonical, canonical.lowercased()))
        XCTAssertFalse(SimulatorService.udidsMatch(canonical, "B73B3AF0-8C9F-4A8B-A89A-4F4E10AF6821"))
    }
}

@MainActor
final class SimulatorListModelLifecycleTests: XCTestCase {
    func testHiddenViewDoesNotStartRefreshTimer() {
        let model = SimulatorListModel()

        model.setVisibleInUI(false)
        model.startAutoRefresh()

        XCTAssertFalse(model.isAutoRefreshTimerActiveForTesting)
        model.stopAutoRefresh()
    }

    func testVisibilityTransitionStopsRefreshTimer() {
        let model = SimulatorListModel()

        model.startAutoRefresh()
        XCTAssertTrue(model.isAutoRefreshTimerActiveForTesting)

        model.setVisibleInUI(false)

        XCTAssertFalse(model.isAutoRefreshTimerActiveForTesting)
        model.stopAutoRefresh()
    }
}
