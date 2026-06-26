import AppKit
import CmuxFoundation
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
            makePanel: { _ in nil }
        )

        #expect(!mirror.requestSplit(fromPane: 7, vertical: true))
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

@MainActor
@Suite(.serialized) struct WorkspaceSplitPaneTintTests {
    @Test func terminalSplitsReceiveDistinctPaneBackgroundTintsAndPersistThem() throws {
        try withIsolatedDefaults { defaults in
            let workspace = Workspace(terminalSplitPaneTintDefaults: defaults)
            let sourcePanel = try #require(workspace.focusedTerminalPanel)

            #expect(sourcePanel.surface.paneBackgroundOverrideColor == nil)

            let secondPanel = try #require(
                workspace.newTerminalSplit(
                    from: sourcePanel.id,
                    orientation: .horizontal,
                    focus: false
                )
            )
            let sourceTint = try #require(sourcePanel.surface.paneBackgroundOverrideColor?.hexString())
            let secondTint = try #require(secondPanel.surface.paneBackgroundOverrideColor?.hexString())

            #expect(sourceTint != secondTint)

            let thirdPanel = try #require(
                workspace.newTerminalSplit(
                    from: secondPanel.id,
                    orientation: .horizontal,
                    focus: false
                )
            )
            let thirdTint = try #require(thirdPanel.surface.paneBackgroundOverrideColor?.hexString())

            #expect(Set([sourceTint, secondTint, thirdTint]).count == 3)

            let snapshot = workspace.sessionSnapshot(includeScrollback: false)
            let persistedTints = Dictionary(uniqueKeysWithValues: snapshot.panels.compactMap { panel -> (UUID, String)? in
                guard let tint = panel.terminal?.backgroundColorHex else { return nil }
                return (panel.id, tint)
            })

            #expect(persistedTints[sourcePanel.id] == sourceTint)
            #expect(persistedTints[secondPanel.id] == secondTint)
            #expect(persistedTints[thirdPanel.id] == thirdTint)
        }
    }

    @Test func terminalSplitPreservesExistingPaneBackgroundOverride() throws {
        try withIsolatedDefaults { defaults in
            let workspace = Workspace(terminalSplitPaneTintDefaults: defaults)
            let sourcePanel = try #require(workspace.focusedTerminalPanel)
            let manualColor = try #require(NSColor(hex: "#123456"))
            sourcePanel.surface.paneBackgroundOverrideColor = manualColor

            let splitPanel = try #require(
                workspace.newTerminalSplit(
                    from: sourcePanel.id,
                    orientation: .horizontal,
                    focus: false
                )
            )
            let splitTint = try #require(splitPanel.surface.paneBackgroundOverrideColor?.hexString())

            #expect(sourcePanel.surface.paneBackgroundOverrideColor?.hexString() == "#123456")
            #expect(splitTint != "#123456")
        }
    }

    @Test func terminalSplitTintingCanBeDisabled() throws {
        try withIsolatedDefaults { defaults in
            defaults.set(false, forKey: TerminalSplitPaneTintSettings.autoTintSplitPanesKey)
            let workspace = Workspace(terminalSplitPaneTintDefaults: defaults)
            let sourcePanel = try #require(workspace.focusedTerminalPanel)

            let splitPanel = try #require(
                workspace.newTerminalSplit(
                    from: sourcePanel.id,
                    orientation: .horizontal,
                    focus: false
                )
            )

            #expect(sourcePanel.surface.paneBackgroundOverrideColor == nil)
            #expect(splitPanel.surface.paneBackgroundOverrideColor == nil)
        }
    }

    @Test func remoteTmuxMirrorPanesReceiveDistinctBackgroundTints() throws {
        try withIsolatedDefaults { defaults in
            let workspace = Workspace(terminalSplitPaneTintDefaults: defaults)
            let connection = RemoteTmuxControlConnection(
                host: RemoteTmuxHost(destination: "user@host"),
                sessionName: "work"
            )
            let mirror = RemoteTmuxWindowMirror(
                windowId: 1,
                panelId: UUID(),
                connection: connection,
                layout: splitLayout(panes: [1, 2]),
                paneTintDefaults: defaults,
                makePanel: { paneId in
                    workspace.makeRemoteTmuxPanePanel(onInput: { _ in _ = paneId })
                }
            )
            let firstPanel = try #require(mirror.panel(forPane: 1))
            let secondPanel = try #require(mirror.panel(forPane: 2))
            let firstTint = try #require(firstPanel.surface.paneBackgroundOverrideColor?.hexString())
            let secondTint = try #require(secondPanel.surface.paneBackgroundOverrideColor?.hexString())

            #expect(firstTint != secondTint)

            mirror.reconcile(layout: splitLayout(panes: [1, 2, 3]))
            let thirdPanel = try #require(mirror.panel(forPane: 3))
            let thirdTint = try #require(thirdPanel.surface.paneBackgroundOverrideColor?.hexString())

            #expect(Set([firstTint, secondTint, thirdTint]).count == 3)
        }
    }

    private func withIsolatedDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suiteName = "cmux.split-pane-tint.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }

    private func splitLayout(panes: [Int]) -> RemoteTmuxLayoutNode {
        RemoteTmuxLayoutNode(
            width: max(1, panes.count) * 80,
            height: 24,
            x: 0,
            y: 0,
            content: .horizontal(panes.enumerated().map { index, paneId in
                RemoteTmuxLayoutNode(
                    width: 80,
                    height: 24,
                    x: index * 80,
                    y: 0,
                    content: .pane(paneId)
                )
            })
        )
    }
}
