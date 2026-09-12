import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite
struct SurfaceCatalogCloudRenameCompatibilityTests {
    @Test("Cursorless machine updates retain genuinely new cloud workspaces")
    func cursorlessMachineUpdateRetainsPendingWorkspaces() throws {
        let machine = SurfaceMachineID.cloud("vivid-newt")
        let catalog = SurfaceCatalog()
        let provider = SurfaceCatalogTests.FakeProvider(machine: machine)
        catalog.register(provider)

        var canonicalInfo = provider.info
        canonicalInfo.remoteWorkspaces = [
            SurfaceRemoteWorkspace(id: "ws", name: "canonical", index: 0, focused: true),
        ]
        #expect(catalog.replaceCloudResources(
            [],
            on: machine,
            info: canonicalInfo,
            cursor: CloudVMCursor(generation: "g1", revision: 1),
            from: provider
        ))

        var pendingInfo = provider.info
        pendingInfo.remoteWorkspaces = [
            SurfaceRemoteWorkspace(id: "ws", name: "stale", index: 0, focused: false),
            SurfaceRemoteWorkspace(id: "pending", name: "new", index: 1, focused: false),
        ]
        catalog.updateMachine(pendingInfo, from: provider)

        #expect(catalog.machines[machine]?.remoteWorkspaces?.map(\.id) == ["ws", "pending"])
        #expect(catalog.machines[machine]?.remoteWorkspaces?.last?.name == "new")
    }

    @Test("Typed cloud state applies optimistic workspace rename overlay")
    func typedCloudStateAppliesWorkspaceRenameOverlay() throws {
        let machine = SurfaceMachineID.cloud("vivid-newt")
        let catalog = SurfaceCatalog()
        let provider = SurfaceCatalogTests.FakeProvider(machine: machine)
        catalog.register(provider)

        let snapshot: [String: Any] = [
            "cursor": ["generation": "g1", "revision": "1"],
            "workspaces": [["id": "ws", "name": "old"]],
            "screens": [],
            "panes": [],
            "tabs": [],
            "terminals": [],
            "browsers": [],
            "agents": [],
        ]
        let state = try #require(CmuxTuiSnapshotParser.state(fromSnapshot: snapshot, machine: machine))
        var info = provider.info
        let workspace = SurfaceRemoteWorkspace(id: "ws", name: "old", index: 0, focused: true)
        info.remoteWorkspaces = [
            workspace,
        ]
        var resource = SurfaceResource(
            id: SurfaceResourceID(machine: machine, kind: .terminal, key: "term"),
            title: "term",
            detail: "/root",
            lifecycle: .running,
            agent: nil,
            remoteWorkspace: workspace,
            port: nil,
            url: nil
        )
        resource.remoteViews = [SurfaceRemoteView(tabID: "tab", workspace: workspace)]
        catalog.replaceCloudState(state, resources: [resource], info: info)

        let initialResource = try #require(catalog.snapshot.resources(on: machine).first)
        #expect(initialResource.remoteWorkspace?.name == "old")
        #expect(initialResource.remoteViews?.map { $0.workspace.name } == ["old"])

        let token = try catalog.beginCloudWorkspaceRename(
            machine: machine,
            workspaceID: "ws",
            name: "new"
        )
        #expect(catalog.machines[machine]?.remoteWorkspaces?.first?.name == "new")

        let renamedResource = try #require(catalog.snapshot.resources(on: machine).first)
        #expect(renamedResource.remoteWorkspace?.name == "new")
        #expect(renamedResource.remoteViews?.map { $0.workspace.name } == ["new"])

        catalog.replaceCloudState(state, resources: [resource], info: info)
        let republishedResource = try #require(catalog.snapshot.resources(on: machine).first)
        #expect(republishedResource.remoteWorkspace?.name == "new")
        #expect(republishedResource.remoteViews?.map { $0.workspace.name } == ["new"])

        _ = catalog.applyCloudStateResourcePatch(
            state,
            resources: [resource],
            affectedResourceIDs: [resource.id],
            info: info
        )
        let patchedResource = try #require(catalog.snapshot.resources(on: machine).first)
        #expect(patchedResource.remoteWorkspace?.name == "new")
        #expect(patchedResource.remoteViews?.map { $0.workspace.name } == ["new"])

        catalog.rollbackCloudWorkspaceRename(token)
        #expect(catalog.machines[machine]?.remoteWorkspaces?.first?.name == "old")

        let restoredResource = try #require(catalog.snapshot.resources(on: machine).first)
        #expect(restoredResource.remoteWorkspace?.name == "old")
        #expect(restoredResource.remoteViews?.map { $0.workspace.name } == ["old"])
    }

    @Test("Typed cloud state retires a committed workspace rename overlay")
    func typedCloudStateRetiresCommittedWorkspaceRenameOverlay() throws {
        let machine = SurfaceMachineID.cloud("vivid-newt")
        let catalog = SurfaceCatalog()
        let provider = SurfaceCatalogTests.FakeProvider(machine: machine)
        catalog.register(provider)

        func state(cursorRevision: String, workspaceName: String) throws -> CloudVMState {
            let snapshot: [String: Any] = [
                "cursor": ["generation": "g1", "revision": cursorRevision],
                "workspaces": [["id": "ws", "name": workspaceName]],
                "screens": [],
                "panes": [],
                "tabs": [],
                "terminals": [],
                "browsers": [],
                "agents": [],
            ]
            return try #require(CmuxTuiSnapshotParser.state(fromSnapshot: snapshot, machine: machine))
        }

        let initialState = try state(cursorRevision: "1", workspaceName: "old")
        var initialInfo = provider.info
        initialInfo.remoteWorkspaces = [
            SurfaceRemoteWorkspace(id: "ws", name: "old", index: 0, focused: true),
        ]
        catalog.replaceCloudState(initialState, resources: [], info: initialInfo)

        let token = try catalog.beginCloudWorkspaceRename(
            machine: machine,
            workspaceID: "ws",
            name: "new"
        )
        catalog.commitCloudWorkspaceRename(
            token,
            receipt: CloudVMCursor(generation: "g1", revision: 2)
        )

        let acceptedState = try state(cursorRevision: "2", workspaceName: "new")
        var acceptedInfo = provider.info
        acceptedInfo.remoteWorkspaces = [
            SurfaceRemoteWorkspace(id: "ws", name: "new", index: 0, focused: true),
        ]
        catalog.replaceCloudState(acceptedState, resources: [], info: acceptedInfo)

        let laterState = try state(cursorRevision: "3", workspaceName: "remote")
        var laterInfo = provider.info
        laterInfo.remoteWorkspaces = [
            SurfaceRemoteWorkspace(id: "ws", name: "remote", index: 0, focused: true),
        ]
        catalog.replaceCloudState(laterState, resources: [], info: laterInfo)

        #expect(catalog.pendingCloudWorkspaceRenameName(machine: machine, workspaceID: "ws") == nil)
        #expect(catalog.machines[machine]?.remoteWorkspaces?.first?.name == "remote")
    }

    @Test("Typed cloud state applies optimistic rename overlays to pending workspaces")
    func typedCloudStateAppliesRenameOverlayToPendingWorkspace() throws {
        let machine = SurfaceMachineID.cloud("vivid-newt")
        let catalog = SurfaceCatalog()
        let provider = SurfaceCatalogTests.FakeProvider(machine: machine)
        catalog.register(provider)

        let snapshot: [String: Any] = [
            "cursor": ["generation": "g1", "revision": "1"],
            "workspaces": [["id": "canonical", "name": "canonical"]],
            "screens": [],
            "panes": [],
            "tabs": [],
            "terminals": [],
            "browsers": [],
            "agents": [],
        ]
        let state = try #require(CmuxTuiSnapshotParser.state(fromSnapshot: snapshot, machine: machine))
        var info = provider.info
        info.remoteWorkspaces = [
            SurfaceRemoteWorkspace(id: "canonical", name: "canonical", index: 0, focused: true),
            SurfaceRemoteWorkspace(id: "pending", name: "pending", index: 1, focused: false),
        ]
        catalog.replaceCloudState(state, resources: [], info: info)

        let token = try catalog.beginCloudWorkspaceRename(
            machine: machine,
            workspaceID: "pending",
            name: "renamed pending"
        )

        #expect(catalog.machines[machine]?.remoteWorkspaces?.map(\.name) == ["canonical", "renamed pending"])
        catalog.rollbackCloudWorkspaceRename(token)
        #expect(catalog.machines[machine]?.remoteWorkspaces?.map(\.name) == ["canonical", "pending"])
    }

    @Test("Typed cloud state keeps committed rename for an unobserved pending workspace")
    func typedCloudStateKeepsCommittedRenameForUnobservedPendingWorkspace() throws {
        let machine = SurfaceMachineID.cloud("vivid-newt")
        let catalog = SurfaceCatalog()
        let provider = SurfaceCatalogTests.FakeProvider(machine: machine)
        catalog.register(provider)

        func state(cursorGeneration: String, cursorRevision: String) throws -> CloudVMState {
            let snapshot: [String: Any] = [
                "cursor": ["generation": cursorGeneration, "revision": cursorRevision],
                "workspaces": [["id": "canonical", "name": "canonical"]],
                "screens": [],
                "panes": [],
                "tabs": [],
                "terminals": [],
                "browsers": [],
                "agents": [],
            ]
            return try #require(CmuxTuiSnapshotParser.state(fromSnapshot: snapshot, machine: machine))
        }

        let initialState = try state(cursorGeneration: "g1", cursorRevision: "1")
        var initialInfo = provider.info
        initialInfo.remoteWorkspaces = [
            SurfaceRemoteWorkspace(id: "canonical", name: "canonical", index: 0, focused: true),
            SurfaceRemoteWorkspace(id: "pending", name: "pending", index: 1, focused: false),
        ]
        catalog.replaceCloudState(initialState, resources: [], info: initialInfo)

        let token = try catalog.beginCloudWorkspaceRename(
            machine: machine,
            workspaceID: "pending",
            name: "renamed pending"
        )
        catalog.commitCloudWorkspaceRename(
            token,
            receipt: CloudVMCursor(generation: "g1", revision: 2)
        )

        let newerState = try state(cursorGeneration: "g1", cursorRevision: "3")
        var newerInfo = provider.info
        newerInfo.remoteWorkspaces = initialInfo.remoteWorkspaces
        catalog.replaceCloudState(newerState, resources: [], info: newerInfo)

        #expect(catalog.pendingCloudWorkspaceRenameName(machine: machine, workspaceID: "pending") == "renamed pending")
        #expect(catalog.machines[machine]?.remoteWorkspaces?.map(\.name) == ["canonical", "renamed pending"])
    }
}
