import XCTest
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
import Bonsplit
import UserNotifications
import Combine

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Fork agent conversation
extension WorkspacePanelGitBranchTests {
    private func rootSplit(in workspace: Workspace) throws -> ExternalSplitNode {
        switch workspace.bonsplitController.treeSnapshot() {
        case .split(let split):
            return split
        case .pane:
            let split: ExternalSplitNode? = nil
            return try XCTUnwrap(split, "Expected workspace root to be a split")
        }
    }

    private func paneId(in node: ExternalTreeNode) throws -> String {
        switch node {
        case .pane(let pane):
            return pane.id
        case .split:
            let paneId: String? = nil
            return try XCTUnwrap(paneId, "Expected split child to be a pane")
        }
    }

    func testForkAgentConversationToRightCreatesRightSplitWithForkStartupInput() throws {
        let workspace = Workspace()
        let sourcePanelId = try XCTUnwrap(workspace.focusedPanelId)
        let sourcePanel = try XCTUnwrap(workspace.terminalPanel(for: sourcePanelId))
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "019dad34-d218-7943-b81a-eddac5c87951",
            workingDirectory: "/tmp/fork repo",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "/Users/example/.bun/bin/codex",
                arguments: [
                    "/Users/example/.bun/bin/codex",
                    "--model",
                    "gpt-5.4",
                    "--search",
                    "initial prompt should not replay"
                ],
                workingDirectory: "/tmp/fork repo",
                environment: ["CODEX_HOME": "/tmp/codex"],
                capturedAt: 123,
                source: "process"
            )
        )

        let forkPanel = try XCTUnwrap(
            workspace.forkAgentConversation(
                fromPanelId: sourcePanelId,
                snapshot: snapshot,
                direction: .right
            )
        )

        XCTAssertNotEqual(forkPanel.id, sourcePanelId)
        XCTAssertEqual(workspace.terminalPanel(for: sourcePanelId)?.id, sourcePanel.id)
        XCTAssertEqual(workspace.bonsplitController.allPaneIds.count, 2)
        XCTAssertEqual(workspace.focusedPanelId, forkPanel.id)
        XCTAssertEqual(forkPanel.requestedWorkingDirectory, "/tmp/fork repo")
        XCTAssertEqual(forkPanel.surface.initialInput, snapshot.forkCommand.map { $0 + "\n" })
        let split = try rootSplit(in: workspace)
        let sourcePaneId = try XCTUnwrap(workspace.paneId(forPanelId: sourcePanelId)).id.uuidString
        let forkPaneId = try XCTUnwrap(workspace.paneId(forPanelId: forkPanel.id)).id.uuidString
        XCTAssertEqual(split.orientation, "horizontal")
        XCTAssertEqual(try paneId(in: split.first), sourcePaneId)
        XCTAssertEqual(try paneId(in: split.second), forkPaneId)
    }

    func testForkAgentConversationSupportsAllSplitDirections() throws {
        for direction in [SplitDirection.left, .right, .up, .down] {
            let workspace = Workspace()
            let sourcePanelId = try XCTUnwrap(workspace.focusedPanelId)
            let snapshot = SessionRestorableAgentSnapshot(
                kind: .codex,
                sessionId: "019dad34-d218-7943-b81a-eddac5c87951",
                workingDirectory: "/tmp/fork repo",
                launchCommand: AgentLaunchCommandSnapshot(
                    launcher: "codex",
                    executablePath: "/Users/example/.bun/bin/codex",
                    arguments: ["/Users/example/.bun/bin/codex", "--search"],
                    workingDirectory: "/tmp/fork repo",
                    environment: nil,
                    capturedAt: 123,
                    source: "process"
                )
            )

            let forkPanel = try XCTUnwrap(
                workspace.forkAgentConversation(
                    fromPanelId: sourcePanelId,
                    snapshot: snapshot,
                    direction: direction
                )
            )

            XCTAssertNotEqual(forkPanel.id, sourcePanelId)
            XCTAssertEqual(workspace.bonsplitController.allPaneIds.count, 2)
            XCTAssertEqual(workspace.focusedPanelId, forkPanel.id)
            XCTAssertEqual(forkPanel.requestedWorkingDirectory, "/tmp/fork repo")
            XCTAssertEqual(forkPanel.surface.initialInput, snapshot.forkCommand.map { $0 + "\n" })
            let split = try rootSplit(in: workspace)
            let sourcePaneId = try XCTUnwrap(workspace.paneId(forPanelId: sourcePanelId)).id.uuidString
            let forkPaneId = try XCTUnwrap(workspace.paneId(forPanelId: forkPanel.id)).id.uuidString
            XCTAssertEqual(split.orientation, direction.isHorizontal ? "horizontal" : "vertical")
            XCTAssertEqual(
                try paneId(in: split.first),
                direction.insertFirst ? forkPaneId : sourcePaneId
            )
            XCTAssertEqual(
                try paneId(in: split.second),
                direction.insertFirst ? sourcePaneId : forkPaneId
            )
        }
    }

    func testForkAgentConversationUsesWorkspaceDirectoryFallback() throws {
        let workspace = Workspace()
        workspace.currentDirectory = "/tmp/workspace fork repo"
        let sourcePanelId = try XCTUnwrap(workspace.focusedPanelId)
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "019dad34-d218-7943-b81a-eddac5c87951",
            workingDirectory: nil,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "/Users/example/.bun/bin/codex",
                arguments: ["/Users/example/.bun/bin/codex"],
                workingDirectory: nil,
                environment: nil,
                capturedAt: 123,
                source: "process"
            )
        )

        let forkPanel = try XCTUnwrap(
            workspace.forkAgentConversation(
                fromPanelId: sourcePanelId,
                snapshot: snapshot,
                direction: .right
            )
        )

        XCTAssertEqual(forkPanel.requestedWorkingDirectory, "/tmp/workspace fork repo")
        XCTAssertEqual(
            forkPanel.surface.initialInput,
            "{ cd -- '/tmp/workspace fork repo' 2>/dev/null || [ ! -d '/tmp/workspace fork repo' ]; } && '/Users/example/.bun/bin/codex' 'fork' '019dad34-d218-7943-b81a-eddac5c87951'\n"
        )
    }

    private func makeForkableClaudeSnapshot(
        sessionId: String = "019dad34-d218-7943-b81a-eddac5c87951",
        workingDirectory: String = "/tmp/fork repo"
    ) -> SessionRestorableAgentSnapshot {
        SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: sessionId,
            workingDirectory: workingDirectory,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "claude",
                executablePath: "/opt/homebrew/bin/claude",
                arguments: ["/opt/homebrew/bin/claude"],
                workingDirectory: workingDirectory,
                environment: nil,
                capturedAt: 123,
                source: "process"
            )
        )
    }

    private func makeForkableCodexSnapshot(
        sessionId: String = "019dad34-d218-7943-b81a-eddac5c87951",
        workingDirectory: String = "/tmp/fork repo"
    ) -> SessionRestorableAgentSnapshot {
        SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: sessionId,
            workingDirectory: workingDirectory,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "/Users/example/.bun/bin/codex",
                arguments: ["/Users/example/.bun/bin/codex"],
                workingDirectory: workingDirectory,
                environment: nil,
                capturedAt: 123,
                source: "process"
            )
        )
    }

    func testForkAgentConversationToNewTabCreatesSiblingTabWithForkStartupInput() throws {
        let workspace = Workspace()
        let sourcePanelId = try XCTUnwrap(workspace.focusedPanelId)
        let sourcePaneId = try XCTUnwrap(workspace.paneId(forPanelId: sourcePanelId))
        let anchorTabId = try XCTUnwrap(workspace.surfaceIdFromPanelId(sourcePanelId))
        let snapshot = makeForkableClaudeSnapshot()

        let forkPanel = try XCTUnwrap(
            workspace.forkAgentConversationToNewTab(
                fromPanelId: sourcePanelId,
                snapshot: snapshot,
                anchorTabId: anchorTabId,
                paneId: sourcePaneId
            )
        )

        XCTAssertNotEqual(forkPanel.id, sourcePanelId)
        XCTAssertEqual(
            workspace.paneId(forPanelId: forkPanel.id),
            sourcePaneId,
            "Fork should land in the same pane as the source tab, not a split pane"
        )
        XCTAssertEqual(
            workspace.bonsplitController.allPaneIds.count,
            1,
            "Fork creates a sibling tab, not a new pane"
        )
        XCTAssertEqual(
            workspace.bonsplitController.tabs(inPane: sourcePaneId).count,
            2,
            "Pane should now host both the source and forked tabs"
        )
        XCTAssertEqual(workspace.focusedPanelId, forkPanel.id, "Fork should focus the new tab")
        XCTAssertEqual(forkPanel.requestedWorkingDirectory, "/tmp/fork repo")
        XCTAssertEqual(
            forkPanel.surface.initialInput,
            snapshot.forkCommand.map { $0 + "\n" },
            "Forked tab should boot with the snapshot's --fork-session command"
        )
    }

    func testForkAgentConversationToNewTabPlacesForkImmediatelyRightOfAnchor() throws {
        let workspace = Workspace()
        let sourcePanelId = try XCTUnwrap(workspace.focusedPanelId)
        let sourcePaneId = try XCTUnwrap(workspace.paneId(forPanelId: sourcePanelId))
        let anchorTabId = try XCTUnwrap(workspace.surfaceIdFromPanelId(sourcePanelId))

        // Drop a second unrelated terminal tab to the right of the source so we can
        // verify the fork lands *between* the source and the unrelated tab, not at the
        // end of the strip.
        let trailingPanel = try XCTUnwrap(
            workspace.newTerminalSurface(inPane: sourcePaneId, focus: false)
        )
        XCTAssertEqual(workspace.bonsplitController.tabs(inPane: sourcePaneId).count, 2)

        let snapshot = makeForkableClaudeSnapshot()
        let forkPanel = try XCTUnwrap(
            workspace.forkAgentConversationToNewTab(
                fromPanelId: sourcePanelId,
                snapshot: snapshot,
                anchorTabId: anchorTabId,
                paneId: sourcePaneId
            )
        )

        let tabIdsInOrder = workspace.bonsplitController.tabs(inPane: sourcePaneId).map(\.id)
        let sourceTabId = try XCTUnwrap(workspace.surfaceIdFromPanelId(sourcePanelId))
        let forkTabId = try XCTUnwrap(workspace.surfaceIdFromPanelId(forkPanel.id))
        let trailingTabId = try XCTUnwrap(workspace.surfaceIdFromPanelId(trailingPanel.id))
        XCTAssertEqual(
            tabIdsInOrder,
            [sourceTabId, forkTabId, trailingTabId],
            "Fork should be inserted immediately to the right of its source tab"
        )
    }

    func testCanForkAgentConversationFromPanelReturnsTrueForRestoredClaudeSnapshot() throws {
        let workspace = Workspace()
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        XCTAssertFalse(
            workspace.canForkAgentConversationFromPanel(panelId),
            "Vanilla shell tab without an agent snapshot should not advertise fork"
        )

        workspace.setRestoredAgentSnapshotForTesting(makeForkableClaudeSnapshot(), panelId: panelId)
        XCTAssertTrue(
            workspace.canForkAgentConversationFromPanel(panelId),
            "Tab hosting a restored Claude snapshot should advertise fork"
        )
    }

    func testCanForkAgentConversationFromPanelReturnsFalseForUnknownPanel() {
        let workspace = Workspace()
        XCTAssertFalse(workspace.canForkAgentConversationFromPanel(UUID()))
    }

    func testForkConversationDefaultSettingFallsBackToRight() throws {
        let suiteName = "cmux.forkConversationDefault.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(
            AgentConversationForkDefaultSettings.current(defaults: defaults),
            .right,
            "Missing setting should use the product default"
        )

        defaults.set(AgentConversationForkDestination.newTab.rawValue, forKey: AgentConversationForkDefaultSettings.key)
        XCTAssertEqual(AgentConversationForkDefaultSettings.current(defaults: defaults), .newTab)

        defaults.set("unsupported", forKey: AgentConversationForkDefaultSettings.key)
        XCTAssertEqual(
            AgentConversationForkDefaultSettings.current(defaults: defaults),
            .right,
            "Invalid settings file values should fall back to the product default"
        )
    }

    func testForkConversationContextMenuDefaultActionWorksForCodexSnapshot() throws {
        // Parity coverage with the Claude path: Codex sessions are also `.supportedWithoutProbe`
        // and should reach the default right-split path through the context-menu dispatcher.
        let defaults = UserDefaults.standard
        let previousValue = defaults.object(forKey: AgentConversationForkDefaultSettings.key)
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: AgentConversationForkDefaultSettings.key)
            } else {
                defaults.removeObject(forKey: AgentConversationForkDefaultSettings.key)
            }
        }
        defaults.removeObject(forKey: AgentConversationForkDefaultSettings.key)

        let workspace = Workspace()
        let sourcePanelId = try XCTUnwrap(workspace.focusedPanelId)
        let sourcePaneId = try XCTUnwrap(workspace.paneId(forPanelId: sourcePanelId))
        let anchorTabId = try XCTUnwrap(workspace.surfaceIdFromPanelId(sourcePanelId))
        let snapshot = makeForkableCodexSnapshot()
        workspace.setRestoredAgentSnapshotForTesting(snapshot, panelId: sourcePanelId)

        XCTAssertTrue(workspace.canForkAgentConversationFromPanel(sourcePanelId))

        let anchorTab = try XCTUnwrap(
            workspace.bonsplitController.tabs(inPane: sourcePaneId).first { $0.id == anchorTabId }
        )

        workspace.splitTabBar(
            workspace.bonsplitController,
            didRequestTabContextAction: .forkConversation,
            for: anchorTab,
            inPane: sourcePaneId
        )

        let forkPanelId = try XCTUnwrap(workspace.focusedPanelId)
        XCTAssertNotEqual(forkPanelId, sourcePanelId, "Codex fork should focus the new split")
        let forkPanel = try XCTUnwrap(workspace.terminalPanel(for: forkPanelId))
        XCTAssertEqual(workspace.bonsplitController.allPaneIds.count, 2)
        XCTAssertEqual(
            forkPanel.surface.initialInput,
            snapshot.forkCommand.map { $0 + "\n" },
            "Codex fork split should boot with the Codex --fork-session command"
        )
        let split = try rootSplit(in: workspace)
        let sourcePaneUUID = sourcePaneId.id.uuidString
        let forkPaneUUID = try XCTUnwrap(workspace.paneId(forPanelId: forkPanelId)).id.uuidString
        XCTAssertEqual(split.orientation, "horizontal")
        XCTAssertEqual(try paneId(in: split.first), sourcePaneUUID)
        XCTAssertEqual(try paneId(in: split.second), forkPaneUUID)
    }

    func testForkConversationContextMenuNewTabActionCreatesSiblingTab() throws {
        // Drive the same code path the bonsplit context menu triggers, end-to-end,
        // to lock in that the menu wiring stays connected.
        let workspace = Workspace()
        let sourcePanelId = try XCTUnwrap(workspace.focusedPanelId)
        let sourcePaneId = try XCTUnwrap(workspace.paneId(forPanelId: sourcePanelId))
        let anchorTabId = try XCTUnwrap(workspace.surfaceIdFromPanelId(sourcePanelId))
        workspace.setRestoredAgentSnapshotForTesting(makeForkableClaudeSnapshot(), panelId: sourcePanelId)

        let tabs = workspace.bonsplitController.tabs(inPane: sourcePaneId)
        let anchorTab = try XCTUnwrap(tabs.first { $0.id == anchorTabId })

        workspace.splitTabBar(
            workspace.bonsplitController,
            didRequestTabContextAction: .forkConversationNewTab,
            for: anchorTab,
            inPane: sourcePaneId
        )

        XCTAssertEqual(
            workspace.bonsplitController.tabs(inPane: sourcePaneId).count,
            2,
            "Fork Conversation New Tab context action should spawn a sibling tab"
        )
        XCTAssertEqual(
            workspace.bonsplitController.allPaneIds.count,
            1,
            "Fork Conversation New Tab should not create a split pane"
        )
    }

    func testForkConversationContextMenuPrimaryActionUsesConfiguredDefault() throws {
        let defaults = UserDefaults.standard
        let previousValue = defaults.object(forKey: AgentConversationForkDefaultSettings.key)
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: AgentConversationForkDefaultSettings.key)
            } else {
                defaults.removeObject(forKey: AgentConversationForkDefaultSettings.key)
            }
        }
        defaults.set(AgentConversationForkDestination.newTab.rawValue, forKey: AgentConversationForkDefaultSettings.key)

        let workspace = Workspace()
        let sourcePanelId = try XCTUnwrap(workspace.focusedPanelId)
        let sourcePaneId = try XCTUnwrap(workspace.paneId(forPanelId: sourcePanelId))
        let anchorTabId = try XCTUnwrap(workspace.surfaceIdFromPanelId(sourcePanelId))
        workspace.setRestoredAgentSnapshotForTesting(makeForkableClaudeSnapshot(), panelId: sourcePanelId)

        let anchorTab = try XCTUnwrap(
            workspace.bonsplitController.tabs(inPane: sourcePaneId).first { $0.id == anchorTabId }
        )

        workspace.splitTabBar(
            workspace.bonsplitController,
            didRequestTabContextAction: .forkConversation,
            for: anchorTab,
            inPane: sourcePaneId
        )

        XCTAssertEqual(
            workspace.bonsplitController.tabs(inPane: sourcePaneId).count,
            2,
            "Configured default should control the primary Fork Conversation context action"
        )
        XCTAssertEqual(
            workspace.bonsplitController.allPaneIds.count,
            1,
            "Configured New Tab default should keep the fork in the source pane"
        )
    }
}
