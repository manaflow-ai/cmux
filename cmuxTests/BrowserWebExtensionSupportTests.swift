import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct BrowserWebExtensionSupportTests {
    @Test
    func reconciliationSkipsEnvPathWhenSettingsEntryIsDisabled() {
        let planner = BrowserWebExtensionReconciliationPlanner()
        let appexPath = "/Applications/Bitwarden.app/Contents/PlugIns/safari.appex"
        let plan = planner.plan(
            settingsEntries: [
                BrowserWebExtensionEntry(
                    id: "com.bitwarden.desktop.safari",
                    kind: .safariAppExtension,
                    path: appexPath,
                    enabled: false
                ),
            ],
            environmentPaths: [appexPath],
            loadedEntries: []
        )

        #expect(plan.desiredEntries.isEmpty)
        #expect(plan.loadEntries.isEmpty)
        #expect(plan.unloadEntryIDs.isEmpty)
    }

    @Test
    func reconciliationSkipsEnvResourceRootWhenSettingsEntryIsDisabled() {
        let planner = BrowserWebExtensionReconciliationPlanner()
        let appexPath = "/Applications/Bitwarden.app/Contents/PlugIns/safari.appex"
        let resourcePath = "\(appexPath)/Contents/Resources"
        let plan = planner.plan(
            settingsEntries: [
                BrowserWebExtensionEntry(
                    id: "com.bitwarden.desktop.safari",
                    kind: .safariAppExtension,
                    path: appexPath,
                    enabled: false
                ),
            ],
            environmentPaths: [resourcePath],
            loadedEntries: []
        )

        #expect(plan.desiredEntries.isEmpty)
        #expect(plan.loadEntries.isEmpty)
        #expect(plan.unloadEntryIDs.isEmpty)
    }

    @Test
    func reconciliationDoesNotLoadSamePathTwice() {
        let planner = BrowserWebExtensionReconciliationPlanner()
        let appexPath = "/Applications/Bitwarden.app/Contents/PlugIns/safari.appex"
        let plan = planner.plan(
            settingsEntries: [
                BrowserWebExtensionEntry(
                    id: "com.bitwarden.desktop.safari",
                    kind: .safariAppExtension,
                    path: appexPath,
                    enabled: true
                ),
            ],
            environmentPaths: [appexPath],
            loadedEntries: []
        )

        #expect(plan.desiredEntries.map(\.id) == ["com.bitwarden.desktop.safari"])
        #expect(plan.loadEntries.map(\.id) == ["com.bitwarden.desktop.safari"])
    }

    @Test
    func reconciliationDoesNotLoadBundleAndResourceRootTwice() {
        let planner = BrowserWebExtensionReconciliationPlanner()
        let appexPath = "/Applications/Bitwarden.app/Contents/PlugIns/safari.appex"
        let resourcePath = "\(appexPath)/Contents/Resources"
        let plan = planner.plan(
            settingsEntries: [
                BrowserWebExtensionEntry(
                    id: "com.bitwarden.desktop.safari",
                    kind: .safariAppExtension,
                    path: appexPath,
                    enabled: true
                ),
                BrowserWebExtensionEntry(
                    id: resourcePath,
                    kind: .unpackedDirectory,
                    path: resourcePath,
                    enabled: true
                ),
            ],
            environmentPaths: [],
            loadedEntries: []
        )

        #expect(plan.desiredEntries.map(\.id) == ["com.bitwarden.desktop.safari"])
        #expect(plan.loadEntries.map(\.id) == ["com.bitwarden.desktop.safari"])
    }

    @Test
    func reconciliationKeepsLoadedSafariExtensionWhenResourceRootMatches() {
        let planner = BrowserWebExtensionReconciliationPlanner()
        let appexPath = "/Applications/Bitwarden.app/Contents/PlugIns/safari.appex"
        let resourcePath = BrowserWebExtensionEntry.standardizedSafariAppExtensionResourceRootPath(appexPath)
        let plan = planner.plan(
            settingsEntries: [
                BrowserWebExtensionEntry(
                    id: "com.bitwarden.desktop.safari",
                    kind: .safariAppExtension,
                    path: appexPath,
                    enabled: true
                ),
            ],
            environmentPaths: [],
            loadedEntries: [
                BrowserWebExtensionReconciliationPlanner.LoadedEntry(
                    id: "com.bitwarden.desktop.safari",
                    standardizedPath: resourcePath
                ),
            ]
        )

        #expect(plan.unloadEntryIDs.isEmpty)
        #expect(plan.loadEntries.isEmpty)
    }

    @Test
    func reconciliationDeduplicatesRepeatedEnvironmentPaths() {
        let planner = BrowserWebExtensionReconciliationPlanner()
        let extensionPath = "/tmp/cmux-web-extensions/../cmux-web-extensions/Example"
        let standardizedPath = BrowserWebExtensionReconciliationPlanner.standardizedPath(extensionPath)
        let plan = planner.plan(
            settingsEntries: [],
            environmentPaths: [
                extensionPath,
                standardizedPath,
            ],
            loadedEntries: []
        )

        #expect(plan.desiredEntries.map(\.id) == [extensionPath])
        #expect(plan.desiredEntries.map(\.path) == [extensionPath])
        #expect(plan.loadEntries.map(\.id) == [extensionPath])
        #expect(plan.unloadEntryIDs.isEmpty)
    }

    @Test
    func reconciliationReloadsWhenPathChangesForSameEntryID() {
        let planner = BrowserWebExtensionReconciliationPlanner()
        let oldPath = "/Applications/Bitwarden.app/Contents/PlugIns/safari.appex"
        let newPath = "/Applications/Bitwarden Beta.app/Contents/PlugIns/safari.appex"
        let plan = planner.plan(
            settingsEntries: [
                BrowserWebExtensionEntry(
                    id: "com.bitwarden.desktop.safari",
                    kind: .safariAppExtension,
                    path: newPath,
                    enabled: true
                ),
            ],
            environmentPaths: [],
            loadedEntries: [
                BrowserWebExtensionReconciliationPlanner.LoadedEntry(
                    id: "com.bitwarden.desktop.safari",
                    standardizedPath: BrowserWebExtensionReconciliationPlanner.standardizedPath(oldPath)
                ),
            ]
        )

        #expect(plan.unloadEntryIDs == ["com.bitwarden.desktop.safari"])
        #expect(plan.loadEntries.map(\.path) == [newPath])
    }

    @Test
    @available(macOS 15.4, *)
    func permissionStateStorePersistsEntryStatesIndependently() throws {
        let suiteName = "cmux-web-extension-permissions-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = BrowserWebExtensionPermissionStateStore(defaults: defaults)
        let expiration = Date(timeIntervalSince1970: 1_800_000_000)
        let firstState = BrowserWebExtensionPermissionState(
            grantedPermissions: ["tabs": expiration],
            deniedPermissions: ["cookies": expiration],
            grantedPermissionMatchPatterns: ["https://example.com/*": expiration],
            deniedPermissionMatchPatterns: ["https://denied.example/*": expiration],
            hasRequestedOptionalAccessToAllHosts: true,
            hasAccessToPrivateData: false
        )
        let secondState = BrowserWebExtensionPermissionState(
            grantedPermissions: ["storage": expiration],
            deniedPermissions: [:],
            grantedPermissionMatchPatterns: [:],
            deniedPermissionMatchPatterns: [:],
            hasRequestedOptionalAccessToAllHosts: false,
            hasAccessToPrivateData: true
        )

        store.save(firstState, for: "com.example.first")
        store.save(secondState, for: "com.example.second")

        #expect(store.state(for: "com.example.first") == firstState)
        #expect(store.state(for: "com.example.second") == secondState)
        #expect(store.state(for: "missing") == nil)
    }

    @Test
    func pluginkitParserHandlesVerboseSpaceSeparatedOutput() {
        let output = """
        +    com.bitwarden.desktop.safari(2026.7.0)  01234567-89AB-CDEF-0123-456789ABCDEF  2026-07-09 03:21:09 +0000  /Applications/Bitwarden.app/Contents/PlugIns/safari.appex
        -    com.example.disabled(1.2.3)\tAAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE\t2026-07-09 03:22:09 +0000\t/Applications/Example App.app/Contents/PlugIns/Example Extension.appex
        """

        let candidates = BrowserWebExtensionDiscoveryService.parse(pluginkitOutput: output)

        #expect(candidates.map(\.id) == [
            "com.bitwarden.desktop.safari",
            "com.example.disabled",
        ])
        #expect(candidates.first?.version == "2026.7.0")
        #expect(candidates.first?.path == "/Applications/Bitwarden.app/Contents/PlugIns/safari.appex")
        #expect(candidates.last?.version == "1.2.3")
        #expect(candidates.last?.path == "/Applications/Example App.app/Contents/PlugIns/Example Extension.appex")
    }
}
