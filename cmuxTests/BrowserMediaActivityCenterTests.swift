import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Browser media activity aggregation (#6100)")
struct BrowserMediaActivityCenterTests {
    private func audio() -> PaneMediaActivity {
        PaneMediaActivity(isPlayingAudio: true, isUsingMicrophone: false, isUsingCamera: false)
    }
    private func camera() -> PaneMediaActivity {
        PaneMediaActivity(isPlayingAudio: false, isUsingMicrophone: false, isUsingCamera: true)
    }
    private func mic() -> PaneMediaActivity {
        PaneMediaActivity(isPlayingAudio: false, isUsingMicrophone: true, isUsingCamera: false)
    }

    @Test func aggregatesDistinctPanesOfOneWorkspace() {
        let center = BrowserMediaActivityCenter()
        let workspace = UUID()
        center.update(panelId: UUID(), workspaceId: workspace, activity: audio())
        center.update(panelId: UUID(), workspaceId: workspace, activity: camera())

        let activity = center.currentWorkspaceActivity[workspace]
        #expect(activity?.isPlayingAudio == true)
        #expect(activity?.isUsingCamera == true)
        #expect(activity?.isUsingMicrophone == false)
    }

    @Test func keepsWorkspacesIndependent() {
        let center = BrowserMediaActivityCenter()
        let a = UUID()
        let b = UUID()
        center.update(panelId: UUID(), workspaceId: a, activity: audio())
        center.update(panelId: UUID(), workspaceId: b, activity: mic())

        #expect(center.currentWorkspaceActivity[a]?.isPlayingAudio == true)
        #expect(center.currentWorkspaceActivity[a]?.isUsingMicrophone == false)
        #expect(center.currentWorkspaceActivity[b]?.isUsingMicrophone == true)
        #expect(center.currentWorkspaceActivity[b]?.isPlayingAudio == false)
    }

    @Test func inactiveActivityDropsThePane() {
        let center = BrowserMediaActivityCenter()
        let workspace = UUID()
        let panel = UUID()
        center.update(panelId: panel, workspaceId: workspace, activity: audio())
        #expect(center.currentWorkspaceActivity[workspace] != nil)

        center.update(panelId: panel, workspaceId: workspace, activity: .none)
        #expect(center.currentWorkspaceActivity[workspace] == nil)
    }

    @Test func removingLastActivePaneClearsWorkspace() {
        let center = BrowserMediaActivityCenter()
        let workspace = UUID()
        let panel = UUID()
        center.update(panelId: panel, workspaceId: workspace, activity: camera())
        center.remove(panelId: panel)
        #expect(center.currentWorkspaceActivity[workspace] == nil)
    }

    @Test func movingPaneRehomesActivityToNewWorkspace() {
        let center = BrowserMediaActivityCenter()
        let oldWorkspace = UUID()
        let newWorkspace = UUID()
        let panel = UUID()
        center.update(panelId: panel, workspaceId: oldWorkspace, activity: audio())
        center.update(panelId: panel, workspaceId: newWorkspace, activity: audio())

        #expect(center.currentWorkspaceActivity[oldWorkspace] == nil)
        #expect(center.currentWorkspaceActivity[newWorkspace]?.isPlayingAudio == true)
    }

    @Test func onlyNotifiesOnRealChange() {
        let center = BrowserMediaActivityCenter()
        var notifications = 0
        center.onActivityChanged = { _ in notifications += 1 }
        let workspace = UUID()
        let panel = UUID()

        center.update(panelId: panel, workspaceId: workspace, activity: audio())
        #expect(notifications == 1)

        // Identical activity for the same pane must not re-emit.
        center.update(panelId: panel, workspaceId: workspace, activity: audio())
        #expect(notifications == 1)

        // A new dimension is a real change.
        center.update(
            panelId: panel,
            workspaceId: workspace,
            activity: PaneMediaActivity(isPlayingAudio: true, isUsingMicrophone: false, isUsingCamera: true)
        )
        #expect(notifications == 2)
    }

    @Test func aggregateFoldIsPureAndOrderIndependent() {
        let workspace = UUID()
        let entries: [UUID: BrowserMediaActivityEntry] = [
            UUID(): BrowserMediaActivityEntry(workspaceId: workspace, activity: mic()),
            UUID(): BrowserMediaActivityEntry(workspaceId: workspace, activity: camera()),
        ]
        let folded = BrowserMediaActivityCenter.aggregate(entries)
        #expect(folded[workspace] == WorkspaceMediaActivity(
            isPlayingAudio: false,
            isUsingMicrophone: true,
            isUsingCamera: true
        ))
    }
}
