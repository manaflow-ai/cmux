import CmuxSurfaceCatalogModel
import Foundation
import Observation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite
struct SurfaceCatalogObservationTests {
    @Test("Rebuilding Cloud membership during an observed read does not publish")
    func invalidatedReadDoesNotPublish() async {
        let catalog = SurfaceCatalog()
        let workspaceID = UUID()
        let panelID = UUID()
        #expect(!catalog.hasCloudProjection(panelID: panelID, workspaceID: workspaceID))

        await confirmation("A membership read must not invalidate another reader", expectedCount: 0) { changed in
            withObservationTracking {
                _ = catalog.hasCloudProjection(panelID: panelID, workspaceID: workspaceID)
            } onChange: {
                // Observation delivers willSet. Re-subscribe before the mutation
                // completes, leaving an observer installed when the next read
                // rebuilds the invalidated index. Tracking only that next read
                // would miss writes made before its onChange is installed.
                MainActor.assumeIsolated {
                    withObservationTracking {
                        _ = catalog.hasCloudProjection(panelID: panelID, workspaceID: workspaceID)
                    } onChange: {
                        changed()
                    }
                }
            }

            catalog.record(SurfaceProjection(
                resource: SurfaceResourceID(machine: .local, kind: .terminal, key: "local"),
                workspaceID: workspaceID,
                panelID: panelID
            ))
            withObservationTracking {
                #expect(!catalog.hasCloudProjection(panelID: panelID, workspaceID: workspaceID))
            } onChange: {
                changed()
            }
        }
    }

    @Test("Live projection changes invalidate cold and warm membership readers", arguments: [false, true])
    func liveProjectionChangesNotify(warmCache: Bool) async {
        let catalog = SurfaceCatalog()
        let projection = projection()
        if warmCache {
            #expect(!hasProjection(catalog, projection))
        }
        await expectChange(catalog, projection, from: false, to: true) {
            catalog.record(projection)
        }
        var reconciled = projection
        reconciled.workspaceID = UUID()
        await expectChange(catalog, projection, from: true, to: false) {
            // This path mutates only live projections. A no-op pending-restore
            // mutation must not be able to satisfy the notification assertion.
            catalog.reconcileRemotePlacements([projection: reconciled])
        }
        #expect(hasProjection(catalog, reconciled))
        await expectChange(catalog, reconciled, from: true, to: false) {
            catalog.endProjections(panelID: projection.panelID)
        }
    }

    @Test("Moving a live projection updates both workspace memberships")
    func liveProjectionMove() async {
        let catalog = SurfaceCatalog()
        let original = projection()
        var moved = original
        moved.workspaceID = UUID()
        catalog.record(original)
        #expect(hasProjection(catalog, original))
        #expect(!hasProjection(catalog, moved))

        await expectChange(catalog, original, from: true, to: false) {
            catalog.moveProjections(panelID: original.panelID, to: moved.workspaceID)
        }
        #expect(hasProjection(catalog, moved))
        #expect(!catalog.hasCloudProjection(panelID: UUID(), workspaceID: moved.workspaceID))
        await expectChange(catalog, moved, from: true, to: false) {
            catalog.unregister(machine: moved.resource.machine)
        }
    }

    @Test("Pending restore changes invalidate cold and warm membership readers", arguments: [false, true])
    func pendingRestoreChangesNotify(warmCache: Bool) async {
        let catalog = SurfaceCatalog()
        let workspace = Workspace(initialSurface: .cloudVMLoading)
        defer { workspace.teardownAllPanels() }
        let pending = projection(workspaceID: workspace.id)
        if warmCache {
            #expect(!hasProjection(catalog, pending))
        }

        await expectChange(catalog, pending, from: false, to: true) {
            catalog.restore(
                [SurfaceProjectionRecord(panelID: pending.panelID, resource: pending.resource)],
                workspaceID: workspace.id,
                restoringWorkspace: workspace
            )
        }
        var moved = pending
        moved.workspaceID = UUID()
        await expectChange(catalog, pending, from: true, to: false) {
            catalog.moveProjections(panelID: pending.panelID, to: moved.workspaceID)
        }
        #expect(hasProjection(catalog, moved))
        await expectChange(catalog, moved, from: true, to: false) {
            catalog.endProjections(panelID: pending.panelID)
        }
    }

    @Test("Consuming a staged identity invalidates its cached membership")
    func consumedRestoreIsNoLongerCloudBacked() async {
        let catalog = SurfaceCatalog()
        let workspace = Workspace(initialSurface: .cloudVMLoading)
        defer { workspace.teardownAllPanels() }
        let pending = projection(workspaceID: workspace.id)
        catalog.restore(
            [SurfaceProjectionRecord(panelID: pending.panelID, resource: pending.resource)],
            workspaceID: workspace.id,
            restoringWorkspace: workspace
        )
        #expect(hasProjection(catalog, pending))

        await expectChange(catalog, pending, from: true, to: false) {
            catalog.consumePendingProjectionIfMaterialized(pending)
        }
    }

    private func projection(workspaceID: UUID = UUID()) -> SurfaceProjection {
        SurfaceProjection(
            resource: SurfaceResourceID(machine: .cloud("observation-test"), kind: .terminal, key: "terminal"),
            workspaceID: workspaceID,
            panelID: UUID()
        )
    }

    private func hasProjection(_ catalog: SurfaceCatalog, _ projection: SurfaceProjection) -> Bool {
        catalog.hasCloudProjection(panelID: projection.panelID, workspaceID: projection.workspaceID)
    }

    private func expectChange(
        _ catalog: SurfaceCatalog,
        _ projection: SurfaceProjection,
        from before: Bool,
        to after: Bool,
        mutation: () -> Void
    ) async {
        await confirmation("Projection changes invalidate membership readers") { changed in
            withObservationTracking {
                #expect(hasProjection(catalog, projection) == before)
            } onChange: {
                changed()
            }
            mutation()
            #expect(hasProjection(catalog, projection) == after)
        }
    }
}
