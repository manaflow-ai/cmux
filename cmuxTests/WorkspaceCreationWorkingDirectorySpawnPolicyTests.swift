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

@MainActor
@Suite("Workspace creation working-directory spawn policy", .serialized)
struct WorkspaceCreationWorkingDirectorySpawnPolicyTests {
    @Test("ready terminal configuration creates the first window workspace synchronously")
    func readyConfigurationCreatesInitialWorkspaceSynchronously() async throws {
        let runtime = try makeWindowSettingsRuntime()
        await runtime.declarativeTerminalConfigurationModel.waitForInitialSnapshot()
        let appDelegate = try #require(AppDelegate.shared)
        let originalRuntime = appDelegate.settingsRuntime
        appDelegate.settingsRuntime = runtime
        let windowID = appDelegate.createMainWindow(shouldActivate: false)
        appDelegate.settingsRuntime = originalRuntime
        defer { appDelegate.mainWindow(for: windowID)?.close() }
        let manager = try #require(appDelegate.tabManagerFor(windowId: windowID))
        #expect(manager.tabs.count == 1)
        #expect(manager.selectedWorkspace != nil)
        await manager.waitForInitialWorkspace()
    }

    @Test("a window stays hidden while its initial terminal configuration loads")
    func unreadyConfigurationDoesNotPresentAnEmptyWindow() async throws {
        let appDelegate = try #require(AppDelegate.shared)
        let originalRuntime = appDelegate.settingsRuntime
        let loadingRuntime = try makeWindowSettingsRuntime()
        appDelegate.settingsRuntime = loadingRuntime
        let windowID = appDelegate.createMainWindow(shouldActivate: false)
        appDelegate.settingsRuntime = originalRuntime
        defer { appDelegate.mainWindow(for: windowID)?.close() }

        let window = try #require(appDelegate.mainWindow(for: windowID))
        let manager = try #require(appDelegate.tabManagerFor(windowId: windowID))
        #expect(manager.tabs.isEmpty)
        #expect(!window.isVisible)
        await manager.waitForInitialWorkspace()
        #expect(manager.tabs.count == 1)
    }

    @Test(
        "activation requests cannot reveal a window before its first workspace is ready",
        arguments: [
            MainWindowVisibilityController.Reason.applicationReopen,
            .menuBar,
            .socketActivate,
            .ensureInitialWindow
        ]
    )
    func activationDoesNotPresentAnEmptyWindow(reason: MainWindowVisibilityController.Reason) async throws {
        let appDelegate = try #require(AppDelegate.shared)
        let originalRuntime = appDelegate.settingsRuntime
        let loadingRuntime = try makeWindowSettingsRuntime()
        appDelegate.settingsRuntime = loadingRuntime
        let windowID = appDelegate.createMainWindow(shouldActivate: false)
        appDelegate.settingsRuntime = originalRuntime
        defer { appDelegate.mainWindow(for: windowID)?.close() }

        let window = try #require(appDelegate.mainWindow(for: windowID))
        let manager = try #require(appDelegate.tabManagerFor(windowId: windowID))
        #expect(manager.tabs.isEmpty)
        #expect(appDelegate.focusWindowForAppActivation(window, reason: reason))
        #expect(!window.isVisible)
        await manager.waitForInitialWorkspace()
        #expect(manager.tabs.count == 1)
    }

