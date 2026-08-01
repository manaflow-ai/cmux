import AppKit
import CmuxControlSocket
import Foundation
import Testing
import CmuxSettings
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Remote-tmux behavior tests using pure seams and cached, unstarted connections.
@MainActor
@Suite(.serialized)
struct RemoteTmuxMirrorTargetingTests {
    private func session(_ name: String, id: String? = nil) -> RemoteTmuxSession {
        RemoteTmuxSession(
            id: id ?? "$\(name)",
            name: name,
            windowCount: 1,
            attached: false,
            createdUnix: nil
        )
    }

    private func cacheConnection(
        controller: RemoteTmuxController,
        host: RemoteTmuxHost,
        sessionName: String
    ) {
        controller.cacheConnection(RemoteTmuxControlConnection(host: host, sessionName: sessionName))
    }

    @Test func unmirroredSessionsFiltersAlreadyMirroredNamesForHost() throws {
        let controller = RemoteTmuxController()
        let manager = TabManager()
        let host = RemoteTmuxHost(destination: "user@host")
        cacheConnection(controller: controller, host: host, sessionName: "old")
        try controller.mirrorSession(host: host, sessionName: "old", into: manager)

        let sessions = [session("old"), session("new")]
        #expect(controller.unmirroredSessions(sessions, host: host).map(\.name) == ["new"])
    }

    @Test func tmuxSessionNumericIdParsesOnlyDollarPrefixedDecimalIds() {
        #expect(RemoteTmuxController.tmuxSessionNumericId("$0") == 0)
        #expect(RemoteTmuxController.tmuxSessionNumericId("$42") == 42)
        #expect(RemoteTmuxController.tmuxSessionNumericId("0") == nil)
        #expect(RemoteTmuxController.tmuxSessionNumericId("") == nil)
        #expect(RemoteTmuxController.tmuxSessionNumericId("$x") == nil)
        #expect(RemoteTmuxController.tmuxSessionNumericId("$-1") == nil)
    }

    @Test func unmirroredSessionsUsesStableSessionIdsBeforeNames() {
        // Rename race: the mirrored session's %session-renamed has not re-keyed
        // yet, so its stable id must prevent a duplicate mirror under the new name.
        let renameRace = RemoteTmuxController.unmirroredSessions(
            [session("zeromain", id: "$0")],
            mirroredSessionIds: [0],
            mirroredNames: ["0"]
        )
        #expect(renameRace.isEmpty)

        // A NEW session reusing a mirrored session's stale pre-rename name stays
        // undiscovered until the rename event re-keys the mirror (deliberate: the
        // name-keyed attach pipeline would drop it anyway; see the helper's doc).
        let reusedOldName = RemoteTmuxController.unmirroredSessions(
            [session("0", id: "$5")],
            mirroredSessionIds: [0],
            mirroredNames: ["0"]
        )
        #expect(reusedOldName.isEmpty)

        // Mid-attach mirrors have no sessionId yet; the name fallback covers them.
        let midAttach = RemoteTmuxController.unmirroredSessions(
            [session("dev", id: "$5")],
            mirroredSessionIds: [],
            mirroredNames: ["dev"]
        )
        #expect(midAttach.isEmpty)

        let fresh = RemoteTmuxController.unmirroredSessions(
            [session("fresh", id: "$7")],
            mirroredSessionIds: [0],
            mirroredNames: ["old"]
        )
        #expect(fresh.map(\.name) == ["fresh"])
    }

    @Test func unmirroredSessionsSeesSeededSessionIdBeforeStreamReportsIt() throws {
        let controller = RemoteTmuxController()
        let manager = TabManager()
        let host = RemoteTmuxHost(destination: "user@host")
        cacheConnection(controller: controller, host: host, sessionName: "old")
        try controller.mirrorSession(host: host, sessionName: "old", sessionId: 3, into: manager)

        // Renamed remotely before %session-changed re-keys: same $3, new name —
        // the discovery-seeded id must prevent a duplicate mirror.
        #expect(controller.unmirroredSessions([session("renamed", id: "$3")], host: host).isEmpty)
        // A genuinely new session is still discovered.
        #expect(controller.unmirroredSessions([session("fresh", id: "$4")], host: host).map(\.name) == ["fresh"])
    }

