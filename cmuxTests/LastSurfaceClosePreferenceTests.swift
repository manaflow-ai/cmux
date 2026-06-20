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

            secondWorkspace.markTabCloseButtonClose(surfaceId: secondSurfaceId)
            #expect(secondWorkspace.closePanel(secondPanelId))
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

            secondWorkspace.markTabStripMiddleClickClose(surfaceId: secondSurfaceId)
            #expect(secondWorkspace.closePanel(secondPanelId))
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
        try run(TabManager(settings: settings))
    }
}
