import Foundation
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Real local workspaces that a test's `SurfaceCatalog` resolves as live destinations.
///
/// `SurfaceCatalog.validateOwnership` refuses to project, materialize or restore into a
/// workspace it cannot resolve, so a made-up workspace ID fails with `destinationNotFound`.
/// Register every local workspace a test names, then build its catalog with
/// `renameService`, the same lookup the app installs at its composition root.
///
/// Only `workspace(_:)` resolves. `workspaces()` stays empty so the catalog's native
/// projection coordinator does not start mirroring Cloud tabs into these workspaces.
@MainActor
final class LiveWorkspaceFixture {
    private var workspacesByID: [UUID: Workspace] = [:]

    init(_ ids: UUID...) {
        for id in ids { add(id: id) }
    }

    /// Creates and registers a live workspace, keeping `id` when the test already chose one.
    @discardableResult
    func add(id: UUID = UUID()) -> Workspace {
        if let existing = workspacesByID[id] { return existing }
        let workspace = Workspace(id: id)
        workspacesByID[id] = workspace
        return workspace
    }

    /// Registers a workspace the test built itself.
    func register(_ workspace: Workspace) {
        workspacesByID[workspace.id] = workspace
    }

    /// The ID of a newly registered live workspace.
    func id() -> UUID {
        add().id
    }

    subscript(id: UUID) -> Workspace? {
        workspacesByID[id]
    }

    var environment: CloudWorkspaceRenameEnvironment {
        CloudWorkspaceRenameEnvironment(workspace: { [self] id in workspacesByID[id] })
    }

    var renameService: CloudWorkspaceRenameService {
        CloudWorkspaceRenameService(environment: environment)
    }

    /// Closes the panels of the workspaces this fixture created or registered.
    func tearDown() {
        for workspace in workspacesByID.values { workspace.teardownAllPanels() }
        workspacesByID.removeAll()
    }
}

extension LiveWorkspaceFixture {
    /// `SurfaceCatalog.shared` resolves workspaces through the app delegate. Registers
    /// `manager` as a windowless main-window context for the duration of `body`, so its
    /// workspaces are live destinations there too. Call it from synchronous tests only:
    /// the registration is process-global while `body` runs.
    static func withAppRegistration<T>(of manager: TabManager, _ body: () throws -> T) rethrows -> T {
        guard let app = AppDelegate.shared else { return try body() }
        let windowId = app.registerMainWindowContextForTesting(tabManager: manager)
        defer {
            app.unregisterMainWindowContextForTesting(windowId: windowId)
            app.forgetRecoverableMainWindowRoute(windowId: windowId)
        }
        return try body()
    }
}

extension SurfaceCatalog {
    /// A catalog whose local destinations resolve through `live`.
    @MainActor
    convenience init(
        live: LiveWorkspaceFixture,
        cloudPlacementCoordinator: CloudPlacementCoordinator? = nil,
        cloudWorkspaceProjectionCoordinator: CloudWorkspaceProjectionCoordinator? = nil
    ) {
        self.init(
            cloudWorkspaceRenameService: live.renameService,
            cloudPlacementCoordinator: cloudPlacementCoordinator,
            cloudWorkspaceProjectionCoordinator: cloudWorkspaceProjectionCoordinator
        )
    }
}
