import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct MobileWorkspaceGroupRPCTests {
    @Test func groupNewWorkspaceReturnsGroupedCreatedWorkspace() async throws {
        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let manager = TabManager()
        TerminalController.shared.setActiveTabManager(manager)
        defer {
            TerminalController.shared.setActiveTabManager(previousManager)
        }

        let groupId = try #require(manager.createWorkspaceGroup(name: "Mobile Group"))
        let selectedWorkspace = try #require(manager.selectedWorkspace)
        manager.setWorkspaceGroupCollapsed(groupId: groupId, isCollapsed: true)

        let response = await TerminalController.shared.mobileHostHandleRPC(
            MobileHostRPCRequest(
                id: "group-workspace-create",
                method: "workspace.group.new_workspace",
                params: ["group_id": groupId.uuidString],
                auth: nil
            )
        )

        guard case let .ok(rawPayload) = response else {
            Issue.record("Expected mobile workspace.group.new_workspace to return a grouped workspace payload")
            return
        }
        let payload = try #require(rawPayload as? [String: Any])
        let createdWorkspaceID = try #require(payload["created_workspace_id"] as? String)
        let createdUUID = try #require(UUID(uuidString: createdWorkspaceID))
        let workspaces = try #require(payload["workspaces"] as? [[String: Any]])
        let groups = try #require(payload["groups"] as? [[String: Any]])

        let createdWorkspace = try #require(manager.tabs.first { $0.id == createdUUID })
        let createdPayload = try #require(workspaces.first { ($0["id"] as? String) == createdWorkspaceID })
        let groupPayload = try #require(groups.first { ($0["id"] as? String) == groupId.uuidString })
        #expect(createdWorkspace.groupId == groupId)
        #expect(createdPayload["group_id"] as? String == groupId.uuidString)
        #expect(groupPayload["id"] as? String == groupId.uuidString)
        #expect(manager.selectedWorkspace?.id == selectedWorkspace.id)
        #expect(manager.workspaceGroups.first(where: { $0.id == groupId })?.isCollapsed == false)
    }

    @Test func groupNewWorkspaceRejectsInvalidPlacement() async throws {
        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let manager = TabManager()
        TerminalController.shared.setActiveTabManager(manager)
        defer {
            TerminalController.shared.setActiveTabManager(previousManager)
        }

        let groupId = try #require(manager.createWorkspaceGroup(name: "Mobile Group"))

        let response = await TerminalController.shared.mobileHostHandleRPC(
            MobileHostRPCRequest(
                id: "group-workspace-create-invalid-placement",
                method: "workspace.group.new_workspace",
                params: [
                    "group_id": groupId.uuidString,
                    "placement": "",
                ],
                auth: nil
            )
        )

        guard case let .failure(error) = response else {
            Issue.record("Expected mobile workspace.group.new_workspace to reject an empty placement")
            return
        }
        #expect(error.code == "invalid_params")
        #expect(error.message == "placement must be one of: afterCurrent, top, end")
    }
}
