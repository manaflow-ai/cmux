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
        var initialSnapshot = DeclarativeTerminalConfiguration().snapshot(fileURL: configurationFile)
        initialSnapshot.fixedPathIsUsable = true
        let manager = TabManager(
            initialWorkingDirectory: sourceDirectory,
            autoWelcomeIfNeeded: false,
            settings: settings,
            declarativeTerminalConfigurationFileURL: configurationFile,
            defaultWorkspaceWorkingDirectoryProvider: { fallbackDirectory },
            declarativeTerminalConfigurationSource: DeclarativeTerminalConfigurationSnapshotSource(
                snapshot: initialSnapshot,
                fileURL: configurationFile
            )
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

    @Test("unusable fixed-path policy falls back to the workspace root")
    func unusableFixedPathFallsBackToWorkspaceRoot() throws {
        let suiteName = "WorkspaceCreationWorkingDirectorySpawnPolicyTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = UserDefaultsSettingsClient(defaults: defaults)
        settings.set(false, for: SettingCatalog().app.workspaceInheritWorkingDirectory)

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-declarative-cwd-invalid-\(UUID().uuidString)", isDirectory: true)
        let configurationFile = temporaryDirectory.appendingPathComponent("cmux.json")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let missingDirectory = temporaryDirectory.appendingPathComponent("deleted", isDirectory: true)
        try Data(
            #"{"terminal":{"newSurfaceWorkingDirectory":{"policy":"fixedPath","path":"\#(missingDirectory.path)"}}}"#.utf8
        ).write(to: configurationFile)

        let workspaceRoot = temporaryDirectory.appendingPathComponent("workspace-root").path
        let manager = TabManager(
            initialWorkingDirectory: workspaceRoot,
            autoWelcomeIfNeeded: false,
            settings: settings,
            declarativeTerminalConfigurationFileURL: configurationFile,
            defaultWorkspaceWorkingDirectoryProvider: { workspaceRoot },
            declarativeTerminalConfigurationSource: DeclarativeTerminalConfigurationSnapshotSource(
                snapshot: DeclarativeTerminalConfiguration().snapshot(fileURL: configurationFile),
                fileURL: configurationFile
            )
        )

        let workspace = manager.addWorkspace(
            inheritWorkingDirectory: false,
            autoWelcomeIfNeeded: false
        )
        let requestedDirectory = try #require(
            workspace.focusedTerminalPanel?.requestedWorkingDirectory
        )

        #expect(requestedDirectory == workspaceRoot)
        #expect(requestedDirectory != missingDirectory.path)
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
        let configurationFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-isolated-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: configurationFile) }
        let workspace = Workspace(
            workingDirectory: localWorkspaceRoot,
            settings: settings,
            declarativeTerminalConfigurationFileURL: configurationFile
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

    @Test("remote respawn preserves remote working-directory provenance")
    func remoteRespawnPreservesRemoteSourceDirectory() throws {
        let suiteName = "WorkspaceCreationWorkingDirectorySpawnPolicyTests.remote-respawn-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = UserDefaultsSettingsClient(defaults: defaults)
        settings.set(true, for: SettingCatalog().app.workspaceInheritWorkingDirectory)
        let configurationFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-isolated-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: configurationFile) }

        let remoteDirectory = "/home/remote/project"
        let workspace = Workspace(
            workingDirectory: remoteDirectory,
            settings: settings,
            declarativeTerminalConfigurationFileURL: configurationFile
        )
        let remotePanelId = try #require(workspace.focusedPanelId)
        workspace.trackRemoteTerminalSurface(remotePanelId)
        workspace.panelDirectories[remotePanelId] = remoteDirectory

        let resolvedDirectory = workspace.resolvedTerminalStartupWorkingDirectory(
            requestedWorkingDirectory: nil,
            sourcePanelId: remotePanelId,
            allowsDeclarativeDefaults: false
        )

        #expect(resolvedDirectory == remoteDirectory)
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
        let configurationFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-isolated-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: configurationFile) }
        let manager = TabManager(
            initialWorkingDirectory: remoteDirectory,
            autoWelcomeIfNeeded: false,
            settings: settings,
            declarativeTerminalConfigurationFileURL: configurationFile,
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
