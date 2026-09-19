import AppKit
import CmuxCloudMachines
import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct SidebarNewLocalWorkspaceTests {
    @Test func plusMenuCreatesLocalWhileCommandNStillTargetsSelectedCloudMachine() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let fixture = try Fixture()
            defer { fixture.tearDown() }
            let cloudWorkspace = try #require(fixture.manager.selectedWorkspace)
            cloudWorkspace.cloudVMBinding = WorkspaceCloudVMBinding(vmID: "selected-machine", isBase: false)
            cloudWorkspace.currentDirectory = "/cloud-only/project"
            let originalCount = fixture.manager.tabs.count
            var targets: [String] = []
            let defaultMachineStore = DefaultCloudMachineStore(defaults: fixture.defaults)
            defaultMachineStore.machineID = "different-default"
            fixture.app.cloudWorkspaceCoordinator = CloudWorkspaceCoordinator(
                defaultMachineStore: defaultMachineStore,
                allowsOperation: { true },
                loadMachines: { Issue.record("New Workspace must not resolve the default VM"); return [] },
                createWorkspace: { id, focus in
                    #expect(focus)
                    targets.append(id)
                    return UUID()
                }
            )
            fixture.app.cloudWorkspaceOperationController = CloudWorkspaceOperationController(isAvailable: { true })

            try fixture.clickNewWorkspace()
            await fixture.app.cloudWorkspaceOperationController?.waitForPendingOperations()
            #expect(targets.isEmpty, "The plus-menu override must never invoke Cloud creation")
            #expect(fixture.manager.tabs.count == originalCount + 1)
            let localWorkspace = try #require(fixture.manager.selectedWorkspace)
            #expect(localWorkspace.id != cloudWorkspace.id)
            #expect(localWorkspace.cloudVMID == nil)
            #expect(localWorkspace.remoteConfiguration == nil)
            #expect(localWorkspace.currentDirectory == fixture.root.path)

            fixture.manager.selectedTabId = cloudWorkspace.id
            targets.removeAll()
            // This is the same action called by the File menu and shortcut.cmdN.
            #expect(fixture.app.performNewWorkspaceAction(tabManager: fixture.manager))
            await fixture.app.cloudWorkspaceOperationController?.waitForPendingOperations()
            #expect(targets == ["selected-machine"])
            #expect(fixture.manager.tabs.count == originalCount + 1)
            #expect(defaultMachineStore.machineID == "different-default")
        }
    }

    @Test(arguments: [false, true])
    func plusMenuCreatesLocalWithoutCloudServicesAndDoesNotAdvertiseCommandN(cloudSelected: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let selected = try #require(fixture.manager.selectedWorkspace)
        if cloudSelected {
            selected.cloudVMBinding = WorkspaceCloudVMBinding(vmID: "unavailable-machine", isBase: false)
        }
        let originalCount = fixture.manager.tabs.count

        try fixture.clickNewWorkspace()

        #expect(fixture.manager.tabs.count == originalCount + 1)
        let created = try #require(fixture.manager.selectedWorkspace)
        #expect(created.id != selected.id)
        #expect(created.cloudVMID == nil)
        #expect(created.remoteConfiguration == nil)
    }
}

private extension SidebarNewLocalWorkspaceTests {
    @MainActor
    final class Fixture {
        let app = AppDelegate()
        let manager: TabManager
        let root: URL
        let defaults: UserDefaults
        let suiteName: String
        let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        let store: CmuxConfigStore
        let windowID: UUID

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let config = root.appendingPathComponent("cmux.json")
            try "{}".write(to: config, atomically: true, encoding: .utf8)
            let defaultsSuite = "SidebarNewLocalWorkspaceTests.\(UUID().uuidString)"
            suiteName = defaultsSuite
            defaults = try #require(UserDefaults(suiteName: defaultsSuite))
            store = CmuxConfigStore(globalConfigPath: config.path, localConfigPath: nil, startFileWatchers: false)
            store.loadAll()
            let localDirectory = root.path
            manager = TabManager(
                initialWorkingDirectory: localDirectory,
                autoWelcomeIfNeeded: false,
                settings: UserDefaultsSettingsClient(defaults: defaults),
                defaultWorkspaceWorkingDirectoryProvider: { localDirectory }
            )
            windowID = app.registerMainWindowContextForTesting(tabManager: manager, cmuxConfigStore: store)
            let context = try #require(app.mainWindowContexts.values.first { $0.windowId == windowID })
            context.window = window
        }

        func clickNewWorkspace() throws {
            let context = try #require(app.mainWindowContexts.values.first { $0.windowId == windowID })
            let menu = try #require(app.makeNewWorkspaceContextMenu(context: context, cmuxConfigStore: store))
            let index = try #require(menu.items.firstIndex {
                ($0.representedObject as? NewWorkspaceContextMenuActionBox)?.action.action == .builtIn(.newWorkspace)
            })
            let item = menu.items[index]
            #expect(item.title == String(localized: "command.newWorkspace.title", defaultValue: "New Workspace"))
            #expect(item.keyEquivalent.isEmpty)
            #expect(item.keyEquivalentModifierMask.isEmpty)
            menu.performActionForItem(at: index)
        }

        func tearDown() {
            manager.tabs.forEach { $0.teardownAllPanels() }
            app.unregisterMainWindowContextForTesting(windowId: windowID)
            app.forgetRecoverableMainWindowRoute(windowId: windowID)
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
