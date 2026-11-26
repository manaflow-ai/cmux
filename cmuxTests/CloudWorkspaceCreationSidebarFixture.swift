import AppKit
import CmuxSettings
import CmuxSurfaceCatalogModel
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
    private let previousSharedRenameService: CloudWorkspaceRenameService?
    private let cloudOptIn: CloudMachinesOptInForTesting?

    /// - Parameter enablesCloudMachines: Holds the Cloud opt-in on for tests
    ///   that press a Cloud creation action, which otherwise shows the welcome.
    init(useSharedCatalog: Bool = false, machine: SurfaceMachineID? = nil, enablesCloudMachines: Bool = false) throws {
        cloudOptIn = enablesCloudMachines ? CloudMachinesOptInForTesting() : nil
        defaults = try #require(UserDefaults(suiteName: defaultsName))
        manager = TabManager(autoWelcomeIfNeeded: false, settings: UserDefaultsSettingsClient(defaults: defaults))
        originalWorkspaceID = try #require(manager.selectedTabId)
        let owner = manager
        let ownerEnvironment = CloudWorkspaceRenameEnvironment(
            workspace: { owner.workspacesById[$0] }, tabManager: { _ in owner }, workspaces: { owner.tabs }
        )
        if useSharedCatalog {
            // The shared catalog's rename service was installed by the host
            // app delegate and resolves workspaces through that delegate's
            // windows, which never contain this fixture's manager. Without
            // this, bindCloudWorkspace is a no-op and reservations never get
            // their cloudVMBinding.
            let shared = SurfaceCatalog.shared
            previousSharedRenameService = shared.cloudWorkspaceRenameService
            shared.installCloudWorkspaceRenameService(CloudWorkspaceRenameService(environment: ownerEnvironment))
            catalog = shared
        } else {
            previousSharedRenameService = nil
            catalog = SurfaceCatalog(cloudWorkspaceRenameService: CloudWorkspaceRenameService(environment: ownerEnvironment))
        }
        if let machine {
            provider = CloudWorkspaceCreationSidebarProvider(catalog: catalog, machine: machine)
        } else {
            provider = CloudWorkspaceCreationSidebarProvider(catalog: catalog)
        }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(windowID.uuidString)")
        AppDelegate.shared = app
        // This fixture owns a short-lived app delegate and exercises Cloud
        // projections only. Keep session autosave disabled so an async
        // persistence block cannot become the last owner of `app` and run its
        // main-actor service deinitializers on the persistence worker queue.
        app.isTerminatingApp = true
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
        app.isTerminatingApp = true
        provider.beforeRefresh = nil
        provider.beforeMaterialize = nil
        provider.beforeCreate = nil
        provider.afterCreateWorkspace = nil
        catalog.unregister(machine: provider.machine)
        manager.tabs.forEach { $0.teardownAllPanels() }
        app.unregisterMainWindowContextForTesting(windowId: windowID)
        window.close()
        if let previousSharedRenameService {
            catalog.installCloudWorkspaceRenameService(previousSharedRenameService)
        }
        AppDelegate.shared = previousApp
        TerminalController.shared.setActiveTabManager(previousManager)
        defaults.removePersistentDomain(forName: defaultsName)
        cloudOptIn?.restore()
    }
}
