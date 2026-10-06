import Foundation
import Testing

import CmuxSettings

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

private final class ClassicConfigWatcherSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func record() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

@Suite("Classic cmux.json catalog coverage", .serialized)
struct ClassicConfigCatalogCoverageTests {
    @MainActor
    @Test
    func watcherReloadsNewCatalogSectionsAndScalars() async throws {
        let suiteName = "cmux-classic-config-coverage-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-classic-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settingsURL = directory.appendingPathComponent("cmux.json")

        try write(
            """
            {
              "account": { "piiDisplayMode": "hidden" },
              "devices": {
                "discovery": { "enabled": true },
                "incomingAccess": { "enabled": true },
                "sidebar": { "hiddenMacIDs": ["mac-a", "mac-b"] }
              },
              "app": {
                "fileDropDefaultBehavior": "preview",
                "titlebarControlsStyle": 2,
                "workspaceButtonFade": "enabled",
                "workspaceTitlebarVisibility": false,
                "systemWideHotkeyEnabled": true
              },
              "browser": { "disabled": true, "importHintVariant": "floatingCard" },
              "mobile": {
                "phonePush": {
                  "forwardingEnabled": false,
                  "mode": "onlyWhenAway",
                  "hideContent": true
                },
                "iOSPairingHost": {
                  "enabled": true,
                  "port": 58466,
                  "displayName": "Build Mac"
                }
              },
              "sidebarAppearance": {
                "blurOpacity": 0.5,
                "cornerRadius": 12,
                "preset": "custom",
                "material": "titlebar",
                "blendMode": "behindWindow",
                "state": "active"
              },
              "workspaceGroups": { "anchorCloseSuppressed": true }
            }
            """,
            to: settingsURL
        )

        let signal = ClassicConfigWatcherSignal()
        let store = CmuxSettingsFileStore(
            primaryPath: settingsURL.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            userDefaults: defaults,
            startWatching: true,
            onWatchedFileReload: { _ in signal.record() }
        )

        #expect(defaults.string(forKey: "cmux.settings.piiDisplayMode") == "hidden")
        #expect(defaults.bool(forKey: "devices.discovery.enabled"))
        #expect(defaults.bool(forKey: "devices.incomingAccess.enabled"))
        #expect(defaults.array(forKey: "devices.sidebar.hiddenMacIDs") as? [String] == ["mac-a", "mac-b"])
        #expect(defaults.string(forKey: "fileDrop.defaultBehavior") == "preview")
        #expect(defaults.integer(forKey: "titlebarControlsStyle") == 2)
        #expect(defaults.string(forKey: "workspaceButtonsFadeMode") == "enabled")
        #expect(defaults.bool(forKey: "workspaceTitlebarVisible") == false)
        #expect(defaults.bool(forKey: "systemWideHotkey.enabled"))
        #expect(defaults.bool(forKey: "browserDisabledOverride"))
        #expect(defaults.string(forKey: "browserImportHintVariant") == "floatingCard")
        #expect(defaults.bool(forKey: "forwardNotificationsToPhone") == false)
        #expect(defaults.string(forKey: "forwardNotificationsToPhoneMode") == "onlyWhenAway")
        #expect(defaults.bool(forKey: "forwardNotificationsHideContent"))
        #expect(defaults.bool(forKey: "mobile.iOSPairingHost.enabled"))
        #expect(defaults.integer(forKey: "mobile.iOSPairingHost.port") == 58466)
        #expect(defaults.string(forKey: "mobile.iOSPairingHost.displayName") == "Build Mac")
        #expect(defaults.double(forKey: "sidebarBlurOpacity") == 0.5)
        #expect(defaults.double(forKey: "sidebarCornerRadius") == 12)
        #expect(defaults.string(forKey: "sidebarPreset") == "custom")
        #expect(defaults.string(forKey: "sidebarMaterial") == "titlebar")
        #expect(defaults.string(forKey: "sidebarBlendMode") == "behindWindow")
        #expect(defaults.string(forKey: "sidebarState") == "active")
        #expect(defaults.bool(forKey: "workspaceGroup.anchorCloseSuppressed"))

        try write(
            """
            {
              "account": { "piiDisplayMode": "visible" },
              "devices": {
                "discovery": { "enabled": false },
                "incomingAccess": { "enabled": false },
                "sidebar": { "hiddenMacIDs": ["mac-c"] }
              },
              "app": {
                "fileDropDefaultBehavior": "text",
                "titlebarControlsStyle": 1,
                "workspaceButtonFade": "disabled",
                "workspaceTitlebarVisibility": true,
                "systemWideHotkeyEnabled": false
              },
              "browser": { "disabled": false, "importHintVariant": "toolbarChip" },
              "mobile": {
                "phonePush": {
                  "forwardingEnabled": true,
                  "mode": "always",
                  "hideContent": false
                },
                "iOSPairingHost": {
                  "enabled": false,
                  "port": 58467,
                  "displayName": ""
                }
              },
              "sidebarAppearance": {
                "blurOpacity": 1,
                "cornerRadius": 0,
                "preset": "nativeSidebar",
                "material": "sidebar",
                "blendMode": "withinWindow",
                "state": "followsWindowActiveState"
              },
              "workspaceGroups": { "anchorCloseSuppressed": false }
            }
            """,
            to: settingsURL
        )

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while clock.now < deadline {
            if signal.count > 0,
               defaults.string(forKey: "cmux.settings.piiDisplayMode") == "visible",
               defaults.array(forKey: "devices.sidebar.hiddenMacIDs") as? [String] == ["mac-c"] {
                break
            }
            try await clock.sleep(for: .milliseconds(50))
        }

        #expect(signal.count > 0)
        #expect(defaults.string(forKey: "cmux.settings.piiDisplayMode") == "visible")
        #expect(defaults.bool(forKey: "devices.discovery.enabled") == false)
        #expect(defaults.array(forKey: "devices.sidebar.hiddenMacIDs") as? [String] == ["mac-c"])
        #expect(defaults.string(forKey: "fileDrop.defaultBehavior") == "text")
        #expect(defaults.bool(forKey: "browserDisabledOverride") == false)
        #expect(defaults.string(forKey: "browserImportHintVariant") == "toolbarChip")
        #expect(defaults.bool(forKey: "mobile.iOSPairingHost.enabled") == false)
        #expect(defaults.integer(forKey: "mobile.iOSPairingHost.port") == 58467)
        #expect(defaults.string(forKey: "mobile.iOSPairingHost.displayName") == "")
        #expect(defaults.double(forKey: "sidebarBlurOpacity") == 1)
        #expect(defaults.object(forKey: "sidebarCornerRadius") != nil)
        #expect(defaults.double(forKey: "sidebarCornerRadius") == 0)
        #expect(defaults.string(forKey: "sidebarPreset") == "nativeSidebar")
        #expect(defaults.string(forKey: "sidebarMaterial") == "sidebar")
        #expect(defaults.string(forKey: "sidebarBlendMode") == "withinWindow")
        #expect(defaults.string(forKey: "sidebarState") == "followsWindowActiveState")
        #expect(defaults.object(forKey: "workspaceGroup.anchorCloseSuppressed") != nil)
        #expect(defaults.bool(forKey: "workspaceGroup.anchorCloseSuppressed") == false)

        withExtendedLifetime(store) {}
    }

    private func write(_ contents: String, to url: URL) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
}
