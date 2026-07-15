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
        let harness = try ActivityQueryHarness(
            controller: controller,
            manager: manager,
            windowCount: 1
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

        // A live mobile RPC has only a short response budget. The host query must
        // fail closed before that budget expires even if the connected stream is
        // wedged and never emits either a command result or a reset.
        try await Task.sleep(for: .milliseconds(1_500))
        let releasedByDeadline = harness.connection.activityQueryCompletions.isEmpty
        #expect(releasedByDeadline)

        if !releasedByDeadline {
            harness.connection.failPendingActivityQueries()
        }
        let result = await query.value
        #expect(result == nil)
    }

    @Test func cancellingLiveActivityQueryReleasesItsContinuation() async throws {
        let controller = RemoteTmuxController()
        let manager = TabManager()
        let harness = try ActivityQueryHarness(
            controller: controller,
            manager: manager,
            windowCount: 1
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

        query.cancel()
        for _ in 0..<50 where !harness.connection.activityQueryCompletions.isEmpty {
            await Task.yield()
        }
        let releasedAfterCancellation = harness.connection.activityQueryCompletions.isEmpty
        #expect(releasedAfterCancellation)

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
            for _ in 0..<50 where harness.connection.activityQueryCompletions.isEmpty && !close.isCancelled {
                await Task.yield()
            }

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
            }
            let result = await close.value
            guard case .ok = result else {
                Issue.record("Expected the confirmed remote terminal close to succeed")
                return
            }
        }
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
            windowCount: Int
        ) throws {
            self.controller = controller
            self.manager = manager
            host = RemoteTmuxHost(destination: "activity-query-\(UUID().uuidString)@host")
            connection = RemoteTmuxControlConnection(host: host, sessionName: "activity-query")
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
}
