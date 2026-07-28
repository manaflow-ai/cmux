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

        let panel = harness.workspace.newTerminalSplit(
            from: harness.sourcePanelId,
            orientation: .horizontal,
            focus: false
        )

        #expect(panel != nil)
        #expect(harness.workspace.panels.count == panelsBefore + 1)
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
