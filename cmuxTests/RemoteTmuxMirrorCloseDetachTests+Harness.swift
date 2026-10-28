import AppKit
import CmuxSettings
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension RemoteTmuxMirrorCloseDetachTests {
    @MainActor
    struct Harness {
        let appDelegate: AppDelegate
        let windowId: UUID
        let manager: TabManager
        let workspace: Workspace
        private let restoreChiefSetting: () -> Void
        var controller: RemoteTmuxController { appDelegate.remoteTmuxController }

        init() throws {
            let defaults = UserDefaults.standard
            let chiefEnabledKey = ChiefCatalogSection().enabled.userDefaultsKey
            let originalChiefEnabled = defaults.object(forKey: chiefEnabledKey)
            let restoreChiefSetting = {
                if let originalChiefEnabled {
                    defaults.set(originalChiefEnabled, forKey: chiefEnabledKey)
                } else {
                    defaults.removeObject(forKey: chiefEnabledKey)
                }
            }
            self.restoreChiefSetting = restoreChiefSetting
            // Closing the initial local workspace must leave only the mirror.
            // Home is deliberately persistent and is not part of this fixture.
            ChiefSettings.setEnabled(false, in: defaults)
            do {
                appDelegate = try #require(AppDelegate.shared)
                windowId = appDelegate.createMainWindow()
                manager = try #require(appDelegate.tabManagerFor(windowId: windowId))
                workspace = try #require(manager.selectedWorkspace)
            } catch {
                restoreChiefSetting()
                throw error
            }
        }

        func tearDown() {
            defer { restoreChiefSetting() }
            workspace.isRemoteTmuxMirror = false
            // Clear any marker so it can't leak into another serialized test.
            controller.consumeKillSessionsOnWindowClose(windowId: windowId)
            closeWindow(windowId)
        }

        func cacheConnection(host: RemoteTmuxHost, session: String) {
            controller.cacheConnection(RemoteTmuxControlConnection(host: host, sessionName: session))
        }

        func closeWindow(_ id: UUID) {
            let identifier = "cmux.main.\(id.uuidString)"
            if let manager = appDelegate.tabManagerFor(windowId: id) {
                manager.tabs.forEach { $0.teardownAllPanels() }
            }
            if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == identifier }) {
                appDelegate.suppressClosedWindowHistoryForTesting(windowId: id)
                window.close()
            }
            appDelegate.forgetRecoverableMainWindowRoute(windowId: id)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
    }
}
