import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Pure resolution rules for `cmux://workspace/...` deep links: runtime ids
/// win, restart-stable ids keep links working after a relaunch, and surface
/// routes survive a tab moving to another workspace.
@Suite("Navigation target resolver")
struct CmuxNavigationTargetResolverTests {
    private typealias Resolver = CmuxNavigationTargetResolver

    private let workspaceId = UUID()
    private let stableWorkspaceId = UUID()
    private let paneId = UUID()
    private let panelId = UUID()
    private let stableSurfaceId = UUID()

    private var workspace: Resolver.WorkspaceDescriptor {
        Resolver.WorkspaceDescriptor(
            workspaceId: workspaceId,
            stableId: stableWorkspaceId,
            paneIds: [paneId],
            surfaces: [Resolver.SurfaceDescriptor(panelId: panelId, stableSurfaceId: stableSurfaceId)]
        )
    }

    @Test func workspaceResolvesByRuntimeId() {
        let resolver = Resolver(workspaces: [workspace])

        #expect(resolver.resolve(.workspace(workspaceId)) == .workspace(workspaceId: workspaceId))
    }

    @Test func workspaceResolvesByStableIdAfterRestart() {
        let resolver = Resolver(workspaces: [workspace])

        #expect(resolver.resolve(.workspace(stableWorkspaceId)) == .workspace(workspaceId: workspaceId))
    }

    @Test func runtimeIdBeatsStableIdWhenBothMatch() {
        let other = Resolver.WorkspaceDescriptor(
            workspaceId: UUID(),
            stableId: workspaceId,
            paneIds: [],
            surfaces: []
        )
        let resolver = Resolver(workspaces: [other, workspace])

        #expect(resolver.resolve(.workspace(workspaceId)) == .workspace(workspaceId: workspaceId))
    }

    @Test func unknownWorkspaceDoesNotResolve() {
        let resolver = Resolver(workspaces: [workspace])

        #expect(resolver.resolve(.workspace(UUID())) == nil)
    }

    @Test func surfaceResolvesByRuntimeIds() {
        let resolver = Resolver(workspaces: [workspace])

        #expect(
            resolver.resolve(.surface(workspaceId: workspaceId, surfaceId: panelId))
                == .surface(workspaceId: workspaceId, panelId: panelId)
        )
    }

    @Test func surfaceResolvesByStableIdsAfterRestart() {
        let resolver = Resolver(workspaces: [workspace])

        #expect(
            resolver.resolve(.surface(workspaceId: stableWorkspaceId, surfaceId: stableSurfaceId))
                == .surface(workspaceId: workspaceId, panelId: panelId)
        )
    }

    @Test func surfaceRuntimeIdBeatsStableIdWithinWorkspace() {
        let collidingPanelId = UUID()
        let descriptor = Resolver.WorkspaceDescriptor(
            workspaceId: workspaceId,
            stableId: stableWorkspaceId,
            paneIds: [],
            surfaces: [
                Resolver.SurfaceDescriptor(panelId: panelId, stableSurfaceId: collidingPanelId),
                Resolver.SurfaceDescriptor(panelId: collidingPanelId, stableSurfaceId: UUID())
            ]
        )
        let resolver = Resolver(workspaces: [descriptor])

        #expect(
            resolver.resolve(.surface(workspaceId: workspaceId, surfaceId: collidingPanelId))
                == .surface(workspaceId: workspaceId, panelId: collidingPanelId)
        )
    }

    @Test func surfaceMovedToAnotherWorkspaceStillResolves() {
        let homeWorkspace = Resolver.WorkspaceDescriptor(
            workspaceId: workspaceId,
            stableId: stableWorkspaceId,
            paneIds: [],
            surfaces: []
        )
        let movedPanelId = UUID()
        let otherWorkspaceId = UUID()
        let otherWorkspace = Resolver.WorkspaceDescriptor(
            workspaceId: otherWorkspaceId,
            stableId: UUID(),
            paneIds: [],
            surfaces: [Resolver.SurfaceDescriptor(panelId: movedPanelId, stableSurfaceId: stableSurfaceId)]
        )
        let resolver = Resolver(workspaces: [homeWorkspace, otherWorkspace])

        #expect(
            resolver.resolve(.surface(workspaceId: stableWorkspaceId, surfaceId: stableSurfaceId))
                == .surface(workspaceId: otherWorkspaceId, panelId: movedPanelId)
        )
    }

    @Test func surfaceResolvesWhenLinkedWorkspaceIsGone() {
        let movedPanelId = UUID()
        let survivingWorkspaceId = UUID()
        let survivingWorkspace = Resolver.WorkspaceDescriptor(
            workspaceId: survivingWorkspaceId,
            stableId: UUID(),
            paneIds: [],
            surfaces: [Resolver.SurfaceDescriptor(panelId: movedPanelId, stableSurfaceId: stableSurfaceId)]
        )
        let resolver = Resolver(workspaces: [survivingWorkspace])

        #expect(
            resolver.resolve(.surface(workspaceId: stableWorkspaceId, surfaceId: stableSurfaceId))
                == .surface(workspaceId: survivingWorkspaceId, panelId: movedPanelId)
        )
    }

    @Test func unknownSurfaceInResolvedWorkspaceDoesNotResolve() {
        let resolver = Resolver(workspaces: [workspace])

        #expect(resolver.resolve(.surface(workspaceId: workspaceId, surfaceId: UUID())) == nil)
    }

    @Test func paneResolvesByRuntimeIdThroughStableWorkspaceRoute() {
        let resolver = Resolver(workspaces: [workspace])

        #expect(
            resolver.resolve(.pane(workspaceId: stableWorkspaceId, paneId: paneId))
                == .pane(workspaceId: workspaceId, paneId: paneId)
        )
    }

    @Test func unknownPaneDoesNotResolve() {
        let resolver = Resolver(workspaces: [workspace])

        #expect(resolver.resolve(.pane(workspaceId: workspaceId, paneId: UUID())) == nil)
    }
}
