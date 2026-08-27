import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for the workspace-group "Edit Group Configuration…"
/// action. The opener must route the cmux config file through the same
/// editor-resolving path the rest of the app uses (so `preferredEditorCommand`
/// is honored) rather than handing it to `NSWorkspace.shared.open`, which
/// routes to the OS default `.json` handler and ignores the cmux setting.
///
/// Before the fix the opener called `NSWorkspace.shared.open(configURL)`
/// directly, so the injected opener was never invoked and this test fails.
@Suite struct SidebarWorkspaceGroupConfigOpenerTests {
    @Test func routesConfigFileThroughInjectedOpener() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-group-config-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        var opened: [URL] = []
        SidebarWorkspaceGroupConfigOpener.openCmuxConfigInEditor(home: home) { opened.append($0) }

        #expect(opened.count == 1)
        let url = try #require(opened.first)
        #expect(url.lastPathComponent == "cmux.json")
        // Resolved beneath the injected home, under .config/cmux.
        #expect(url.path.hasPrefix(home.path))
        #expect(url.deletingLastPathComponent().lastPathComponent == "cmux")

        // The opener materializes an empty config when none exists, scoped to
        // the injected home (no real-filesystem side effects).
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}
