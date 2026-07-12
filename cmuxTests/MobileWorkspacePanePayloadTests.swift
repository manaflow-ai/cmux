import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Covers the pane membership projected into the iOS workspace payload.
@MainActor
@Suite(.serialized)
struct MobileWorkspacePanePayloadTests {
    @Test func groupsOnlyTerminalIDsInPaneOrder() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let paneID = try #require(workspace.bonsplitController.focusedPaneId)
        let firstTerminalID = try #require(workspace.focusedPanelId)
        let secondTerminal = try #require(workspace.newTerminalSurface(inPane: paneID, focus: false))
        let terminalIDs = [firstTerminalID, secondTerminal.id]
        let browser = try #require(workspace.newBrowserSurface(
            inPane: paneID,
            focus: false,
            creationPolicy: .restoration
        ))

        let payload = TerminalController.shared.mobileWorkspacePayload(
            workspace: workspace,
            isSelected: true,
            requestedTerminalID: nil
        )
        let panes = try #require(payload["panes"] as? [[String: Any]])
        let pane = try #require(panes.first(where: { $0["id"] as? String == paneID.id.uuidString }))
        #expect(pane["terminal_ids"] as? [String] == terminalIDs.map(\.uuidString))
        #expect(!(pane["terminal_ids"] as? [String] ?? []).contains(browser.id.uuidString))

        let terminals = try #require(payload["terminals"] as? [[String: Any]])
        #expect(terminals.count == terminalIDs.count)
        #expect(terminals.allSatisfy { $0["pane_id"] as? String == paneID.id.uuidString })
    }

    @Test func backgroundTerminalReorderPreservesMacPaneAndTabFocus() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let focusedPanelID = try #require(workspace.focusedPanelId)
        let focusedPaneID = try #require(workspace.paneId(forPanelId: focusedPanelID))
        let backgroundTerminal = try #require(workspace.newTerminalSplit(
            from: focusedPanelID,
            orientation: .horizontal,
            focus: false
        ))
        let backgroundPaneID = try #require(workspace.paneId(forPanelId: backgroundTerminal.id))
        let secondBackgroundTerminal = try #require(workspace.newTerminalSurface(
            inPane: backgroundPaneID,
            focus: false
        ))
        let selectedBackgroundTab = workspace.bonsplitController.selectedTab(inPane: backgroundPaneID)?.id

        #expect(workspace.reorderSurface(
            panelId: secondBackgroundTerminal.id,
            toIndex: 0,
            focus: false
        ))

        #expect(workspace.bonsplitController.focusedPaneId == focusedPaneID)
        #expect(workspace.bonsplitController.selectedTab(inPane: backgroundPaneID)?.id == selectedBackgroundTab)
        #expect(workspace.focusedPanelId == focusedPanelID)
    }
}
