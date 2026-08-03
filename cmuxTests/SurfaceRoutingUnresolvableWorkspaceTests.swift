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

    /// `resolveTabManager` is the choke point every routed command reaches,
    /// including the ones whose own workspace param is optional (todos,
    /// status, remote-tmux host selection). It has to refuse a named-but-
    /// unresolvable workspace there, or those commands mutate the caller's
    /// focused workspace instead.
    @Test
    func unresolvableWorkspaceIDResolvesToNoTabManager() {
        // An unparseable/unknown ref, which decodes to no UUID at all...
        #expect(TerminalController.shared.resolveTabManager(
            routing: Self.routing(workspaceID: nil, hasWorkspaceIDParam: true)
        ) == nil)
        // ...and a well-formed UUID that no window owns (a closed workspace, or
        // an id from another app instance), which parses but locates nothing.
        #expect(TerminalController.shared.resolveTabManager(
            routing: Self.routing(workspaceID: UUID(), hasWorkspaceIDParam: true)
        ) == nil)
    }

    /// A non-surface mutation: `workspace.todo.add` carries an optional
    /// workspace param, so an unknown ref used to fall through to the selected
    /// workspace and add the item there. It must refuse instead.
    @Test
    func unresolvableWorkspaceIDDoesNotMutateTheFocusedWorkspaceTodos() {
        for workspaceID in [nil, UUID()] as [UUID?] {
            let result = TerminalController.shared.controlWorkspaceTodoAdd(
                routing: Self.routing(workspaceID: workspaceID, hasWorkspaceIDParam: true),
                workspaceID: workspaceID,
                text: "must not land in the focused workspace",
                stateRaw: nil,
                originRaw: nil
            )

            switch result {
            case .tabManagerUnavailable, .notFound:
                continue
            default:
                Issue.record("expected the add to be refused, got \(result)")
            }
        }
    }

    /// The app-side request decoder is the single place every non-coordinator
    /// entrypoint (`surface.read_text` on the socket-worker lane, the
    /// remote-tmux paths) gets its selectors from, so the presence flag cannot
    /// be wired into one command and forgotten in another.
    @Test
    func appSideDecoderFlagsPresentButUnresolvableWorkspaceID() {
        let controller = TerminalController.shared

        let unresolvable = controller.v2RoutingSelectors(["workspace_id": "workspace:999"])
        #expect(unresolvable.workspaceID == nil)
        #expect(unresolvable.hasWorkspaceIDParam)

        #expect(!controller.v2RoutingSelectors([:]).hasWorkspaceIDParam)
        #expect(!controller.v2RoutingSelectors(["workspace_id": NSNull()]).hasWorkspaceIDParam)

        let uuid = UUID()
        let resolved = controller.v2RoutingSelectors(["workspace_id": uuid.uuidString])
        #expect(resolved.workspaceID == uuid)
        #expect(resolved.hasWorkspaceIDParam)

        #expect(
            controller.remoteTmuxRouting(from: ["workspace_id": "workspace:999"]) == unresolvable
        )
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
