import Foundation
import CmuxCore
import CmuxSettings
import CmuxSettingsUI
import CmuxWorkspaces
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct TerminalSessionRestoreOptOutTests {
    @Test
    func disablingTerminalRestoreSkipsTerminalWorkspaces() async throws {
        let source = TabManager()
        let terminalWorkspace = try #require(source.selectedWorkspace)
        let browserWorkspace = source.addWorkspace(
            title: "Browser-only workspace",
            workingDirectory: "/tmp/cmux-browser-only",
            select: false
        )
        browserWorkspace.setCustomTitle("Browser-only workspace")
        let snapshot = source.sessionSnapshot(includeScrollback: false)
        let terminalWorkspaceId = try #require(snapshot.workspaces[0].workspaceId)
        var browserSnapshot = snapshot.workspaces[1]
        browserSnapshot.customTitle = browserWorkspace.customTitle
        browserSnapshot.currentDirectory = ""
        browserSnapshot.panels = []
        browserSnapshot.layout = .pane(
            SessionPaneLayoutSnapshot(panelIds: [], selectedPanelId: nil)
        )
        browserSnapshot.focusedPanelId = nil
        browserSnapshot.dock = nil

        var filteredInput = snapshot
        filteredInput.workspaces = [snapshot.workspaces[0], browserSnapshot]
        filteredInput.selectedWorkspaceIndex = 1

        let suiteName = "cmux.terminal-restore-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let notificationCenter = NotificationCenter()
        let settings = TerminalSessionRestoreSettings(
            defaults: defaults,
            notificationCenter: notificationCenter
        )
        var notificationCount = 0
        let observer = notificationCenter.addObserver(
            forName: TerminalSessionRestoreSettings.didChangeNotification,
            object: nil,
            queue: nil
        ) { _ in
            notificationCount += 1
        }
        defer {
            notificationCenter.removeObserver(observer)
            defaults.removePersistentDomain(forName: suiteName)
        }
        #expect(settings.isEnabled)
        let defaultsStore = UserDefaultsSettingsStore(defaults: defaults)
        let restoreKey = SettingCatalog().terminal.restoreTerminalSessions
        let restoreModel = DefaultsValueModel(store: defaultsStore, key: restoreKey)
        _ = restoreModel.set(false) {
            settings.notifyDidChange()
        }
        for _ in 0..<1_000 where notificationCount == 0 {
            await Task.yield()
        }
        #expect(!settings.isEnabled)
        #expect(notificationCount == 1)
        #expect(!settings.setEnabled(false))
        #expect(notificationCount == 1)

        let restored = TabManager()
        let policy = SessionTerminalRestorePolicy(settings: settings)
        restored.restoreSessionSnapshot(
            filteredInput,
            terminalRestorePolicy: policy
        )

        #expect(restored.tabs.count == 1)
        #expect(restored.tabs.first?.customTitle == "Browser-only workspace")
        #expect(!restored.tabs.contains { $0.id == terminalWorkspaceId })
        #expect(restored.tabs.first?.id != terminalWorkspace.id)
        #expect(settings.reset())
        #expect(settings.isEnabled)
        #expect(notificationCount == 2)
    }
}
