import XCTest
import Combine

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class AppDelegateMoveTabToNewWorkspaceTests: XCTestCase {
    private final class MoveFixturePanel: NSObject, Panel, ObservableObject {
        let id = UUID()
        let panelType: PanelType = .project
        let title: String

        init(title: String) {
            self.title = title
            super.init()
        }

        var displayTitle: String { title }
        var displayIcon: String? { "hammer" }
        var isDirty: Bool { false }

        func close() {}
        func focus() {}
        func unfocus() {}
        func triggerFlash(reason: WorkspaceAttentionFlashReason) {}
    }

    func testMoveSurfaceToNewWorkspaceCreatesSinglePanelWorkspaceFromPanelTitle() throws {
        let movedPanel = MoveFixturePanel(title: "Build")
        let transfer = try makeMoveTransfer(panel: movedPanel, title: movedPanel.displayTitle)

        let request = AppDelegate.surfaceNewWorkspaceCreationRequest(
            detached: transfer,
            explicitTitle: nil,
            panelTitle: "Build logs",
            panel: movedPanel
        )

        let requestPanel = try XCTUnwrap(request.detached.panel as? MoveFixturePanel)
        XCTAssertTrue(requestPanel === movedPanel)
        XCTAssertEqual(request.detached.panelId, movedPanel.id)
        XCTAssertEqual(request.title, "Build logs")
        XCTAssertEqual(
            AppDelegate.titleForDetachedWorkspace(
                explicitTitle: "  Deploy  ",
                panelTitle: "Build logs",
                panelDisplayTitle: movedPanel.displayTitle
            ),
            "Deploy"
        )
        XCTAssertEqual(
            AppDelegate.titleForDetachedWorkspace(
                explicitTitle: nil,
                panelTitle: nil,
                panelDisplayTitle: movedPanel.displayTitle
            ),
            "Build"
        )
    }

    func testMoveSurfaceToNewWorkspacePreservesDetachedPanelInstanceWhenDefaultsChange() throws {
        let defaults = UserDefaults.standard
        let showKey = TerminalTextBoxInputSettings.showOnNewTerminalsKey
        let focusKey = TerminalTextBoxInputSettings.focusOnNewTerminalsKey
        let previousShowValue = defaults.object(forKey: showKey)
        let previousFocusValue = defaults.object(forKey: focusKey)
        defer {
            if let previousShowValue {
                defaults.set(previousShowValue, forKey: showKey)
            } else {
                defaults.removeObject(forKey: showKey)
            }
            if let previousFocusValue {
                defaults.set(previousFocusValue, forKey: focusKey)
            } else {
                defaults.removeObject(forKey: focusKey)
            }
        }

        defaults.set(false, forKey: showKey)
        defaults.set(false, forKey: focusKey)

        let movedPanel = MoveFixturePanel(title: "Moved")
        let transfer = try makeMoveTransfer(panel: movedPanel, title: movedPanel.displayTitle)

        defaults.set(true, forKey: showKey)
        defaults.set(true, forKey: focusKey)

        let request = AppDelegate.surfaceNewWorkspaceCreationRequest(
            detached: transfer,
            explicitTitle: nil,
            panelTitle: nil,
            panel: movedPanel
        )

        let requestPanel = try XCTUnwrap(request.detached.panel as? MoveFixturePanel)
        XCTAssertTrue(requestPanel === movedPanel)
        XCTAssertEqual(request.title, "Moved")
    }

    func testBrowserNewWorkspaceMoveRequestsAddressBarFocusIntent() throws {
        let focusIntent = AppDelegate.focusIntentForNewWorkspaceMove(
            panelType: .browser,
            preferredFocusIntent: .browser(.webView)
        )

        XCTAssertEqual(focusIntent, .browser(.addressBar))
    }

    func testMoveSurfaceToNewWorkspaceRejectsOnlyPanel() {
        XCTAssertFalse(AppDelegate.canMoveSurfaceToNewWorkspace(
            sourceContainsPanel: true,
            sourcePanelCount: 1
        ))
        XCTAssertFalse(AppDelegate.canMoveSurfaceToNewWorkspace(
            sourceContainsPanel: false,
            sourcePanelCount: 2
        ))
        XCTAssertTrue(AppDelegate.canMoveSurfaceToNewWorkspace(
            sourceContainsPanel: true,
            sourcePanelCount: 2
        ))
    }

    func testMoveBonsplitTabRouteClosesEmptiedSourceWorkspaceAfterDetachedMove() throws {
        XCTAssertEqual(
            AppDelegate.emptySourceWorkspaceCleanupAction(
                sourceWorkspaceIsEmpty: true,
                sourceWorkspaceIsRegistered: true,
                sourceWorkspaceCount: 2
            ),
            .closeWorkspace
        )
        XCTAssertNil(AppDelegate.emptySourceWorkspaceCleanupAction(
            sourceWorkspaceIsEmpty: false,
            sourceWorkspaceIsRegistered: true,
            sourceWorkspaceCount: 2
        ))
        XCTAssertNil(AppDelegate.emptySourceWorkspaceCleanupAction(
            sourceWorkspaceIsEmpty: true,
            sourceWorkspaceIsRegistered: false,
            sourceWorkspaceCount: 2
        ))
    }

    func testExistingWorkspaceDetachedMoveClosesEmptiedSourceWorkspaceAndFocusesDestination() throws {
        XCTAssertEqual(
            AppDelegate.surfaceMovePostAttachActions(
                focus: true,
                sourceWorkspaceIsEmpty: true,
                sourceWorkspaceIsRegistered: true,
                sourceWorkspaceCount: 2
            ),
            [
                .focusDestination,
                .cleanupEmptySourceWorkspace(.closeWorkspace)
            ]
        )
        XCTAssertEqual(
            AppDelegate.surfaceMovePostAttachActions(
                focus: false,
                sourceWorkspaceIsEmpty: true,
                sourceWorkspaceIsRegistered: true,
                sourceWorkspaceCount: 1
            ),
            [
                .cleanupEmptySourceWorkspace(.closeWindow)
            ]
        )
    }

    private func makeMoveTransfer(
        sourceWorkspaceId: UUID = UUID(),
        panel providedPanel: MoveFixturePanel? = nil,
        title: String
    ) throws -> Workspace.DetachedSurfaceTransfer {
        let panel: MoveFixturePanel
        if let providedPanel {
            panel = providedPanel
        } else {
            panel = MoveFixturePanel(title: title)
        }
        return Workspace.DetachedSurfaceTransfer(
            sourceWorkspaceId: sourceWorkspaceId,
            panelId: panel.id,
            panel: panel,
            title: title,
            icon: panel.displayIcon,
            iconImageData: nil,
            kind: "project",
            isLoading: false,
            isPinned: false,
            directory: nil,
            ttyName: nil,
            cachedTitle: panel.displayTitle,
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
    }
}
