import CmuxSettings
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct BrowserWebExtensionPermissionReconciliationTests {
    @Test
    func purgesPermissionStateWhenDisabledEntryIsRemoved() {
        let planner = BrowserWebExtensionReconciliationPlanner()
        let removedEntry = BrowserWebExtensionEntry(
            id: "com.example.extension",
            kind: .unpackedDirectory,
            path: "/Extensions/Example",
            enabled: false
        )

        let plan = planner.plan(
            settingsEntries: [],
            previousSettingsEntries: [removedEntry],
            environmentPaths: [],
            loadedEntries: []
        )

        #expect(plan.permissionStateRemovalEntries == [
            BrowserWebExtensionPermissionStateRemoval(
                id: removedEntry.id,
                standardizedPath: removedEntry.standardizedResourceRootPath
            ),
        ])
    }
}
