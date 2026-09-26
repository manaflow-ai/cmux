import CmuxWorkspaces
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
struct ExtensionSidebarGroupIdentityTests {
    @Test
    func projectsConfiguredIdentityAndExplicitOverridesForMembers() throws {
        let anchor = Workspace(workingDirectory: "/tmp/group-identity")
        let member = Workspace(workingDirectory: "/tmp/group-member")
        var group = WorkspaceGroup(
            id: UUID(), name: "Group", isCollapsed: false, isPinned: false,
            anchorWorkspaceId: anchor.id, customColor: nil, iconSymbol: nil
        )
        member.groupId = group.id
        let configured = CmuxResolvedWorkspaceGroupConfig(
            originalKey: "/tmp/group-identity", normalizedKey: "/tmp/group-identity",
            isGlob: false, color: "#123456", iconSymbol: "shippingbox.fill",
            contextMenuItems: [], newWorkspacePlacement: nil
        )
        var resolvedPaths: [String?] = []
        func project() -> [UUID: ExtensionSidebarGroupIdentity] {
            ExtensionSidebarGroupIdentity.byWorkspaceId(workspaces: [anchor, member], groups: [group]) { cwd in
                resolvedPaths.append(cwd)
                return configured
            }
        }
        let initial = project()
        #expect(initial[anchor.id] == initial[member.id])
        #expect(initial[member.id]?.iconSymbol == "shippingbox.fill")
        #expect(initial[member.id]?.colorHex == "#123456")
        #expect(resolvedPaths == [anchor.currentDirectory])

        group.iconSymbol = "star.fill"
        group.customColor = "#654321"
        let updated = project()
        #expect(updated[member.id]?.iconSymbol == "star.fill")
        #expect(updated[member.id]?.colorHex == "#654321")

        member.groupId = nil
        #expect(project()[member.id] == nil)
        #expect(project()[anchor.id] != nil)
    }

    @Test
    func ignoresStaleMembershipAndKeepsUncustomizedFallback() {
        let anchor = Workspace()
        let member = Workspace()
        var group = WorkspaceGroup(
            id: UUID(), name: "Group", isCollapsed: false, isPinned: false,
            anchorWorkspaceId: anchor.id, customColor: nil, iconSymbol: nil
        )
        member.groupId = group.id
        #expect(ExtensionSidebarGroupIdentity.byWorkspaceId(
            workspaces: [anchor, member], groups: [group], resolveConfig: { _ in nil }
        ).isEmpty)
        group.customColor = "#123456"
        let tinted = ExtensionSidebarGroupIdentity.byWorkspaceId(
            workspaces: [anchor, member], groups: [group], resolveConfig: { _ in nil }
        )
        #expect(tinted[member.id]?.iconSymbol == "folder.fill")
        #expect(tinted[member.id]?.colorHex == "#123456")
        #expect(ExtensionSidebarGroupIdentity.byWorkspaceId(
            workspaces: [member], groups: [group], resolveConfig: { _ in nil }
        ).isEmpty)
    }
}
