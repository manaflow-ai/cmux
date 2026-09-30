import CmuxRemoteSession
import AppKit
import Bonsplit
import CmuxControlSocket
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for the remote-tmux mirror split routing contract
/// (https://github.com/manaflow-ai/cmux/pull/5553): a split request on a
/// remote tmux mirror workspace must never create a local panel — it is
/// routed to the remote tmux session (the pane arrives via %layout-change),
/// or fails when no live mirror exists. A local panel here would be an
/// orphan the mirror's rebuild() never reconciles, and the socket layer
/// reporting routed requests as errors makes automation retry and duplicate
/// remote panes.
@MainActor
@Suite(.serialized) struct RemoteTmuxMirrorSplitRoutingTests {
    @Test func mirrorWorkspaceSplitNeverCreatesLocalPanel() throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        harness.workspace.isRemoteTmuxMirror = true
        let panelsBefore = harness.workspace.panels.count

        let panel = harness.workspace.newTerminalSplit(
            from: harness.sourcePanelId,
            orientation: .horizontal,
            focus: false
        )

        #expect(panel == nil)
        #expect(harness.workspace.panels.count == panelsBefore)
    }

    @Test func localWorkspaceSplitStillCreatesLocalPanel() throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        let panelsBefore = harness.workspace.panels.count
        let before = splitDiagnostics(
            "local-split before", appDelegate: harness.appDelegate, windowId: harness.windowId,
            workspace: harness.workspace, panelId: harness.sourcePanelId
        )
        let outcome = harness.workspace.newTerminalSplitOutcome(
            from: harness.sourcePanelId,
            orientation: .horizontal,
            focus: false
        )
        let after = splitDiagnostics(
            "local-split after outcome=\(outcome)", appDelegate: harness.appDelegate, windowId: harness.windowId,
            workspace: harness.workspace, panelId: harness.sourcePanelId
        )
        print(before)
        print(after)
        NSLog("%@", before + "\n" + after)
        let panel: TerminalPanel?
        if case .created(let created) = outcome { panel = created } else { panel = nil }

        #expect(panel != nil, Comment(rawValue: before + "\n" + after))
        #expect(harness.workspace.panels.count == panelsBefore + 1)
    }

    /// A mirrored pane lives in the mirror's nested Bonsplit tree, so its drop
    /// context names a pane the workspace tree has never seen. The mirror must
    /// own that target: without an owner every Finder file drop snapped back
    /// (https://github.com/manaflow-ai/cmux/issues/14896).
    @Test func mirrorPaneDropContextResolvesToTheWindowMirror() throws {
        let harness = try RemoteTmuxMirrorCLIObservabilityTests.Harness()
        defer { harness.tearDown() }
        let tmuxPaneID = try #require(harness.mirror.paneIDsInOrder.last)
        let panel = try #require(harness.mirror.panel(forPane: tmuxPaneID))
        let paneID = try #require(harness.mirror.paneIdByPaneId[tmuxPaneID])
        let context = PaneDropContext(
            workspaceId: harness.workspace.id,
            panelId: panel.id,
            paneId: paneID
        )

        let container = try #require(harness.appDelegate.paneDropContainer(for: context))

        #expect(container === harness.mirror)
        #expect(container.fileDropTextDestinationKind(in: paneID, hasHostedTerminal: false) == .terminal)
        #expect(!container.canPerformPortalPaneDrop(
            PaneDragTransfer(
                tabId: UUID(),
                sourcePaneId: UUID(),
                sourceProcessId: Int32(ProcessInfo.processInfo.processIdentifier)
            ),
            source: .surface
        ))

        let otherPanel = try #require(harness.mirror.panel(forPane: 11))
        #expect(harness.appDelegate.paneDropContainer(for: PaneDropContext(
            workspaceId: harness.workspace.id,
            panelId: otherPanel.id,
            paneId: paneID
        )) == nil)
    }

    @Test func windowMirrorSplitRejectsWhileConnecting() {
        let connection = RemoteTmuxControlConnection(host: RemoteTmuxHost(destination: "user@host"), sessionName: "work")
        let mirror = RemoteTmuxWindowMirror(
            windowId: 1,
            panelId: UUID(),
            connection: connection,
            layout: RemoteTmuxLayoutNode(width: 80, height: 24, x: 0, y: 0, content: .pane(7)),
            appearance: .default,
            makePanel: { _ in nil }
        )

        #expect(!mirror.requestSplit(
            fromPane: 7,
            vertical: true,
            focusIntent: .focusCreatedPane
        ))
    }

    @Test func focusedSplitRequestsTheCreatedPaneID() {
        #expect(
            RemoteTmuxSplitFocusIntent.focusCreatedPane.command(
                vertical: false,
                windowID: 2,
                paneID: 4
            ) == "split-window -P -F '#{pane_id}' -h -t @2.%4"
        )
    }

    @Test func projectedForkSplitPreservesBeforePlacementAndRemoteLaunchContext() throws {
        let command = try #require(
            RemoteTmuxSplitFocusIntent.focusCreatedPane.agentForkCommand(
                vertical: true,
                windowID: 2,
                paneID: 4,
                insertBefore: true,
                shellCommand: "claude --fork-session abc",
                workingDirectory: "/tmp/remote fork"
            )
        )

        #expect(command.hasPrefix("split-window -P -F '#{pane_id}' -v -b -t @2.%4"))
        #expect(command.contains("-c '/tmp/remote fork'"))
        #expect(command.hasSuffix("'claude --fork-session abc'"))
    }

    /// `new-split --focus false` must ask tmux to create the pane detached.
    /// Without `-d`, tmux selects the new pane and its authoritative active-pane
    /// publication also changes the mirror's internal focus (#7733).
    @Test func backgroundControlSplitPreservesTheRemoteActivePane() throws {
        let harness = try RemoteTmuxMirrorCLIObservabilityTests.Harness(
            connectedTransport: true
        )
        defer { harness.tearDown() }
        let activePaneBefore = harness.mirror.activePaneId
        let tmuxPaneID = try #require(harness.mirror.paneIDsInOrder.first)
        let surfaceID = try #require(harness.mirror.panel(forPane: tmuxPaneID)?.id)

        let result = TerminalController.shared.controlSurfaceSplit(
            routing: harness.routing(),
            inputs: ControlSurfaceSplitInputs(
                directionRaw: "right",
                typeRaw: nil,
                urlRaw: nil,
                requestedSourceSurfaceID: surfaceID,
                workingDirectory: nil,
                initialCommand: nil,
                tmuxStartCommand: nil,
                remotePTYSessionID: nil,
                remoteContextRaw: nil,
                startupEnvironment: [:],
                clientUnsupportedRemoteTmuxOptions: [],
                requestedFocus: false,
                initialDividerPosition: nil
            )
        )

        guard case .routedToRemote = result else {
            Issue.record("Expected background split to route to remote tmux: \(result)")
            return
        }
        let writer = try #require(harness.controlWriter)
        let pipe = try #require(harness.controlPipe)
        writer.close()
        let commands = try #require(String(
            bytes: try pipe.fileHandleForReading.readToEnd() ?? Data(),
            encoding: .utf8
        ))
        let splitCommands = commands.split(separator: "\n").filter {
            $0.hasPrefix("split-window ")
        }
        #expect(splitCommands.count == 1)
        #expect(splitCommands.first?.split(separator: " ").contains("-d") == true)
        #expect(harness.mirror.activePaneId == activePaneBefore)
    }

    @Test func windowMirrorConfigurationTracksWorkspaceAppearanceAndEmbeddedPolicy() {
        let connection = RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "user@host"),
            sessionName: "work"
        )
        let mirror = RemoteTmuxWindowMirror(
            windowId: 1,
            panelId: UUID(),
            connection: connection,
            layout: RemoteTmuxLayoutNode(
                width: 80,
                height: 24,
                x: 0,
                y: 0,
                content: .pane(7)
            ),
            makePanel: { _ in nil }
        )
        var appearance = BonsplitConfiguration.Appearance.default
        appearance.tabBarHeight = 36
        appearance.tabTitleFontSize = 14
        appearance.tabBarLeadingInset = 72
        var workspaceConfiguration = BonsplitConfiguration(
            allowCloseTabs: false,
            appearance: appearance
        )

        mirror.applyWorkspaceBonsplitConfiguration(workspaceConfiguration)
        #expect(mirror.bonsplitController.configuration.appearance.tabBarHeight == 36)
        #expect(mirror.bonsplitController.configuration.appearance.tabTitleFontSize == 14)
        #expect(mirror.bonsplitController.configuration.appearance.tabBarLeadingInset == 0)
        #expect(!mirror.bonsplitController.configuration.allowCloseTabs)
        #expect(!mirror.bonsplitController.configuration.allowsTabContextMenu)
        #expect(!mirror.bonsplitController.tabShortcutHintsEnabled)

        workspaceConfiguration.appearance.tabBarHeight = 42
        workspaceConfiguration.appearance.tabTitleFontSize = 16
        mirror.applyWorkspaceBonsplitConfiguration(workspaceConfiguration)
        #expect(mirror.bonsplitController.configuration.appearance.tabBarHeight == 42)
        #expect(mirror.bonsplitController.configuration.appearance.tabTitleFontSize == 16)
    }

    @MainActor
    private struct Harness {
        let appDelegate: AppDelegate
        let windowId: UUID
        let workspace: Workspace
        let sourcePanelId: UUID

        init() throws {
            appDelegate = try #require(AppDelegate.shared)
            windowId = appDelegate.createMainWindow()
            let manager = try #require(appDelegate.tabManagerFor(windowId: windowId))
            workspace = try #require(manager.selectedWorkspace)
            sourcePanelId = try #require(workspace.focusedPanelId)
        }

        func tearDown() {
            workspace.isRemoteTmuxMirror = false
            let identifier = "cmux.main.\(windowId.uuidString)"
            if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == identifier }) {
                window.performClose(nil)
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            }
        }
    }
}

