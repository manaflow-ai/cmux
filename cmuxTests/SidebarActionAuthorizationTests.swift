import AppKit
import Foundation
import Testing
@_spi(CmuxHostTransport) import CmuxExtensionKit
import CmuxWorkspaces

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite @MainActor
struct SidebarActionAuthorizationTests {
    @Test func cancelledOperationCannotCommit() async {
        var mutations = 0
        let authorization = SidebarActionAuthorization(isCurrent: { true })
        let operation = Task { @MainActor in authorization.perform { mutations += 1 } }
        operation.cancel()
        _ = await operation.value
        #expect(mutations == 0)
    }

    @Test func capturedEpochDoesNotBecomeValidAfterRegrant() {
        var revision = 1
        let captured = revision
        let authorization = SidebarActionAuthorization(isCurrent: { revision == captured })
        #expect(authorization.isValid)
        revision = 2
        revision = 3
        var mutations = 0
        authorization.perform { mutations += 1 }
        #expect(mutations == 0)
    }

    @Test func alreadyRevokedMenuIsNotPresented() {
        let authorization = SidebarActionAuthorization(isCurrent: { false })
        var presentations = 0
        SidebarAuthorizedMenuDispatch(authorization: authorization).present(NSMenu()) { _ in presentations += 1 }
        #expect(presentations == 0)
    }

    @Test func nativeRenameCapturesScopedAuthorityAndRejectsRevocationDuringPrompt() {
        let manager = TabManager(autoWelcomeIfNeeded: false, createInitialWorkspace: false)
        let workspace = Workspace()
        manager.tabs = [workspace]
        var revision = 1
        let captured = revision
        let authorization = SidebarActionAuthorization(isCurrent: { revision == captured })
        var result: CmuxSidebarActionResult?
        authorization.perform {
            let coordinator = SidebarExtensionManagementCoordinator(
                tabManager: manager, notificationStore: .shared,
                requestTitle: { _, _, _ in revision += 1; return "Must not commit" }
            )
            result = coordinator.perform(.renameWorkspace(workspaceID: workspace.id, title: nil))
        }
        #expect(result?.rejectionReason == .cancelled)
        #expect(workspace.customTitle == nil)
        #expect(SidebarActionAuthorization.current == nil)
    }

    @Test func groupDeletionCannotCommitAfterConfirmationRevokesAuthority() {
        let manager = TabManager(autoWelcomeIfNeeded: false, createInitialWorkspace: false)
        let workspace = Workspace()
        let groupID = UUID()
        workspace.groupId = groupID
        manager.tabs = [workspace]
        manager.workspaceGroups = [WorkspaceGroup(id: groupID, name: "Retained", isCollapsed: false,
            isPinned: false, anchorWorkspaceId: workspace.id, customColor: nil, iconSymbol: nil)]
        var valid = true
        let coordinator = SidebarExtensionManagementCoordinator(
            tabManager: manager, notificationStore: .shared,
            authorization: SidebarActionAuthorization(isCurrent: { valid }),
            confirmGroupDeletion: { _, _ in valid = false; return true }
        )
        let result = coordinator.perform(.deleteWorkspaceGroup(groupID: groupID))
        #expect(result?.rejectionReason == .cancelled)
        #expect(manager.workspaceGroups.contains(where: { $0.id == groupID }))
        #expect(manager.tabs.contains(where: { $0.id == workspace.id }))
    }

    @Test func closeConfirmationCannotAuthorizeMutationAfterRevocation() {
        let manager = TabManager(autoWelcomeIfNeeded: false, createInitialWorkspace: false)
        var valid = true
        let authorization = SidebarActionAuthorization(isCurrent: { valid })
        manager.confirmCloseHandler = { _, _, _ in valid = false; return true }
        var accepted = false
        authorization.perform {
            accepted = manager.confirmClose(title: "Captured target", message: "Confirmation", acceptCmdD: false)
        }
        #expect(!accepted)
    }
}
