import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension RemoteTmuxMirrorTargetingTests {
    @Test func liveActivityQueryTimesOutAndReleasesItsContinuationWhenTmuxNeverReplies() async throws {
        let controller = RemoteTmuxController()
        let manager = TabManager()
        let deadlineScheduler = CapturingActivityQueryDeadlineScheduler()
        let harness = try ActivityQueryHarness(
            controller: controller,
            manager: manager,
            windowCount: 1,
            scheduleActivityQueryDeadline: deadlineScheduler.schedule
        )
        defer { harness.tearDown() }
        let panelID = try harness.panelID(forWindow: 1)

        let query = Task { @MainActor in
            await controller.queryLiveMirrorTabActivity(
                workspaceId: harness.workspace.id,
                panelId: panelID
            )
        }
        for _ in 0..<50 where harness.connection.activityQueryCompletions.isEmpty {
            await Task.yield()
        }
        #expect(harness.connection.activityQueryCompletions.count == 1)
        #expect(deadlineScheduler.delays == [.seconds(1)])

        // A live mobile RPC has only a short response budget. The host query must
        // fail closed before that budget expires even if the connected stream is
        // wedged and never emits either a command result or a reset.
        deadlineScheduler.fireAll()
        let releasedByDeadline = harness.connection.activityQueryCompletions.isEmpty
        #expect(releasedByDeadline)
        #expect(deadlineScheduler.firedCount == 1)

        if !releasedByDeadline {
            harness.connection.failPendingActivityQueries()
        }
        let result = await query.value
        #expect(result == nil)
    }

    @Test func cancellingLiveActivityQueryReleasesItsContinuation() async throws {
        let controller = RemoteTmuxController()
        let manager = TabManager()
        let deadlineScheduler = CapturingActivityQueryDeadlineScheduler()
        let harness = try ActivityQueryHarness(
            controller: controller,
            manager: manager,
            windowCount: 1,
            scheduleActivityQueryDeadline: deadlineScheduler.schedule
        )
        defer { harness.tearDown() }
        let panelID = try harness.panelID(forWindow: 1)

        let query = Task { @MainActor in
            await controller.queryLiveMirrorTabActivity(
                workspaceId: harness.workspace.id,
                panelId: panelID
            )
        }
        for _ in 0..<50 where harness.connection.activityQueryCompletions.isEmpty {
            await Task.yield()
        }
        #expect(harness.connection.activityQueryCompletions.count == 1)
        #expect(deadlineScheduler.scheduledCount == 1)

        query.cancel()
        for _ in 0..<50 where !harness.connection.activityQueryCompletions.isEmpty {
            await Task.yield()
        }
        let releasedAfterCancellation = harness.connection.activityQueryCompletions.isEmpty
        #expect(releasedAfterCancellation)
        #expect(deadlineScheduler.cancelledCount == 1)

        // A cancelled deadline cannot later resume the query a second time.
        deadlineScheduler.fireAll()
        #expect(deadlineScheduler.firedCount == 0)

        if !releasedAfterCancellation {
            harness.connection.failPendingActivityQueries()
        }
        let result = await query.value
        #expect(result == nil)
    }

    @Test func confirmedMobileRemoteCloseDoesNotIssueAnotherActivityQuery() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let previousAppDelegate = AppDelegate.shared
            let appDelegate = AppDelegate()
            let manager = TabManager()
            let windowID = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
            AppDelegate.shared = appDelegate
            let harness = try ActivityQueryHarness(
                controller: appDelegate.remoteTmuxController,
                manager: manager,
                windowCount: 2
            )
            defer {
                harness.tearDown()
                appDelegate.unregisterMainWindowContextForTesting(windowId: windowID)
                AppDelegate.shared = previousAppDelegate
            }
            let panelID = try harness.panelID(forWindow: 1)

            let close = Task { @MainActor in
                await TerminalController.shared.v2MobileTerminalClose(params: [
                    "window_id": windowID.uuidString,
                    "workspace_id": harness.workspace.id.uuidString,
                    "terminal_id": panelID.uuidString,
                    "confirmed": true,
                ])
            }
            await waitForPendingCommand(on: harness.connection)

            let issuedRedundantQuery = !harness.connection.activityQueryCompletions.isEmpty
            #expect(!issuedRedundantQuery)

            // Let the current implementation finish after recording the failure,
            // so the test never strands a continuation in the shared controller.
            if issuedRedundantQuery {
                harness.connection.handleMessageForTesting(.commandResult(
                    commandNumber: 99,
                    lines: ["%0|0|zsh"],
                    isError: false
                ))
                await waitForPendingCommand(on: harness.connection)
            }
            harness.connection.handleMessageForTesting(.commandResult(
                commandNumber: 100,
                lines: [],
                isError: false
            ))
            harness.connection.handleMessageForTesting(.windowClose(windowId: 1))
            let result = await close.value
            guard case .ok = result else {
                Issue.record("Expected the confirmed remote terminal close to succeed")
                return
            }
        }
    }

    @Test func confirmedMobileRemoteCloseWaitsForAuthoritativeWindowCloseBeforeClearingViewport() async throws {
        try await withMobileRPCActivityHarness { harness, windowID in
            let panelID = try harness.panelID(forWindow: 1)
            let controller = TerminalController.shared
            controller.debugResetMobileViewportReportsForTesting()
            defer { controller.debugResetMobileViewportReportsForTesting() }
            controller.debugSetMobileViewportReportForTesting(
                surfaceID: panelID,
                clientID: "ipad-close",
                columns: 92,
                rows: 31
            )
            var observedResult: TerminalController.V2CallResult?
            let close = Task { @MainActor in
                let result = await controller.v2MobileTerminalClose(params: mobileCloseParams(
                    windowID: windowID,
                    workspaceID: harness.workspace.id,
                    panelID: panelID
                ))
                observedResult = result
                return result
            }
            await waitForPendingCommand(on: harness.connection)

            #expect(observedResult == nil)
            #expect(controller.debugMobileViewportReportClientIDsForTesting(surfaceID: panelID) == ["ipad-close"])
            #expect(harness.workspace.terminalPanel(for: panelID) != nil)

            harness.connection.handleMessageForTesting(.commandResult(
                commandNumber: 100,
                lines: [],
                isError: false
            ))
            #expect(observedResult == nil)
            harness.connection.handleMessageForTesting(.windowClose(windowId: 1))

            let result = await close.value
            guard case .ok = result else {
                Issue.record("Expected confirmed close to succeed after %window-close")
                return
            }
            #expect(harness.workspace.terminalPanel(for: panelID) == nil)
            #expect(controller.debugMobileViewportReportClientIDsForTesting(surfaceID: panelID) == nil)
        }
    }

    @Test func rejectedMobileRemoteClosePreservesViewportAndTerminal() async throws {
        try await withMobileRPCActivityHarness { harness, windowID in
            let panelID = try harness.panelID(forWindow: 1)
            let controller = TerminalController.shared
            controller.debugResetMobileViewportReportsForTesting()
            defer { controller.debugResetMobileViewportReportsForTesting() }
            controller.debugSetMobileViewportReportForTesting(
                surfaceID: panelID,
                clientID: "ipad-rejected-close",
                columns: 92,
                rows: 31
            )
            let close = Task { @MainActor in
                await controller.v2MobileTerminalClose(params: mobileCloseParams(
                    windowID: windowID,
                    workspaceID: harness.workspace.id,
                    panelID: panelID
                ))
            }
            await waitForPendingCommand(on: harness.connection)
            harness.connection.handleMessageForTesting(.commandResult(
                commandNumber: 101,
                lines: ["can't find window: @1"],
                isError: true
            ))

            guard case .err = await close.value else {
                Issue.record("Expected rejected remote close to fail")
                return
            }
            #expect(harness.workspace.terminalPanel(for: panelID) != nil)
            #expect(
                controller.debugMobileViewportReportClientIDsForTesting(surfaceID: panelID)
                    == ["ipad-rejected-close"]
            )
        }
    }

    @Test(arguments: [true, false])
    func timedOutMobileRemoteCloseResolvesFromAuthoritativeSnapshot(
        mutationApplied: Bool
    ) async throws {
        let deadlines = CapturingActivityQueryDeadlineScheduler()
        try await withMobileRPCActivityHarness(deadlineScheduler: deadlines) { harness, windowID in
            let panelID = try harness.panelID(forWindow: 1)
            let controller = TerminalController.shared
            controller.debugResetMobileViewportReportsForTesting()
            defer { controller.debugResetMobileViewportReportsForTesting() }
            controller.debugSetMobileViewportReportForTesting(
                surfaceID: panelID,
                clientID: "ipad-timeout-close",
                columns: 92,
                rows: 31
            )
            var observedResult: TerminalController.V2CallResult?
            let close = Task { @MainActor in
                let result = await controller.v2MobileTerminalClose(params: mobileCloseParams(
                    windowID: windowID,
                    workspaceID: harness.workspace.id,
                    panelID: panelID
                ))
                observedResult = result
                return result
            }
            await waitForPendingCommand(on: harness.connection)

            #expect(deadlines.scheduledCount == 1)
            deadlines.fireAll()
            #expect(observedResult == nil, "a written close remains pending until FIFO-following recovery")

            harness.connection.handleMessageForTesting(.commandResult(
                commandNumber: 102,
                lines: [],
                isError: false
            ))
            #expect(harness.connection.pendingCommandKindsForTesting.first == .listWindows(
                reorderGeneration: 0,
                retainedPaneIDs: []
            ))
            harness.connection.handleMessageForTesting(.commandResult(
                commandNumber: 103,
                lines: mobileRecoveryWindowLines(mutationApplied ? [2] : [1, 2]),
                isError: false
            ))

            let result = await close.value
            if mutationApplied {
                guard case .ok = result else {
                    Issue.record("Expected authoritative target absence to confirm the close")
                    return
                }
                #expect(harness.workspace.terminalPanel(for: panelID) == nil)
                #expect(controller.debugMobileViewportReportClientIDsForTesting(surfaceID: panelID) == nil)
            } else {
                guard case .err = result else {
                    Issue.record("Expected authoritative target presence to reject the close")
                    return
                }
                #expect(harness.workspace.terminalPanel(for: panelID) != nil)
                #expect(
                    controller.debugMobileViewportReportClientIDsForTesting(surfaceID: panelID)
                        == ["ipad-timeout-close"]
                )
            }
        }
    }

    @Test func timedOutMobileRemoteCloseReportsUnknownWhenRecoveryFails() async throws {
        let deadlines = CapturingActivityQueryDeadlineScheduler()
        try await withMobileRPCActivityHarness(deadlineScheduler: deadlines) { harness, windowID in
            let panelID = try harness.panelID(forWindow: 1)
            var observedResult: TerminalController.V2CallResult?
            let close = Task { @MainActor in
                let result = await TerminalController.shared.v2MobileTerminalClose(params: mobileCloseParams(
                    windowID: windowID,
                    workspaceID: harness.workspace.id,
                    panelID: panelID
                ))
                observedResult = result
                return result
            }
            await waitForPendingCommand(on: harness.connection)

            deadlines.fireAll()
            #expect(observedResult == nil)
            harness.connection.handleMessageForTesting(.commandResult(
                commandNumber: 104,
                lines: [],
                isError: false
            ))
            harness.connection.handleMessageForTesting(.commandResult(
                commandNumber: 105,
                lines: ["recovery rejected"],
                isError: true
            ))

            guard case let .err(code, _, _) = await close.value else {
                Issue.record("Expected failed close recovery to report an error")
                return
            }
            #expect(code == "result_unknown")
        }
    }

    @Test func timedOutMobileRemoteCloseBoundsSilentRecoveryAndResetsStream() async throws {
        let deadlines = CapturingActivityQueryDeadlineScheduler()
        try await withMobileRPCActivityHarness(deadlineScheduler: deadlines) { harness, windowID in
            let panelID = try harness.panelID(forWindow: 1)
            var observedResult: TerminalController.V2CallResult?
            let close = Task { @MainActor in
                let result = await TerminalController.shared.v2MobileTerminalClose(params: mobileCloseParams(
                    windowID: windowID,
                    workspaceID: harness.workspace.id,
                    panelID: panelID
                ))
                observedResult = result
                return result
            }
            await waitForPendingCommand(on: harness.connection)
            let token = try #require(harness.connection.windowCloseRequests.keys.first)

            deadlines.fireNext()
            #expect(observedResult == nil)
            harness.connection.handleMessageForTesting(.commandResult(
                commandNumber: 106,
                lines: [],
                isError: false
            ))
            #expect(harness.connection.pendingCommandKindsForTesting.first == .listWindows(
                reorderGeneration: 0,
                retainedPaneIDs: []
            ))
            #expect(deadlines.scheduledCount == 2, "the written recovery read needs its own deadline")

            deadlines.fireNext()

            #expect(resultErrorCode(observedResult) == "result_unknown")
            #expect(harness.connection.windowCloseRequests[token] == nil)
            #expect(harness.connection.windowCloseDeadlineCancellations[token] == nil)
            #expect(!harness.connection.windowCloseRecoveryTokensAwaitingList.contains(token))
            #expect(!harness.connection.windowCloseRecoveryTokensInFlight.contains(token))
            #expect(!harness.connection.windowListRequestInFlight)
            #expect(!harness.connection.windowListRequestDirty)
            #expect(harness.connection.pendingCommandKindsForTesting.isEmpty)
            #expect(harness.connection.connectionState == .reconnecting)

            if observedResult != nil {
                let orderBeforeLateReply = harness.connection.windowOrder
                harness.connection.handleMessageForTesting(.commandResult(
                    commandNumber: 107,
                    lines: mobileRecoveryWindowLines([2]),
                    isError: false
                ))
                #expect(harness.connection.windowOrder == orderBeforeLateReply)
                #expect(resultErrorCode(observedResult) == "result_unknown")
            } else {
                // Keep the RED bounded without supplying the missing recovery
                // reply that this regression deliberately withholds.
                harness.connection.beginReconnecting()
            }
            #expect(resultErrorCode(await close.value) == "result_unknown")
        }
    }

    @Test func disconnectedMobileRemoteClosePreservesViewportAndTerminal() async throws {
        try await withMobileRPCActivityHarness { harness, windowID in
            let panelID = try harness.panelID(forWindow: 1)
            let controller = TerminalController.shared
            controller.debugResetMobileViewportReportsForTesting()
            defer { controller.debugResetMobileViewportReportsForTesting() }
            controller.debugSetMobileViewportReportForTesting(
                surfaceID: panelID,
                clientID: "ipad-disconnect-close",
                columns: 92,
                rows: 31
            )
            let close = Task { @MainActor in
                await controller.v2MobileTerminalClose(params: mobileCloseParams(
                    windowID: windowID,
                    workspaceID: harness.workspace.id,
                    panelID: panelID
                ))
            }
            await waitForPendingCommand(on: harness.connection)
            harness.connection.beginReconnecting()

            guard case .err = await close.value else {
                Issue.record("Expected disconnected remote close to fail")
                return
            }
            #expect(harness.workspace.terminalPanel(for: panelID) != nil)
            #expect(
                controller.debugMobileViewportReportClientIDsForTesting(surfaceID: panelID)
                    == ["ipad-disconnect-close"]
            )
        }
    }

    @Test func cancelledMobileRemoteClosePreservesViewportAndTerminal() async throws {
        try await withMobileRPCActivityHarness { harness, windowID in
            let panelID = try harness.panelID(forWindow: 1)
            let controller = TerminalController.shared
            controller.debugResetMobileViewportReportsForTesting()
            defer { controller.debugResetMobileViewportReportsForTesting() }
            controller.debugSetMobileViewportReportForTesting(
                surfaceID: panelID,
                clientID: "ipad-cancel-close",
                columns: 92,
                rows: 31
            )
            let close = Task { @MainActor in
                await controller.v2MobileTerminalClose(params: mobileCloseParams(
                    windowID: windowID,
                    workspaceID: harness.workspace.id,
                    panelID: panelID
                ))
            }
            await waitForPendingCommand(on: harness.connection)
            close.cancel()

            guard case .err = await close.value else {
                Issue.record("Expected cancelled remote close to fail")
                return
            }
            #expect(harness.workspace.terminalPanel(for: panelID) != nil)
            #expect(
                controller.debugMobileViewportReportClientIDsForTesting(surfaceID: panelID)
                    == ["ipad-cancel-close"]
            )
        }
    }

    @Test func mobileRemoteReorderWaitsForAuthoritativeMismatchAndReconciles() async throws {
        try await withMobileRPCActivityHarness { harness, windowID in
            let firstPanelID = try harness.panelID(forWindow: 1)
            let secondPanelID = try harness.panelID(forWindow: 2)
            let paneID = try #require(harness.workspace.paneId(forPanelId: firstPanelID))
            var observedResult: TerminalController.V2CallResult?
            let reorder = Task { @MainActor in
                let result = await TerminalController.shared.v2MobileTerminalReorder(params: [
                    "window_id": windowID.uuidString,
                    "workspace_id": harness.workspace.id.uuidString,
                    "pane_id": paneID.id.uuidString,
                    "surface_id": firstPanelID.uuidString,
                    "index": 1,
                ])
                observedResult = result
                return result
            }
            await waitForPendingCommand(on: harness.connection)

            #expect(observedResult == nil)
            harness.connection.handleMessageForTesting(.commandResult(
                commandNumber: 110,
                lines: [],
                isError: false
            ))
            harness.connection.handleMessageForTesting(.commandResult(
                commandNumber: 111,
                lines: ["@1", "@2"],
                isError: false
            ))

            guard case .err = await reorder.value else {
                Issue.record("Expected authoritative reorder mismatch to fail")
                return
            }
            let reconciledOrder = harness.workspace.bonsplitController.tabs(inPane: paneID).compactMap {
                harness.workspace.panelIdFromSurfaceId($0.id)
            }
            #expect(reconciledOrder == [firstPanelID, secondPanelID])
        }
    }

    @Test(arguments: [true, false])
    func mobileRemoteReorderTimeoutResolvesFromAuthoritativeSnapshot(
        mutationApplied: Bool
    ) async throws {
        let deadlines = CapturingActivityQueryDeadlineScheduler()
        try await withMobileRPCActivityHarness(deadlineScheduler: deadlines) { harness, windowID in
            let firstPanelID = try harness.panelID(forWindow: 1)
            let paneID = try #require(harness.workspace.paneId(forPanelId: firstPanelID))
            var observedResult: TerminalController.V2CallResult?
            let reorder = Task { @MainActor in
                let result = await TerminalController.shared.v2MobileTerminalReorder(params: [
                    "window_id": windowID.uuidString,
                    "workspace_id": harness.workspace.id.uuidString,
                    "pane_id": paneID.id.uuidString,
                    "surface_id": firstPanelID.uuidString,
                    "index": 1,
                ])
                observedResult = result
                return result
            }
            await waitForPendingCommand(on: harness.connection)

            #expect(deadlines.scheduledCount == 1)
            deadlines.fireAll()
            #expect(observedResult == nil, "a written reorder remains pending until FIFO-following recovery")
            harness.connection.handleMessageForTesting(.commandResult(
                commandNumber: 112,
                lines: [],
                isError: false
            ))
            #expect(harness.connection.pendingCommandKindsForTesting.first == .listWindows(
                reorderGeneration: 1,
                retainedPaneIDs: []
            ))
            harness.connection.handleMessageForTesting(.commandResult(
                commandNumber: 113,
                lines: mobileRecoveryWindowLines(mutationApplied ? [2, 1] : [1, 2]),
                isError: false
            ))

            let result = await reorder.value
            if mutationApplied {
                guard case .ok = result else {
                    Issue.record("Expected authoritative desired order to confirm the reorder")
                    return
                }
            } else {
                guard case .err = result else {
                    Issue.record("Expected authoritative original order to reject the reorder")
                    return
                }
            }
        }
    }

    @Test func mobileRemoteReorderTimeoutReportsUnknownWhenRecoveryFails() async throws {
        let deadlines = CapturingActivityQueryDeadlineScheduler()
        try await withMobileRPCActivityHarness(deadlineScheduler: deadlines) { harness, windowID in
            let firstPanelID = try harness.panelID(forWindow: 1)
            let paneID = try #require(harness.workspace.paneId(forPanelId: firstPanelID))
            var observedResult: TerminalController.V2CallResult?
            let reorder = Task { @MainActor in
                let result = await TerminalController.shared.v2MobileTerminalReorder(params: [
                    "window_id": windowID.uuidString,
                    "workspace_id": harness.workspace.id.uuidString,
                    "pane_id": paneID.id.uuidString,
                    "surface_id": firstPanelID.uuidString,
                    "index": 1,
                ])
                observedResult = result
                return result
            }
            await waitForPendingCommand(on: harness.connection)

            deadlines.fireAll()
            #expect(observedResult == nil)
            harness.connection.handleMessageForTesting(.commandResult(
                commandNumber: 114,
                lines: [],
                isError: false
            ))
            harness.connection.handleMessageForTesting(.commandResult(
                commandNumber: 115,
                lines: ["recovery rejected"],
                isError: true
            ))

            guard case let .err(code, _, _) = await reorder.value else {
                Issue.record("Expected failed reorder recovery to report an error")
                return
            }
            #expect(code == "result_unknown")
        }
    }

    @Test func mobileRemoteReorderBoundsSilentRecoveryAndResetsStream() async throws {
        let deadlines = CapturingActivityQueryDeadlineScheduler()
        try await withMobileRPCActivityHarness(deadlineScheduler: deadlines) { harness, windowID in
            let firstPanelID = try harness.panelID(forWindow: 1)
            let paneID = try #require(harness.workspace.paneId(forPanelId: firstPanelID))
            var observedResult: TerminalController.V2CallResult?
            let reorder = Task { @MainActor in
                let result = await TerminalController.shared.v2MobileTerminalReorder(params: [
                    "window_id": windowID.uuidString,
                    "workspace_id": harness.workspace.id.uuidString,
                    "pane_id": paneID.id.uuidString,
                    "surface_id": firstPanelID.uuidString,
                    "index": 1,
                ])
                observedResult = result
                return result
            }
            await waitForPendingCommand(on: harness.connection)
            let token = try #require(harness.connection.windowReorderVerificationTokens.keys.first)

            deadlines.fireNext()
            #expect(observedResult == nil)
            harness.connection.handleMessageForTesting(.commandResult(
                commandNumber: 116,
                lines: [],
                isError: false
            ))
            #expect(harness.connection.pendingCommandKindsForTesting.first == .listWindows(
                reorderGeneration: 1,
                retainedPaneIDs: []
            ))
            #expect(deadlines.scheduledCount == 2, "the written recovery read needs its own deadline")

            deadlines.fireNext()

            #expect(resultErrorCode(observedResult) == "result_unknown")
            #expect(harness.connection.windowReorderVerificationTokens[token] == nil)
            #expect(harness.connection.windowReorderVerificationGeneration == nil)
            #expect(harness.connection.windowReorderVerifications.isEmpty)
            #expect(harness.connection.windowReorderDeadlineCancellations.isEmpty)
            #expect(harness.connection.windowReorderRecoveryGeneration == nil)
            #expect(!harness.connection.windowListRequestInFlight)
            #expect(!harness.connection.windowListRequestDirty)
            #expect(harness.connection.pendingCommandKindsForTesting.isEmpty)
            #expect(harness.connection.connectionState == .reconnecting)

            if observedResult != nil {
                let orderBeforeLateReply = harness.connection.windowOrder
                harness.connection.handleMessageForTesting(.commandResult(
                    commandNumber: 117,
                    lines: mobileRecoveryWindowLines([2, 1]),
                    isError: false
                ))
                #expect(harness.connection.windowOrder == orderBeforeLateReply)
                #expect(resultErrorCode(observedResult) == "result_unknown")
            } else {
                harness.connection.beginReconnecting()
            }
            #expect(resultErrorCode(await reorder.value) == "result_unknown")
        }
    }

    @Test func mobileRemoteReorderDisconnectReturnsFailure() async throws {
        try await withMobileRPCActivityHarness { harness, windowID in
            let firstPanelID = try harness.panelID(forWindow: 1)
            let paneID = try #require(harness.workspace.paneId(forPanelId: firstPanelID))
            let reorder = Task { @MainActor in
                await TerminalController.shared.v2MobileTerminalReorder(params: [
                    "window_id": windowID.uuidString,
                    "workspace_id": harness.workspace.id.uuidString,
                    "pane_id": paneID.id.uuidString,
                    "surface_id": firstPanelID.uuidString,
                    "index": 1,
                ])
            }
            await waitForPendingCommand(on: harness.connection)
            harness.connection.beginReconnecting()

            guard case .err = await reorder.value else {
                Issue.record("Expected disconnected remote reorder to fail")
                return
            }
        }
    }

    @MainActor
    private func withMobileRPCActivityHarness(
        deadlineScheduler: CapturingActivityQueryDeadlineScheduler? = nil,
        _ body: @MainActor (ActivityQueryHarness, UUID) async throws -> Void
    ) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let previousAppDelegate = AppDelegate.shared
            let appDelegate = AppDelegate()
            let manager = TabManager()
            let windowID = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
            AppDelegate.shared = appDelegate
            let harness = try ActivityQueryHarness(
                controller: appDelegate.remoteTmuxController,
                manager: manager,
                windowCount: 2,
                scheduleActivityQueryDeadline: deadlineScheduler?.schedule
            )
            defer {
                harness.tearDown()
                appDelegate.unregisterMainWindowContextForTesting(windowId: windowID)
                AppDelegate.shared = previousAppDelegate
            }
            try await body(harness, windowID)
        }
    }

    private func mobileCloseParams(
        windowID: UUID,
        workspaceID: UUID,
        panelID: UUID
    ) -> [String: Any] {
        [
            "window_id": windowID.uuidString,
            "workspace_id": workspaceID.uuidString,
            "terminal_id": panelID.uuidString,
            "confirmed": true,
        ]
    }

    private func mobileRecoveryWindowLines(_ order: [Int]) -> [String] {
        order.map { windowID in
            let paneID = windowID - 1
            let layout = "f92f,80x24,0,0,\(paneID)"
            return "@\(windowID) \(layout) \(layout) [] window-\(windowID)"
        }
    }

    private func resultErrorCode(_ result: TerminalController.V2CallResult?) -> String? {
        guard case let .err(code, _, _)? = result else { return nil }
        return code
    }

    @MainActor
    private func waitForPendingCommand(on connection: RemoteTmuxControlConnection) async {
        for _ in 0..<50 where connection.pendingCommandKindsForTesting.isEmpty {
            await Task.yield()
        }
        #expect(!connection.pendingCommandKindsForTesting.isEmpty)
    }

    @MainActor private struct ActivityQueryHarness {
        let controller: RemoteTmuxController
        let manager: TabManager
        let host: RemoteTmuxHost
        let connection: RemoteTmuxControlConnection
        let writer: RemoteTmuxControlPipeWriter
        let pipe: Pipe
        let workspace: Workspace

        init(
            controller: RemoteTmuxController,
            manager: TabManager,
            windowCount: Int,
            scheduleActivityQueryDeadline: RemoteTmuxControlConnection.ActivityQueryDeadlineScheduler? = nil
        ) throws {
            self.controller = controller
            self.manager = manager
            host = RemoteTmuxHost(destination: "activity-query-\(UUID().uuidString)@host")
            if let scheduleActivityQueryDeadline {
                connection = RemoteTmuxControlConnection(
                    host: host,
                    sessionName: "activity-query",
                    scheduleActivityQueryDeadline: scheduleActivityQueryDeadline
                )
            } else {
                connection = RemoteTmuxControlConnection(host: host, sessionName: "activity-query")
            }
            pipe = Pipe()
            writer = RemoteTmuxControlPipeWriter(
                handle: pipe.fileHandleForWriting,
                label: "remote-tmux-activity-query-test",
                maxPendingBytes: 1 << 16,
                onFailure: {}
            )
            connection.installStdinWriterForTesting(writer)
            connection.handleMessageForTesting(.enter)
            connection.handleMessageForTesting(
                .commandResult(commandNumber: 0, lines: [], isError: false)
            )
            controller.cacheConnection(connection)
            try controller.mirrorSession(
                host: host,
                sessionName: "activity-query",
                into: manager
            )

            let windowLines = (1...windowCount).map { windowID in
                let paneID = windowID - 1
                let layout = "f92f,80x24,0,0,\(paneID)"
                return "@\(windowID) \(layout) \(layout) [] window-\(windowID)"
            }
            connection.handleMessageForTesting(.commandResult(
                commandNumber: 1,
                lines: windowLines,
                isError: false
            ))

            var drained = 0
            while let kind = connection.pendingCommandKindsForTesting.first {
                let lines: [String]
                if case let .paneRects(windowID, _) = kind {
                    let paneID = windowID - 1
                    lines = ["%\(paneID) 0 0 80 24 1 off :0 \"host\""]
                } else {
                    lines = []
                }
                connection.handleMessageForTesting(.commandResult(
                    commandNumber: 2 + drained,
                    lines: lines,
                    isError: false
                ))
                drained += 1
                guard drained < 200 else {
                    Issue.record("Activity-query harness command queue did not drain")
                    break
                }
            }
            workspace = try #require(manager.tabs.first { $0.isRemoteTmuxMirror })
        }

        func panelID(forWindow windowID: Int) throws -> UUID {
            let mirror = try #require(controller.sessionMirror(
                host: host,
                sessionName: "activity-query"
            ))
            return try #require(mirror.panelIdByWindow[windowID])
        }

        func tearDown() {
            controller.detach(host: host, sessionName: "activity-query")
            writer.close()
            try? pipe.fileHandleForReading.close()
        }
    }

    @MainActor
    private final class CapturingActivityQueryDeadlineScheduler {
        private struct PendingDeadline {
            let delay: Duration
            var isCancelled = false
            var hasFired = false
            let action: @MainActor () -> Void
        }

        private var pendingDeadlines: [PendingDeadline] = []

        var schedule: RemoteTmuxControlConnection.ActivityQueryDeadlineScheduler {
            { [weak self] delay, action in
                guard let self else { return {} }
                let index = pendingDeadlines.count
                pendingDeadlines.append(PendingDeadline(delay: delay, action: action))
                return { [weak self] in
                    guard let self, pendingDeadlines.indices.contains(index) else { return }
                    pendingDeadlines[index].isCancelled = true
                }
            }
        }

        var scheduledCount: Int { pendingDeadlines.count }
        var cancelledCount: Int { pendingDeadlines.filter(\.isCancelled).count }
        var firedCount: Int { pendingDeadlines.filter(\.hasFired).count }
        var delays: [Duration] { pendingDeadlines.map(\.delay) }

        func fireNext() {
            guard let index = pendingDeadlines.indices.first(where: {
                !pendingDeadlines[$0].isCancelled && !pendingDeadlines[$0].hasFired
            }) else { return }
            pendingDeadlines[index].hasFired = true
            pendingDeadlines[index].action()
        }

        func fireAll() {
            for index in pendingDeadlines.indices {
                guard !pendingDeadlines[index].isCancelled,
                      !pendingDeadlines[index].hasFired else { continue }
                pendingDeadlines[index].hasFired = true
                pendingDeadlines[index].action()
            }
        }
    }
}
