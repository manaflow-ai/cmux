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
@Suite("Cloud shortcuts retain their execution machine", .serialized, .timeLimit(.minutes(1)))
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

    @Test("A rapid split chain uses each completed predecessor's remote tab")
    func orderedPendingChain() async throws {
        let h = try CloudShortcutTestHarness()
        defer { h.tearDown() }
        var calls = h.provider.calls.stream.makeAsyncIterator()
        try invoke(.down, h)
        let first = try #require(await calls.next())
        #expect(first.nearTabID == "tab-source")
        try invoke(.right, h)
        try invoke(.tab, h)
        let lastPanel = try #require(h.workspace.focusedPanelId)
        let last = try #require(h.workspace.cloudPendingCreations[lastPanel])
        #expect(h.provider.callCount == 1)
        assertOnlyCloudPanelsAdded(h)
        h.provider.succeed(first.number)
        let second = try #require(await calls.next())
        #expect(second.nearTabID == "tab-created-1")
        h.provider.succeed(second.number)
        let third = try #require(await calls.next())
        #expect(third.nearTabID == "tab-created-2")
        h.provider.succeed(third.number)
        let completed = try await last.resolution.value()
        #expect(completed.panelID == lastPanel)
        #expect(completed.resource.machine == h.provider.machine)
        #expect(h.provider.callCount == 3)
    }

    @Test("Parent failure settles dependent shortcuts as Cloud failures", arguments: [false, true])
    func parentFailure(transportCancelled: Bool) async throws {
        let h = try CloudShortcutTestHarness()
        defer { h.tearDown() }
        var calls = h.provider.calls.stream.makeAsyncIterator()
        try invoke(.down, h)
        let first = try #require(await calls.next())
        try invoke(.right, h)
        let panel = try #require(h.workspace.focusedPanelId)
        let child = try #require(h.workspace.cloudPendingCreations[panel])
        h.provider.fail(first.number, error: transportCancelled ? CancellationError() : CloudDiagnosticFailure.network)
        do { _ = try await child.resolution.value(); Issue.record("dependent request unexpectedly succeeded") }
        catch { #expect(error as? CloudDiagnosticFailure == (transportCancelled ? .cancelled : .network)) }
        #expect(h.provider.callCount == 1)
        #expect(h.workspace.cloudMaterializationFailures[panel] != nil)
        assertOnlyCloudPanelsAdded(h)
    }

    @Test("Explicit command and cwd keep the Cloud execution target")
    func remoteLaunchOptions() async throws {
        let h = try CloudShortcutTestHarness()
        defer { h.tearDown() }
        var calls = h.provider.calls.stream.makeAsyncIterator()
        let pane = try #require(h.workspace.bonsplitController.focusedPaneId)
        let outcome = h.workspace.newTerminalSurfaceOutcome(inPane: pane, workingDirectory: "/remote/custom", initialCommand: "pwd")
        #expect(outcome.isAccepted)
        let call = try #require(await calls.next())
        #expect(call.command == ["sh", "-lc", "pwd"])
        #expect(call.cwd == "/remote/custom")
        #expect(call.remoteWorkspaceID == "ws-source")
        assertOnlyCloudPanelsAdded(h)
    }

    @Test("Explicit local materialization remains available without implicit fallback")
    func explicitLocalMaterialization() throws {
        let h = try CloudShortcutTestHarness()
        defer { h.tearDown() }
        let pane = try #require(h.workspace.bonsplitController.focusedPaneId)
        let result = h.workspace.newTerminalSurfaceOutcome(inPane: pane, initialCommand: "/usr/bin/true",
            suppressWorkspaceRemoteStartupCommand: true)
        #expect(result.panel != nil)
        #expect(result.panel?.surface.ioMode != .manualMirror)
        #expect(h.provider.callCount == 0)
    }

    @Test("Closing a pending parent does not strand its child or start a local shell")
    func parentClosed() async throws {
        let h = try CloudShortcutTestHarness()
        defer { h.tearDown() }
        var calls = h.provider.calls.stream.makeAsyncIterator()
        try invoke(.down, h)
        _ = try #require(await calls.next())
        let parentID = try #require(h.workspace.focusedPanelId)
        try invoke(.right, h)
        let childID = try #require(h.workspace.focusedPanelId)
        let child = try #require(h.workspace.cloudPendingCreations[childID])
        h.workspace.cancelReservedCloudTerminalPane(panelID: parentID)
        do { _ = try await child.resolution.value(); Issue.record("closed parent unexpectedly resolved") }
        catch { #expect(error as? CloudDiagnosticFailure == .notFound) }
        #expect(h.provider.callCount == 1)
        assertOnlyCloudPanelsAdded(h)
    }

    @Test("Initial input is queued for the Cloud terminal")
    func initialInput() throws {
        let h = try CloudShortcutTestHarness()
        defer { h.tearDown() }
        h.manager.newSurface(initialInput: "pwd")
        let panel = try #require(h.workspace.focusedPanelId)
        let pending = try #require(h.workspace.cloudPendingCreations[panel])
        #expect(pending.inputRelay.pendingCount == 1)
        assertOnlyCloudPanelsAdded(h)
    }

    @Test("A local workspace still creates local terminals")
    func localWorkspace() throws {
        let h = try CloudShortcutTestHarness(projected: false)
        defer { h.tearDown() }
        h.workspace.cloudVMBinding = nil
        h.manager.newSurface()
        let panel = try #require(h.workspace.focusedPanelId)
        #expect(h.workspace.terminalPanel(for: panel)?.surface.ioMode != .manualMirror)
        #expect(h.workspace.cloudPendingCreations.isEmpty)
    }

    @Test("Closing the final pane of a Cloud workspace replaces it on Cloud")
    func closingLastPane() throws {
        let h = try CloudShortcutTestHarness()
        defer { h.tearDown() }
        _ = h.workspace.closePanel(h.source, force: true)
        assertOnlyCloudPanelsAdded(h)
    }

    @Test("Dragging the only tab into a split keeps the replacement on Cloud")
    func dragOnlyTabToSplit() throws {
        let h = try CloudShortcutTestHarness()
        defer { h.tearDown() }
        let pane = try #require(h.workspace.bonsplitController.focusedPaneId)
        let tab = try #require(h.workspace.bonsplitController.selectedTab(inPane: pane))
        _ = h.workspace.bonsplitController.splitPane(pane, orientation: .horizontal, movingTab: tab.id)
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
