import Foundation
import Testing
import CmuxTerminalCore

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct TabManagerNotificationFocusRegressionTests {
    @Test
    func focusTabFromNotificationAcceptsBonsplitSurfaceIdForNestedTabNotification() async throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let firstPanelId = try #require(workspace.focusedPanelId)
        let paneId = try #require(workspace.bonsplitController.focusedPaneId)
        _ = workspace.newTerminalSurface(inPane: paneId, focus: false)
        let thirdPanel = try #require(workspace.newTerminalSurface(inPane: paneId, focus: false))
        let thirdSurfaceId = try #require(workspace.surfaceIdFromPanelId(thirdPanel.id)?.uuid)

        workspace.focusPanel(firstPanelId)
        #expect(workspace.focusedPanelId == firstPanelId)
        #expect(manager.focusTabFromNotification(workspace.id, surfaceId: thirdSurfaceId))
        await drainMainQueue()
        await drainMainQueue()

        #expect(workspace.focusedPanelId == thirdPanel.id)
        #expect(workspace.bonsplitController.selectedTab(inPane: paneId)?.id.uuid == thirdSurfaceId)
    }

    /// Regression for https://github.com/manaflow-ai/cmux/issues/6244.
    ///
    /// A split created with an initial command, such as an agent pane spawned by
    /// `surface.split` with `initial_command`, is configured to wait after its
    /// command exits so the user can read its output. When that foreground command
    /// finishes, the child exit must not collapse the split out from under the user.
    @Test
    func childExitKeepsWaitAfterCommandSplitOpen() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let initialPanelId = try #require(workspace.focusedPanelId)

        let splitPanel = try #require(
            workspace.newTerminalSplit(
                from: initialPanelId,
                orientation: .horizontal,
                focus: false,
                initialCommand: "echo subagent"
            )
        )

        #expect(
            splitPanel.surface.waitAfterCommand,
            "A split with an initial command should wait after its command exits"
        )
        #expect(
            splitPanel.surface.initialCommand != nil,
            "A split created with an initial command owns that command"
        )
        #expect(!workspace.isRemoteTerminalSurface(splitPanel.id))
        #expect(
            workspace.shouldKeepSurfaceOpenAfterCommandExit(surfaceId: splitPanel.id),
            "A local split with its own wait-after command must be kept open on child exit"
        )

        // A plain shell split can inherit Ghostty's wait-after-command config bit
        // from a wait-after source pane while still having no command of its own.
        // Headless test panels do not have a live runtime surface for real config
        // inheritance, so seed the equivalent command-less panel with a config
        // template and exercise the real `waitAfterCommand` property.
        let paneId = try #require(workspace.bonsplitController.allPaneIds.first)
        var inheritedWaitAfterConfig = CmuxSurfaceConfigTemplate()
        inheritedWaitAfterConfig.waitAfterCommand = true
        let plainSplit = TerminalPanel(
            workspaceId: workspace.id,
            configTemplate: inheritedWaitAfterConfig
        )
        workspace.panels[plainSplit.id] = plainSplit
        workspace.panelTitles[plainSplit.id] = plainSplit.displayTitle
        let plainSplitTabId = try #require(
            workspace.bonsplitController.createTab(
                title: plainSplit.displayTitle,
                icon: plainSplit.displayIcon,
                kind: SurfaceKind.terminal.rawValue,
                isDirty: plainSplit.isDirty,
                inPane: paneId
            )
        )
        workspace.bindSurface(plainSplitTabId, toPanelId: plainSplit.id)

        #expect(plainSplit.surface.initialCommand == nil, "A plain split has no startup command of its own")
        #expect(
            plainSplit.surface.waitAfterCommand,
            "The command-less split now carries the inherited wait-after-command bit"
        )
        #expect(
            !workspace.shouldKeepSurfaceOpenAfterCommandExit(surfaceId: plainSplit.id),
            "A split with no command of its own must not be kept open after child exit, "
                + "even when it inherited wait-after-command from its source pane"
        )

        let panelsBeforePlainClose = workspace.panels.count
        manager.closePanelAfterChildExited(tabId: workspace.id, surfaceId: plainSplit.id)
        #expect(
            workspace.panels[plainSplit.id] == nil,
            "A command-less split must collapse when its child process exits, "
                + "even with an inherited wait-after-command bit"
        )
        #expect(workspace.panels.count == panelsBeforePlainClose - 1, "Only the command-less split should be removed")

        let panelCountBefore = workspace.panels.count
        manager.closePanelAfterChildExited(tabId: workspace.id, surfaceId: splitPanel.id)

        #expect(manager.tabs.count == 1)
        #expect(
            workspace.panels.count == panelCountBefore,
            "Wait-after-command split must survive its child process exiting"
        )
        #expect(
            workspace.panels[splitPanel.id] != nil,
            "Expected the wait-after-command split to remain open after child exit"
        )
        #expect(workspace.panels[initialPanelId] != nil, "Expected sibling panel to remain")
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
