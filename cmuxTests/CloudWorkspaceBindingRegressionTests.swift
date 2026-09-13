import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite
struct CloudWorkspaceBindingRegressionTests {
    private static let machine = SurfaceMachineID.cloud("vivid-newt")
    private static let workspace = SurfaceRemoteWorkspace(id: "ws_api", name: "api", index: 0, focused: true)

    private static func state(workspaces: [[String: Any]]) throws -> CloudVMState {
        try #require(CmuxTuiSnapshotParser.state(fromSnapshot: [
            "cursor": ["generation": "g", "revision": "12"],
            "workspaces": workspaces,
            "screens": [["id": "screen", "workspace_id": workspaces[0]["id"] as? String ?? ""]],
            "panes": [["id": "pane", "screen_id": "screen"]],
            "tabs": [["id": "tab", "pane_id": "pane", "content_kind": "terminal", "content_id": "term_1"]],
            "terminals": [["id": "term_1", "tab_ids": ["tab"]]],
            "browsers": [], "agents": [],
        ], machine: Self.machine))
    }

    @Test func aDeletedBoundWorkspaceCannotRouteCreationBackToItsStaleID() {
        let bound = UUID()
        let coordinator = CloudPlacementCoordinator(binding: { id in
            id == bound
                ? WorkspaceCloudVMBinding(vmID: "vivid-newt", isBase: false, remoteWorkspaceID: "ws_deleted")
                : nil
        }, workspaceExists: { _, remoteID in remoteID == "ws_deleted" ? false : nil })
        let resource = SurfaceResource(
            id: SurfaceResourceID(machine: Self.machine, kind: .terminal, key: "term_1"),
            title: "term_1", detail: "/root", lifecycle: .running, agent: nil,
            remoteWorkspace: Self.workspace,
            remoteViews: [SurfaceRemoteView(tabID: "tab_1", workspace: Self.workspace)],
            port: nil, url: nil
        )

        #expect(coordinator.creationWorkspaceID(in: bound, near: resource) == "ws_api")

        let detached = SurfaceResource(
            id: resource.id,
            title: resource.title,
            detail: resource.detail,
            lifecycle: resource.lifecycle,
            agent: resource.agent,
            remoteWorkspace: nil,
            remoteViews: [],
            port: nil,
            url: nil
        )
        #expect(coordinator.creationWorkspaceID(in: bound, near: detached) == nil)
    }

    @Test func mixedRemotePlacementsUseTheSelectedAnchorAndNeverTheFocusedWorkspace() {
        let bound = UUID()
        let coordinator = CloudPlacementCoordinator(binding: { id in
            id == bound
                ? WorkspaceCloudVMBinding(vmID: "vivid-newt", isBase: false, remoteWorkspaceID: "ws_deleted")
                : nil
        }, workspaceExists: { _, _ in false })
        let other = SurfaceRemoteWorkspace(id: "ws_other", name: "other", index: 1, focused: false)
        let resource = SurfaceResource(
            id: SurfaceResourceID(machine: Self.machine, kind: .terminal, key: "term_1"),
            title: "term_1", detail: "/root", lifecycle: .running, agent: nil,
            remoteWorkspace: Self.workspace,
            remoteViews: [
                SurfaceRemoteView(tabID: "tab_1", workspace: Self.workspace),
                SurfaceRemoteView(tabID: "tab_2", workspace: other),
            ],
            port: nil, url: nil
        )

        #expect(coordinator.creationWorkspaceID(in: bound, near: resource) == nil)
        #expect(coordinator.creationWorkspaceID(in: bound, near: resource, preferredRemoteWorkspaceID: "ws_other") == "ws_other")
    }

    @Test func aSelectedLivePlacementOverridesAnotherLiveWorkspaceBinding() {
        let bound = UUID()
        let coordinator = CloudPlacementCoordinator(binding: { id in
            id == bound
                ? WorkspaceCloudVMBinding(vmID: "vivid-newt", isBase: false, remoteWorkspaceID: "ws_api")
                : nil
        }, workspaceExists: { _, remoteID in ["ws_api", "ws_other"].contains(remoteID) })
        let other = SurfaceRemoteWorkspace(id: "ws_other", name: "other", index: 1, focused: false)
        let resource = SurfaceResource(
            id: SurfaceResourceID(machine: Self.machine, kind: .terminal, key: "term_1"),
            title: "term_1", detail: "/root", lifecycle: .running, agent: nil,
            remoteWorkspace: Self.workspace,
            remoteViews: [
                SurfaceRemoteView(tabID: "tab_1", workspace: Self.workspace),
                SurfaceRemoteView(tabID: "tab_2", workspace: other),
            ],
            port: nil, url: nil
        )

        #expect(coordinator.creationWorkspaceID(in: bound, near: resource, preferredRemoteWorkspaceID: "ws_other") == "ws_other")
    }

    @Test func authoritativeDeletionRebindsOneSurvivingProjectedWorkspace() throws {
        let service = CloudWorkspaceRenameService()
        let state = try Self.state(workspaces: [["id": "ws_api", "name": "api"]])
        let resource = SurfaceResource(
            id: SurfaceResourceID(machine: Self.machine, kind: .terminal, key: "term_1"),
            title: "term_1", detail: nil, lifecycle: .running, agent: nil,
            remoteWorkspace: Self.workspace,
            remoteViews: [SurfaceRemoteView(tabID: "tab_1", workspace: Self.workspace)],
            port: nil, url: nil
        )
        let projection = SurfaceProjection(
            resource: resource.id,
            workspaceID: UUID(),
            panelID: UUID(),
            remoteWorkspaceID: "ws_api",
            remoteTabID: "tab_1"
        )

        #expect(
            service.bindingReconciliation(
                binding: WorkspaceCloudVMBinding(vmID: "vivid-newt", isBase: false, remoteWorkspaceID: "ws_deleted"),
                machine: Self.machine,
                state: state,
                observation: .current,
                projections: [projection],
                resources: [resource]
            ) == .rebind(machine: Self.machine, remoteWorkspaceID: "ws_api")
        )
    }

    @Test func authoritativeDeletionUsesTheSharedResourceLookup() throws {
        let service = CloudWorkspaceRenameService()
        let state = try Self.state(workspaces: [["id": "ws_api", "name": "api"]])
        let resource = SurfaceResource(
            id: SurfaceResourceID(machine: Self.machine, kind: .terminal, key: "term_1"),
            title: "term_1", detail: nil, lifecycle: .running, agent: nil,
            remoteWorkspace: Self.workspace,
            remoteViews: [SurfaceRemoteView(tabID: "tab_1", workspace: Self.workspace)],
            port: nil, url: nil
        )
        let projection = SurfaceProjection(
            resource: resource.id, workspaceID: UUID(), panelID: UUID(),
            remoteWorkspaceID: "ws_api", remoteTabID: "tab_1"
        )
        #expect(service.bindingReconciliation(
            binding: WorkspaceCloudVMBinding(vmID: "vivid-newt", isBase: false, remoteWorkspaceID: "ws_deleted"),
            machine: Self.machine, state: state, observation: .current,
            projections: [projection], resources: [], resourcesByID: [resource.id: resource]
        ) == .rebind(machine: Self.machine, remoteWorkspaceID: "ws_api"))
    }

    @Test func authoritativeDeletionClearsMixedOrEmptyBindingWithoutMovingPanes() throws {
        let service = CloudWorkspaceRenameService()
        let other = SurfaceRemoteWorkspace(id: "ws_other", name: "other", index: 1, focused: false)
        let state = try Self.state(workspaces: [
            ["id": "ws_api", "name": "api"], ["id": "ws_other", "name": "other"],
        ])
        let first = SurfaceResource(
            id: SurfaceResourceID(machine: Self.machine, kind: .terminal, key: "term_1"),
            title: "term_1", detail: nil, lifecycle: .running, agent: nil,
            remoteWorkspace: Self.workspace,
            remoteViews: [SurfaceRemoteView(tabID: "tab_1", workspace: Self.workspace)],
            port: nil, url: nil
        )
        let second = SurfaceResource(
            id: SurfaceResourceID(machine: Self.machine, kind: .terminal, key: "term_2"),
            title: "term_2", detail: nil, lifecycle: .running, agent: nil,
            remoteWorkspace: other,
            remoteViews: [SurfaceRemoteView(tabID: "tab_2", workspace: other)],
            port: nil, url: nil
        )
        let localWorkspaceID = UUID()
        let projections = [
            SurfaceProjection(resource: first.id, workspaceID: localWorkspaceID, panelID: UUID(), remoteWorkspaceID: "ws_api", remoteTabID: "tab_1"),
            SurfaceProjection(resource: second.id, workspaceID: localWorkspaceID, panelID: UUID(), remoteWorkspaceID: "ws_other", remoteTabID: "tab_2"),
        ]

        #expect(
            service.bindingReconciliation(
                binding: WorkspaceCloudVMBinding(vmID: "vivid-newt", isBase: false, remoteWorkspaceID: "ws_deleted"),
                machine: Self.machine,
                state: state,
                observation: .current,
                projections: projections,
                resources: [first, second]
            ) == .clear
        )
        #expect(
            service.bindingReconciliation(
                binding: WorkspaceCloudVMBinding(vmID: "vivid-newt", isBase: false, remoteWorkspaceID: "ws_deleted"),
                machine: Self.machine,
                state: state,
                observation: .stale(reason: "offline"),
                projections: projections,
                resources: [first, second]
        ) == .keep
        )
    }

    @Test func cloudCreationErrorsNameTheMissingWorkspaceAndPlacementSeparately() {
        let workspace = CmuxTuiSurfaceProvider.ProviderError.remoteWorkspaceNotFound("ws_deleted")
        let placement = CmuxTuiSurfaceProvider.ProviderError.remotePlacementUnavailable("ws_api")
        let tab = CmuxTuiSurfaceProvider.ProviderError.remoteTabNotFound("tab_gone")

        #expect(workspace.errorDescription?.lowercased().contains("remote workspace ws_deleted") == true)
        #expect(placement.errorDescription?.lowercased().contains("remote workspace ws_api has no available terminal placement") == true)
        #expect(tab.errorDescription?.lowercased().contains("remote tab tab_gone") == true)
    }
}
