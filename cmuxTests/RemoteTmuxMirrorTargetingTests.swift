import Foundation
import Testing
import CmuxSettings

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavior tests for remote-tmux mirror targeting and lifecycle decisions. These
/// exercise pure seams and cached unstarted control connections; no ssh/tmux
/// process is launched.
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

    @Test func mirrorTargetTabManagerPrefersDedicatedWindowWhenResolvable() {
        let dedicatedId = UUID()
        let dedicated = TabManager()
        let fallback = TabManager()

        let resolved = RemoteTmuxController.mirrorTargetTabManager(
            dedicatedWindowId: dedicatedId,
            tabManagerForWindow: { $0 == dedicatedId ? dedicated : nil },
            fallbackTabManager: { fallback }
        )

        #expect(resolved === dedicated)
    }

    @Test func mirrorTargetTabManagerFallsBackWhenDedicatedMissingOrUnresolved() {
        let dedicatedId = UUID()
        let fallback = TabManager()

        let missing = RemoteTmuxController.mirrorTargetTabManager(
            dedicatedWindowId: nil,
            tabManagerForWindow: { _ in nil },
            fallbackTabManager: { fallback }
        )
        let unresolved = RemoteTmuxController.mirrorTargetTabManager(
            dedicatedWindowId: dedicatedId,
            tabManagerForWindow: { _ in nil },
            fallbackTabManager: { fallback }
        )

        #expect(missing === fallback)
        #expect(unresolved === fallback)
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
}
