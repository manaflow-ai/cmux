import CmuxSettings
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
        let suiteName = "WorkspaceCreationWorkingDirectorySpawnPolicyTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = UserDefaultsSettingsClient(defaults: defaults)
        settings.set(false, for: SettingCatalog().app.workspaceInheritWorkingDirectory)

        let sourceDirectory = "/tmp/cmux-issue-8741-source-\(UUID().uuidString)"
        let ghosttyDefaultDirectory = FileManager.default.homeDirectoryForCurrentUser.path
        let manager = TabManager(
            initialWorkingDirectory: sourceDirectory,
            autoWelcomeIfNeeded: false,
            settings: settings,
            defaultWorkspaceWorkingDirectoryProvider: { ghosttyDefaultDirectory }
        )

        let workspace = manager.addWorkspace(autoWelcomeIfNeeded: false)
        let requestedDirectory = try #require(workspace.focusedTerminalPanel?.requestedWorkingDirectory)

        #expect(requestedDirectory == ghosttyDefaultDirectory)
        #expect(requestedDirectory != sourceDirectory)
    }
}
