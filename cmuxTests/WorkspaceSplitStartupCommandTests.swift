import XCTest
import CmuxTerminalEngine
import Bonsplit
import AppKit
import SwiftUI
import CmuxTerminal

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

private func firstWorkspaceDescendant<ViewType: NSView>(
    ofType type: ViewType.Type,
    in root: NSView
) -> ViewType? {
    if let match = root as? ViewType {
        return match
    }

    for subview in root.subviews {
        if let match = firstWorkspaceDescendant(ofType: type, in: subview) {
            return match
        }
    }

    return nil
}

@MainActor
private func waitForWorkspaceSplitView(
    in hostingView: NSView,
    contentView: NSView,
    expectedDividerPosition: Double,
    accuracy: Double,
    timeout: TimeInterval = 2.0,
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> NSSplitView {
    let deadline = Date.now.addingTimeInterval(timeout)
    var lastRenderedDividerPosition: Double?

    repeat {
        contentView.layoutSubtreeIfNeeded()

        if let splitView = firstWorkspaceDescendant(ofType: NSSplitView.self, in: hostingView),
           splitView.arrangedSubviews.count == 2 {
            splitView.layoutSubtreeIfNeeded()

            let availableWidth = splitView.bounds.width - splitView.dividerThickness
            if availableWidth > 0 {
                let renderedDividerPosition = splitView.arrangedSubviews[0].frame.width / availableWidth
                lastRenderedDividerPosition = Double(renderedDividerPosition)

                if abs(Double(renderedDividerPosition) - expectedDividerPosition) <= accuracy {
                    return splitView
                }
            }
        }

        _ = RunLoop.current.run(
            mode: .default,
            before: min(Date.now.addingTimeInterval(0.01), deadline)
        )
    } while Date.now < deadline

    let lastRatioDescription = lastRenderedDividerPosition.map { String(describing: $0) } ?? "nil"
    XCTFail(
        "Timed out waiting for rendered cmux.json split ratio \(expectedDividerPosition); last ratio: \(lastRatioDescription)",
        file: file,
        line: line
    )
    return try XCTUnwrap(
        firstWorkspaceDescendant(ofType: NSSplitView.self, in: hostingView),
        "Expected rendered Bonsplit NSSplitView",
        file: file,
        line: line
    )
}

@MainActor
final class WorkspaceSplitStartupCommandTests: XCTestCase {
    func testCustomLayoutSplitRatioSurvivesInitialBonsplitViewLayout() throws {
        let workspace = Workspace()
        let expectedDividerPosition = 0.33
        let layout = CmuxLayoutNode.split(CmuxSplitDefinition(
            direction: .horizontal,
            split: expectedDividerPosition,
            children: [
                .pane(CmuxPaneDefinition(surfaces: [
                    CmuxSurfaceDefinition(type: .terminal, name: "Left")
                ])),
                .pane(CmuxPaneDefinition(surfaces: [
                    CmuxSurfaceDefinition(type: .terminal, name: "Right")
                ]))
            ]
        ))

        workspace.applyCustomLayout(layout, baseCwd: NSTemporaryDirectory())

        let modelSplitBeforeRender = try XCTUnwrap(workspaceSplitNodes(in: workspace.bonsplitController.treeSnapshot()).first)
        XCTAssertEqual(
            modelSplitBeforeRender.dividerPosition,
            expectedDividerPosition,
            accuracy: 0.000_1,
            "cmux.json split ratio should be applied to the Bonsplit model before rendering"
        )

        let hostingView = NSHostingView(
            rootView: BonsplitView(controller: workspace.bonsplitController) { _, _ in
                Color.clear
            } emptyPane: { _ in
                Color.clear
            }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 500),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }

        let contentView = try XCTUnwrap(window.contentView)
        hostingView.frame = contentView.bounds
        hostingView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostingView)

        window.makeKeyAndOrderFront(nil)
        contentView.layoutSubtreeIfNeeded()
        _ = try waitForWorkspaceSplitView(
            in: hostingView,
            contentView: contentView,
            expectedDividerPosition: expectedDividerPosition,
            accuracy: 0.03
        )

        let modelSplitAfterRender = try XCTUnwrap(workspaceSplitNodes(in: workspace.bonsplitController.treeSnapshot()).first)
        XCTAssertEqual(
            modelSplitAfterRender.dividerPosition,
            expectedDividerPosition,
            accuracy: 0.000_1,
            "Bonsplit initial view layout should not rewrite the cmux.json split ratio back to 0.5"
        )
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
    }

    func testRespawnTerminalSurfacePreservesPaneTabAndSurfaceIdentity() throws {
        let workspace = Workspace()
        let sourcePanelId = try XCTUnwrap(workspace.focusedPanelId)
        let placeholderCommand = "/bin/sh -c 'printf placeholder; while :; do sleep 86400; done'"
        let attachCommand = "/bin/sh -c 'opencode attach http://127.0.0.1:4096 --session subagent --dir /tmp/omo'"
        let requestedDirectory = "/tmp/cmux-respawn-\(UUID().uuidString)"
        let startupEnvironment = [
            "CMUX_OMO_SUBAGENT": "1",
            "OMO_SUBAGENT_DESC": "test"
        ]

        let placeholderPanel = try XCTUnwrap(workspace.newTerminalSplit(
            from: sourcePanelId,
            orientation: .horizontal,
            focus: true,
            initialCommand: placeholderCommand,
            tmuxStartCommand: placeholderCommand,
            startupEnvironment: startupEnvironment
        ))
        let originalPanelId = placeholderPanel.id
        let originalPane = try XCTUnwrap(workspace.paneId(forPanelId: originalPanelId))
        let originalPaneId = originalPane.id
        let originalTabId = try XCTUnwrap(workspace.surfaceIdFromPanelId(originalPanelId))
        let originalPaneCount = workspace.bonsplitController.allPaneIds.count
        let originalTabCount = workspace.bonsplitController.tabs(inPane: originalPane).count
        let originalWaitAfterCommand = placeholderPanel.surface.debugWaitAfterCommand()

        let respawnedPanel = try XCTUnwrap(workspace.respawnTerminalSurface(
            panelId: originalPanelId,
            command: attachCommand,
            workingDirectory: requestedDirectory,
            tmuxStartCommand: attachCommand
        ))

        XCTAssertEqual(respawnedPanel.id, originalPanelId)
        XCTAssertTrue(workspace.terminalPanel(for: originalPanelId) === respawnedPanel)
        let currentPane = try XCTUnwrap(workspace.paneId(forPanelId: originalPanelId))
        XCTAssertEqual(currentPane.id, originalPaneId)
        XCTAssertEqual(workspace.surfaceIdFromPanelId(originalPanelId), originalTabId)
        XCTAssertEqual(workspace.bonsplitController.allPaneIds.count, originalPaneCount)
        XCTAssertTrue(workspace.bonsplitController.allPaneIds.contains(where: { $0.id == originalPaneId }))
        XCTAssertEqual(workspace.bonsplitController.tabs(inPane: currentPane).count, originalTabCount)
        XCTAssertTrue(workspace.bonsplitController.tabs(inPane: currentPane).contains(where: { $0.id == originalTabId }))
        XCTAssertEqual(respawnedPanel.requestedWorkingDirectory, requestedDirectory)
        XCTAssertEqual(respawnedPanel.surface.debugInitialCommand(), attachCommand)
        XCTAssertEqual(respawnedPanel.surface.debugTmuxStartCommand(), attachCommand)
        XCTAssertEqual(respawnedPanel.surface.debugWaitAfterCommand(), originalWaitAfterCommand)
        for (key, value) in startupEnvironment {
            XCTAssertEqual(respawnedPanel.surface.startupEnvironmentValue(key), value)
        }
        XCTAssertTrue(
            GhosttyApp.terminalSurfaceRegistry.surface(id: originalPanelId) === respawnedPanel.surface,
            "Respawn should replace the registered terminal surface for the existing cmux surface id"
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
