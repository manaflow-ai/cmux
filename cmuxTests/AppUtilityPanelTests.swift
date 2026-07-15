import CmuxWorkspaces
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite
struct AppUtilityPanelTests {
    @Test func initialSettingsTargetDoesNotScheduleACompetingNavigationPost() {
        let panel = AppUtilityPanel(
            workspaceId: UUID(),
            kind: .settings,
            settingsNavigationTarget: .keyboardShortcuts
        )

        #expect(panel.settingsNavigationTarget == .keyboardShortcuts)
        #expect(panel.settingsNavigationRevision == 0)

        panel.requestSettingsNavigation(.browserImport)

        #expect(panel.settingsNavigationTarget == .browserImport)
        #expect(panel.settingsNavigationRevision == 1)
    }

    @Test func openOrFocusAppUtilityPaneCreatesRightSplitAndReusesExistingKind() throws {
        let workspace = Workspace()
        let paneId = try #require(workspace.bonsplitController.focusedPaneId)
        let originalPanelId = try #require(workspace.focusedPanelId)

        let firstPanel = try #require(workspace.openOrFocusAppUtilityPane(
            fromPane: paneId,
            kind: .settings,
            focus: true
        ))
        let utilityPaneId = try #require(workspace.paneId(forPanelId: firstPanel.id))
        let secondPanel = try #require(workspace.openOrFocusAppUtilityPane(
            fromPane: paneId,
            kind: .settings,
            focus: true
        ))

        #expect(firstPanel.id == secondPanel.id)
        #expect(utilityPaneId != paneId)
        #expect(workspace.paneId(forPanelId: originalPanelId) == paneId)
        #expect(workspace.bonsplitController.adjacentPane(to: paneId, direction: .right) == utilityPaneId)
        #expect(workspace.bonsplitController.tabs(inPane: utilityPaneId).count == 1)
        #expect(workspace.bonsplitController.allPaneIds.count == 2)
        #expect(
            workspace.panels.values.compactMap { $0 as? AppUtilityPanel }.filter { $0.kind == .settings }.count == 1
        )
        #expect(workspace.focusedPanelId == firstPanel.id)
        #expect(
            workspace.surfaceIdFromPanelId(firstPanel.id).flatMap { workspace.bonsplitController.tab($0)?.kind }
                == SurfaceKind.appUtility.rawValue
        )
    }

    @Test func appUtilityKindsCreateIndependentPanes() throws {
        let workspace = Workspace()
        let paneId = try #require(workspace.bonsplitController.focusedPaneId)
        let originalFocusedPanelId = try #require(workspace.focusedPanelId)

        let settingsPanel = try #require(workspace.openOrFocusAppUtilityPane(
            fromPane: paneId,
            kind: .settings,
            focus: false
        ))
        let mobilePanel = try #require(workspace.openOrFocusAppUtilityPane(
            fromPane: paneId,
            kind: .mobilePairing,
            focus: false
        ))

        #expect(settingsPanel.id != mobilePanel.id)
        #expect(workspace.paneId(forPanelId: settingsPanel.id) != workspace.paneId(forPanelId: mobilePanel.id))
        #expect(workspace.bonsplitController.allPaneIds.count == 3)
        #expect(settingsPanel.displayTitle == "Settings")
        #expect(mobilePanel.displayTitle == "Pair iPhone")
        #expect(workspace.focusedPanelId == originalFocusedPanelId)
    }

    @Test func selectingAppUtilityTabHidesTerminalPortalInSamePane() throws {
        let workspace = Workspace()
        let terminalPaneId = try #require(workspace.bonsplitController.focusedPaneId)
        let terminalPanelId = try #require(workspace.focusedPanelId)
        let terminalPanel = try #require(workspace.panels[terminalPanelId] as? TerminalPanel)
        terminalPanel.hostedView.setVisibleInUI(true)

        let utilityPanel = try #require(workspace.openOrFocusAppUtilityPane(
            fromPane: terminalPaneId,
            kind: .mobilePairing,
            focus: false
        ))
        let utilityTabId = try #require(workspace.surfaceIdFromPanelId(utilityPanel.id))

        #expect(workspace.bonsplitController.moveTab(utilityTabId, toPane: terminalPaneId))
        workspace.focusPanel(utilityPanel.id)

        #expect(workspace.bonsplitController.selectedTab(inPane: terminalPaneId)?.id == utilityTabId)
        #expect(!terminalPanel.hostedView.debugPortalVisibleInUI)
    }
}
