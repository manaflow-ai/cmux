import CmuxPanes
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

    // #177: Ghostty's own `*-inherit-working-directory = false` keys apply to
    // the matching cmux creation path, not only cmux's workspace setting.

    @Test("window-inherit-working-directory = false starts new workspaces in Ghostty's default")
    func ghosttyWindowInheritanceOffStartsNewWorkspaceInDefault() throws {
        let fixture = try InheritanceFixture(GhosttyWorkingDirectoryInheritance(window: false))
        defer { fixture.tearDown() }

        let workspace = fixture.manager.addWorkspace(autoWelcomeIfNeeded: false)

        #expect(workspace.focusedTerminalPanel?.requestedWorkingDirectory == fixture.defaultDirectory)
    }

    @Test("tab-inherit-working-directory = false starts new terminal tabs in Ghostty's default")
    func ghosttyTabInheritanceOffStartsNewTabInDefault() throws {
        let fixture = try InheritanceFixture(GhosttyWorkingDirectoryInheritance(tab: false))
        defer { fixture.tearDown() }
        let workspace = try fixture.sourceWorkspace()
        let pane = try #require(workspace.bonsplitController.focusedPaneId)
        let source = try #require(workspace.focusedTerminalPanel).id

        let tab = workspace.newTerminalSurface(inPane: pane, inheritWorkingDirectoryFallback: true)
        let splitPanel = fixture.manager.createSplitOutcome(
            tabId: workspace.id,
            surfaceId: source,
            direction: .right
        ).panel

        #expect(tab?.requestedWorkingDirectory == fixture.defaultDirectory)
        #expect(splitPanel?.requestedWorkingDirectory == fixture.sourceDirectory)
    }

    @Test("split-inherit-working-directory = false starts new splits in Ghostty's default")
    func ghosttySplitInheritanceOffStartsNewSplitInDefault() throws {
        let fixture = try InheritanceFixture(GhosttyWorkingDirectoryInheritance(split: false))
        defer { fixture.tearDown() }
        let workspace = try fixture.sourceWorkspace()
        let pane = try #require(workspace.bonsplitController.focusedPaneId)
        let source = try #require(workspace.focusedTerminalPanel).id

        let splitPanel = fixture.manager.createSplitOutcome(
            tabId: workspace.id,
            surfaceId: source,
            direction: .right
        ).panel
        let tab = workspace.newTerminalSurface(inPane: pane, inheritWorkingDirectoryFallback: true)
        // Layout and restore scaffolds split through the same workspace API
        // and must keep their anchor's directory.
        let scaffoldSplit = workspace.newTerminalSplit(from: source, orientation: .vertical, focus: false)

        #expect(splitPanel?.requestedWorkingDirectory == fixture.defaultDirectory)
        #expect(tab?.requestedWorkingDirectory == fixture.sourceDirectory)
        #expect(scaffoldSplit?.requestedWorkingDirectory == fixture.sourceDirectory)
    }

    @MainActor
    private struct InheritanceFixture {
        let suiteName = "WorkspaceCreationWorkingDirectorySpawnPolicyTests.\(UUID().uuidString)"
        // Real directories: inheritance falls back to the nearest existing
        // ancestor for a source directory that is gone.
        let root = "/tmp/cmux-issue-177-\(UUID().uuidString)"
        var sourceDirectory: String { root + "/source" }
        var defaultDirectory: String { root + "/default" }
        let manager: TabManager

        init(_ inheritance: GhosttyWorkingDirectoryInheritance) throws {
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            for directory in [root + "/source", root + "/default"] {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            }
            let defaultDirectory = root + "/default"
            let sourceDirectory = root + "/source"
            manager = TabManager(
                initialWorkingDirectory: sourceDirectory,
                autoWelcomeIfNeeded: false,
                settings: UserDefaultsSettingsClient(defaults: defaults),
                defaultWorkspaceWorkingDirectoryProvider: { defaultDirectory },
                ghosttyWorkingDirectoryInheritanceProvider: { inheritance }
            )
        }

        /// A workspace whose terminal was explicitly started in the source directory.
        func sourceWorkspace() throws -> Workspace {
            let workspace = manager.addWorkspace(
                workingDirectory: sourceDirectory,
                autoWelcomeIfNeeded: false
            )
            #expect(workspace.focusedTerminalPanel?.requestedWorkingDirectory == sourceDirectory)
            return workspace
        }

        func tearDown() {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(atPath: root)
        }
    }
}
