import AppKit
import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class CloudWorkspaceCreationSidebarFixture {
    private let previousApp = AppDelegate.shared
    private let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
    let app = AppDelegate()
    let manager: TabManager
    let catalog: SurfaceCatalog
    let provider: CloudWorkspaceCreationSidebarProvider
    let window: NSWindow
    let windowID = UUID()
    let originalWorkspaceID: UUID
    private let defaults: UserDefaults
    private let defaultsName = "cloud-workspace-creation-\(UUID().uuidString)"

    init() throws {
        defaults = try #require(UserDefaults(suiteName: defaultsName))
        manager = TabManager(autoWelcomeIfNeeded: false, settings: UserDefaultsSettingsClient(defaults: defaults))
        originalWorkspaceID = try #require(manager.selectedTabId)
        let owner = manager
        catalog = SurfaceCatalog(cloudWorkspaceRenameService: CloudWorkspaceRenameService(environment: .init(
            workspace: { owner.workspacesById[$0] }, tabManager: { _ in owner }, workspaces: { owner.tabs }
        )))
        provider = CloudWorkspaceCreationSidebarProvider(catalog: catalog)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(windowID.uuidString)")
        AppDelegate.shared = app
        app.tabManager = manager
        TerminalController.shared.setActiveTabManager(manager)
        app.registerMainWindow(window, windowId: windowID, tabManager: manager,
                               sidebarState: SidebarState(), sidebarSelectionState: SidebarSelectionState(),
                               fileExplorerState: FileExplorerState())
        catalog.register(provider)
    }

    func workspaceRows() -> [CloudTreeNode] {
        CloudTreeNodeBuilder.flattened(CloudTreeNodeBuilder.nodes(
            machines: [], snapshot: catalog.snapshot, localWorkspaces: [], includeLocalMachine: false
        )).filter { $0.structureTag == "workspace" }
    }

    func close() {
        provider.beforeRefresh = nil
        provider.beforeMaterialize = nil
        provider.beforeCreate = nil
        // Tear down native Ghostty panels before unregistering the provider.
        // Provider retirement can discard a reserved projection itself; doing
        // that first races the workspace's panel teardown and can trip AppKit's
        // defunct renderer trap in the test host.
        manager.tabs.forEach { $0.teardownAllPanels() }
        catalog.cloudWorkspaceCreationCoordinator.cancelAll()
        catalog.unregister(machine: provider.machine)
        app.unregisterMainWindowContextForTesting(windowId: windowID)
        window.close()
        AppDelegate.shared = previousApp
        TerminalController.shared.setActiveTabManager(previousManager)
        defaults.removePersistentDomain(forName: defaultsName)
    }
}
