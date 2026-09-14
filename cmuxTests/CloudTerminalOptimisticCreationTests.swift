import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct CloudTerminalOptimisticCreationTests {
    @Test(arguments: ["d", "shift-d", "t"])
    func appShortcutActionsRouteRepeatedGesturesThroughPendingCloudPanes(key: String) async throws {
        let harness = try CloudTerminalOptimisticHarness()
        defer { harness.close() }
        try harness.shortcutAction(key)
        try #require(harness.pending.count == 1)
        try harness.shortcutAction(key)
        try #require(harness.pending.count == 2)
        var arrivals = harness.provider.arrivals.stream.makeAsyncIterator()
        _ = await arrivals.next()
        harness.provider.acceptNext()
        _ = await arrivals.next()
        #expect(harness.provider.anchors == ["source-tab", "tab-1"])
        harness.provider.acceptNext()
        #expect(await harness.waitUntil { harness.pending.isEmpty })
        #expect(harness.provider.projected == 2)
    }

    @Test(arguments: ["d", "shift-d", "t"])
    func shortcutsInsertTheirPendingDestinationBeforeRemoteWork(key: String) async throws {
        let harness = try CloudTerminalOptimisticHarness()
        defer { harness.close() }
        try harness.shortcut(key)
        let pending = try #require(harness.pending.first)
        #expect(harness.pending.count == 1)
        #expect(harness.workspace.focusedPanelId == pending.id)
        let pane = try #require(harness.workspace.paneId(forPanelId: pending.id))
        #expect((pane == harness.sourcePaneID) == (key == "t"))
        #expect(harness.workspace.bonsplitController.allPaneIds.count == (key == "t" ? 1 : 2))
        var arrivals = harness.provider.arrivals.stream.makeAsyncIterator()
        _ = await arrivals.next()
        harness.provider.acceptNext()
        #expect(await harness.waitUntil { harness.pending.isEmpty })
        #expect(harness.provider.anchors.count == 1)
        #expect(harness.provider.directions == [key == "t" ? nil : key == "d" ? .right : .down])
        #expect(harness.provider.projected == 1)
        #expect(harness.workspace.bonsplitController.allPaneIds.count == (key == "t" ? 1 : 2))
        #expect(harness.workspace.panels.count == 2)
    }

    @Test
    func rapidShortcutsWaitForThePendingCloudAnchor() async throws {
        let harness = try CloudTerminalOptimisticHarness()
        defer { harness.close() }
        try harness.shortcut("d")
        try harness.shortcut("t")
        try #require(harness.pending.count == 2)
        var arrivals = harness.provider.arrivals.stream.makeAsyncIterator()
        _ = await arrivals.next()
        #expect(harness.provider.anchors == ["source-tab"])
        harness.provider.acceptNext()
        _ = await arrivals.next()
        #expect(harness.provider.anchors == ["source-tab", "tab-1"])
        harness.provider.acceptNext()
        #expect(await harness.waitUntil { harness.pending.isEmpty })
        #expect(harness.provider.projected == 2)
        #expect(harness.workspace.panels.count == 3)
    }

    @Test
    func closingPendingSplitCannotReopenItWhenCreationFinishes() async throws {
        let harness = try CloudTerminalOptimisticHarness()
        defer { harness.close() }
        try harness.shortcut("d")
        let pending = try #require(harness.pending.first)
        var arrivals = harness.provider.arrivals.stream.makeAsyncIterator()
        _ = await arrivals.next()
        _ = harness.workspace.closePanel(pending.id, force: true)
        harness.provider.acceptNext()
        #expect(await harness.waitUntil { harness.pending.isEmpty })
        #expect(harness.provider.projected == 0)
        #expect(harness.workspace.panels.count == 1)
    }

    @Test
    func projectionRetryReusesTheAcknowledgedTerminal() async throws {
        let harness = try CloudTerminalOptimisticHarness()
        defer { harness.close() }
        harness.provider.failNextProjection = true
        try harness.shortcut("t")
        let pending = try #require(harness.pending.first)
        var arrivals = harness.provider.arrivals.stream.makeAsyncIterator()
        _ = await arrivals.next()
        harness.provider.acceptNext()
        #expect(await harness.waitUntil {
            if case .failed = pending.state.phase { return true }
            return false
        })
        pending.retry()
        #expect(await harness.waitUntil { harness.pending.isEmpty })
        #expect(harness.provider.anchors.count == 1)
        #expect(harness.provider.projected == 1)
    }

    @Test(arguments: ["d", "shift-d", "t"])
    func backgroundCreationKeepsFocusBeforeAndAfterAcknowledgement(key: String) async throws {
        let harness = try CloudTerminalOptimisticHarness()
        defer { harness.close() }
        try harness.shortcut(key, focus: false)
        #expect(harness.pending.count == 1)
        #expect(harness.workspace.focusedPanelId == harness.sourcePanelID)
        var arrivals = harness.provider.arrivals.stream.makeAsyncIterator()
        _ = await arrivals.next()
        harness.provider.acceptNext()
        #expect(await harness.waitUntil { harness.pending.isEmpty })
        #expect(harness.workspace.focusedPanelId == harness.sourcePanelID)
    }

    @Test
    func switchingAwayBeforeAcknowledgementKeepsTheNewSelection() async throws {
        let harness = try CloudTerminalOptimisticHarness()
        defer { harness.close() }
        try harness.shortcut("d")
        harness.workspace.focusPanel(harness.sourcePanelID)
        var arrivals = harness.provider.arrivals.stream.makeAsyncIterator()
        _ = await arrivals.next()
        harness.provider.acceptNext()
        #expect(await harness.waitUntil { harness.pending.isEmpty })
        #expect(harness.workspace.focusedPanelId == harness.sourcePanelID)
    }

    @Test
    func unknownCreationOutcomeStaysInlineWithoutReissuingTheRequest() async throws {
        let harness = try CloudTerminalOptimisticHarness()
        defer { harness.close() }
        try harness.shortcut("t")
        let pending = try #require(harness.pending.first)
        var arrivals = harness.provider.arrivals.stream.makeAsyncIterator()
        _ = await arrivals.next()
        harness.provider.rejectNext()
        #expect(await harness.waitUntil {
            if case .failed = pending.state.phase { return true }
            return false
        })
        pending.retry()
        #expect(await harness.waitUntil { pending.state.phase != .starting })
        #expect(harness.provider.anchors.count == 1)
        #expect(harness.provider.projected == 0)
        #expect(harness.workspace.panels[pending.id] === pending)
    }

    @Test
    func dividerButtonReservesItsExistingEmptyPane() async throws {
        let harness = try CloudTerminalOptimisticHarness()
        defer { harness.close() }
        _ = harness.workspace.bonsplitController.splitPane(harness.sourcePaneID, orientation: .vertical)
        let pending = try #require(harness.pending.first)
        #expect(harness.workspace.bonsplitController.allPaneIds.count == 2)
        #expect(harness.workspace.focusedPanelId == pending.id)
        var arrivals = harness.provider.arrivals.stream.makeAsyncIterator()
        _ = await arrivals.next()
        harness.provider.acceptNext()
        #expect(await harness.waitUntil { harness.pending.isEmpty })
        #expect(harness.provider.directions == [.down])
        #expect(harness.workspace.bonsplitController.allPaneIds.count == 2)
    }

    @Test
    func sidebarNewTerminalUsesTheSamePendingTabOperation() async throws {
        let harness = try CloudTerminalOptimisticHarness()
        defer { harness.close() }
        let actions = CloudTreeNodeActions.bound(
            catalog: { .shared }, selectedWorkspaceID: { harness.workspace.id },
            selectLocalWorkspace: { _ in }, onWillMutate: { _ in },
            onDidMutate: {}, onFailure: { _ in }, refresh: {}
        )
        actions.newTerminal(harness.provider.machine, "ws")
        let pending = try #require(harness.pending.first)
        #expect(harness.workspace.paneId(forPanelId: pending.id) == harness.sourcePaneID)
        var arrivals = harness.provider.arrivals.stream.makeAsyncIterator()
        _ = await arrivals.next()
        harness.provider.acceptNext()
        #expect(await harness.waitUntil { harness.pending.isEmpty })
        #expect(harness.provider.anchors == ["sidebar"])
    }
}
