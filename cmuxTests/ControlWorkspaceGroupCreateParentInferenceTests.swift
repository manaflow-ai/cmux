import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct ControlWorkspaceGroupCreateParentInferenceTests {
    private func call(method: String, params: [String: Any]) throws -> [String: Any] {
        let request: [String: Any] = ["id": method, "method": method, "params": params]
        let requestData = try JSONSerialization.data(withJSONObject: request)
        let requestLine = try #require(String(data: requestData, encoding: .utf8))
        let responseData = try #require(TerminalController.shared.handleSocketLine(requestLine).data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
    }

    @Test func socketCreateGroupInfersParentFromExplicitChildrenInsideOneGroup() throws {
        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let manager = TabManager(autoWelcomeIfNeeded: false)
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        let workspaceIds = manager.tabs.map(\.id)
        let parentId = try #require(manager.createWorkspaceGroup(
            name: "Parent",
            childWorkspaceIds: [
                workspaceIds[0],
                workspaceIds[1],
            ],
            selectAnchor: false,
            collapseSidebarSelection: false
        ))

        TerminalController.shared.setActiveTabManager(manager)
        defer { TerminalController.shared.setActiveTabManager(previousManager) }

        let envelope = try call(method: "workspace.group.create", params: [
            "name": "Sub",
            "child_workspace_ids": [
                workspaceIds[1].uuidString,
            ],
        ])

        #expect(envelope["ok"] as? Bool == true)
        let result = try #require(envelope["result"] as? [String: Any])
        let group = try #require(result["group"] as? [String: Any])
        #expect(group["parent_group_id"] as? String == parentId.uuidString)
        let createdGroupIdString = try #require(group["id"] as? String)
        let createdGroupId = try #require(UUID(uuidString: createdGroupIdString))
        #expect(manager.workspaceGroups.first { $0.id == createdGroupId }?.parentGroupId == parentId)
    }

    @Test func socketMoveGroupRejectsNonSiblingRelativeTargets() throws {
        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let manager = TabManager(autoWelcomeIfNeeded: false)
        for _ in 0..<4 {
            manager.addWorkspace(autoWelcomeIfNeeded: false)
        }
        let workspaceIds = manager.tabs.map(\.id)
        let parentId = try #require(manager.createWorkspaceGroup(
            name: "Parent",
            childWorkspaceIds: [workspaceIds[0]],
            selectAnchor: false,
            collapseSidebarSelection: false
        ))
        let childId = try #require(manager.createWorkspaceGroup(
            name: "Child",
            childWorkspaceIds: [workspaceIds[1]],
            parentGroupId: parentId,
            selectAnchor: false,
            collapseSidebarSelection: false
        ))
        let rootPeerId = try #require(manager.createWorkspaceGroup(
            name: "Root",
            childWorkspaceIds: [workspaceIds[2]],
            selectAnchor: false,
            collapseSidebarSelection: false
        ))
        let originalOrder = manager.workspaceGroups.map(\.id)

        TerminalController.shared.setActiveTabManager(manager)
        defer { TerminalController.shared.setActiveTabManager(previousManager) }

        let beforeEnvelope = try call(method: "workspace.group.move", params: [
            "group_id": childId.uuidString,
            "before_group_id": rootPeerId.uuidString,
        ])
        #expect(beforeEnvelope["ok"] as? Bool == false)
        #expect((beforeEnvelope["error"] as? [String: Any])?["code"] as? String == "invalid_params")
        #expect(manager.workspaceGroups.map(\.id) == originalOrder)
        #expect(manager.workspaceGroups.first { $0.id == childId }?.parentGroupId == parentId)

        let afterEnvelope = try call(method: "workspace.group.move", params: [
            "group_id": childId.uuidString,
            "after_group_id": rootPeerId.uuidString,
        ])
        #expect(afterEnvelope["ok"] as? Bool == false)
        #expect((afterEnvelope["error"] as? [String: Any])?["code"] as? String == "invalid_params")
        #expect(manager.workspaceGroups.map(\.id) == originalOrder)
        #expect(manager.workspaceGroups.first { $0.id == childId }?.parentGroupId == parentId)
    }
}