/// Diagnostics-only helper (issue 15488 investigation branch; never merged).
@MainActor
func splitDiagnostics(
    _ label: String,
    appDelegate: AppDelegate,
    windowId: UUID,
    workspace: Workspace,
    panelId: UUID
) -> String {
    var lines: [String] = ["[split-diag] \(label)"]
    let screen = NSScreen.main
    lines.append("[split-diag] screen.frame=\(String(describing: screen?.frame)) visible=\(String(describing: screen?.visibleFrame)) screens=\(NSScreen.screens.map { "\($0.frame)" })")
    let identifier = "cmux.main.\(windowId.uuidString)"
    let window = NSApp.windows.first { $0.identifier?.rawValue == identifier }
    lines.append("[split-diag] window.frame=\(String(describing: window?.frame)) content=\(String(describing: window?.contentView?.bounds)) key=\(window?.isKeyWindow ?? false) visible=\(window?.isVisible ?? false) minSize=\(String(describing: window?.minSize))")
    let defaults = UserDefaults.standard
    lines.append("[split-diag] defaults fileExplorer.isVisible=\(String(describing: defaults.object(forKey: "fileExplorer.isVisible"))) fileExplorer.width=\(String(describing: defaults.object(forKey: "fileExplorer.width"))) rightSidebar.mode=\(String(describing: defaults.object(forKey: "rightSidebar.mode")))")
    if let context = appDelegate.mainWindowContexts.values.first(where: { $0.windowId == windowId }) {
        let files = context.fileExplorerState
        lines.append("[split-diag] leftSidebar visible=\(context.sidebarState.isVisible) width=\(context.sidebarState.persistedWidth) rightSidebar visible=\(String(describing: files?.isVisible)) autoCollapsed=\(String(describing: files?.isAutoCollapsed)) mode=\(String(describing: files?.mode)) width=\(String(describing: files?.width)) windowDock=\(context.windowDock != nil)")
    } else {
        lines.append("[split-diag] no main window context for \(windowId)")
    }
    let layout = workspace.bonsplitController.layoutSnapshot()
    lines.append("[split-diag] bonsplit container=\(layout.containerFrame) panes=\(layout.panes.map { "\($0.paneId.prefix(5)):\($0.frame)" })")
    lines.append("[split-diag] minimum=\(workspace.splitMinimumPaneSize) divider=\(workspace.bonsplitController.configuration.appearance.dividerThickness) minPaneW=\(workspace.bonsplitController.configuration.appearance.minimumPaneWidth) tabBarH=\(workspace.bonsplitController.configuration.appearance.tabBarHeight) verdictH=\(workspace.splitSpaceVerdict(splittingPanel: panelId, orientation: .horizontal)) verdictV=\(workspace.splitSpaceVerdict(splittingPanel: panelId, orientation: .vertical)) layoutMode=\(workspace.layoutMode) retired=\(workspace.isRetiredFromOwningTabManager) mirror=\(workspace.isRemoteTmuxMirror)")
    let mains = NSApp.windows.filter { ($0.identifier?.rawValue ?? "").hasPrefix("cmux.main.") }
    lines.append("[split-diag] mainWindows=\(mains.count) \(mains.map { "\(Int($0.frame.width))x\(Int($0.frame.height))\($0.isKeyWindow ? "*key" : "")\($0.isVisible ? "" : "(hidden)")" }) allWindows=\(NSApp.windows.count) key=\(String(describing: NSApp.keyWindow?.identifier?.rawValue)) contexts=\(appDelegate.mainWindowContexts.count)")
    return lines.joined(separator: "\n")
}
