import AppKit
import Bonsplit
import CmuxControlSocket
import CmuxPanes
import CmuxTerminal
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Cloud shortcuts retain their execution machine", .serialized)
struct CloudTerminalShortcutRoutingTests {
    enum Entry: CaseIterable { case right, down, tab, splitButton, socketSplit, socketTab }

    @Test("Repeated shortcuts from a pending Cloud pane never create a local PTY", arguments: Entry.allCases)
    func pendingPane(entry: Entry) throws {
        let h = try CloudShortcutTestHarness()
        defer { h.tearDown() }
        #expect(h.workspace.newTerminalSplitOutcome(from: h.source, orientation: .vertical).isAccepted)
        // No suspension: the first remote operation cannot have produced a
        // projection yet. This is the user's rapid Cmd+Shift+D, Cmd+D path.
        let pendingID = try #require(h.workspace.focusedPanelId)
        #expect(h.workspace.cloudPendingCreations[pendingID] != nil)
        try invoke(entry, h)
        assertOnlyCloudPanelsAdded(h)
    }

    @Test("A failed pending Cloud pane retains routing", arguments: Entry.allCases)
    func failedPendingPane(entry: Entry) throws {
        let h = try CloudShortcutTestHarness()
        defer { h.tearDown() }
        _ = h.workspace.newTerminalSplitOutcome(from: h.source, orientation: .vertical)
        let id = try #require(h.workspace.focusedPanelId)
        let pending = try #require(h.workspace.cloudPendingCreations[id])
        h.workspace.failReservedCloudTerminalPane(pending, error: CloudDiagnosticFailure.network)
        try invoke(entry, h)
        assertOnlyCloudPanelsAdded(h)
    }

    @Test("A bound workspace without a projected source stays Cloud", arguments: Entry.allCases)
    func bindingWithoutProjection(entry: Entry) throws {
        let h = try CloudShortcutTestHarness(projected: false)
        defer { h.tearDown() }
        try invoke(entry, h)
        assertOnlyCloudPanelsAdded(h)
    }

    @Test("A missing provider never converts a Cloud action to local", arguments: Entry.allCases)
    func missingProvider(entry: Entry) throws {
        let h = try CloudShortcutTestHarness()
        defer { h.tearDown() }
        SurfaceCatalog.shared.unregister(machine: h.provider.machine)
        try invoke(entry, h)
        assertOnlyCloudPanelsAdded(h)
    }

    private func assertOnlyCloudPanelsAdded(_ h: CloudShortcutTestHarness) {
        let added = h.workspace.panels.values.compactMap { $0 as? TerminalPanel }.filter { $0.id != h.source }
        #expect(!added.isEmpty)
        #expect(added.allSatisfy { $0.surface.ioMode == .manualMirror }, "Cloud intent escaped to a local PTY")
    }

    private func invoke(_ entry: Entry, _ h: CloudShortcutTestHarness) throws {
        let pane = try #require(h.workspace.bonsplitController.focusedPaneId)
        switch entry {
        case .right, .down:
            #expect(h.app.performSplitShortcut(direction: entry == .right ? .right : .down, preferredWindow: h.window))
        case .tab:
            h.manager.newSurface()
        case .splitButton:
            _ = h.workspace.bonsplitController.splitPane(pane, orientation: .horizontal)
        case .socketSplit:
            _ = TerminalController.shared.controlSurfaceSplit(routing: h.routing, inputs: ControlSurfaceSplitInputs(
                directionRaw: "right", typeRaw: "terminal", urlRaw: nil, requestedSourceSurfaceID: h.workspace.focusedPanelId,
                workingDirectory: nil, initialCommand: nil, tmuxStartCommand: nil, remotePTYSessionID: nil,
                remoteContextRaw: nil, startupEnvironment: [:], clientUnsupportedRemoteTmuxOptions: [],
                requestedFocus: false, initialDividerPosition: nil))
        case .socketTab:
            _ = TerminalController.shared.controlSurfaceCreate(routing: h.routing, inputs: ControlSurfaceCreateInputs(
                typeRaw: "terminal", providerRaw: nil, rendererRaw: nil, urlRaw: nil,
                workingDirectory: nil, initialCommand: nil, tmuxStartCommand: nil, remotePTYSessionID: nil,
                remoteContextRaw: nil, startupEnvironment: [:], requestedPaneID: pane.id, requestedFocus: false))
        }
    }
}
