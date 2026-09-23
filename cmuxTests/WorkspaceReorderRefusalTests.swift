import CmuxControlSocket
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct WorkspaceReorderRefusalTests {
    @Test(arguments: [false, true])
    func groupedMemberAboveAnchorIsRejectedWithoutMutation(dryRun: Bool) throws {
        let manager = TabManager()
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        defer { for workspace in manager.tabs { workspace.teardownAllPanels() } }
        let members = Array(manager.tabs.prefix(2).map(\.id))
        let groupID = try #require(manager.createWorkspaceGroup(name: "Reorder test", childWorkspaceIds: members))
        let group = try #require(manager.workspaceGroups.first { $0.id == groupID })
        let order = manager.tabs.map(\.id)
        let anchorIndex = try #require(order.firstIndex(of: group.anchorWorkspaceId))
        let controller = TerminalController.shared
        let previous = controller.activeTabManagerForCallerNotification()
        controller.setActiveTabManager(manager)
        defer { controller.setActiveTabManager(previous) }
        let routing = ControlRoutingSelectors(
            hasWindowIDParam: false, windowID: nil, groupID: nil,
            workspaceID: nil, surfaceID: nil, paneID: nil
        )
        for relative in [false, true] {
            let result = controller.controlReorderWorkspace(
                routing: routing, workspaceID: members[0],
                toIndex: relative ? nil : anchorIndex,
                beforeWorkspaceID: relative ? group.anchorWorkspaceId : nil,
                afterWorkspaceID: nil, dryRun: dryRun
            )
            guard case .rejected(_, let plan) = result else {
                Issue.record("Expected grouped member placement to be rejected, got \(result)")
                continue
            }
            #expect(plan.fromIndex == plan.toIndex)
            #expect(manager.tabs.map(\.id) == order)
            #expect(manager.tabs.first { $0.id == members[0] }?.groupId == groupID)
        }
    }
}
