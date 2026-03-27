import XCTest
import AppKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// Behavioral regression tests for the focused-panel menu-state snapshot fields
// (focusedPanelIsAtPrompt, focusedPanelHasTerminal) introduced to prevent
// menu dismissal during terminal process churn.
//
// All tests run on the main actor because Workspace is an ObservableObject
// whose mutations must happen on the main thread.

@MainActor
final class FocusedPanelMenuStateTests: XCTestCase {

    // MARK: - Test 1: isAtPrompt follows shell-state changes on the focused panel

    func testFocusedPanelIsAtPromptFollowsShellStateChanges() {
        let workspace = Workspace()
        guard let panelId = workspace.focusedPanelId else {
            XCTFail("Expected a focused panel in a fresh workspace")
            return
        }

        // Initial state: no shell-state reported yet — should be false.
        XCTAssertFalse(
            workspace.focusedPanelIsAtPrompt,
            "Expected false before any shell state is reported"
        )

        // Drive the panel to a running state.
        workspace.updatePanelShellActivityState(panelId: panelId, state: .commandRunning)
        XCTAssertFalse(
            workspace.focusedPanelIsAtPrompt,
            "Expected false when focused panel is running a command"
        )

        // Drive the panel to prompt-idle.
        workspace.updatePanelShellActivityState(panelId: panelId, state: .promptIdle)
        XCTAssertTrue(
            workspace.focusedPanelIsAtPrompt,
            "Expected true when focused panel reaches promptIdle"
        )

        // Back to running.
        workspace.updatePanelShellActivityState(panelId: panelId, state: .commandRunning)
        XCTAssertFalse(
            workspace.focusedPanelIsAtPrompt,
            "Expected false after focused panel returns to commandRunning"
        )
    }

    // MARK: - Test 2: isAtPrompt updates on focus switch

    func testFocusedPanelIsAtPromptUpdatesOnFocusSwitch() {
        let workspace = Workspace()
        guard let panelA = workspace.focusedPanelId else {
            XCTFail("Expected a focused panel in a fresh workspace")
            return
        }
        guard let paneId = workspace.bonsplitController.focusedPaneId else {
            XCTFail("Expected a focused pane in a fresh workspace")
            return
        }

        // Create a second terminal panel in the same pane.
        guard let panelB = workspace.newTerminalSurface(inPane: paneId, focus: false) else {
            XCTFail("Expected newTerminalSurface to succeed")
            return
        }

        // Give panel A prompt-idle and panel B command-running.
        workspace.updatePanelShellActivityState(panelId: panelA, state: .promptIdle)
        workspace.updatePanelShellActivityState(panelId: panelB.id, state: .commandRunning)

        // Panel A is currently focused — snapshot should be true.
        XCTAssertEqual(
            workspace.focusedPanelId, panelA,
            "Expected panel A to still be focused"
        )
        XCTAssertTrue(
            workspace.focusedPanelIsAtPrompt,
            "Expected true while focused panel A is at prompt"
        )

        // Switch focus to panel B.
        workspace.focusPanel(panelB.id)

        XCTAssertEqual(
            workspace.focusedPanelId, panelB.id,
            "Expected panel B to be focused after focusPanel"
        )
        XCTAssertFalse(
            workspace.focusedPanelIsAtPrompt,
            "Expected false after switching focus to running panel B"
        )
    }

    // MARK: - Test 3: focusedPanelHasTerminal

    // Workspace always contains a TerminalPanel as its initial panel type, so
    // focusedPanelHasTerminal should be true after normal workspace creation
    // and should remain true when moving focus between terminal panels.
    // Switching to a non-terminal panel type (browser/markdown) is not
    // straightforwardly exercisable in a headless unit test because
    // BrowserPanel and MarkdownPanel require AppKit window infrastructure.
    // This test confirms the true case and documents the limitation.

    func testFocusedPanelHasTerminalIsTrueForTerminalWorkspace() {
        let workspace = Workspace()

        // After applyTabSelection fires during init, focusedPanelHasTerminal
        // should reflect that the focused panel is a TerminalPanel.
        XCTAssertTrue(
            workspace.focusedPanelHasTerminal,
            "Expected focusedPanelHasTerminal true when focused panel is a terminal"
        )
    }

    // MARK: - Test 4: Removal path regression

    func testSnapshotReflectsNewFocusedPanelAfterFocusedPanelIsRemoved() {
        let workspace = Workspace()
        guard let initialPanelId = workspace.focusedPanelId else {
            XCTFail("Expected a focused panel in a fresh workspace")
            return
        }
        guard let paneId = workspace.bonsplitController.focusedPaneId else {
            XCTFail("Expected a focused pane in a fresh workspace")
            return
        }

        // Create a second panel and mark it as at-prompt.
        guard let secondPanel = workspace.newTerminalSurface(inPane: paneId, focus: false) else {
            XCTFail("Expected newTerminalSurface to succeed")
            return
        }
        workspace.updatePanelShellActivityState(panelId: secondPanel.id, state: .promptIdle)

        // Initial panel is at commandRunning — it is focused.
        workspace.updatePanelShellActivityState(panelId: initialPanelId, state: .commandRunning)
        XCTAssertFalse(
            workspace.focusedPanelIsAtPrompt,
            "Expected false while focused initial panel is running"
        )

        // Close the focused panel (force:true bypasses any confirmation guard).
        // Workspace delegate will select the next available panel.
        let closed = workspace.closePanel(initialPanelId, force: true)
        XCTAssertTrue(closed, "Expected closePanel to succeed for the focused panel")

        // After removal the new focused panel is the second panel (promptIdle).
        XCTAssertTrue(
            workspace.focusedPanelIsAtPrompt,
            "Expected focusedPanelIsAtPrompt to reflect the new focused panel (promptIdle) after removal"
        )
        // The new focused panel is still a terminal.
        XCTAssertTrue(
            workspace.focusedPanelHasTerminal,
            "Expected focusedPanelHasTerminal true after panel removal"
        )
        // The removed panel's ID must not still be the focused panel.
        XCTAssertNotEqual(
            workspace.focusedPanelId, initialPanelId,
            "Expected focused panel to change after removing the previously focused panel"
        )
    }
}
