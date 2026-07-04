import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Session workspace group parent chains")
struct SessionWorkspaceGroupSnapshotParentChainTests {
    @Test func snapshotWriterLinksChildFolderToNearestRestorableAncestor() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        let workspaceIds = manager.tabs.map(\.id)
        let grandparentId = try #require(manager.createWorkspaceGroup(
            name: "Hotels",
            childWorkspaceIds: [workspaceIds[0]]
        ))
        let parentId = try #require(manager.createWorkspaceGroup(
            name: "Marriott",
            childWorkspaceIds: [workspaceIds[1]],
            parentGroupId: grandparentId
        ))
        let childId = try #require(manager.createWorkspaceGroup(
            name: "Downtown",
            childWorkspaceIds: [workspaceIds[2]],
            parentGroupId: parentId
        ))
        manager.tabs.first { $0.id == workspaceIds[1] }?.isRemoteTmuxMirror = true

        let snapshot = manager.sessionSnapshot(includeScrollback: false)
        let groups = try #require(snapshot.workspaceGroups)
        let child = try #require(groups.first { $0.id == childId })

        #expect(groups.contains { $0.id == grandparentId })
        #expect(!groups.contains { $0.id == parentId })
        #expect(child.parentGroupId == grandparentId)
        #expect(child.parentGroupIndex == groups.firstIndex { $0.id == grandparentId })
    }
}
