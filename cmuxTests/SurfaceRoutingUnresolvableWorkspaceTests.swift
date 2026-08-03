import CmuxControlSocket
import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

/// Regression coverage for GitHub issue #9191: an input RPC that carries a
/// `workspace_id` the app cannot resolve (a recycled or foreign `workspace:N`
/// ref, or a typo) must fail closed instead of silently retargeting the
/// caller's focused workspace.
@Suite(.serialized)
@MainActor
struct SurfaceRoutingUnresolvableWorkspaceTests {
    @Test
    func unresolvableWorkspaceIDResolvesToNoWorkspace() throws {
        let manager = TabManager()
        let selected = try #require(manager.selectedWorkspace)

        let omitted = TerminalController.shared.resolveSurfaceWorkspace(
            routing: Self.routing(workspaceID: nil, hasWorkspaceIDParam: false),
            tabManager: manager
        )
        #expect(omitted?.id == selected.id)

        let unresolvable = TerminalController.shared.resolveSurfaceWorkspace(
            routing: Self.routing(workspaceID: nil, hasWorkspaceIDParam: true),
            tabManager: manager
        )
        #expect(unresolvable == nil)
    }

    @Test
    func resolvedWorkspaceIDStillRoutesToItsWorkspace() throws {
        let manager = TabManager()
        let selected = try #require(manager.selectedWorkspace)

        let resolved = TerminalController.shared.resolveSurfaceWorkspace(
            routing: Self.routing(workspaceID: selected.id, hasWorkspaceIDParam: true),
            tabManager: manager
        )
        #expect(resolved?.id == selected.id)
    }

    private static func routing(
        workspaceID: UUID?,
        hasWorkspaceIDParam: Bool
    ) -> ControlRoutingSelectors {
        ControlRoutingSelectors(
            hasWindowIDParam: false,
            windowID: nil,
            groupID: nil,
            workspaceID: workspaceID,
            surfaceID: nil,
            paneID: nil,
            hasWorkspaceIDParam: hasWorkspaceIDParam
        )
    }
}
