import Foundation
import CmuxSurfaceCatalogModel
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Cloud workspace projection reconciliation")
struct CloudWorkspaceProjectionPlanTests {
    private let machine = SurfaceMachineID.cloud("desktop-plan")

    @Test("A local Desktop preview survives a refresh with a remote placement")
    func localDisplayPreviewIsNotClosedAsObsolete() {
        let display = SurfaceResourceID(machine: machine, kind: .display, key: "display:1")
        let preview = SurfaceProjection(
            resource: display,
            workspaceID: UUID(),
            panelID: UUID(),
            remoteWorkspaceID: "remote-workspace"
        )
        let desired = SurfaceResourcePlacement(
            resource: display,
            remoteWorkspaceID: "remote-workspace",
            remoteTabID: "remote-tab"
        )

        let plan = CloudWorkspaceProjectionPlan(desired: [desired], existing: [preview])

        #expect(plan.obsolete.isEmpty)
        #expect(plan.missing == [desired])
    }

    @Test("A preview whose remote placement was deleted is retired")
    func deletedRemotePlacementIsNotMistakenForPreview() {
        let display = SurfaceResourceID(machine: machine, kind: .display, key: "display:1")
        let deleted = SurfaceProjection(resource: display, workspaceID: UUID(), panelID: UUID())
        let plan = CloudWorkspaceProjectionPlan(desired: [], existing: [deleted])

        #expect(plan.obsolete == [deleted])
        #expect(plan.missing.isEmpty)
    }

    @Test("A stale remote terminal remains eligible for reconciliation")
    func staleRemotePlacementIsObsolete() {
        let terminal = SurfaceResourceID(machine: machine, kind: .terminal, key: "terminal-1")
        let existing = SurfaceProjection(
            resource: terminal,
            workspaceID: UUID(),
            panelID: UUID(),
            remoteWorkspaceID: "old-workspace",
            remoteTabID: "old-tab"
        )
        let desired = SurfaceResourcePlacement(
            resource: terminal,
            remoteWorkspaceID: "new-workspace",
            remoteTabID: "new-tab"
        )

        let plan = CloudWorkspaceProjectionPlan(desired: [desired], existing: [existing])

        #expect(plan.obsolete == [existing])
        #expect(plan.missing == [desired])
    }
}
