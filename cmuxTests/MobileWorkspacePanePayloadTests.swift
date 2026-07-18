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

    @Test func staleExpectedTerminalOrderRejectsBeforeMutatingRelativeDestination() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let previousAppDelegate = AppDelegate.shared
            let appDelegate = AppDelegate()
            let manager = TabManager()
            let windowID = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
            AppDelegate.shared = appDelegate
            defer {
                appDelegate.unregisterMainWindowContextForTesting(windowId: windowID)
                AppDelegate.shared = previousAppDelegate
            }

            let workspace = try #require(manager.selectedWorkspace)
            let firstTerminalID = try #require(workspace.focusedPanelId)
            let paneID = try #require(workspace.paneId(forPanelId: firstTerminalID))
            let secondTerminalID = try #require(
                workspace.newTerminalSurface(inPane: paneID, focus: false)?.id
            )
            let thirdTerminalID = try #require(
                workspace.newTerminalSurface(inPane: paneID, focus: false)?.id
            )
            let hostOrder = [firstTerminalID, secondTerminalID, thirdTerminalID]
            #expect(terminalOrder(in: workspace, paneID: paneID) == hostOrder)

            // The client saw A,C,B and asks to move A after C. If the host applies
            // index 1 to its newer A,B,C order, A lands after B instead.
            let staleExpectedOrder = [firstTerminalID, thirdTerminalID, secondTerminalID]
            let result = await TerminalController.shared.v2MobileTerminalReorder(params: [
                "window_id": windowID.uuidString,
                "workspace_id": workspace.id.uuidString,
                "pane_id": paneID.id.uuidString,
                "surface_id": firstTerminalID.uuidString,
                "index": 1,
                "expected_terminal_ids": staleExpectedOrder.map(\.uuidString),
            ])

            guard case let .err(code, _, _) = result else {
                Issue.record("Expected stale terminal order to fail before mutation")
                #expect(terminalOrder(in: workspace, paneID: paneID) == hostOrder)
                return
            }
            #expect(code == "stale_state")
            #expect(terminalOrder(in: workspace, paneID: paneID) == hostOrder)
        }
    }

    @Test func duplicateExpectedTerminalIDsRejectBeforeMutation() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let previousAppDelegate = AppDelegate.shared
            let appDelegate = AppDelegate()
            let manager = TabManager()
            let windowID = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
            AppDelegate.shared = appDelegate
            defer {
                appDelegate.unregisterMainWindowContextForTesting(windowId: windowID)
                AppDelegate.shared = previousAppDelegate
            }

            let workspace = try #require(manager.selectedWorkspace)
            let firstTerminalID = try #require(workspace.focusedPanelId)
            let paneID = try #require(workspace.paneId(forPanelId: firstTerminalID))
            let secondTerminalID = try #require(
                workspace.newTerminalSurface(inPane: paneID, focus: false)?.id
            )
            let hostOrder = [firstTerminalID, secondTerminalID]
            #expect(terminalOrder(in: workspace, paneID: paneID) == hostOrder)

            let result = await TerminalController.shared.v2MobileTerminalReorder(params: [
                "window_id": windowID.uuidString,
                "workspace_id": workspace.id.uuidString,
                "pane_id": paneID.id.uuidString,
                "surface_id": firstTerminalID.uuidString,
                "index": 1,
                "expected_terminal_ids": [
                    firstTerminalID.uuidString,
                    firstTerminalID.uuidString,
                ],
            ])

            guard case let .err(code, _, _) = result else {
                Issue.record("Expected duplicate terminal identities to be rejected")
                return
            }
            #expect(code == "invalid_params")
            #expect(terminalOrder(in: workspace, paneID: paneID) == hostOrder)
        }
    }

    private func terminalOrder(in workspace: Workspace, paneID: PaneID) -> [UUID] {
        workspace.bonsplitController.tabs(inPane: paneID).compactMap {
            guard let panelID = workspace.panelIdFromSurfaceId($0.id),
                  workspace.terminalPanel(for: panelID) != nil else {
                return nil
            }
            return panelID
        }
    }
}
