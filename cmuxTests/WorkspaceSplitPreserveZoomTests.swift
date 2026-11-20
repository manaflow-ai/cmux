import Bonsplit
import Foundation
import GhosttyKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Ghostty's `split-preserve-zoom = navigation` keeps a zoomed split zoomed
/// when focus moves to another split; without it, navigation unzooms first
/// (https://github.com/manaflow-ai/cmux/issues/47784).
@MainActor
@Suite(.serialized)
struct WorkspaceSplitPreserveZoomTests {
    /// Installs the app's Ghostty config with `contents` layered on top and
    /// returns a closure that restores the original.
    private func installGhosttyConfig(_ contents: String) throws -> () -> Void {
        let base = try #require(GhosttyApp.shared.config)
        let clone = try #require(ghostty_config_clone(base))
        contents.withCString { pointer in
            ghostty_config_load_string(
                clone,
                pointer,
                UInt(contents.utf8.count),
                "/__cmux_test__/split-preserve-zoom.conf"
            )
        }
        ghostty_config_finalize(clone)
        #expect(ghostty_config_diagnostics_count(clone) == 0)
        let original = try #require(GhosttyApp.shared.swapConfigForTesting(clone))
        return {
            if let installed = GhosttyApp.shared.swapConfigForTesting(original) {
                ghostty_config_free(installed)
            }
        }
    }

    /// A workspace with a left and a right pane, the left one focused and zoomed.
    private func zoomedTwoPaneWorkspace() throws -> (
        manager: TabManager, workspace: Workspace, left: PaneID, right: PaneID, rightPanelId: UUID
    ) {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let leftPanelId = try #require(workspace.focusedPanelId)
        let left = try #require(workspace.bonsplitController.focusedPaneId)
        let rightPanel = try #require(workspace.newTerminalSplit(from: leftPanelId, orientation: .horizontal))
        let right = try #require(workspace.paneId(forPanelId: rightPanel.id))
        workspace.focusPanel(leftPanelId)
        #expect(workspace.toggleSplitZoom(panelId: leftPanelId))
        #expect(workspace.bonsplitController.zoomedPaneId == left)
        #expect(workspace.bonsplitController.focusedPaneId == left)
        return (manager, workspace, left, right, rightPanel.id)
    }

    @Test func ghosttySplitNavigationKeepsZoomOnReachedPaneWhenPreserveZoomIsNavigation() throws {
        let restore = try installGhosttyConfig("split-preserve-zoom = navigation\n")
        defer { restore() }
        let fixture = try zoomedTwoPaneWorkspace()

        // The Ghostty `goto_split:right` binding goes through this TabManager entry point.
        #expect(fixture.manager.moveSplitFocus(
            tabId: fixture.workspace.id,
            surfaceId: try #require(fixture.workspace.focusedPanelId),
            direction: .right
        ))

        #expect(fixture.workspace.focusedPanelId == fixture.rightPanelId)
        #expect(fixture.workspace.bonsplitController.zoomedPaneId == fixture.right)
    }

    @Test func cyclingSplitsKeepsZoomOnReachedPaneWhenPreserveZoomIsNavigation() throws {
        let restore = try installGhosttyConfig("split-preserve-zoom = navigation\n")
        defer { restore() }
        let fixture = try zoomedTwoPaneWorkspace()

        // `goto_split:next` and cmux's own next-pane shortcut share this path.
        #expect(fixture.manager.cycleSplitFocus(tabId: fixture.workspace.id, forward: true))

        #expect(fixture.workspace.focusedPanelId == fixture.rightPanelId)
        #expect(fixture.workspace.bonsplitController.zoomedPaneId == fixture.right)
    }

    @Test func splitNavigationUnzoomsByDefault() throws {
        let restore = try installGhosttyConfig("split-preserve-zoom =\n")
        defer { restore() }
        let fixture = try zoomedTwoPaneWorkspace()

        #expect(fixture.workspace.moveFocus(direction: .right))

        #expect(fixture.workspace.focusedPanelId == fixture.rightPanelId)
        #expect(fixture.workspace.bonsplitController.zoomedPaneId == nil)
    }

    @Test(arguments: ["split-preserve-zoom = navigation\n", "split-preserve-zoom =\n"])
    func navigationPastTheEdgeKeepsTheZoom(config: String) throws {
        let restore = try installGhosttyConfig(config)
        defer { restore() }
        let fixture = try zoomedTwoPaneWorkspace()

        #expect(!fixture.workspace.moveFocus(direction: .left))

        #expect(fixture.workspace.bonsplitController.focusedPaneId == fixture.left)
        #expect(fixture.workspace.bonsplitController.zoomedPaneId == fixture.left)
    }
}
