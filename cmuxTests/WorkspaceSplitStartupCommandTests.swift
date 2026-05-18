import XCTest
import AppKit
import Bonsplit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

private func workspaceSplitNodes(in node: ExternalTreeNode) -> [ExternalSplitNode] {
    switch node {
    case .pane:
        return []
    case .split(let split):
        return [split] + workspaceSplitNodes(in: split.first) + workspaceSplitNodes(in: split.second)
    }
}

@MainActor
final class WorkspaceSplitStartupCommandTests: XCTestCase {
    private func waitForCondition(
        timeout: TimeInterval = 2,
        pollInterval: TimeInterval = 0.01,
        _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if condition() {
                return true
            }
            RunLoop.current.run(until: Date.now.addingTimeInterval(pollInterval))
        }
        return condition()
    }

    private func hostTerminalPanelInWindow(_ panel: TerminalPanel) throws -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 280),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let contentView = try XCTUnwrap(window.contentView)
        let hostedView = panel.hostedView
        hostedView.frame = contentView.bounds
        hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostedView)
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        XCTAssertTrue(
            waitForCondition {
                panel.surface.surface != nil
            },
            "Expected runtime surface to materialize after hosting panel in a window"
        )
        return window
    }

    func testTabManagerSplitCarriesRequestedWorkingDirectoryAndStartupCommand() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let sourcePanelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace with a focused terminal")
            return
        }

        let requestedDirectory = "/tmp/cmux-split-startup-\(UUID().uuidString)"
        let startupCommand = "/tmp/cmux-tmux-command-\(UUID().uuidString).sh"
        let tmuxStartCommand = "node /opt/oh-my-codex/dist/omx.js hud --watch"
        let initialDividerPosition = 0.875
        guard let splitPanelId = manager.newSplit(
            tabId: workspace.id,
            surfaceId: sourcePanelId,
            direction: .down,
            focus: false,
            workingDirectory: requestedDirectory,
            initialCommand: startupCommand,
            tmuxStartCommand: tmuxStartCommand,
            initialDividerPosition: initialDividerPosition
        ) else {
            XCTFail("Expected split terminal panel to be created")
            return
        }

        guard let splitPanel = workspace.terminalPanel(for: splitPanelId) else {
            XCTFail("Expected split terminal panel to resolve")
            return
        }
        XCTAssertEqual(splitPanel.requestedWorkingDirectory, requestedDirectory)
        XCTAssertEqual(
            splitPanel.surface.debugInitialCommand(),
            startupCommand,
            "Programmatic tmux-compatible splits must launch their command as the pane process"
        )
        XCTAssertEqual(
            splitPanel.surface.debugTmuxStartCommand(),
            tmuxStartCommand,
            "Programmatic tmux-compatible splits must preserve the original tmux command for pane format queries"
        )
        XCTAssertFalse(
            splitPanel.surface.debugConfigTemplateWaitAfterCommand(),
            "Startup-command splits must not ask Ghostty to retain a child-exited PTY"
        )
        guard let split = workspaceSplitNodes(in: workspace.bonsplitController.treeSnapshot()).first else {
            XCTFail("Expected split terminal panel to create a split node")
            return
        }
        XCTAssertEqual(split.orientation, "vertical")
        XCTAssertEqual(
            split.dividerPosition,
            initialDividerPosition,
            accuracy: 0.000_1,
            "Programmatic tmux-compatible splits should enter layout with their requested divider"
        )
    }

    func testNewTerminalSurfaceCarriesRequestedWorkingDirectoryAndStartupCommand() {
        let workspace = Workspace()
        guard let paneId = workspace.bonsplitController.focusedPaneId else {
            XCTFail("Expected focused pane in new workspace")
            return
        }

        let requestedDirectory = "/tmp/cmux-surface-startup-\(UUID().uuidString)"
        let startupCommand = "/tmp/cmux-surface-command-\(UUID().uuidString).sh"
        let tmuxStartCommand = "node /opt/oh-my-codex/dist/omx.js hud --watch"
        guard let surface = workspace.newTerminalSurface(
            inPane: paneId,
            focus: false,
            workingDirectory: requestedDirectory,
            initialCommand: startupCommand,
            tmuxStartCommand: tmuxStartCommand
        ) else {
            XCTFail("Expected terminal surface to be created")
            return
        }

        XCTAssertEqual(surface.requestedWorkingDirectory, requestedDirectory)
        XCTAssertEqual(surface.surface.debugInitialCommand(), startupCommand)
        XCTAssertEqual(surface.surface.debugTmuxStartCommand(), tmuxStartCommand)
        XCTAssertFalse(
            surface.surface.debugConfigTemplateWaitAfterCommand(),
            "Startup-command tabs must not ask Ghostty to retain a child-exited PTY"
        )
    }

    func testInitialWorkspaceStartupCommandDoesNotRequestWaitAfterCommand() throws {
        let startupCommand = "/bin/cat"
        let workspace = Workspace(initialTerminalCommand: startupCommand)
        defer { workspace.teardownAllPanels() }
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let panel = try XCTUnwrap(workspace.terminalPanel(for: panelId))

        XCTAssertEqual(panel.surface.debugInitialCommand(), startupCommand)
        XCTAssertFalse(
            panel.surface.debugConfigTemplateWaitAfterCommand(),
            "Initial startup commands must close through the normal child-exit lifecycle instead of retaining a dead PTY"
        )
    }

    func testRemoteSplitStartupCommandDoesNotRequestWaitAfterCommand() throws {
        let workspace = Workspace()
        guard let paneId = workspace.bonsplitController.focusedPaneId else {
            XCTFail("Expected focused pane in new workspace")
            return
        }

        let panel = try XCTUnwrap(workspace.splitPaneWithNewTerminal(
            targetPane: paneId,
            orientation: .vertical,
            insertFirst: false,
            workingDirectory: nil,
            initialInput: nil,
            remoteStartupCommand: "ssh example.com"
        ))

        XCTAssertEqual(panel.surface.debugInitialCommand(), "ssh example.com")
        XCTAssertFalse(
            panel.surface.debugConfigTemplateWaitAfterCommand(),
            "Remote startup splits must not ask Ghostty to retain a child-exited PTY"
        )
    }

    func testRuntimeSurfaceDisablesWaitAfterCommandEvenWhenTemplateRequestsIt() throws {
        var template = CmuxSurfaceConfigTemplate()
        template.waitAfterCommand = true
        let panel = TerminalPanel(
            workspaceId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_TAB,
            configTemplate: template,
            initialCommand: "/bin/cat"
        )
        let window = try hostTerminalPanelInWindow(panel)
        defer {
            panel.close()
            window.close()
        }

        XCTAssertEqual(panel.surface.debugInitialCommand(), "/bin/cat")
        XCTAssertFalse(
            try XCTUnwrap(panel.surface.debugRuntimeWaitAfterCommand(context: GHOSTTY_SURFACE_CONTEXT_TAB)),
            "cmux must override inherited/user wait-after-command before creating the Ghostty runtime surface"
        )
    }

    func testSessionRestoreRelaunchesOMXHudTmuxStartCommand() throws {
        let workspace = Workspace()
        let sourcePanelId = try XCTUnwrap(workspace.focusedPanelId)
        let requestedDirectory = "/tmp/cmux-hud-restore-\(UUID().uuidString)"
        let originalStartupScript = "/tmp/cmux-tmux-command-\(UUID().uuidString).sh"
        let tmuxStartCommand = "env OMX_SESSION_ID=omx-test node '/opt/oh-my-codex/dist/cli/omx.js' hud --watch"
        let hudPanel = try XCTUnwrap(workspace.newTerminalSplit(
            from: sourcePanelId,
            orientation: .vertical,
            insertFirst: false,
            focus: false,
            workingDirectory: requestedDirectory,
            initialCommand: originalStartupScript,
            tmuxStartCommand: tmuxStartCommand,
            initialDividerPosition: 0.82
        ))

        let snapshot = workspace.sessionSnapshot(includeScrollback: false)
        let hudSnapshot = try XCTUnwrap(snapshot.panels.first { $0.id == hudPanel.id })
        XCTAssertEqual(hudSnapshot.terminal?.tmuxStartCommand, tmuxStartCommand)

        let restored = Workspace()
        restored.restoreSessionSnapshot(snapshot)

        let restoredHudPanel = try XCTUnwrap(
            restored.panels.values
                .compactMap { $0 as? TerminalPanel }
                .first { $0.surface.debugTmuxStartCommand() == tmuxStartCommand }
        )
        let restoredStartupScript = try XCTUnwrap(restoredHudPanel.surface.debugInitialCommand())
        XCTAssertNotEqual(
            restoredStartupScript,
            originalStartupScript,
            "Restored HUD panes must launch through a fresh script, not a deleted tmux temp script"
        )
        XCTAssertTrue(restoredStartupScript.contains("cmux-session-terminal-command"))
        XCTAssertEqual(restoredHudPanel.requestedWorkingDirectory, requestedDirectory)
    }

    func testSessionSnapshotDoesNotPersistGenericTmuxStartCommand() throws {
        let workspace = Workspace()
        let paneId = try XCTUnwrap(workspace.bonsplitController.focusedPaneId)
        let genericCommand = "sleep 600"
        let panel = try XCTUnwrap(workspace.newTerminalSurface(
            inPane: paneId,
            focus: false,
            initialCommand: "/tmp/cmux-command-\(UUID().uuidString).sh",
            tmuxStartCommand: genericCommand
        ))

        let snapshot = workspace.sessionSnapshot(includeScrollback: false)
        let panelSnapshot = try XCTUnwrap(snapshot.panels.first { $0.id == panel.id })
        XCTAssertNil(panelSnapshot.terminal?.tmuxStartCommand)
        XCTAssertNil(Workspace.restorableTmuxStartCommand(genericCommand))
    }
}
