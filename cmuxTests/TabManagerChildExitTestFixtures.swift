import XCTest
import Combine

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
private final class TabManagerChildExitFixturePanel: Panel {
    let objectWillChange = ObservableObjectPublisher()
    let id = UUID()
    let panelType: PanelType = .terminal
    let displayTitle = "Remote test"
    let displayIcon: String? = "terminal.fill"
    let isDirty = false

    func close() {}
    func focus() {}
    func unfocus() {}
    func triggerFlash(reason: WorkspaceAttentionFlashReason) {}
}

@MainActor
func makeTabManagerChildExitFixture(
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> (manager: TabManager, workspace: Workspace, panelId: UUID) {
    let manager = TabManager(debugCreateInitialWorkspace: false)
    let panel = TabManagerChildExitFixturePanel()
    let workspace = Workspace(
        title: "Terminal",
        initialDetachedSurface: Workspace.DetachedSurfaceTransfer(
            sourceWorkspaceId: UUID(),
            panelId: panel.id,
            panel: panel,
            title: panel.displayTitle,
            icon: panel.displayIcon,
            iconImageData: nil,
            kind: "terminal",
            isLoading: false,
            isPinned: false,
            directory: nil,
            ttyName: nil,
            cachedTitle: nil,
            customTitle: nil,
            manuallyUnread: false,
            restoredUnreadIndicator: nil,
            restorableAgent: nil,
            restorableAgentResumeState: nil,
            resumeBinding: nil,
            agentRuntime: nil,
            isRemoteTerminal: false,
            remoteRelayPort: nil,
            remotePTYSessionID: nil,
            remoteCleanupConfiguration: nil
        )
    )
    workspace.owningTabManager = manager
    manager.tabs = [workspace]
    manager.selectedTabId = workspace.id

    let paneId = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first, file: file, line: line)
    let surfaceId = try XCTUnwrap(workspace.surfaceIdFromPanelId(panel.id), file: file, line: line)
    workspace.bonsplitController.focusPane(paneId)
    workspace.bonsplitController.selectTab(surfaceId)
    return (manager, workspace, panel.id)
}
