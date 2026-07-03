import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class WorkspaceForkConversationContextMenuTests: XCTestCase {
    func testPanelContextMenuActionUsesClickedPanel() throws {
        let workspace = Workspace()
        let sourcePanelId = try XCTUnwrap(workspace.focusedPanelId)
        let sourcePaneId = try XCTUnwrap(workspace.paneId(forPanelId: sourcePanelId))
        workspace.setRestoredAgentSnapshotForTesting(makeForkableClaudeSnapshot(), panelId: sourcePanelId)
        let otherPanel = try XCTUnwrap(workspace.newTerminalSurfaceInFocusedPane(focus: true))
        XCTAssertEqual(workspace.focusedPanelId, otherPanel.id)

        XCTAssertTrue(
            workspace.forkAgentConversationFromContextMenu(
                fromPanelId: sourcePanelId,
                destination: .newTab
            )
        )

        XCTAssertEqual(
            workspace.bonsplitController.tabs(inPane: sourcePaneId).count,
            3,
            "Fork Conversation from the terminal context menu should fork the clicked panel"
        )
        XCTAssertEqual(
            workspace.bonsplitController.allPaneIds.count,
            1,
            "New Tab destination should stay in the clicked panel's pane"
        )
    }

    private func makeForkableClaudeSnapshot(
        sessionId: String = "019dad34-d218-7943-b81a-eddac5c87951",
        workingDirectory: String = "/tmp/fork repo"
    ) -> SessionRestorableAgentSnapshot {
        SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: sessionId,
            workingDirectory: workingDirectory,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "claude",
                executablePath: "/opt/homebrew/bin/claude",
                arguments: ["/opt/homebrew/bin/claude"],
                workingDirectory: workingDirectory,
                environment: nil,
                capturedAt: 123,
                source: "process"
            )
        )
    }
}
