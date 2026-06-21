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
            #expect(secondWorkspace.panels[secondPanelId] == nil)
            #expect(secondWorkspace.panels.count == 1)
            #expect(secondWorkspace.focusedPanelId != secondPanelId)
        }
    }

    @Test
    func remoteTmuxWindowCloseCreatesReplacementWhenWorkspaceCloseIsCanceled() throws {
        try withManager(closeWorkspaceOnLastSurface: true) { manager in
            let firstWorkspace = manager.tabs[0]
            let secondWorkspace = manager.addWorkspace()
            manager.selectWorkspace(secondWorkspace)

            let secondPanelId = try #require(secondWorkspace.focusedPanelId)
            let secondSurfaceId = try #require(secondWorkspace.surfaceIdFromPanelId(secondPanelId))
            let catalog = AppCatalogSection()
            UserDefaults.standard.set(true, forKey: catalog.warnBeforeClosingTabXButton.userDefaultsKey)
            manager.confirmCloseHandler = { _, _, _ in false }

            #expect(secondWorkspace.markRemoteTmuxWorkspaceCloseAfterWindowCloseIfNeeded(
                surfaceId: secondSurfaceId,
                tabStripClose: true,
                tabCloseButton: true
            ))
            #expect(secondWorkspace.closePanel(secondPanelId, force: true))
            drainMainQueue()
            drainMainQueue()

            #expect(manager.tabs.map(\.id) == [firstWorkspace.id, secondWorkspace.id])
            #expect(manager.selectedTabId == secondWorkspace.id)
            #expect(secondWorkspace.panels[secondPanelId] == nil)
            #expect(secondWorkspace.panels.count == 1)
            #expect(secondWorkspace.focusedPanelId != secondPanelId)
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
        let warningDefaults = UserDefaults.standard
        let catalog = AppCatalogSection()
        let originalWarnBeforeClosingTab = warningDefaults.object(
            forKey: catalog.warnBeforeClosingTab.userDefaultsKey
        )
        let originalWarnBeforeClosingTabXButton = warningDefaults.object(
            forKey: catalog.warnBeforeClosingTabXButton.userDefaultsKey
        )
        ClosedItemHistoryStore.shared.removeAll()
        warningDefaults.set(false, forKey: catalog.warnBeforeClosingTab.userDefaultsKey)
        warningDefaults.set(false, forKey: catalog.warnBeforeClosingTabXButton.userDefaultsKey)
        defer {
            restore(originalWarnBeforeClosingTab, forKey: catalog.warnBeforeClosingTab.userDefaultsKey)
            restore(originalWarnBeforeClosingTabXButton, forKey: catalog.warnBeforeClosingTabXButton.userDefaultsKey)
            ClosedItemHistoryStore.shared.removeAll()
        }
        try run(TabManager(settings: settings))
    }

    private func restore(_ value: Any?, forKey key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
