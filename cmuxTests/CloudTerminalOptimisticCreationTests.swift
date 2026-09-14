import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct CloudTerminalOptimisticCreationTests {
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
        #expect(harness.pending.count == 2)
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

    @Test
    func backgroundSplitKeepsFocusBeforeAndAfterAcknowledgement() async throws {
        let harness = try CloudTerminalOptimisticHarness()
        defer { harness.close() }
        try harness.shortcut("shift-d", focus: false)
        #expect(harness.pending.count == 1)
        #expect(harness.workspace.focusedPanelId == harness.sourcePanelID)
        var arrivals = harness.provider.arrivals.stream.makeAsyncIterator()
        _ = await arrivals.next()
        harness.provider.acceptNext()
        #expect(await harness.waitUntil { harness.pending.isEmpty })
        #expect(harness.workspace.focusedPanelId == harness.sourcePanelID)
    }
}
