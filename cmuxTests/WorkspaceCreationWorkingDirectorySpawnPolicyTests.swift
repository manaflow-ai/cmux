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
    @Test("explicit fixed-path policy overrides the legacy caller inheritance flag")
    func explicitFixedPathPolicyOverridesLegacyCallerFlag() throws {
        let suiteName = "WorkspaceCreationWorkingDirectorySpawnPolicyTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = UserDefaultsSettingsClient(defaults: defaults)
        settings.set(false, for: SettingCatalog().app.workspaceInheritWorkingDirectory)

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-declarative-cwd-\(UUID().uuidString)", isDirectory: true)
        let fixedDirectory = temporaryDirectory.appendingPathComponent("fixed", isDirectory: true)
        let configurationFile = temporaryDirectory.appendingPathComponent("cmux.json")
        try FileManager.default.createDirectory(
            at: fixedDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        try Data(
            #"{"terminal":{"newSurfaceWorkingDirectory":{"policy":"fixedPath","path":"\#(fixedDirectory.path)"}}}"#.utf8
        ).write(to: configurationFile)

        let sourceDirectory = temporaryDirectory.appendingPathComponent("source").path
        let fallbackDirectory = temporaryDirectory.appendingPathComponent("fallback").path
        let manager = TabManager(
            initialWorkingDirectory: sourceDirectory,
            autoWelcomeIfNeeded: false,
            settings: settings,
            declarativeTerminalConfigurationFileURL: configurationFile,
            defaultWorkspaceWorkingDirectoryProvider: { fallbackDirectory }
        )

        let workspace = manager.addWorkspace(
            inheritWorkingDirectory: false,
            autoWelcomeIfNeeded: false
        )
        let requestedDirectory = try #require(
            workspace.focusedTerminalPanel?.requestedWorkingDirectory
        )

        #expect(requestedDirectory == fixedDirectory.path)
        #expect(requestedDirectory != sourceDirectory)
        #expect(requestedDirectory != fallbackDirectory)
    }

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

    @Test("local terminal fails closed to workspace root when its source pane is remote")
    func localTerminalRejectsRemoteSourcePaneDirectory() throws {
        let suiteName = "WorkspaceCreationWorkingDirectorySpawnPolicyTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = UserDefaultsSettingsClient(defaults: defaults)
        settings.set(true, for: SettingCatalog().app.workspaceInheritWorkingDirectory)

        let localWorkspaceRoot = "/tmp/cmux-local-root-\(UUID().uuidString)"
        let remoteDirectory = "/home/remote/project"
        let workspace = Workspace(
            workingDirectory: localWorkspaceRoot,
            settings: settings
        )
        let remotePanelId = try #require(workspace.focusedPanelId)
        workspace.trackRemoteTerminalSurface(remotePanelId)
        workspace.panelDirectories[remotePanelId] = remoteDirectory

        let resolvedDirectory = workspace.resolvedTerminalStartupWorkingDirectory(
            requestedWorkingDirectory: nil,
            sourcePanelId: remotePanelId
        )

        #expect(resolvedDirectory == localWorkspaceRoot)
        #expect(resolvedDirectory != remoteDirectory)
    }

    @Test("new local workspace rejects remote workspace cwd and root")
    func newLocalWorkspaceRejectsRemoteWorkspaceDirectoryProvenance() throws {
        let suiteName = "WorkspaceCreationWorkingDirectorySpawnPolicyTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = UserDefaultsSettingsClient(defaults: defaults)
        settings.set(true, for: SettingCatalog().app.workspaceInheritWorkingDirectory)

        let remoteDirectory = "/home/remote/project"
        let localDefaultDirectory = "/tmp/cmux-local-default-\(UUID().uuidString)"
        let manager = TabManager(
            initialWorkingDirectory: remoteDirectory,
            autoWelcomeIfNeeded: false,
            settings: settings,
            defaultWorkspaceWorkingDirectoryProvider: { localDefaultDirectory }
        )
        let remoteWorkspace = try #require(manager.selectedWorkspace)
        remoteWorkspace.isRemoteTmuxMirror = true

        let localWorkspace = manager.addWorkspace(autoWelcomeIfNeeded: false)
        let requestedDirectory = try #require(
            localWorkspace.focusedTerminalPanel?.requestedWorkingDirectory
        )

        #expect(requestedDirectory == localDefaultDirectory)
        #expect(requestedDirectory != remoteDirectory)
    }
}
