import XCTest
@testable import cmux_DEV

/// Regression coverage for https://github.com/manaflow-ai/cmux/pull/8095:
/// selecting a NON-terminal tab (todo/markdown/simulator) in a pane that also
/// holds a terminal must hide the deselected terminal's window-level portal.
/// The terminal-focus layout follow-up only reconciles portal visibility when
/// the newly focused panel is itself a terminal, so without an explicit
/// reconcile on non-terminal selection the deselected terminal keeps floating
/// above the newly selected pane content (the "terminal glyphs over the
/// simulator pane" overlay).
@MainActor
final class WorkspaceNonTerminalTabSelectionPortalTests: XCTestCase {
    func testSelectingNonTerminalTabHidesDeselectedTerminalPortal() throws {
#if DEBUG
        let workspace = Workspace()
        let terminalPanelId = try XCTUnwrap(workspace.focusedPanelId)
        let terminalPanel = try XCTUnwrap(workspace.terminalPanel(for: terminalPanelId))
        let paneId = try XCTUnwrap(workspace.bonsplitController.focusedPaneId)

        // A non-terminal surface sharing the terminal's pane (the todo pane is
        // the flag-independent stand-in for every SwiftUI panel kind).
        let todoPanel = try XCTUnwrap(
            workspace.newWorkspaceTodoSurface(inPane: paneId, focus: false)
        )
        let todoTabId = try XCTUnwrap(workspace.surfaceIdFromPanelId(todoPanel.id))

        // The terminal starts as the selected, visible tab.
        terminalPanel.hostedView.setVisibleInUI(true)
        XCTAssertTrue(terminalPanel.hostedView.debugPortalVisibleInUI)

        // Select the non-terminal tab the way a tab click does.
        workspace.applyTabSelection(tabId: todoTabId, inPane: paneId)

        XCTAssertEqual(workspace.focusedPanelId, todoPanel.id)
        XCTAssertFalse(
            terminalPanel.hostedView.debugPortalVisibleInUI,
            "Deselected terminal's window portal must hide when a non-terminal tab is selected"
        )
#else
        throw XCTSkip("Debug-only regression test")
#endif
    }
}
