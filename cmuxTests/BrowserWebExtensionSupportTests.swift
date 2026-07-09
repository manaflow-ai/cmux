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
