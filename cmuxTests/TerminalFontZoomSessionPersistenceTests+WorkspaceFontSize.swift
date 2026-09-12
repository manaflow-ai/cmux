import Foundation
import Testing
import CmuxControlSocket
import CmuxFoundation
import CmuxRemoteSession
import CmuxSettings
import CmuxTerminalCore
@testable import CmuxTerminal

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension TerminalFontZoomSessionPersistenceTests {
    @Test("control workspace font size targets an inactive workspace through its window")
    func controlWorkspaceFontSizeTargetsInactiveWorkspaceWithoutSelectingIt() throws {
        let previousAppDelegate = AppDelegate.shared
        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let appDelegate = AppDelegate()
        let manager = TabManager()
        let windowID = UUID()
        AppDelegate.shared = appDelegate
        appDelegate.tabManager = manager
        TerminalController.shared.setActiveTabManager(manager)
        appDelegate.registerMainWindowContextForTesting(windowId: windowID, tabManager: manager)
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowID)
            appDelegate.forgetRecoverableMainWindowRoute(windowId: windowID)
            manager.tabs.forEach { $0.teardownAllPanels() }
            TerminalController.shared.setActiveTabManager(previousManager)
            AppDelegate.shared = previousAppDelegate
        }

        let selectedWorkspace = try #require(manager.selectedWorkspace)
        let inactiveWorkspace = try #require(manager.addTab(select: false))
        let inactivePanel = try #require(inactiveWorkspace.focusedTerminalPanel)
        let selectedWorkspaceID = try #require(manager.selectedTabId)
        let initialLineage = TerminalFontSizeLineage(basePoints: 11, isExplicitOverride: true)
        inactivePanel.surface.recordCurrentFontSizeLineage(initialLineage)

        let routing = ControlRoutingSelectors(
            hasWindowIDParam: true,
            windowID: windowID,
            groupID: nil,
            workspaceID: inactiveWorkspace.id,
            surfaceID: nil,
            paneID: nil
        )
        let result = TerminalController.shared.controlWorkspaceFontSize(
            routing: routing,
            action: .increase
        )

        guard case .accepted(let acceptedWorkspaceID) = result else {
            Issue.record("Expected the inactive workspace font-size request to be accepted, got \(result)")
            return
        }
        #expect(acceptedWorkspaceID == inactiveWorkspace.id)
        drainWorkspaceFontSizeChanges(appDelegate)

        #expect(
            inactivePanel.surface.fontSizeLineageSnapshot()?.basePoints
                == initialLineage.basePoints + 1
        )
        #expect(manager.selectedTabId == selectedWorkspaceID)
        #expect(selectedWorkspace.id == selectedWorkspaceID)
    }

    @Test("control workspace font size applies increase decrease and reset to a hibernated panel")
    func controlWorkspaceFontSizeChangesHibernatedPanel() throws {
        let previousAppDelegate = AppDelegate.shared
        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let appDelegate = AppDelegate()
        let manager = TabManager()
        let windowID = UUID()
        AppDelegate.shared = appDelegate
        appDelegate.tabManager = manager
        TerminalController.shared.setActiveTabManager(manager)
        appDelegate.registerMainWindowContextForTesting(windowId: windowID, tabManager: manager)
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowID)
            appDelegate.forgetRecoverableMainWindowRoute(windowId: windowID)
            manager.tabs.forEach { $0.teardownAllPanels() }
            TerminalController.shared.setActiveTabManager(previousManager)
            AppDelegate.shared = previousAppDelegate
        }

        let workspace = try #require(manager.selectedWorkspace)
        let panel = try #require(workspace.focusedTerminalPanel)
        let initialLineage = TerminalFontSizeLineage(basePoints: 11, isExplicitOverride: true)
        panel.surface.recordCurrentFontSizeLineage(initialLineage)
        let agent = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "font-size-hibernated-panel",
            workingDirectory: "/tmp",
            launchCommand: nil
        )
        try #require(panel.enterAgentHibernation(
            agent: agent,
            lastActivityAt: Date(timeIntervalSince1970: 0)
        ))
        #expect(panel.isAgentHibernated)
        #expect(!panel.surface.hasLiveSurface)

        let routing = ControlRoutingSelectors(
            hasWindowIDParam: true,
            windowID: windowID,
            groupID: nil,
            workspaceID: workspace.id,
            surfaceID: nil,
            paneID: nil
        )
        let increase = TerminalController.shared.controlWorkspaceFontSize(
            routing: routing,
            action: .increase
        )
        expectAccepted(increase, workspaceID: workspace.id)
        drainWorkspaceFontSizeChanges(appDelegate)
        #expect(
            panel.surface.fontSizeLineageSnapshot()?.basePoints
                == initialLineage.basePoints + 1
        )

        let decrease = TerminalController.shared.controlWorkspaceFontSize(
            routing: routing,
            action: .decrease
        )
        expectAccepted(decrease, workspaceID: workspace.id)
        drainWorkspaceFontSizeChanges(appDelegate)
        #expect(panel.surface.fontSizeLineageSnapshot()?.basePoints == initialLineage.basePoints)

        let reset = TerminalController.shared.controlWorkspaceFontSize(
            routing: routing,
            action: .reset
        )
        expectAccepted(reset, workspaceID: workspace.id)
        drainWorkspaceFontSizeChanges(appDelegate)
        let configuredRuntimePoints = Float32(
            GhosttyConfig.load(
                globalFontMagnificationPercent: GlobalFontMagnification.storedPercent
            ).fontSize
        )
        let configuredBasePoints = CmuxSurfaceConfigTemplate.baseFontSize(
            fromRuntimePoints: configuredRuntimePoints,
            percent: GlobalFontMagnification.storedPercent
        )
        let resetLineage = try #require(panel.surface.fontSizeLineageSnapshot())
        #expect(abs(resetLineage.basePoints - configuredBasePoints) < 0.001)
        #expect(!resetLineage.isExplicitOverride)
        #expect(panel.surface.sessionFontSizeOverrideBasePoints() == nil)
    }

    @Test("control workspace font size rejects a workspace owned by another explicit window")
    func controlWorkspaceFontSizeDoesNotMutateWrongWindowWorkspace() throws {
        let previousAppDelegate = AppDelegate.shared
        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let appDelegate = AppDelegate()
        let firstManager = TabManager()
        let secondManager = TabManager()
        AppDelegate.shared = appDelegate
        appDelegate.tabManager = firstManager
        TerminalController.shared.setActiveTabManager(firstManager)
        let firstWindowID = appDelegate.registerMainWindowContextForTesting(
            tabManager: firstManager
        )
        let secondWindowID = appDelegate.registerMainWindowContextForTesting(
            tabManager: secondManager
        )
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: secondWindowID)
            appDelegate.unregisterMainWindowContextForTesting(windowId: firstWindowID)
            appDelegate.forgetRecoverableMainWindowRoute(windowId: secondWindowID)
            appDelegate.forgetRecoverableMainWindowRoute(windowId: firstWindowID)
            firstManager.tabs.forEach { $0.teardownAllPanels() }
            secondManager.tabs.forEach { $0.teardownAllPanels() }
            TerminalController.shared.setActiveTabManager(previousManager)
            AppDelegate.shared = previousAppDelegate
        }

        let firstWorkspace = try #require(firstManager.selectedWorkspace)
        let secondWorkspace = try #require(secondManager.selectedWorkspace)
        let firstPanel = try #require(firstWorkspace.focusedTerminalPanel)
        let secondPanel = try #require(secondWorkspace.focusedTerminalPanel)
        let firstLineage = TerminalFontSizeLineage(basePoints: 9, isExplicitOverride: true)
        let secondLineage = TerminalFontSizeLineage(basePoints: 17, isExplicitOverride: true)
        firstPanel.surface.recordCurrentFontSizeLineage(firstLineage)
        secondPanel.surface.recordCurrentFontSizeLineage(secondLineage)
        let firstSelectedWorkspaceID = try #require(firstManager.selectedTabId)
        let secondSelectedWorkspaceID = try #require(secondManager.selectedTabId)

        let routing = ControlRoutingSelectors(
            hasWindowIDParam: true,
            windowID: firstWindowID,
            groupID: nil,
            workspaceID: secondWorkspace.id,
            surfaceID: nil,
            paneID: nil
        )
        let result = TerminalController.shared.controlWorkspaceFontSize(
            routing: routing,
            action: .increase
        )

        #expect(result == .notFound)
        drainWorkspaceFontSizeChanges(appDelegate)
        #expect(firstPanel.surface.fontSizeLineageSnapshot() == firstLineage)
        #expect(secondPanel.surface.fontSizeLineageSnapshot() == secondLineage)
        #expect(firstManager.selectedTabId == firstSelectedWorkspaceID)
        #expect(secondManager.selectedTabId == secondSelectedWorkspaceID)
    }

    private func expectAccepted(
        _ result: ControlWorkspaceFontSizeResolution,
        workspaceID: UUID
    ) {
        guard case .accepted(let acceptedWorkspaceID) = result else {
            Issue.record("Expected an accepted font-size request, got \(result)")
            return
        }
        #expect(acceptedWorkspaceID == workspaceID)
    }

    private func drainWorkspaceFontSizeChanges(_ appDelegate: AppDelegate) {
#if DEBUG
        appDelegate.drainAllPendingWorkspaceTerminalFontSizeChangesForVerification()
#endif
    }
}
