import AppKit
import Bonsplit
import CmuxWorkspaces
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite
struct AppUtilityPanelTests {
    private final class SplitRequestRecorder: BonsplitDelegate {
        var splitRequestCount = 0

        func splitTabBar(
            _ controller: BonsplitController,
            shouldSplitPane pane: PaneID,
            orientation: SplitOrientation
        ) -> Bool {
            splitRequestCount += 1
            return false
        }
    }

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

    @Test func remoteTmuxMirrorDoesNotRequestSplitForAppUtilityPane() throws {
        let workspace = Workspace()
        let paneId = try #require(workspace.bonsplitController.focusedPaneId)
        let panelsBefore = workspace.panels.count
        let recorder = SplitRequestRecorder()
        workspace.isRemoteTmuxMirror = true
        workspace.bonsplitController.delegate = recorder

        let panel = workspace.openOrFocusAppUtilityPane(
            fromPane: paneId,
            kind: .settings,
            focus: true
        )

        #expect(panel == nil)
        #expect(recorder.splitRequestCount == 0)
        #expect(workspace.panels.count == panelsBefore)
        #expect(workspace.bonsplitController.allPaneIds.count == 1)
    }

    @Test func appUtilityOpenUsesExistingLocalWorkspaceWhenRemoteMirrorIsSelected() throws {
        let appDelegate = AppDelegate()
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        let remoteWorkspace = try #require(tabManager.selectedWorkspace)
        remoteWorkspace.isRemoteTmuxMirror = true
        let localWorkspace = tabManager.addWorkspace(
            inheritWorkingDirectory: false,
            select: false,
            autoWelcomeIfNeeded: false
        )

        let didOpen = appDelegate.openMobilePairingPane(
            debugSource: "test.existingLocalFallback",
            tabManager: tabManager
        )

        #expect(didOpen)
        #expect(tabManager.tabs.count == 2)
        #expect(tabManager.selectedWorkspace === localWorkspace)
        #expect(remoteWorkspace.panels.values.allSatisfy { !($0 is AppUtilityPanel) })
        #expect(localWorkspace.panels.values.contains { ($0 as? AppUtilityPanel)?.kind == .mobilePairing })
    }

    @Test func appUtilityOpenCreatesLocalWorkspaceWhenOnlyRemoteMirrorsExist() throws {
        let appDelegate = AppDelegate()
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        let remoteWorkspace = try #require(tabManager.selectedWorkspace)
        remoteWorkspace.isRemoteTmuxMirror = true

        let didOpen = appDelegate.openMobilePairingPane(
            debugSource: "test.newLocalFallback",
            tabManager: tabManager
        )

        let localWorkspace = try #require(tabManager.selectedWorkspace)
        #expect(didOpen)
        #expect(tabManager.tabs.count == 2)
        #expect(!localWorkspace.isRemoteTmuxMirror)
        #expect(localWorkspace !== remoteWorkspace)
        #expect(remoteWorkspace.panels.values.allSatisfy { !($0 is AppUtilityPanel) })
        #expect(localWorkspace.panels.values.contains { ($0 as? AppUtilityPanel)?.kind == .mobilePairing })
    }

    @Test func nonActivatingUtilityPresentationOrdersAndDeminiaturizesWithoutMakingKey() {
        let appDelegate = AppDelegate()
        let window = AppUtilityPresentationTestWindow()
        window.simulatesMiniaturized = true

        appDelegate.presentAppUtilityHostWindow(window, activateApplication: false)

        #expect(window.deminiaturizeCallCount == 1)
        #expect(window.orderFrontCallCount == 1)
        #expect(window.makeKeyAndOrderFrontCallCount == 0)
        #expect(window.makeKeyCallCount == 0)
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

    @Test func selectingAppUtilityPaneDoesNotReconcilePortalInAnotherPane() throws {
        let workspace = Workspace()
        let terminalPaneId = try #require(workspace.bonsplitController.focusedPaneId)
        let terminalPanelId = try #require(workspace.focusedPanelId)
        let terminalPanel = try #require(workspace.panels[terminalPanelId] as? TerminalPanel)
        let utilityPanel = try #require(workspace.openOrFocusAppUtilityPane(
            fromPane: terminalPaneId,
            kind: .mobilePairing,
            focus: false
        ))

        terminalPanel.hostedView.setVisibleInUI(false)
        workspace.focusPanel(utilityPanel.id)

        #expect(!terminalPanel.hostedView.debugPortalVisibleInUI)
    }
}

@MainActor
private final class AppUtilityPresentationTestWindow: NSWindow {
    var simulatesMiniaturized = false
    private(set) var deminiaturizeCallCount = 0
    private(set) var orderFrontCallCount = 0
    private(set) var makeKeyAndOrderFrontCallCount = 0
    private(set) var makeKeyCallCount = 0

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
    }

    override var isMiniaturized: Bool { simulatesMiniaturized }

    override func deminiaturize(_ sender: Any?) {
        deminiaturizeCallCount += 1
        simulatesMiniaturized = false
    }

    override func orderFront(_ sender: Any?) {
        orderFrontCallCount += 1
    }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        makeKeyAndOrderFrontCallCount += 1
    }

    override func makeKey() {
        makeKeyCallCount += 1
    }
}
