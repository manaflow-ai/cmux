import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Workspace title bar settings")
struct WorkspaceTitlebarSettingsTests {
    @Test(arguments: [false, true], [false, true])
    func titlePreferenceDoesNotChangePresentationMode(showTitlebar: Bool, minimalMode: Bool) throws {
        try withDefaults { defaults in
            let client = UserDefaultsSettingsClient(defaults: defaults)
            let app = AppCatalogSection()
            client.set(showTitlebar, for: app.workspaceTitlebarVisibility)
            client.set(minimalMode ? .minimal : .standard, for: app.presentationMode)
            let settings = WorkspaceTitlebarSettings(defaults: defaults)
            #expect(settings.isHidden == (minimalMode || !showTitlebar))
            #expect(settings.isMinimalMode == minimalMode)
            #expect(client.value(for: app.workspaceTitlebarVisibility) == showTitlebar)
            client.set(.standard, for: app.presentationMode)
            #expect(WorkspaceTitlebarSettings(defaults: defaults).isHidden == !showTitlebar)
        }
    }

    @Test
    func settingsDefaultAndPersistence() async throws {
        let suite = "WorkspaceTitlebarSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(!WorkspaceTitlebarSettings(defaults: defaults).isHidden)
        let key = AppCatalogSection().workspaceTitlebarVisibility
        let store = UserDefaultsSettingsStore(defaults: defaults)
        await store.set(false, for: key)
        let reopenedDefaults = try #require(UserDefaults(suiteName: suite))
        let reopenedStore = UserDefaultsSettingsStore(defaults: reopenedDefaults)
        #expect(await reopenedStore.value(for: key) == false)
        #expect(WorkspaceTitlebarSettings(defaults: reopenedDefaults).isHidden)
        #expect(!WorkspacePresentationModeSettings.isMinimal(defaults: reopenedDefaults))
        await reopenedStore.set(true, for: key)
        #expect(!WorkspaceTitlebarSettings(defaults: defaults).isHidden)
    }

    @Test
    func configurationReloadAndRestartRestoreBothIndependentPreferences() throws {
        try withDefaults { defaults in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent("cmux.json")
            try #"{"app":{"showWorkspaceTitleBar":false,"minimalMode":false}}"#
                .write(to: file, atomically: true, encoding: .utf8)
            let store = settingsStore(file: file, defaults: defaults)
            #expect(WorkspaceTitlebarSettings(defaults: defaults).isHidden)
            #expect(!WorkspacePresentationModeSettings.isMinimal(defaults: defaults))

            try #"{"app":{"showWorkspaceTitleBar":true,"minimalMode":true}}"#
                .write(to: file, atomically: true, encoding: .utf8)
            store.reload()
            #expect(WorkspaceTitlebarSettings(defaults: defaults).isHidden)
            #expect(WorkspaceTitlebarSettings(defaults: defaults).showTitlebar)

            try #"{"app":{"showWorkspaceTitleBar":true,"minimalMode":false}}"#
                .write(to: file, atomically: true, encoding: .utf8)
            _ = settingsStore(file: file, defaults: defaults)
            #expect(!WorkspaceTitlebarSettings(defaults: defaults).isHidden)
            #expect(!WorkspacePresentationModeSettings.isMinimal(defaults: defaults))
        }
    }

    @Test
    func invalidConfigurationDoesNotHideTitlebar() throws {
        try withDefaults { defaults in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent("cmux.json")
            try #"{"app":{"showWorkspaceTitleBar":"false"}}"#
                .write(to: file, atomically: true, encoding: .utf8)
            _ = settingsStore(file: file, defaults: defaults)
            #expect(!WorkspaceTitlebarSettings(defaults: defaults).isHidden)
        }
    }

    @Test(arguments: ["app.showWorkspaceTitleBar", "hide workspace title", "folder title bar"])
    func searchFindsTitlebarSetting(query: String) {
        #expect(SettingsSearchIndex.entries(matching: query).contains {
            $0.id == SettingsSearchIndex.settingID(for: .app, idSuffix: "workspace-title-bar")
        })
    }

    private func settingsStore(file: URL, defaults: UserDefaults) -> CmuxSettingsFileStore {
        CmuxSettingsFileStore(
            primaryPath: file.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            userDefaults: defaults,
            startWatching: false,
            isUserDefaultsKeyForcedByProfile: { _ in false }
        )
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "WorkspaceTitlebarSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }
}
