import CmuxSurfaceCatalogModel
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Cloud agent hook projection")
struct CloudAgentHookProjectionTests {
    @Test("Mirrored hooks prefer the projection in the accepted remote workspace")
    func prefersAcceptedRemoteWorkspaceProjection() {
        let machine = SurfaceMachineID.ssh("builder")
        let resource = SurfaceResourceID(machine: machine, kind: .terminal, key: "term_build")
        let local = SurfaceProjection(
            resource: resource,
            workspaceID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            panelID: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
            remoteWorkspaceID: "remote-local"
        )
        let cloud = SurfaceProjection(
            resource: resource,
            workspaceID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            panelID: UUID(uuidString: "00000000-0000-0000-0000-000000000022")!,
            remoteWorkspaceID: "remote-cloud"
        )

        let selected = CmuxTuiSurfaceProvider.mirroredAgentHookProjection(
            projections: [local, cloud], remoteWorkspaceIDs: ["remote-cloud"]
        )
        #expect(selected == cloud)
        #expect(
            CmuxTuiSurfaceProvider.mirroredAgentHookProjection(
                projections: [local, cloud], remoteWorkspaceIDs: ["remote-missing"]
            ) == nil,
            "an accepted workspace mismatch must not fall through to the adjacent pane"
        )
        #expect(
            CmuxTuiSurfaceProvider.mirroredAgentHookProjection(
                projections: [local, cloud], remoteWorkspaceIDs: []
            ) == local,
            "legacy snapshots without a workspace identity retain catalog order"
        )
        #expect(
            CmuxTuiSurfaceProvider.mirroredAgentHookProjection(
                projections: [cloud], remoteWorkspaceIDs: ["remote-elsewhere", "remote-cloud"]
            ) == cloud,
            "a terminal shown in several remote workspaces routes to whichever one is open here"
        )
        let unscoped = SurfaceProjection(
            resource: resource,
            workspaceID: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            panelID: UUID(uuidString: "00000000-0000-0000-0000-000000000033")!,
            remoteWorkspaceID: nil
        )
        #expect(
            CmuxTuiSurfaceProvider.mirroredAgentHookProjection(
                projections: [local, unscoped], remoteWorkspaceIDs: ["remote-cloud"]
            ) == unscoped,
            "a projection without a workspace identity still receives hooks"
        )
    }
}