    private func makeWindowSettingsRuntime() throws -> SettingsRuntime {
        let identifier = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: "WindowReadiness.\(identifier)"))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-window-readiness-\(identifier)", isDirectory: true)
        return SettingsRuntime(
            catalog: SettingCatalog(),
            userDefaultsStore: UserDefaultsSettingsStore(defaults: defaults),
            jsonStore: JSONConfigStore(fileURL: directory.appendingPathComponent("cmux.json")),
            secretStore: SecretFileStore(baseDirectory: directory),
            errorLog: SettingsErrorLog()
        )
    }

    @Test("deferred focus retains request-time activation permission", arguments: [false, true])
    func deferredFocusRetainsActivationPermission(initiallySuppressed: Bool) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        var activationSuppressed = initiallySuppressed
        var madeKeyCount = 0
        var activationCount = 0
        var fallbackCount = 0
        var operations = MainWindowVisibilityController.WindowOperations.live
        operations.makeKeyAndOrderFront = { _ in madeKeyCount += 1 }
        let controller = MainWindowVisibilityController(dependencies: .init(
            isActivationSuppressed: { activationSuppressed },
            setActiveMainWindow: { _ in },
            isApplicationHidden: { false },
            activateRunningApplication: { _ in activationCount += 1 },
            windowOperations: operations
        ))
        controller.deferInitialPresentation(of: window)
        #expect(controller.focus(window, reason: .socketActivate))
        #expect(madeKeyCount == 0)
        #expect(activationCount == 0)
        activationSuppressed.toggle()
        controller.completeInitialPresentation(of: window) { fallbackCount += 1 }
        #expect(madeKeyCount == (initiallySuppressed ? 0 : 1))
        #expect(activationCount == (initiallySuppressed ? 0 : 1))
        #expect(fallbackCount == (initiallySuppressed ? 1 : 0))
    }

    @Test("passive activation and close cannot reveal a pending initial window")
    func pendingInitialPresentationRejectsPassiveRevealAndClose() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        var madeKeyCount = 0
        var fallbackCount = 0
        var operations = MainWindowVisibilityController.WindowOperations.live
        operations.makeKeyAndOrderFront = { _ in madeKeyCount += 1 }
        operations.orderFront = { _ in madeKeyCount += 1 }
        let controller = MainWindowVisibilityController(dependencies: .init(
            isActivationSuppressed: { false },
            setActiveMainWindow: { _ in },
            isApplicationHidden: { false },
            windowOperations: operations
        ))
        controller.deferInitialPresentation(of: window)
        #expect(controller.reveal([window], preferredWindow: window, reason: .applicationReopen) == nil)
        controller.focusForInWindowCommand(window, reason: .findShortcut)
        #expect(madeKeyCount == 0)
        controller.commitClose(window)
        controller.completeInitialPresentation(of: window) { fallbackCount += 1 }
        #expect(madeKeyCount == 0)
        #expect(fallbackCount == 0)
    }

    @Test("declarative shell startup stays with the surface creation snapshot")
    func declarativeShellStartupDefaultsArePinnedAtSurfaceCreation() {
        @MainActor
        final class MutableConfigurationSource: DeclarativeTerminalConfigurationProviding {
            var snapshot = DeclarativeTerminalConfiguration.Snapshot(
                shellStartupMode: .nonLogin,
                shellStartupCommand: "printf before"
            )
            let fileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-spawn-snapshot-\(UUID().uuidString).json")

            func waitForInitialSnapshot() async {}
        }

        let source = MutableConfigurationSource()
        let configStore = JSONConfigStore(fileURL: source.fileURL)
        let pendingSurfacePolicy = TerminalSurfaceSpawnPolicyBridge(
            declarativeTerminalConfigurationSource: source,
            computerUseConfigStore: configStore
        )

        source.snapshot.shellStartupMode = .login
        source.snapshot.shellStartupCommand = "printf after"

        let pendingSpawn = pendingSurfacePolicy.currentSpawnPolicy()
        #expect(pendingSpawn.shellStartupMode == .nonLogin)
        #expect(pendingSpawn.shellStartupCommand == "printf before")

        let nextSurfacePolicy = TerminalSurfaceSpawnPolicyBridge(
            declarativeTerminalConfigurationSource: source,
            computerUseConfigStore: configStore
        )
        let nextSpawn = nextSurfacePolicy.currentSpawnPolicy()
        #expect(nextSpawn.shellStartupMode == .login)
        #expect(nextSpawn.shellStartupCommand == "printf after")
    }

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

    @Test("new tabs and splits honor the declarative fixed-path policy")
    func newTabsAndSplitsHonorDeclarativeFixedPathPolicy() throws {
        let suiteName = "WorkspaceCreationWorkingDirectorySpawnPolicyTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = UserDefaultsSettingsClient(defaults: defaults)
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-declarative-cwd-\(UUID().uuidString)", isDirectory: true)
        let fixedDirectory = temporaryDirectory.appendingPathComponent("fixed", isDirectory: true)
        let configurationFile = temporaryDirectory.appendingPathComponent("cmux.json")
        try FileManager.default.createDirectory(
            at: fixedDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let initialSnapshot = DeclarativeTerminalConfiguration.Snapshot(
            workingDirectoryPolicy: .fixedPath,
            workingDirectoryPath: fixedDirectory.path,
            fixedPathIsUsable: true
        )
        let sourceDirectory = temporaryDirectory.appendingPathComponent("source").path
        let workspace = Workspace(
            workingDirectory: sourceDirectory,
            settings: settings,
            declarativeTerminalConfigurationFileURL: configurationFile,
            declarativeTerminalConfigurationSource: DeclarativeTerminalConfigurationSnapshotSource(
                snapshot: initialSnapshot,
                fileURL: configurationFile
            )
        )
        let paneId = try #require(workspace.bonsplitController.focusedPaneId)
        let sourcePanelId = try #require(workspace.focusedPanelId)

        let newTab = try #require(workspace.newTerminalSurface(inPane: paneId, focus: false))
        let split = try #require(
            workspace.newTerminalSplit(
                from: sourcePanelId,
                orientation: .vertical,
                focus: false
            )
        )

        #expect(newTab.requestedWorkingDirectory == fixedDirectory.path)
        #expect(split.requestedWorkingDirectory == fixedDirectory.path)
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
