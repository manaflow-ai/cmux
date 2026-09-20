import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The three places a Cloud workspace name is painted (#12986): the left
/// workspace sidebar row, the window title bar (the custom title bar,
/// `NSWindow.title` and the toolbar label all derive from
/// `TabManager.resolvedWorkspaceDisplayTitle`), and the workspace row under the
/// machine in the Cloud tree.
struct CloudWorkspaceNameSurfaces: Equatable, Sendable {
    let sidebarRow: String
    let titleBar: String
    let cloudTree: String?

    static func all(_ name: String) -> Self {
        Self(sidebarRow: name, titleBar: name, cloudTree: name)
    }
}

/// A local rename entry point. Sidebar inline rename, Cmd+Shift+R, the command
/// palette and the row context menu all call `TabManager.setCustomTitle`;
/// `cmux workspace rename` / `cmux rename-workspace` arrive as `workspace.rename`.
enum CloudWorkspaceLocalRenamePath: String, CaseIterable, Sendable {
    case tabManager
    case socket
}

/// How a session manifest recorded a Cloud workspace's title provenance.
enum CloudWorkspaceManifestVintage: String, CaseIterable, Sendable {
    /// The current encoder: `user` plus the `customTitleWasRemote` marker.
    case current
    /// A build that knew `user`/`auto` but not the remote marker.
    case remoteMarkerDropped
    /// A build that recorded no provenance at all (decodes as user-owned).
    case noProvenance
}

/// Drives the shared catalog, the in-memory daemon and one local workspace the
/// way the app does, and reads back every surface that shows the name.
@MainActor
private final class CloudWorkspaceRenameParityHarness {
    let fixture: CloudNameAuthorityFixture
    let settings: SidebarTabItemSettingsSnapshot
    private let originalService: CloudWorkspaceRenameService

    init() throws {
        fixture = try CloudNameAuthorityFixture()
        settings = SidebarTabItemSettingsSnapshot(
            defaults: try #require(UserDefaults(suiteName: "cloud-rename-parity-\(UUID().uuidString)"))
        )
        originalService = fixture.catalog.cloudWorkspaceRenameService
        fixture.catalog.installCloudWorkspaceRenameService(fixture.renameService)
    }

    func close() async {
        fixture.catalog.installCloudWorkspaceRenameService(originalService)
        await fixture.close()
    }

    var workspace: Workspace { fixture.workspace }
    var manager: TabManager { fixture.manager }
    var catalog: SurfaceCatalog { fixture.catalog }
    var provider: CloudNameAuthorityTestProvider { fixture.provider }
    var machine: SurfaceMachineID { fixture.provider.machine }

    func surfaces(of workspace: Workspace? = nil) -> CloudWorkspaceNameSurfaces {
        let workspace = workspace ?? fixture.workspace
        let sidebarRow = SidebarWorkspaceSnapshotFactory(
            workspace: workspace, settings: settings, showsAgentActivity: false
        ).makeSnapshot().title
        let titleBar = manager.resolvedWorkspaceDisplayTitle(for: workspace)
        let nodes = CloudTreeNodeBuilder.flattened(CloudTreeNodeBuilder.nodes(
            machines: [], snapshot: catalog.snapshot, localWorkspaces: [], includeLocalMachine: false
        ))
        let workspaceNodeID = CloudTreeNodeBuilder.nodeID(workspace: "a", machine: machine)
        var cloudTree: String?
        if let node = nodes.first(where: { $0.id == workspaceNodeID }),
           case .workspace(_, let remote, _, _, _) = node.kind {
            // The value `CloudTreeRowContentView` paints for a workspace row.
            cloudTree = remote.name
        }
        return CloudWorkspaceNameSurfaces(sidebarRow: sidebarRow, titleBar: titleBar, cloudTree: cloudTree)
    }

    func projectPane(workspaceID: UUID, panelID: UUID) {
        catalog.record(SurfaceProjection(
            resource: .init(machine: machine, kind: .terminal, key: "term_a"),
            workspaceID: workspaceID, panelID: panelID,
            remoteWorkspaceID: "a", remoteTabID: "tab_a"
        ))
    }

    /// The ordinary way a Cloud workspace acquires a user-owned title: the user
    /// renames it while `cmux vm new` is still discovering the remote identity.
    /// The intent is submitted at the first identity binding and confirmed by
    /// the daemon, and the equal confirmation keeps user provenance.
    func renameDuringCreation(_ name: String) async throws {
        catalog.endProjections(panelID: fixture.panelID, reason: .replaced)
        workspace.cloudVMBinding = nil
        #expect(manager.setCustomTitle(tabId: workspace.id, title: name))
        #expect(workspace.effectiveCustomTitleSource == .user)
        catalog.bindCloudWorkspace(
            localWorkspaceID: workspace.id, machine: machine, remoteWorkspaceID: "a", generatedTitle: "Cloud VM"
        )
        try await fixture.settle()
        projectPane(workspaceID: workspace.id, panelID: fixture.panelID)
        #expect(provider.graph.lookupIndex.workspace(id: "a")?.name == name)
        #expect(workspace.effectiveCustomTitleSource == .user)
        #expect(surfaces() == .all(name))
    }

    /// Another client (cmux-tui on the VM, a second Mac) renamed the daemon
    /// workspace: the accepted graph changes without any local intent.
    func renameFromAnotherClient(_ name: String) throws {
        var document = try #require(provider.graph.snapshotObject())
        let cursor = try #require(provider.graph.cursor)
        document["cursor"] = ["generation": cursor.generation, "revision": String(cursor.revision + 1)]
        var workspaces = try #require(document["workspaces"] as? [[String: Any]])
        let index = try #require(workspaces.firstIndex { $0["id"] as? String == "a" })
        workspaces[index]["name"] = name
        document["workspaces"] = workspaces
        #expect(provider.install(try #require(CmuxTuiSnapshotParser.state(fromSnapshot: document, machine: machine))))
    }

    /// The Cloud tree's "Rename…" action: `CloudTreeNodeActions.renameWorkspace`
    /// calls exactly this on the catalog and never touches the local workspace.
    func renameFromCloudTree(_ name: String) async throws {
        try await catalog.renameRemoteWorkspace(on: machine, id: "a", name: name)
    }

    /// Persists the workspace the way session save does, then rewrites the
    /// provenance fields the way the given build vintage would have.
    func manifest(_ vintage: CloudWorkspaceManifestVintage) throws -> SessionWorkspaceSnapshot {
        var saved = try JSONDecoder().decode(
            SessionWorkspaceSnapshot.self,
            from: JSONEncoder().encode(workspace.sessionSnapshot(includeScrollback: false))
        )
        switch vintage {
        case .current:
            #expect(saved.customTitleWasRemote == true)
        case .remoteMarkerDropped:
            saved.customTitleWasRemote = nil
        case .noProvenance:
            saved.customTitleWasRemote = nil
            saved.customTitleSource = nil
        }
        return saved
    }
}

/// Regression coverage for #12986: renaming a Cloud workspace must move the
/// left sidebar row, the title bar and the Cloud tree together on every rename
/// path, and they must still agree after a refresh, a workspace switch and a
/// session restore. Serialized because the fixture goes through the shared
/// `SurfaceCatalog` and `TerminalController`.
@MainActor
@Suite(.serialized)
struct CloudWorkspaceRenameSurfaceParityTests {
    private func withHarness(_ body: (CloudWorkspaceRenameParityHarness) async throws -> Void) async throws {
        let harness = try CloudWorkspaceRenameParityHarness()
        do { try await body(harness) } catch {
            await harness.close()
            throw error
        }
        await harness.close()
    }

    @Test("A Cloud tree rename of a user-titled workspace reaches the sidebar row and the title bar")
    func cloudTreeRenameReachesEverySurface() async throws {
        try await withHarness { harness in
            #expect(harness.surfaces() == .all("Same workspace"))
            try await harness.renameDuringCreation("Chosen during creation")

            try await harness.renameFromCloudTree("Renamed in tree")
            #expect(harness.surfaces() == .all("Renamed in tree"))
            await harness.provider.refresh()
            #expect(harness.surfaces() == .all("Renamed in tree"))

            // Renaming again from the tree, then locally, keeps converging.
            try await harness.renameFromCloudTree("Renamed in tree again")
            #expect(harness.surfaces() == .all("Renamed in tree again"))
            #expect(harness.manager.setCustomTitle(tabId: harness.workspace.id, title: "Renamed locally"))
            try await harness.fixture.settle()
            #expect(harness.surfaces() == .all("Renamed locally"))
        }
    }

    @Test("Every local rename path converges the three surfaces of a user-titled workspace",
          arguments: CloudWorkspaceLocalRenamePath.allCases)
    func localRenamePathsConverge(path: CloudWorkspaceLocalRenamePath) async throws {
        try await withHarness { harness in
            try await harness.renameDuringCreation("Chosen during creation")
            let name = "Renamed via \(path.rawValue)"
            switch path {
            case .tabManager:
                #expect(harness.manager.setCustomTitle(tabId: harness.workspace.id, title: name))
            case .socket:
                _ = try await harness.fixture.call("workspace.rename", extra: ["title": name])
            }
            // Cloud names are not speculative: the rename lands on every surface
            // together when the daemon's accepted graph comes back.
            try await harness.fixture.settle()
            #expect(harness.surfaces() == .all(name))
            await harness.provider.refresh()
            #expect(harness.surfaces() == .all(name))
        }
    }

    @Test("A rename from another client replaces a user-owned title everywhere and survives refresh and workspace switches")
    func otherClientRenameConverges() async throws {
        try await withHarness { harness in
            try await harness.renameDuringCreation("Chosen during creation")
            try harness.renameFromAnotherClient("Renamed from cmux-tui")
            #expect(harness.surfaces() == .all("Renamed from cmux-tui"))

            let other = try #require(harness.manager.addWorkspaceIfActive(
                title: "Other", select: true, autoWelcomeIfNeeded: false
            ))
            defer { for panel in other.panels.values { panel.close() } }
            #expect(harness.manager.selectedTabId == other.id)
            #expect(harness.manager.resolvedWorkspaceDisplayTitle(forWorkspaceId: harness.workspace.id) == "Renamed from cmux-tui")
            harness.manager.selectTab(harness.workspace)
            #expect(harness.manager.selectedTabId == harness.workspace.id)
            await harness.provider.refresh()
            #expect(harness.surfaces() == .all("Renamed from cmux-tui"))
            #expect(harness.workspace.effectiveCustomTitleSource == .remote)
        }
    }

    @Test("A restored workspace converges on the daemon name whatever build wrote its manifest",
          arguments: CloudWorkspaceManifestVintage.allCases)
    func restoreConvergesOnDaemonName(vintage: CloudWorkspaceManifestVintage) async throws {
        try await withHarness { harness in
            try await harness.renameFromCloudTree("Named before quit")
            #expect(harness.surfaces() == .all("Named before quit"))
            let saved = try harness.manifest(vintage)

            // The daemon workspace was renamed while this Mac was not running.
            try harness.renameFromAnotherClient("Renamed while quit")

            let restored = Workspace()
            let panelMap = restored.restoreSessionSnapshot(saved)
            let restoredPanelID = try #require(panelMap[harness.fixture.panelID])
            defer { for panel in restored.panels.values { panel.close() } }
            harness.manager.tabs = [restored]
            #expect(restored.cloudVMBinding?.remoteWorkspaceID == "a")
            #expect(restored.title == "Named before quit")

            // Re-projecting the pane and the reconnect publish both apply the
            // accepted graph; either alone must already converge.
            harness.catalog.endProjections(panelID: harness.fixture.panelID, reason: .replaced)
            harness.projectPane(workspaceID: restored.id, panelID: restoredPanelID)
            #expect(harness.surfaces(of: restored) == .all("Renamed while quit"))
            await harness.provider.refresh()
            #expect(harness.surfaces(of: restored) == .all("Renamed while quit"))
            #expect(restored.effectiveCustomTitleSource == .remote)
            harness.catalog.endProjections(panelID: restoredPanelID, reason: .replaced)
        }
    }

    @Test("A rejected rename leaves every surface on the accepted name")
    func rejectedRenameKeepsSurfacesTogether() async throws {
        try await withHarness { harness in
            try await harness.renameFromCloudTree("Accepted name")
            #expect(harness.surfaces() == .all("Accepted name"))
            harness.provider.beforeRename = { throw SurfaceCatalogError.unsupported("refused by daemon") }

            #expect(harness.manager.setCustomTitle(tabId: harness.workspace.id, title: "Refused locally"))
            await #expect(throws: SurfaceCatalogError.self) { try await harness.fixture.settle() }
            #expect(harness.surfaces() == .all("Accepted name"))

            await #expect(throws: SurfaceCatalogError.self) { try await harness.renameFromCloudTree("Refused in tree") }
            #expect(harness.surfaces() == .all("Accepted name"))
            await harness.provider.refresh()
            #expect(harness.surfaces() == .all("Accepted name"))
        }
    }

    @Test("A creation-time rename outranks an older snapshot only while its intent is unacknowledged")
    func creationRaceIsScopedToThePendingIntent() async throws {
        try await withHarness { harness in
            let oldGraph = harness.provider.graph
            harness.catalog.endProjections(panelID: harness.fixture.panelID, reason: .replaced)
            harness.workspace.cloudVMBinding = nil
            #expect(harness.manager.setCustomTitle(tabId: harness.workspace.id, title: "Chosen during creation"))

            let gate = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            harness.provider.beforeRename = { for await _ in gate.stream { break } }
            harness.catalog.bindCloudWorkspace(
                localWorkspaceID: harness.workspace.id, machine: harness.machine,
                remoteWorkspaceID: "a", generatedTitle: "Cloud VM"
            )
            let key = CloudRenameCoordinator.Key.workspace(machine: harness.machine, id: "a")
            #expect(harness.catalog.pendingCloudRenameName(for: key) == "Chosen during creation")

            // The older snapshot arrives while the intent is still unacknowledged.
            harness.fixture.renameService.reconcileRemoteState(
                machine: harness.machine, state: oldGraph, catalog: harness.catalog, observation: .current
            )
            #expect(harness.workspace.title == "Chosen during creation")
            #expect(harness.surfaces().cloudTree == "Chosen during creation")
            #expect(
                harness.catalog.authoritativeSnapshot.machines
                    .first(where: { $0.id == harness.machine })?
                    .remoteWorkspaces?
                    .first(where: { $0.id == "a" })?.name == "Same workspace"
            )

            gate.continuation.yield(())
            gate.continuation.finish()
            try await harness.fixture.settle()
            harness.projectPane(workspaceID: harness.workspace.id, panelID: harness.fixture.panelID)
            #expect(harness.catalog.pendingCloudRenameName(for: key) == nil)
            #expect(harness.surfaces() == .all("Chosen during creation"))
            #expect(harness.provider.writes.map { $0.1 } == ["Chosen during creation"])
        }
    }
}
