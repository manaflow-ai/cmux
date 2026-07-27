import Foundation
import Testing
import CmuxSettings

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct LastSurfaceClosePreferenceTests {
    private let closeWorkspaceOnLastSurfaceKey = "closeWorkspaceOnLastSurfaceShortcut"

    @Test
    func tabCloseButtonClosesWorkspaceWhenKeepWorkspaceOpenPreferenceIsDisabled() throws {
        try withManager(closeWorkspaceOnLastSurface: true) { manager in
            let firstWorkspace = manager.tabs[0]
            let secondWorkspace = manager.addWorkspace()
            manager.selectWorkspace(secondWorkspace)

            let secondPanelId = try #require(secondWorkspace.focusedPanelId)
            let secondSurfaceId = try #require(secondWorkspace.surfaceIdFromPanelId(secondPanelId))

            secondWorkspace.markTabCloseButtonClose(surfaceId: secondSurfaceId)
            #expect(secondWorkspace.closePanel(secondPanelId) == false)
            drainMainQueue()
            drainMainQueue()

            #expect(manager.tabs.map(\.id) == [firstWorkspace.id])
            #expect(manager.selectedTabId == firstWorkspace.id)
            #expect(secondWorkspace.panels[secondPanelId] == nil)
            #expect(secondWorkspace.panels.isEmpty)
        }
    }

    @Test
    func tabCloseButtonKeepsWorkspaceOpenWhenKeepWorkspaceOpenPreferenceIsEnabled() throws {
        try withManager(closeWorkspaceOnLastSurface: false) { manager in
            let firstWorkspace = manager.tabs[0]
            let secondWorkspace = manager.addWorkspace()
            manager.selectWorkspace(secondWorkspace)

            let secondPanelId = try #require(secondWorkspace.focusedPanelId)
            let secondSurfaceId = try #require(secondWorkspace.surfaceIdFromPanelId(secondPanelId))

            var didClose = false
            secondWorkspace.withClosedPanelHistorySuppressed {
                secondWorkspace.markTabCloseButtonClose(surfaceId: secondSurfaceId)
                didClose = secondWorkspace.closePanel(secondPanelId)
            }
            #expect(didClose)
            drainMainQueue()
            drainMainQueue()

            #expect(manager.tabs.map(\.id) == [firstWorkspace.id, secondWorkspace.id])
            #expect(manager.selectedTabId == secondWorkspace.id)
            #expect(secondWorkspace.panels[secondPanelId] == nil)
            #expect(secondWorkspace.panels.count == 1)
            #expect(secondWorkspace.focusedPanelId != secondPanelId)
        }
    }

    @Test
    func middleClickClosesWorkspaceWhenKeepWorkspaceOpenPreferenceIsDisabled() throws {
        try withManager(closeWorkspaceOnLastSurface: true) { manager in
            let firstWorkspace = manager.tabs[0]
            let secondWorkspace = manager.addWorkspace()
            manager.selectWorkspace(secondWorkspace)

            let secondPanelId = try #require(secondWorkspace.focusedPanelId)
            let secondSurfaceId = try #require(secondWorkspace.surfaceIdFromPanelId(secondPanelId))

            secondWorkspace.markTabStripMiddleClickClose(surfaceId: secondSurfaceId)
            #expect(secondWorkspace.closePanel(secondPanelId) == false)
            drainMainQueue()
            drainMainQueue()

            #expect(manager.tabs.map(\.id) == [firstWorkspace.id])
            #expect(manager.selectedTabId == firstWorkspace.id)
            #expect(secondWorkspace.panels[secondPanelId] == nil)
            #expect(secondWorkspace.panels.isEmpty)
        }
    }

    @Test
    func middleClickKeepsWorkspaceOpenWhenKeepWorkspaceOpenPreferenceIsEnabled() throws {
        try withManager(closeWorkspaceOnLastSurface: false) { manager in
            let firstWorkspace = manager.tabs[0]
            let secondWorkspace = manager.addWorkspace()
            manager.selectWorkspace(secondWorkspace)

            let secondPanelId = try #require(secondWorkspace.focusedPanelId)
            let secondSurfaceId = try #require(secondWorkspace.surfaceIdFromPanelId(secondPanelId))

            var didClose = false
            secondWorkspace.withClosedPanelHistorySuppressed {
                secondWorkspace.markTabStripMiddleClickClose(surfaceId: secondSurfaceId)
                didClose = secondWorkspace.closePanel(secondPanelId)
            }
            #expect(didClose)
            drainMainQueue()
            drainMainQueue()

            #expect(manager.tabs.map(\.id) == [firstWorkspace.id, secondWorkspace.id])
            #expect(manager.selectedTabId == secondWorkspace.id)
            #expect(secondWorkspace.panels[secondPanelId] == nil)
            #expect(secondWorkspace.panels.count == 1)
            #expect(secondWorkspace.focusedPanelId != secondPanelId)
        }
    }

    @Test
    func remoteTmuxWindowCloseClosesWorkspaceWhenKeepWorkspaceOpenPreferenceIsDisabled() throws {
        try withManager(closeWorkspaceOnLastSurface: true) { manager in
            let firstWorkspace = manager.tabs[0]
            let secondWorkspace = manager.addWorkspace()
            manager.selectWorkspace(secondWorkspace)

            let secondPanelId = try #require(secondWorkspace.focusedPanelId)
            let secondSurfaceId = try #require(secondWorkspace.surfaceIdFromPanelId(secondPanelId))

            #expect(secondWorkspace.markRemoteTmuxWorkspaceCloseAfterWindowCloseIfNeeded(
                surfaceId: secondSurfaceId,
                tabStripClose: true,
                tabCloseButton: true
            ))
            #expect(secondWorkspace.closePanel(secondPanelId, force: true))
            drainMainQueue()
            drainMainQueue()

            #expect(manager.tabs.map(\.id) == [firstWorkspace.id])
            #expect(manager.selectedTabId == firstWorkspace.id)
            #expect(secondWorkspace.panels[secondPanelId] == nil)
            #expect(secondWorkspace.panels.isEmpty)
        }
    }

    @Test
    func remoteTmuxWindowCloseKeepsWorkspaceOpenWhenKeepWorkspaceOpenPreferenceIsEnabled() throws {
        try withManager(closeWorkspaceOnLastSurface: false) { manager in
            let firstWorkspace = manager.tabs[0]
            let secondWorkspace = manager.addWorkspace()
            manager.selectWorkspace(secondWorkspace)

            let secondPanelId = try #require(secondWorkspace.focusedPanelId)
            let secondSurfaceId = try #require(secondWorkspace.surfaceIdFromPanelId(secondPanelId))

            secondWorkspace.isRemoteTmuxMirror = true
            #expect(!secondWorkspace.markRemoteTmuxWorkspaceCloseAfterWindowCloseIfNeeded(
                surfaceId: secondSurfaceId,
                tabStripClose: true,
                tabCloseButton: true
            ))
            #expect(secondWorkspace.closePanel(secondPanelId, force: true))
            drainMainQueue()
            drainMainQueue()

            #expect(manager.tabs.map(\.id) == [firstWorkspace.id, secondWorkspace.id])
            #expect(manager.selectedTabId == secondWorkspace.id)
            #expect(!secondWorkspace.isRemoteTmuxMirror)
            #expect(!secondWorkspace.handleRemoteTmuxSessionEndedKeepingWorkspaceOpenIfNeeded())
            #expect(secondWorkspace.panels[secondPanelId] == nil)
            #expect(secondWorkspace.panels.count == 1)
            #expect(secondWorkspace.focusedPanelId != secondPanelId)
        }
    }

    @Test
    func remoteTmuxSessionEndKeepsWorkspaceOpenWhenKeepWorkspaceOpenPreferenceIsEnabled() throws {
        try withManager(closeWorkspaceOnLastSurface: false) { manager in
            let firstWorkspace = manager.tabs[0]
            let secondWorkspace = manager.addWorkspace()
            manager.selectWorkspace(secondWorkspace)

            let secondPanelId = try #require(secondWorkspace.focusedPanelId)
            let secondSurfaceId = try #require(secondWorkspace.surfaceIdFromPanelId(secondPanelId))

            secondWorkspace.isRemoteTmuxMirror = true
            secondWorkspace.markTabCloseButtonClose(surfaceId: secondSurfaceId)
            #expect(!secondWorkspace.markRemoteTmuxWorkspaceCloseAfterWindowCloseIfNeeded(
                surfaceId: secondSurfaceId,
                tabStripClose: true,
                tabCloseButton: true
            ))
            #expect(secondWorkspace.handleRemoteTmuxSessionEndedKeepingWorkspaceOpenIfNeeded())
            drainMainQueue()
            drainMainQueue()

            #expect(manager.tabs.map(\.id) == [firstWorkspace.id, secondWorkspace.id])
            #expect(manager.selectedTabId == secondWorkspace.id)
            #expect(!secondWorkspace.isRemoteTmuxMirror)
            #expect(secondWorkspace.panels[secondPanelId] == nil)
            #expect(secondWorkspace.panels.count == 1)
            #expect(secondWorkspace.focusedPanelId != secondPanelId)
        }
    }

    @Test
    func remoteTmuxWindowCloseKeepsWorkspaceOpenImmediatelyForShortcut() throws {
        try withManager(closeWorkspaceOnLastSurface: false) { manager in
            let firstWorkspace = manager.tabs[0]
            let secondWorkspace = manager.addWorkspace()
            manager.selectWorkspace(secondWorkspace)

            let secondPanelId = try #require(secondWorkspace.focusedPanelId)
            let secondSurfaceId = try #require(secondWorkspace.surfaceIdFromPanelId(secondPanelId))

            secondWorkspace.isRemoteTmuxMirror = true
            secondWorkspace.markCloseHistoryEligible(panelId: secondPanelId)
            #expect(!secondWorkspace.markRemoteTmuxWorkspaceCloseAfterWindowCloseIfNeeded(
                surfaceId: secondSurfaceId,
                tabStripClose: false,
                tabCloseButton: false
            ))
            #expect(secondWorkspace.closePanel(secondPanelId, force: true))
            drainMainQueue()
            drainMainQueue()

            #expect(manager.tabs.map(\.id) == [firstWorkspace.id, secondWorkspace.id])
            #expect(manager.selectedTabId == secondWorkspace.id)
            #expect(!secondWorkspace.isRemoteTmuxMirror)
            #expect(!secondWorkspace.handleRemoteTmuxSessionEndedKeepingWorkspaceOpenIfNeeded())
            #expect(secondWorkspace.panels[secondPanelId] == nil)
            #expect(secondWorkspace.panels.count == 1)
            #expect(secondWorkspace.focusedPanelId != secondPanelId)
        }
    }

    @Test
    func remoteTmuxWindowCloseClearsKeepOpenMarkerWhenWorkspaceNoLongerEmpty() throws {
        try withManager(closeWorkspaceOnLastSurface: false) { manager in
            let secondWorkspace = manager.addWorkspace()
            manager.selectWorkspace(secondWorkspace)

            let closingPanelId = try #require(secondWorkspace.focusedPanelId)
            let closingSurfaceId = try #require(secondWorkspace.surfaceIdFromPanelId(closingPanelId))

            secondWorkspace.isRemoteTmuxMirror = true
            #expect(!secondWorkspace.markRemoteTmuxWorkspaceCloseAfterWindowCloseIfNeeded(
                surfaceId: closingSurfaceId,
                tabStripClose: true,
                tabCloseButton: true
            ))
            let remainingPanel = secondWorkspace.createReplacementTerminalPanel()
            #expect(secondWorkspace.closePanel(closingPanelId, force: true))
            drainMainQueue()
            drainMainQueue()

            #expect(secondWorkspace.panels[closingPanelId] == nil)
            #expect(secondWorkspace.panels[remainingPanel.id] != nil)
            #expect(secondWorkspace.panels.count == 1)
            #expect(secondWorkspace.isRemoteTmuxMirror)
            #expect(!secondWorkspace.handleRemoteTmuxSessionEndedKeepingWorkspaceOpenIfNeeded())
        }
    }

    @Test
    func remoteTmuxWindowCloseDoesNotPromptAgainAfterRemoteCloseCommitted() throws {
        try withManager(closeWorkspaceOnLastSurface: true) { manager in
            let firstWorkspace = manager.tabs[0]
            let secondWorkspace = manager.addWorkspace()
            manager.selectWorkspace(secondWorkspace)

            let secondPanelId = try #require(secondWorkspace.focusedPanelId)
            let secondSurfaceId = try #require(secondWorkspace.surfaceIdFromPanelId(secondPanelId))
            let catalog = AppCatalogSection()
            manager.closeTabWarningDefaults.set(true, forKey: catalog.warnBeforeClosingTabXButton.userDefaultsKey)
            var confirmationCount = 0
            manager.confirmCloseHandler = { _, _, _ in
                confirmationCount += 1
                return false
            }

            secondWorkspace.isRemoteTmuxMirror = true
            #expect(secondWorkspace.markRemoteTmuxWorkspaceCloseAfterWindowCloseIfNeeded(
                surfaceId: secondSurfaceId,
                tabStripClose: true,
                tabCloseButton: true
            ))
            #expect(secondWorkspace.closePanel(secondPanelId, force: true))
            drainMainQueue()
            drainMainQueue()

            #expect(confirmationCount == 0)
            #expect(manager.tabs.map(\.id) == [firstWorkspace.id])
            #expect(manager.selectedTabId == firstWorkspace.id)
            #expect(!secondWorkspace.isRemoteTmuxMirror)
            #expect(!secondWorkspace.handleRemoteTmuxSessionEndedKeepingWorkspaceOpenIfNeeded())
            #expect(secondWorkspace.panels[secondPanelId] == nil)
            #expect(secondWorkspace.panels.isEmpty)
        }
    }

    @Test
    func remoteTmuxWindowCloseCreatesReplacementWhenOnlyMainWindowWouldBeEmpty() throws {
        try withManager(closeWorkspaceOnLastSurface: true) { manager in
            let workspace = try #require(manager.selectedWorkspace)
            let panelId = try #require(workspace.focusedPanelId)
            let surfaceId = try #require(workspace.surfaceIdFromPanelId(panelId))

            workspace.isRemoteTmuxMirror = true
            #expect(workspace.markRemoteTmuxWorkspaceCloseAfterWindowCloseIfNeeded(
                surfaceId: surfaceId,
                tabStripClose: true,
                tabCloseButton: true,
                explicitUserClose: true
            ))
            #expect(workspace.closePanel(panelId, force: true))
            drainMainQueue()
            drainMainQueue()

            #expect(manager.tabs.map(\.id) == [workspace.id])
            #expect(workspace.panels[panelId] == nil)
            #expect(!workspace.isRemoteTmuxMirror)
            #expect(workspace.panels.count == 1)
            #expect(workspace.focusedPanelId != panelId)
            #expect(!workspace.handleRemoteTmuxSessionEndedKeepingWorkspaceOpenIfNeeded())
        }
    }

    private func withManager(
        closeWorkspaceOnLastSurface: Bool,
        run: (TabManager) throws -> Void
    ) throws {
        let suiteName = "LastSurfaceClosePreferenceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(closeWorkspaceOnLastSurface, forKey: closeWorkspaceOnLastSurfaceKey)
        let settings = UserDefaultsSettingsClient(defaults: defaults)
        let catalog = AppCatalogSection()
        ClosedItemHistoryStore.shared.removeAll()
        defaults.set(false, forKey: catalog.warnBeforeClosingTab.userDefaultsKey)
        defaults.set(false, forKey: catalog.warnBeforeClosingTabXButton.userDefaultsKey)
        defer {
            ClosedItemHistoryStore.shared.removeAll()
        }
        try run(TabManager(settings: settings, closeTabWarningDefaults: defaults))
    }
}
