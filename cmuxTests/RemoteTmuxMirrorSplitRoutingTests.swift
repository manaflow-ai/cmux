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
    @Test func splitTintPlannerAssignsDistinctSourceAndNewPaneColors() throws {
        let assignment = TerminalSplitPaneTintPlanner.assignmentForTerminalSplit(
            baseColor: try #require(NSColor(hex: "#101010")),
            usedHexes: [],
            sourceNeedsTint: true,
            newPaneNeedsTint: true
        )
        let sourceTint = try #require(assignment.source?.hexString())
        let newPaneTint = try #require(assignment.newPane?.hexString())

        #expect(sourceTint != newPaneTint)
    }

    @Test func splitTintPlannerPreservesManualSourceTintAndTintsNewPane() throws {
        let manualTint = "#123456"
        let assignment = TerminalSplitPaneTintPlanner.assignmentForTerminalSplit(
            baseColor: try #require(NSColor(hex: "#101010")),
            usedHexes: [manualTint],
            sourceNeedsTint: false,
            newPaneNeedsTint: true
        )
        let newPaneTint = try #require(assignment.newPane?.hexString())

        #expect(assignment.source == nil)
        #expect(newPaneTint != manualTint)
    }

    @Test func splitTintPlannerReusesFirstPaletteColorAfterExhaustion() throws {
        let baseColor = try #require(NSColor(hex: "#101010"))
        var usedHexes = Set<String>()
        var tints: [String] = []
        for _ in 0..<10 {
            let tint = try #require(TerminalSplitPaneTintPlanner.nextColor(baseColor: baseColor, usedHexes: usedHexes))
            let hex = tint.hexString()
            tints.append(hex)
            usedHexes.insert(hex)
        }

        // The first eight requests exhaust the eight-color palette with distinct tints.
        #expect(Set(tints.prefix(8)).count == 8)
        // After that every palette color is in `usedHexes`, so the Set saturates at
        // eight entries and `nextColor` deterministically falls back to the first
        // palette color for every subsequent request: a saturated Set cannot advance
        // the `usedHexes.count % palette.count` wrap past index 0, which mirrors the
        // real call site where `usedHexes` is the set of distinct live pane colors.
        #expect(tints[8] == tints[0])
        #expect(tints[9] == tints[0])
    }

    @Test func splitTintPlannerKeepsCurrentSplitDistinctAfterPaletteWrap() throws {
        let baseColor = try #require(NSColor(hex: "#101010"))
        var usedHexes = Set<String>()
        for _ in 0..<8 {
            let tint = try #require(TerminalSplitPaneTintPlanner.nextColor(baseColor: baseColor, usedHexes: usedHexes))
            usedHexes.insert(tint.hexString())
        }

        let assignment = TerminalSplitPaneTintPlanner.assignmentForTerminalSplit(
            baseColor: baseColor,
            usedHexes: usedHexes,
            sourceNeedsTint: true,
            newPaneNeedsTint: true
        )
        let sourceTint = try #require(assignment.source?.hexString())
        let newPaneTint = try #require(assignment.newPane?.hexString())

        #expect(sourceTint != newPaneTint)
    }

    @Test func terminalSplitTintingCanBeDisabled() throws {
        try withIsolatedDefaults { defaults in
            defaults.set(false, forKey: TerminalSplitPaneTintSettings.autoTintSplitPanesKey)
            #expect(!TerminalSplitPaneTintSettings().isEnabled(defaults: defaults))
        }
    }

    @Test func terminalSnapshotPersistsPaneBackgroundHex() throws {
        let snapshot = SessionTerminalPanelSnapshot(backgroundColorHex: "#123456")
        let data = try JSONEncoder().encode(snapshot)
        let restored = try JSONDecoder().decode(SessionTerminalPanelSnapshot.self, from: data)

        #expect(restored.backgroundColorHex == "#123456")
    }

    private func withIsolatedDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suiteName = "cmux.split-pane-tint.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }
}
