import AppKit
import CmuxCloudMachines
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Turns the Cloud opt-in on for one test and puts the previous value back.
/// Cloud creation actions present the Cloud welcome instead of creating while
/// the opt-in is off (#19876), so tests that exercise creation hold it on.
/// The opt-in is process-wide, so callers run under `.exclusiveAppContext`.
@MainActor
struct CloudMachinesOptInForTesting {
    private static let key = RightSidebarBetaFeatureSettings.cloudMachinesEnabledKey
    private let previous: Any?

    init() {
        previous = UserDefaults.standard.object(forKey: Self.key)
        UserDefaults.standard.set(true, forKey: Self.key)
    }

    func restore() {
        if let previous {
            UserDefaults.standard.set(previous, forKey: Self.key)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.key)
        }
    }
}

/// Exercises the real window and action owners with an isolated fleet and no remote mutation.
@MainActor
final class CloudWorkspaceTargetingFixture {
    private final class Input {
        var requests: [CloudWorkspaceCreationRequest] = []
        var scope: String? = "scope"
        var available = true
        var onCreate: (@MainActor (CloudWorkspaceCreationRequest) async -> UUID?)?
    }
    let suite = "cloud-workspace-ui-\(UUID().uuidString)"
    let defaults: UserDefaults
    let pins: CloudMachinePinStore
    let app = AppDelegate()
    let coordinator: CloudWorkspaceCoordinator
    let manager: TabManager
    let windowID: UUID
    private let input: Input
    private let cloudOptIn = CloudMachinesOptInForTesting()
    var requests: [CloudWorkspaceCreationRequest] { input.requests }
    var scope: String? { get { input.scope } set { input.scope = newValue } }
    var available: Bool { get { input.available } set { input.available = newValue } }
    var onCreate: (@MainActor (CloudWorkspaceCreationRequest) async -> UUID?)? {
        get { input.onCreate }
        set { input.onCreate = newValue }
    }

    init() {
        defaults = UserDefaults(suiteName: suite)!
        let input = Input()
        self.input = input
        pins = CloudMachinePinStore(defaults: defaults, scopeProvider: { input.scope })
        coordinator = CloudWorkspaceCoordinator(
            machinePinStore: pins, allowsOperation: { input.available }, loadMachines: { ["a", "b"] },
            createWorkspace: { request in
                input.requests.append(request)
                if let onCreate = input.onCreate { return await onCreate(request) }
                return UUID()
            }
        )
        manager = TabManager(cloudWorkspaceSelection: coordinator.makeSelectionState())
        app.cloudWorkspaceCoordinator = coordinator
        app.cloudWorkspaceOperationController = CloudWorkspaceOperationController(isAvailable: { input.available })
        windowID = app.registerMainWindowContextForTesting(tabManager: manager)
    }

    func workspace(machineID: String) throws -> Workspace {
        let workspace = try #require(manager.addWorkspaceIfActive(initialSurface: .cloudVMLoading, select: false))
        workspace.cloudVMBinding = WorkspaceCloudVMBinding(vmID: machineID, isBase: false)
        return workspace
    }

    func close() {
        app.cloudWorkspaceOperationController?.cancelAll()
        app.unregisterMainWindowContextForTesting(windowId: windowID)
        manager.finalizeAllWorkspacesForWindowClose()
        defaults.removePersistentDomain(forName: suite)
        cloudOptIn.restore()
    }
}
