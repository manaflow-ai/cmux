import Foundation
import Testing
import CmuxControlSocket

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Workspace group move-to menu state")
@MainActor
struct WorkspaceGroupMoveToMenuStateTests {
    @Test func isDisabledWhenThereAreNoGroups() {
        let state = WorkspaceGroupMoveToMenuState(groups: [])

        #expect(state.isDisabled)
        #expect(!state.rendersSubmenu)
    }

    @Test func usesSubmenuWhenGroupsExist() {
        let group = WorkspaceGroupMenuSnapshot.Item(
            id: UUID(),
            name: "Group"
        )
        let state = WorkspaceGroupMoveToMenuState(groups: [group])

        #expect(!state.isDisabled)
        #expect(state.rendersSubmenu)
    }

    @Test func mobileWorkspaceMoveBlankGroupIDUngroupsWorkspace() throws {
        let manager = TabManager()
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        let originalIds = manager.tabs.map(\.id)
        let groupId = try #require(manager.createWorkspaceGroup(name: "G", childWorkspaceIds: [
            originalIds[1],
            originalIds[2],
        ]))
        let movingWorkspaceID = originalIds[1]
        #expect(manager.tabs.first { $0.id == movingWorkspaceID }?.groupId == groupId)

        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        TerminalController.shared.setActiveTabManager(manager)
        defer { TerminalController.shared.setActiveTabManager(previousManager) }

        let result = TerminalController.shared.v2MobileWorkspaceMove(params: [
            "workspace_id": movingWorkspaceID.uuidString,
            "group_id": "   ",
        ])

        guard case .ok = result else {
            return #expect(Bool(false), "blank group_id should be treated as nil, not invalid_params")
        }
        #expect(manager.tabs.first { $0.id == movingWorkspaceID }?.groupId == nil)
    }

    @Test func mobileWorkspaceMoveGroupHeaderPreservesGroupMembership() throws {
        let manager = TabManager()
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        let originalIds = manager.tabs.map(\.id)
        let groupId = try #require(manager.createWorkspaceGroup(name: "G", childWorkspaceIds: [
            originalIds[1],
            originalIds[2],
        ]))
        let group = try #require(manager.workspaceGroups.first { $0.id == groupId })
        let memberID = originalIds[2]

        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        TerminalController.shared.setActiveTabManager(manager)
        defer { TerminalController.shared.setActiveTabManager(previousManager) }

        let result = TerminalController.shared.v2MobileWorkspaceMove(params: [
            "workspace_id": group.anchorWorkspaceId.uuidString,
            "move_group": true,
        ])

        guard case .ok = result else {
            return #expect(Bool(false), "group-header move should be accepted")
        }
        #expect(manager.workspaceGroups.contains { $0.id == groupId })
        #expect(manager.tabs.filter { $0.groupId == groupId }.map(\.id) == [
            group.anchorWorkspaceId,
            memberID,
        ])
        #expect(manager.tabs.suffix(2).map(\.id) == [group.anchorWorkspaceId, memberID])
    }

    @Test func mobileWorkspaceGroupDeleteRejectsGroupContainingEveryWorkspace() throws {
        let manager = TabManager()
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        let originalIds = manager.tabs.map(\.id)
        let groupId = try #require(manager.createWorkspaceGroup(name: "G", childWorkspaceIds: originalIds))

        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        TerminalController.shared.setActiveTabManager(manager)
        defer { TerminalController.shared.setActiveTabManager(previousManager) }

        let result = TerminalController.shared.v2MobileWorkspaceGroupAction(params: [
            "group_id": groupId.uuidString,
            "action": "delete",
        ])

        guard case .err(let code, _, _) = result else {
            return #expect(Bool(false), "delete group should reject when it would leave a holdout workspace")
        }
        #expect(code == "invalid_request")
        #expect(manager.workspaceGroups.contains { $0.id == groupId })
        #expect(manager.tabs.filter { $0.groupId == groupId }.count == originalIds.count + 1)
    }

    @Test func mobileWorkspaceGroupCreateUsesTrimmedTitleAndReturnsWorkspaceList() throws {
        let manager = TabManager()
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        TerminalController.shared.setActiveTabManager(manager)
        defer { TerminalController.shared.setActiveTabManager(previousManager) }

        let result = TerminalController.shared.v2MobileWorkspaceGroupCreate(params: ["title": " Ops "])

        guard case .ok(let payload) = result,
              let object = payload as? [String: Any],
              let groups = object["groups"] as? [[String: Any]] else {
            return #expect(Bool(false), "group create should return a workspace list payload")
        }
        #expect(manager.workspaceGroups.count == 1)
        #expect(manager.workspaceGroups.first?.name == "Ops")
        #expect(manager.tabs.contains { $0.id == manager.workspaceGroups.first?.anchorWorkspaceId })
        #expect(groups.first?["name"] as? String == "Ops")
    }

    @Test func mobileWorkspaceGroupCreateTreatsBlankTitleAsAutoName() throws {
        let manager = TabManager()
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        let expectedName = String.localizedStringWithFormat(manager.localizedAutoGroupNameFormat, 1)
        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        TerminalController.shared.setActiveTabManager(manager)
        defer { TerminalController.shared.setActiveTabManager(previousManager) }

        let result = TerminalController.shared.v2MobileWorkspaceGroupCreate(params: ["title": "   "])

        guard case .ok = result else {
            return #expect(Bool(false), "blank title should create a default-named group")
        }
        #expect(manager.workspaceGroups.first?.name == expectedName)
    }

    @Test func mobileWorkspaceGroupCreateWithStableIdentityIsIdempotent() throws {
        let manager = TabManager()
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        TerminalController.shared.setActiveTabManager(manager)
        defer { TerminalController.shared.setActiveTabManager(previousManager) }

        let params: [String: Any] = [
            "title": "Ops",
            "idempotency_key": "repo:cmux",
        ]
        let first = TerminalController.shared.v2MobileWorkspaceGroupCreate(params: params)
        let firstGroupID = try #require(manager.workspaceGroups.first?.id)
        let firstAnchorID = try #require(manager.workspaceGroups.first?.anchorWorkspaceId)
        let workspaceCountAfterFirstCreate = manager.tabs.count

        let second = TerminalController.shared.v2MobileWorkspaceGroupCreate(params: params)

        guard case .ok = first, case .ok = second else {
            return #expect(Bool(false), "repeated group create should succeed")
        }
        #expect(manager.workspaceGroups.count == 1)
        #expect(manager.workspaceGroups.first?.id == firstGroupID)
        #expect(manager.workspaceGroups.first?.anchorWorkspaceId == firstAnchorID)
        #expect(manager.tabs.count == workspaceCountAfterFirstCreate)
    }

    @Test func mobileWorkspaceGroupUngroupCanRemoveOnlyGeneratedAnchor() throws {
        let manager = TabManager()
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        TerminalController.shared.setActiveTabManager(manager)
        defer { TerminalController.shared.setActiveTabManager(previousManager) }

        let groupID = try #require(
            manager.createWorkspaceGroup(
                name: "Orphan",
                selectAnchor: false,
                collapseSidebarSelection: false
            )
        )
        let anchorID = try #require(manager.workspaceGroups.first?.anchorWorkspaceId)

        let result = TerminalController.shared.v2MobileWorkspaceGroupAction(params: [
            "group_id": groupID.uuidString,
            "action": "ungroup",
            "remove_generated_anchor": true,
        ])

        guard case .ok = result else {
            return #expect(Bool(false), "generated-anchor cleanup should succeed")
        }
        #expect(!manager.workspaceGroups.contains { $0.id == groupID })
        #expect(!manager.tabs.contains { $0.id == anchorID })
    }

    @Test func controlWorkspaceGroupCreateWithStableIdentityReturnsExistingGroup() throws {
        let manager = TabManager()
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        TerminalController.shared.setActiveTabManager(manager)
        defer { TerminalController.shared.setActiveTabManager(previousManager) }

        let coordinator = ControlCommandCoordinator(context: TerminalController.shared)
        let params: [String: JSONValue] = [
            "name": .string("Ops"),
            "idempotency_key": .string("repo:control"),
        ]
        let first = coordinator.handle(ControlRequest(
            id: .int(1),
            method: "workspace.group.create",
            params: params
        ))
        let second = coordinator.handle(ControlRequest(
            id: .int(2),
            method: "workspace.group.create",
            params: params
        ))

        guard case .ok = first,
              case .ok(.object(let secondPayload)) = second else {
            return #expect(Bool(false), "control group creates should succeed")
        }
        #expect(manager.workspaceGroups.count == 1)
        #expect(secondPayload["created"] == .bool(false))
    }
}
