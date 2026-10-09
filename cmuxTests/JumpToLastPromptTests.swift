import CmuxSidebar
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct JumpToLastPromptTests {
    private typealias Target = AppDelegate.LastPromptTarget

    private static func target(_ seconds: TimeInterval, workspace: UUID = UUID(), panel: UUID = UUID()) -> Target {
        Target(workspaceId: workspace, panelId: panel, submittedAt: Date(timeIntervalSince1970: seconds))
    }

    @Test func newestIsNilWithoutCandidates() {
        #expect(Target.newest(in: []) == nil)
    }

    @Test func newestPicksTheMostRecentSubmit() {
        let older = Self.target(100)
        let newest = Self.target(300)
        let middle = Self.target(200)

        #expect(Target.newest(in: [older, newest, middle]) == newest)
        #expect(Target.newest(in: [middle, older, newest]) == newest)
    }

    @Test func equalSubmitTimesResolveTheSameWayInAnyOrder() throws {
        let lowWorkspace = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let highWorkspace = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let a = Self.target(100, workspace: lowWorkspace)
        let b = Self.target(100, workspace: highWorkspace)

        #expect(Target.newest(in: [a, b]) == a)
        #expect(Target.newest(in: [b, a]) == a)
    }

    @Test func workspaceOffersOnlyLivePanelsWithAPrompt() throws {
        let workspace = Workspace()
        let livePanel = try #require(workspace.focusedPanelId)
        let closedPanel = UUID()
        workspace.panelPrompts[livePanel] = SidebarPanelPromptState(
            message: "live",
            submittedAt: Date(timeIntervalSince1970: 100)
        )
        workspace.panelPrompts[closedPanel] = SidebarPanelPromptState(
            message: "gone",
            submittedAt: Date(timeIntervalSince1970: 200)
        )

        #expect(workspace.lastPromptTargets == [
            Target(workspaceId: workspace.id, panelId: livePanel, submittedAt: Date(timeIntervalSince1970: 100)),
        ])
    }

    @Test func workspaceWithoutPromptsOffersNothing() {
        #expect(Workspace().lastPromptTargets.isEmpty)
    }

    @Test func newestPromptWinsAcrossWorkspaces() throws {
        let manager = TabManager()
        let first = manager.tabs[0]
        let second = manager.addWorkspace(select: false, placementOverride: .end)
        let firstPanel = try #require(first.focusedPanelId)
        let secondPanel = try #require(second.focusedPanelId)
        first.panelPrompts[firstPanel] = SidebarPanelPromptState(
            message: "older",
            submittedAt: Date(timeIntervalSince1970: 100)
        )
        second.panelPrompts[secondPanel] = SidebarPanelPromptState(
            message: "newer",
            submittedAt: Date(timeIntervalSince1970: 200)
        )

        let picked = Target.newest(in: manager.tabs.flatMap { $0.lastPromptTargets })

        #expect(picked?.workspaceId == second.id)
        #expect(picked?.panelId == secondPanel)
    }
}
