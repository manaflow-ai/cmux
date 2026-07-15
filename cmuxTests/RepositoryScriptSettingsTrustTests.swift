import AppKit
import CmuxSettings
import CmuxSettingsUI
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct RepositoryScriptSettingsTrustTests {
    @MainActor
    @Test func projectScriptsBecomePrivateOverridesOnlyAfterExplicitImport() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-repository-script-settings-trust-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(".git"),
                withIntermediateDirectories: true
            )
            let projectConfigURL = root.appendingPathComponent(".cmux/cmux.json")
            try FileManager.default.createDirectory(
                at: projectConfigURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(
                #"{"scripts":{"setup":"echo project setup","archive":"echo project archive"}}"#.utf8
            ).write(to: projectConfigURL)

            let suiteName = "cmux.repository-script-settings-trust.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let catalog = SettingCatalog()
            let settingsURL = root.appendingPathComponent("user-settings.json")
            let jsonStore = JSONConfigStore(fileURL: settingsURL)
            let hostActions = HostSettingsActions(configFileURL: settingsURL)
            let runtime = SettingsRuntime(
                catalog: catalog,
                userDefaultsStore: UserDefaultsSettingsStore(defaults: defaults),
                jsonStore: jsonStore,
                secretStore: SecretFileStore(baseDirectory: root.appendingPathComponent("secrets")),
                errorLog: SettingsErrorLog(),
                hostActions: hostActions
            )

            let previousAppDelegate = AppDelegate.shared
            let appDelegate = AppDelegate()
            defer { AppDelegate.shared = previousAppDelegate }
            appDelegate.settingsRuntime = runtime
            let manager = TabManager(
                initialWorkingDirectory: root.path,
                autoWelcomeIfNeeded: false
            )
            appDelegate.tabManager = manager
            let windowID = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
            let window = NSWindow()
            let registeredContext = try #require(
                appDelegate.mainWindowContexts.values.first { $0.windowId == windowID }
            )
            registeredContext.window = window
            manager.window = window
            defer { appDelegate.unregisterMainWindowContextForTesting(windowId: windowID) }

            let context = try #require(await hostActions.repositoryScriptSettingsContext())
            #expect(context.setup.isEmpty)
            #expect(context.archive.isEmpty)
            #expect(context.projectSetup == "echo project setup")
            #expect(context.projectArchive == "echo project archive")

            let saved = try #require(await hostActions.saveRepositoryScripts(
                context: context,
                setup: "echo private setup",
                archive: context.archive
            ))
            #expect(saved.setup == "echo private setup")
            #expect(saved.archive.isEmpty)

            let savedPreferences = await jsonStore.value(for: catalog.terminal.repositoryScripts)
            let savedPreference = try #require(savedPreferences.first)
            #expect(savedPreference.setup == "echo private setup")
            #expect(savedPreference.archive == nil)
            #expect(savedPreference.overridesProjectScripts)

            let imported = try #require(
                await hostActions.importProjectRepositoryScripts(context: saved)
            )
            #expect(imported.setup == "echo project setup")
            #expect(imported.archive == "echo project archive")

            let importedPreferences = await jsonStore.value(for: catalog.terminal.repositoryScripts)
            let importedPreference = try #require(importedPreferences.first)
            #expect(importedPreference.setup == "echo project setup")
            #expect(importedPreference.archive == "echo project archive")
            #expect(importedPreference.overridesProjectScripts)
        }
    }
}