    @Test func mirrorSessionsMirrorsOnlyNewSessionsAndIsIdempotent() throws {
        let controller = RemoteTmuxController()
        let manager = TabManager()
        let host = RemoteTmuxHost(destination: "user@host")
        cacheConnection(controller: controller, host: host, sessionName: "old")
        cacheConnection(controller: controller, host: host, sessionName: "new")
        try controller.mirrorSession(host: host, sessionName: "old", into: manager)

        controller.mirrorSessions([session("old"), session("new")], host: host, into: manager)
        controller.mirrorSessions([session("old"), session("new")], host: host, into: manager)

        let mirrorTitles = manager.tabs
            .filter(\.isRemoteTmuxMirror)
            .map(\.title)
            .sorted()
        #expect(mirrorTitles == ["new", "old"])
    }

    @Test func workspaceCloseKillTargetSkipsEndedConnections() {
        #expect(RemoteTmuxController.workspaceCloseKillTarget(
            connectionExited: true,
            sessionId: 5,
            sessionName: "dev"
        ) == nil)
        #expect(RemoteTmuxController.workspaceCloseKillTarget(
            connectionExited: false,
            sessionId: 5,
            sessionName: "dev"
        ) == "$5")
        #expect(RemoteTmuxController.workspaceCloseKillTarget(
            connectionExited: false,
            sessionId: nil,
            sessionName: "dev"
        ) == "dev")
    }

    @Test func shouldRefreshTitleChromeDistinguishesDirectAndSurfaceSourcedNotifications() throws {
        let suiteName = "RemoteTmuxMirrorTargeting.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = UserDefaultsSettingsClient(defaults: defaults)
        let catalog = SettingCatalog()
        let manager = TabManager(settings: settings)
        let selected = try #require(manager.selectedWorkspace)
        manager.selectedTabId = selected.id
        let otherId = UUID()
        let directSelected = Notification(
            name: .workspaceTitleDidChange,
            object: manager,
            userInfo: [GhosttyNotificationKey.tabId: selected.id]
        )
        let directOther = Notification(
            name: .workspaceTitleDidChange,
            object: manager,
            userInfo: [GhosttyNotificationKey.tabId: otherId]
        )
        let surfaceSelected = Notification(
            name: .workspaceTitleDidChange,
            object: manager,
            userInfo: [
                GhosttyNotificationKey.tabId: selected.id,
                GhosttyNotificationKey.surfaceId: UUID(),
            ]
        )

        settings.set(false, for: catalog.terminal.titleUpdateCoalescingEnabled)
        #expect(!manager.shouldRefreshTitleChrome(for: directOther))
        #expect(manager.shouldRefreshTitleChrome(for: directSelected))
        #expect(!manager.shouldRefreshTitleChrome(for: surfaceSelected))

        settings.set(true, for: catalog.terminal.titleUpdateCoalescingEnabled)
        #expect(manager.shouldRefreshTitleChrome(for: directSelected))
        #expect(manager.shouldRefreshTitleChrome(for: surfaceSelected))
    }

    @Test func programmaticMirrorReorderUpdatesTheTmuxWindowOrderLedger() throws {
        let host = RemoteTmuxHost(destination: "reorder-\(UUID().uuidString)@host")
        let connection = RemoteTmuxControlConnection(host: host, sessionName: "work")
        let pipe = Pipe()
        let writer = RemoteTmuxControlPipeWriter(
            handle: pipe.fileHandleForWriting,
            label: "remote-tmux-programmatic-reorder-test",
            maxPendingBytes: 1 << 16,
            onFailure: {}
        )
        defer { writer.close(); try? pipe.fileHandleForReading.close() }
        connection.installStdinWriterForTesting(writer)
        connection.handleMessageForTesting(.enter)
        connection.handleMessageForTesting(
            .commandResult(commandNumber: 0, lines: [], isError: false)
        )
        connection.handleMessageForTesting(.commandResult(
            commandNumber: 1,
            lines: [
                "@1 f92f,80x24,0,0,0 f92f,80x24,0,0,0 [] one",
                "@2 e5d1,90x30,0,0,5 e5d1,90x30,0,0,5 [] two",
            ],
            isError: false
        ))
        for kind in connection.pendingCommandKindsForTesting {
            guard case let .paneRects(windowId, _) = kind else { continue }
            let paneId = windowId == 1 ? 0 : 5
            let size = windowId == 1 ? "80 24" : "90 30"
            connection.handleMessageForTesting(.commandResult(
                commandNumber: 2,
                lines: ["%\(paneId) 0 0 \(size) 1 off :zsh"],
                isError: false
            ))
        }

        let controller = RemoteTmuxController()
        controller.cacheConnection(connection)
        let manager = TabManager()
        try controller.mirrorSession(host: host, sessionName: "work", into: manager)
        let workspace = try #require(manager.tabs.first { $0.isRemoteTmuxMirror })
        let paneId = try #require(workspace.bonsplitController.allPaneIds.first)
        let panelIds = workspace.bonsplitController.tabs(inPane: paneId)
            .compactMap { workspace.panelIdFromSurfaceId($0.id) }
        #expect(panelIds.count == 2)
        let secondPanelId = try #require(panelIds.last)

        #expect(workspace.reorderSurface(panelId: secondPanelId, toIndex: 0, focus: false))
        #expect(connection.windowOrder == [2, 1])
    }

    @Test func mirrorReorderRejectedBySyncOwnerLeavesLocalOrderUnchanged() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let paneId = try #require(workspace.bonsplitController.allPaneIds.first)
        guard let secondPanel = workspace.addRemoteTmuxDisplayPane(
            remotePaneId: 2,
            title: "two",
            onInput: { _ in }
        ) else {
            Issue.record("Expected a second mirror panel")
            return
        }
        workspace.isRemoteTmuxMirror = true
        let orderBefore = workspace.bonsplitController.tabs(inPane: paneId).map(\.id)
        let selectedTabBefore = workspace.bonsplitController.selectedTab(inPane: paneId)?.id
        let focusedPaneBefore = workspace.bonsplitController.focusedPaneId
        let focusedPanelBefore = workspace.focusedPanelId
        var requestedPanelOrder: [UUID]?
        workspace.remoteTmuxWindowOrderSync = { panelOrder, _ in
            requestedPanelOrder = panelOrder
            return false
        }

        let reordered = workspace.reorderSurface(
            panelId: secondPanel.id,
            toIndex: 0,
            focus: false
        )

        #expect(!reordered)
        #expect(requestedPanelOrder?.first == secondPanel.id)
        #expect(workspace.bonsplitController.tabs(inPane: paneId).map(\.id) == orderBefore)
        #expect(workspace.bonsplitController.selectedTab(inPane: paneId)?.id == selectedTabBefore)
        #expect(workspace.bonsplitController.focusedPaneId == focusedPaneBefore)
        #expect(workspace.focusedPanelId == focusedPanelBefore)
    }

    @Test func mirrorPinReorderUsesSyncOwner() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let paneId = try #require(workspace.bonsplitController.allPaneIds.first)
        guard let secondPanel = workspace.addRemoteTmuxDisplayPane(
            remotePaneId: 2, title: "two", onInput: { _ in }
        ) else {
            Issue.record("Expected a second mirror panel")
            return
        }
        workspace.isRemoteTmuxMirror = true
        var requestedPanelOrder: [UUID]?
        workspace.remoteTmuxWindowOrderSync = { panelOrder, _ in
            requestedPanelOrder = panelOrder
            return true
        }

        workspace.setPanelPinned(panelId: secondPanel.id, pinned: true)

        let panelOrder = workspace.bonsplitController.tabs(inPane: paneId)
            .compactMap { workspace.panelIdFromSurfaceId($0.id) }
        #expect(panelOrder.first == secondPanel.id)
        #expect(requestedPanelOrder == panelOrder)
        #expect(workspace.isPanelPinned(secondPanel.id))
    }

    @Test func mirrorPinReorderRejectionRestoresOrderAndPinState() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let paneId = try #require(workspace.bonsplitController.allPaneIds.first)
        guard let secondPanel = workspace.addRemoteTmuxDisplayPane(
            remotePaneId: 2, title: "two", onInput: { _ in }
        ) else {
            Issue.record("Expected a second mirror panel")
            return
        }
        workspace.isRemoteTmuxMirror = true
        let orderBefore = workspace.bonsplitController.tabs(inPane: paneId).map(\.id)
        workspace.remoteTmuxWindowOrderSync = { _, _ in false }

        workspace.setPanelPinned(panelId: secondPanel.id, pinned: true)
        let secondTabId = try #require(workspace.surfaceIdFromPanelId(secondPanel.id))

        #expect(workspace.bonsplitController.tabs(inPane: paneId).map(\.id) == orderBefore)
        #expect(!workspace.isPanelPinned(secondPanel.id))
        #expect(workspace.bonsplitController.tab(secondTabId)?.isPinned == false)
    }

    @Test func mirrorPinAsyncReorderFailureRestoresPinBeforeAuthoritativeOrder() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let paneId = try #require(workspace.bonsplitController.allPaneIds.first)
        guard let secondPanel = workspace.addRemoteTmuxDisplayPane(
            remotePaneId: 2, title: "two", onInput: { _ in }
        ) else {
            Issue.record("Expected a second mirror panel")
            return
        }
        workspace.isRemoteTmuxMirror = true
        let orderBefore = workspace.bonsplitController.tabs(inPane: paneId)
            .compactMap { workspace.panelIdFromSurfaceId($0.id) }
        var verification: ((Bool) -> Void)?
        workspace.remoteTmuxWindowOrderSync = { _, completion in
            verification = completion
            return true
        }

        workspace.setPanelPinned(panelId: secondPanel.id, pinned: true)
        let secondTabId = try #require(workspace.surfaceIdFromPanelId(secondPanel.id))
        #expect(workspace.isPanelPinned(secondPanel.id))
        #expect(workspace.bonsplitController.tabs(inPane: paneId).first?.id == secondTabId)

        verification?(false)
        #expect(!workspace.isPanelPinned(secondPanel.id))
        #expect(workspace.bonsplitController.tab(secondTabId)?.isPinned == false)

        #expect(workspace.reorderRemoteTmuxMirrorTabs(toPanelOrder: orderBefore))
        let recoveredOrder = workspace.bonsplitController.tabs(inPane: paneId)
            .compactMap { workspace.panelIdFromSurfaceId($0.id) }
        #expect(recoveredOrder == orderBefore)
        #expect(!workspace.isPanelPinned(secondPanel.id))
    }

    @Test func stalePinFailureDoesNotOverwriteANewerPinChoice() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let paneId = try #require(workspace.bonsplitController.allPaneIds.first)
        guard let secondPanel = workspace.addRemoteTmuxDisplayPane(
            remotePaneId: 2, title: "two", onInput: { _ in }
        ) else {
            Issue.record("Expected a second mirror panel")
            return
        }
        workspace.isRemoteTmuxMirror = true
        var verification: ((Bool) -> Void)?
        workspace.remoteTmuxWindowOrderSync = { _, completion in
            verification = completion
            return true
        }

        workspace.setPanelPinned(panelId: secondPanel.id, pinned: true)
        let firstVerification = try #require(verification)
        workspace.setPanelPinned(panelId: secondPanel.id, pinned: false)
        workspace.setPanelPinned(panelId: secondPanel.id, pinned: true)
        firstVerification(false)

        let secondTabId = try #require(workspace.surfaceIdFromPanelId(secondPanel.id))
        #expect(workspace.isPanelPinned(secondPanel.id))
        #expect(workspace.bonsplitController.tab(secondTabId)?.isPinned == true)
        #expect(workspace.bonsplitController.tabs(inPane: paneId).first?.id == secondTabId)
    }

    @Test func mirrorWindowReorderUsesDetachedSwaps() {
        let commands = RemoteTmuxController.mirrorWindowReorderCommands(
            current: [0, 1, 2],
            desired: [1, 2, 0]
        )

        #expect(commands == [
            "swap-window -d -s @0 -t @1",
            "swap-window -d -s @0 -t @2",
        ])
    }

    @Test func multiPaneMirrorSurfaceTitlesUseWindowName() throws {
        let harness = try MirrorTitleHarness()
        defer { harness.tearDown() }
        harness.publishListWindows([
            "@1 f92f,80x24,0,0,0 f92f,80x24,0,0,0 [] editor",
            "@2 abcd,120x40,0,0{60x40,0,0,4,59x40,61,0[59x20,61,0,5,59x19,61,21,8]} abcd,120x40,0,0{60x40,0,0,4,59x40,61,0[59x20,61,0,5,59x19,61,21,8]} [] logs",
        ])
        try harness.drainThroughPaneRects([
            1: ["%0 0 0 80 24 1 off :0 \"cmuxs-Mac-mini.local\""],
            2: [
                "%4 0 0 60 40 1 off :0 \"cmuxs-Mac-mini.local\"",
                "%5 61 0 59 20 0 off :1 \"cmuxs-Mac-mini.local\"",
                "%8 61 21 59 19 0 off :2 \"cmuxs-Mac-mini.local\"",
            ],
        ])
        #expect(try harness.surfaceTitles() == ["editor", "logs", "logs [1]", "logs [2]"])
    }

    @Test func singlePaneMirrorSurfaceTitleStillUsesWindowName() throws {
        let harness = try MirrorTitleHarness()
        defer { harness.tearDown() }
        harness.publishListWindows(["@1 f92f,80x24,0,0,0 f92f,80x24,0,0,0 [] editor"])
        try harness.drainThroughPaneRects([1: ["%0 0 0 80 24 1 off :0 \"cmuxs-Mac-mini.local\""]])
        #expect(try harness.surfaceTitles() == ["editor"])
    }

    @Test func singlePaneToMultiPaneTransitionKeepsWindowNameInSurfaceTitles() throws {
        let harness = try MirrorTitleHarness()
        defer { harness.tearDown() }
        harness.publishListWindows(["@2 f92f,80x24,0,0,4 f92f,80x24,0,0,4 [] logs"])
        try harness.drainThroughPaneRects([2: ["%4 0 0 80 24 1 off :0 \"cmuxs-Mac-mini.local\""]])
        #expect(try harness.surfaceTitles() == ["logs"])

        harness.connection.handleMessageForTesting(.layoutChange(
            windowId: 2, layout: "abcd,120x40,0,0{60x40,0,0,4,59x40,61,0,5}", visibleLayout: nil, zoomed: false
        ))
        try harness.drainThroughPaneRects([2: [
            "%4 0 0 60 40 1 off :0 \"cmuxs-Mac-mini.local\"",
            "%5 61 0 59 40 0 off :1 \"cmuxs-Mac-mini.local\"",
        ]])

        #expect(try harness.surfaceTitles() == ["logs", "logs [1]"])
    }

    @MainActor private struct MirrorTitleHarness {
        let windowId: UUID
        let controller: RemoteTmuxController
        let host: RemoteTmuxHost
        let connection: RemoteTmuxControlConnection
        let writer: RemoteTmuxControlPipeWriter
        let pipe: Pipe
        let workspace: Workspace

        init() throws {
            let appDelegate = try #require(AppDelegate.shared)
            let windowId = appDelegate.createMainWindow()
            let manager = try #require(appDelegate.tabManagerFor(windowId: windowId))
            let controller = RemoteTmuxController()
            let host = RemoteTmuxHost(destination: "user@host")
            let connection = RemoteTmuxControlConnection(host: host, sessionName: "dogfood-a")
            let pipe = Pipe()
            let writer = RemoteTmuxControlPipeWriter(
                handle: pipe.fileHandleForWriting, label: "remote-tmux-title-test", maxPendingBytes: 1 << 16, onFailure: {}
            )
            connection.installStdinWriterForTesting(writer)
            connection.handleMessageForTesting(.enter)
            connection.handleMessageForTesting(.commandResult(commandNumber: 0, lines: [], isError: false))
            controller.cacheConnection(connection)
            try controller.mirrorSession(host: host, sessionName: "dogfood-a", into: manager)
            workspace = try #require(manager.tabs.first { $0.isRemoteTmuxMirror })
            self.windowId = windowId
            self.controller = controller
            self.host = host
            self.connection = connection
            self.writer = writer
            self.pipe = pipe
        }

        func publishListWindows(_ lines: [String]) {
            connection.handleMessageForTesting(.commandResult(commandNumber: 1, lines: lines, isError: false))
        }

        func drainThroughPaneRects(_ linesByWindow: [Int: [String]]) throws {
            while let kind = connection.pendingCommandKindsForTesting.first {
                let lines: [String]
                if case let .paneRects(windowId, _) = kind { lines = try #require(linesByWindow[windowId]) } else { lines = [] }
                connection.handleMessageForTesting(.commandResult(commandNumber: 2, lines: lines, isError: false))
            }
        }

        func surfaceTitles() throws -> [String] {
            let routing = ControlRoutingSelectors(
                hasWindowIDParam: false, windowID: nil, groupID: nil, workspaceID: workspace.id, surfaceID: nil, paneID: nil
            )
            let snapshot = try #require(TerminalController.shared.controlSurfaceList(routing: routing))
            return snapshot.surfaces.map(\.title)
        }

        func tearDown() {
            controller.detach(host: host, sessionName: "dogfood-a")
            writer.close()
            try? pipe.fileHandleForReading.close()
            let identifier = "cmux.main.\(windowId.uuidString)"
            NSApp.windows.first { $0.identifier?.rawValue == identifier }?.performClose(nil)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
    }
}
