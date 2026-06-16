import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Workspace action dispatcher")
struct WorkspaceActionDispatcherTests {
    @Test func singleAndSidebarTargetsResolveTheSamePinState() throws {
        let manager = TabManager()
        let workspace = try #require(manager.tabs.first)

        let singleState = try #require(
            WorkspaceActionDispatcher.pinState(
                in: manager,
                target: .single(workspace.id)
            )
        )
        let sidebarState = try #require(
            WorkspaceActionDispatcher.pinState(
                in: manager,
                target: WorkspaceActionDispatcher.Target(
                    workspaceIds: [workspace.id],
                    anchorWorkspaceId: workspace.id
                )
            )
        )
        let workspacesById = Dictionary(uniqueKeysWithValues: manager.tabs.map { ($0.id, $0) })
        let indexedState = try #require(
            WorkspaceActionDispatcher.pinState(
                workspacesById: workspacesById,
                target: WorkspaceActionDispatcher.Target(
                    workspaceIds: [workspace.id],
                    anchorWorkspaceId: workspace.id
                )
            )
        )

        #expect(singleState == sidebarState)
        #expect(singleState == indexedState)
        #expect(singleState.pinned == !workspace.isPinned)
    }

    @Test func indexedPinStateFiltersStaleAndDuplicateTargets() throws {
        let manager = TabManager()
        let first = try #require(manager.tabs.first)
        let second = manager.addWorkspace()
        let stale = UUID()
        let workspacesById = Dictionary(uniqueKeysWithValues: manager.tabs.map { ($0.id, $0) })

        let state = try #require(
            WorkspaceActionDispatcher.pinState(
                workspacesById: workspacesById,
                target: WorkspaceActionDispatcher.Target(
                    workspaceIds: [stale, second.id, second.id, first.id],
                    anchorWorkspaceId: stale
                )
            )
        )

        #expect(state.targetWorkspaceIds == [second.id, first.id])
        #expect(state.anchorWorkspaceId == second.id)
        #expect(state.pinned == !second.isPinned)
    }

    @Test func pinActionPinsMultipleTargetsFromAnchorState() throws {
        let manager = TabManager()
        let first = try #require(manager.tabs.first)
        let second = manager.addWorkspace()
        let third = manager.addWorkspace()
        let target = WorkspaceActionDispatcher.Target(
            workspaceIds: [second.id, third.id],
            anchorWorkspaceId: second.id
        )

        let state = try #require(WorkspaceActionDispatcher.pinState(in: manager, target: target))
        let result = WorkspaceActionDispatcher.performPinAction(state, in: manager)

        #expect(state.pinned)
        #expect(result.targetWorkspaceIds == [second.id, third.id])
        #expect(result.changedWorkspaceIds == [second.id, third.id])
        #expect(second.isPinned)
        #expect(third.isPinned)
        #expect(!first.isPinned)
        #expect(manager.tabs.map(\.id) == [second.id, third.id, first.id])
    }

    @Test func pinActionUnpinsMultipleTargetsWithExistingOrdering() throws {
        let manager = TabManager()
        let first = try #require(manager.tabs.first)
        let second = manager.addWorkspace()
        let third = manager.addWorkspace()
        manager.setPinned(first, pinned: true)
        manager.setPinned(second, pinned: true)
        manager.setPinned(third, pinned: true)
        let target = WorkspaceActionDispatcher.Target(
            workspaceIds: [second.id, third.id],
            anchorWorkspaceId: second.id
        )

        let state = try #require(WorkspaceActionDispatcher.pinState(in: manager, target: target))
        let result = WorkspaceActionDispatcher.performPinAction(state, in: manager)

        #expect(!state.pinned)
        #expect(result.targetWorkspaceIds == [second.id, third.id])
        #expect(result.changedWorkspaceIds == [second.id, third.id])
        #expect(first.isPinned)
        #expect(!second.isPinned)
        #expect(!third.isPinned)
        #expect(manager.tabs.map(\.id) == [first.id, third.id, second.id])
    }

    @Test func capturedPinStateKeepsLabelAndActionConsistent() throws {
        let manager = TabManager()
        let workspace = try #require(manager.tabs.first)
        let state = try #require(
            WorkspaceActionDispatcher.pinState(
                in: manager,
                target: .single(workspace.id)
            )
        )

        manager.setPinned(workspace, pinned: true)
        let result = WorkspaceActionDispatcher.performPinAction(state, in: manager)

        #expect(state.pinned)
        #expect(workspace.isPinned)
        #expect(result.changedWorkspaceIds.isEmpty)
    }
}
