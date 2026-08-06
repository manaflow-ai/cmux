import Bonsplit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite
struct PaneDropTargetOverlaySnapshotTests {
    @Test
    func snapshotTracksOnlyRoutingContext() {
        let context = PaneDropContext(
            workspaceId: UUID(),
            panelId: UUID(),
            paneId: PaneID(id: UUID())
        )

        #expect(
            PaneDropTargetOverlaySnapshot(dropContext: context)
                == PaneDropTargetOverlaySnapshot(dropContext: context)
        )
        #expect(
            PaneDropTargetOverlaySnapshot(dropContext: context)
                != PaneDropTargetOverlaySnapshot(dropContext: nil)
        )
        #expect(
            PaneDropTargetOverlaySnapshot(dropContext: context)
                != PaneDropTargetOverlaySnapshot(dropContext: PaneDropContext(
                    workspaceId: context.workspaceId,
                    panelId: UUID(),
                    paneId: context.paneId
                ))
        )
        #expect(
            PaneDropTargetOverlaySnapshot(dropContext: context)
                != PaneDropTargetOverlaySnapshot(dropContext: PaneDropContext(
                    workspaceId: UUID(),
                    panelId: context.panelId,
                    paneId: context.paneId
                ))
        )
        #expect(
            PaneDropTargetOverlaySnapshot(dropContext: context)
                != PaneDropTargetOverlaySnapshot(dropContext: PaneDropContext(
                    workspaceId: context.workspaceId,
                    panelId: context.panelId,
                    paneId: PaneID(id: UUID())
                ))
        )
    }
}
