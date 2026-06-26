import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// Regression coverage for the "Redraw Window" escape hatch (issue #6031): the
// command-palette / View-menu action must re-run the geometry reconcile + repaint
// pass on the selected workspace only, never on background workspaces.
@MainActor
@Suite(.serialized)
struct TabManagerRedrawSurfacesTests {
    @Test func redrawVisibleSurfacesRoutesToSelectedWorkspaceOnly() {
        let manager = TabManager()
        let first = manager.tabs[0]
        let second = manager.addWorkspace()

        guard let selected = manager.selectedWorkspace else {
            Issue.record("Expected a selected workspace")
            return
        }
        let other = selected.id == first.id ? second : first

        #expect(selected.redrawVisibleSurfacesRequestCount == 0)
        #expect(other.redrawVisibleSurfacesRequestCount == 0)

        manager.redrawVisibleSurfaces()

        // Redraw Window must run on the selected workspace, not background ones.
        #expect(selected.redrawVisibleSurfacesRequestCount == 1)
        #expect(other.redrawVisibleSurfacesRequestCount == 0)

        // Switching selection must re-target the shared action.
        manager.selectWorkspace(other)
        manager.redrawVisibleSurfaces()

        #expect(other.redrawVisibleSurfacesRequestCount == 1)
        #expect(selected.redrawVisibleSurfacesRequestCount == 1)
    }
}
