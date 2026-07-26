import CmuxSettings
import CmuxTerminalCore
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Workspace creation working-directory spawn policy", .serialized)
struct WorkspaceCreationWorkingDirectorySpawnPolicyTests {
    @Test("disabled inheritance passes Ghostty's home default to the first terminal")
    func disabledInheritancePassesGhosttyHomeDefaultToFirstTerminal() throws {
#if DEBUG
        let previousOverride = TerminalStartupAppearancePreviewOverride.installed
        TerminalStartupAppearancePreviewOverride.installed = TerminalStartupAppearancePreviewOverride(
            loadsRealUserConfig: false,
            previewConfigContents: { _ in "working-directory = home" }
        )
        GhosttyConfig.invalidateLoadCache()
        defer {
            TerminalStartupAppearancePreviewOverride.installed = previousOverride
            GhosttyConfig.invalidateLoadCache()
        }
#endif

        let suiteName = "WorkspaceCreationWorkingDirectorySpawnPolicyTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = UserDefaultsSettingsClient(defaults: defaults)
        settings.set(false, for: SettingCatalog().app.workspaceInheritWorkingDirectory)

        let sourceDirectory = "/tmp/cmux-issue-8741-source-\(UUID().uuidString)"
        let manager = TabManager(
            initialWorkingDirectory: sourceDirectory,
            autoWelcomeIfNeeded: false,
            settings: settings
        )

        let workspace = manager.addWorkspace(autoWelcomeIfNeeded: false)
        let requestedDirectory = try #require(workspace.focusedTerminalPanel?.requestedWorkingDirectory)

        #expect(requestedDirectory == FileManager.default.homeDirectoryForCurrentUser.path)
        #expect(requestedDirectory != sourceDirectory)
    }
}
