import XCTest
import AppKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class WorkspaceManualUnreadTests: XCTestCase {
    override func tearDown() {
        TerminalNotificationStore.shared.replaceNotificationsForTesting([])
        super.tearDown()
    }

    func testMarkWorkspaceUnreadCreatesUnreadStateForReadWorkspaceWithoutRetainedNotification() {
        let store = TerminalNotificationStore.shared
        let workspaceId = UUID()

        store.replaceNotificationsForTesting([])

        XCTAssertEqual(store.unreadCount(forTabId: workspaceId), 0)
        XCTAssertTrue(store.canMarkWorkspaceUnread(forTabIds: [workspaceId]))
        XCTAssertFalse(store.canMarkWorkspaceRead(forTabIds: [workspaceId]))

        store.markUnread(forTabId: workspaceId)

        XCTAssertGreaterThan(store.unreadCount(forTabId: workspaceId), 0)
        XCTAssertTrue(store.canMarkWorkspaceRead(forTabIds: [workspaceId]))
        XCTAssertFalse(store.canMarkWorkspaceUnread(forTabIds: [workspaceId]))

        store.markRead(forTabId: workspaceId, surfaceId: UUID())

        XCTAssertEqual(store.unreadCount(forTabId: workspaceId), 1)
        XCTAssertTrue(store.canMarkWorkspaceRead(forTabIds: [workspaceId]))
        XCTAssertFalse(store.canMarkWorkspaceUnread(forTabIds: [workspaceId]))

        store.markRead(forTabId: workspaceId)

        XCTAssertEqual(store.unreadCount(forTabId: workspaceId), 0)
        XCTAssertTrue(store.canMarkWorkspaceUnread(forTabIds: [workspaceId]))
        XCTAssertFalse(store.canMarkWorkspaceRead(forTabIds: [workspaceId]))

        store.markUnread(forTabId: workspaceId)

        XCTAssertGreaterThan(store.unreadCount(forTabId: workspaceId), 0)
        XCTAssertTrue(store.canMarkWorkspaceRead(forTabIds: [workspaceId]))
        XCTAssertFalse(store.canMarkWorkspaceUnread(forTabIds: [workspaceId]))

        store.markRead(forTabId: workspaceId)

        XCTAssertEqual(store.unreadCount(forTabId: workspaceId), 0)
        XCTAssertTrue(store.canMarkWorkspaceUnread(forTabIds: [workspaceId]))
        XCTAssertFalse(store.canMarkWorkspaceRead(forTabIds: [workspaceId]))
    }

    func testSurfaceMarkReadDoesNotClearManualWorkspaceUnread() {
        let store = TerminalNotificationStore.shared
        let workspaceId = UUID()

        store.replaceNotificationsForTesting([])
        store.markUnread(forTabId: workspaceId)

        XCTAssertEqual(store.unreadCount(forTabId: workspaceId), 1)

        store.markRead(forTabId: workspaceId, surfaceId: UUID())

        XCTAssertEqual(store.unreadCount(forTabId: workspaceId), 1)
    }

    func testManualWorkspaceUnreadClearsOnDirectTerminalInteraction() {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = TabManager()
        let store = TerminalNotificationStore.shared

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore

        store.replaceNotificationsForTesting([])
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store

        defer {
            store.replaceNotificationsForTesting([])
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
        }

        guard let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace with focused panel")
            return
        }

        store.markUnread(forTabId: workspace.id)

        XCTAssertEqual(store.unreadCount(forTabId: workspace.id), 1)
        XCTAssertTrue(manager.dismissNotificationOnTerminalInteraction(tabId: workspace.id, surfaceId: panelId))
        XCTAssertEqual(store.unreadCount(forTabId: workspace.id), 0)
    }

    func testManualWorkspaceUnreadSurvivesNonTerminalDirectInteraction() {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = TabManager()
        let store = TerminalNotificationStore.shared

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore

        store.replaceNotificationsForTesting([])
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store

        defer {
            store.replaceNotificationsForTesting([])
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
        }

        guard let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace with focused panel")
            return
        }

        store.markUnread(forTabId: workspace.id)

        XCTAssertFalse(manager.dismissNotificationOnDirectInteraction(tabId: workspace.id, surfaceId: panelId))
        XCTAssertEqual(store.unreadCount(forTabId: workspace.id), 1)
    }

    func testMarkLatestNotificationAsOldestUnreadDefersCurrentNotificationBehindUnreadQueue() {
        let store = TerminalNotificationStore.shared
        let currentWorkspaceId = UUID()
        let currentSurfaceId = UUID()
        let nextWorkspaceId = UUID()
        let oldestWorkspaceId = UUID()
        let currentNotificationId = UUID()
        let nextNotificationId = UUID()
        let oldestNotificationId = UUID()
        let now = Date()

        store.replaceNotificationsForTesting([
            TerminalNotification(
                id: currentNotificationId,
                tabId: currentWorkspaceId,
                surfaceId: currentSurfaceId,
                title: "Current",
                subtitle: "",
                body: "",
                createdAt: now,
                isRead: true
            ),
            TerminalNotification(
                id: nextNotificationId,
                tabId: nextWorkspaceId,
                surfaceId: nil,
                title: "Next",
                subtitle: "",
                body: "",
                createdAt: now.addingTimeInterval(-1),
                isRead: false
            ),
            TerminalNotification(
                id: oldestNotificationId,
                tabId: oldestWorkspaceId,
                surfaceId: nil,
                title: "Oldest",
                subtitle: "",
                body: "",
                createdAt: now.addingTimeInterval(-2),
                isRead: false
            ),
        ])

        XCTAssertEqual(
            store.markLatestNotificationAsOldestUnread(forTabId: currentWorkspaceId, surfaceId: currentSurfaceId),
            currentNotificationId
        )
        XCTAssertEqual(
            store.notifications.map(\.id),
            [nextNotificationId, oldestNotificationId, currentNotificationId]
        )
        XCTAssertFalse(store.notifications.last?.isRead ?? true)
    }

    func testMarkLatestNotificationAsOldestUnreadFallsBackToManualUnreadWhenNoNotificationExists() {
        let store = TerminalNotificationStore.shared
        let workspaceId = UUID()

        store.replaceNotificationsForTesting([])

        XCTAssertNil(store.markLatestNotificationAsOldestUnread(forTabId: workspaceId, surfaceId: UUID()))
        XCTAssertEqual(store.unreadCount(forTabId: workspaceId), 1)
    }

    func testMarkLatestNotificationAsOldestUnreadAppendsWhenNoOtherUnreadNotificationsRemain() {
        let store = TerminalNotificationStore.shared
        let currentWorkspaceId = UUID()
        let currentNotificationId = UUID()
        let readWorkspaceId = UUID()
        let readNotificationId = UUID()
        let now = Date()

        store.replaceNotificationsForTesting([
            TerminalNotification(
                id: currentNotificationId,
                tabId: currentWorkspaceId,
                surfaceId: nil,
                title: "Current",
                subtitle: "",
                body: "",
                createdAt: now,
                isRead: true
            ),
            TerminalNotification(
                id: readNotificationId,
                tabId: readWorkspaceId,
                surfaceId: nil,
                title: "Read",
                subtitle: "",
                body: "",
                createdAt: now.addingTimeInterval(-1),
                isRead: true
            ),
        ])

        XCTAssertEqual(
            store.markLatestNotificationAsOldestUnread(forTabId: currentWorkspaceId, surfaceId: nil),
            currentNotificationId
        )
        XCTAssertEqual(store.notifications.map(\.id), [readNotificationId, currentNotificationId])
        XCTAssertFalse(store.notifications.last?.isRead ?? true)
    }

    func testManualPanelUnreadClearsOnDirectTerminalInteraction() {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = TabManager()
        let store = TerminalNotificationStore.shared

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore

        store.replaceNotificationsForTesting([])
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store

        defer {
            store.replaceNotificationsForTesting([])
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
        }

        guard let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace with focused panel")
            return
        }

        workspace.markPanelUnread(panelId)

        XCTAssertTrue(workspace.manualUnreadPanelIds.contains(panelId))
        XCTAssertTrue(manager.dismissNotificationOnTerminalInteraction(tabId: workspace.id, surfaceId: panelId))
        XCTAssertFalse(workspace.manualUnreadPanelIds.contains(panelId))
    }

    func testManualPanelUnreadSurvivesNonTerminalDirectInteraction() {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = TabManager()
        let store = TerminalNotificationStore.shared

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore

        store.replaceNotificationsForTesting([])
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store

        defer {
            store.replaceNotificationsForTesting([])
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
        }

        guard let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace with focused panel")
            return
        }

        workspace.markPanelUnread(panelId)

        XCTAssertFalse(manager.dismissNotificationOnDirectInteraction(tabId: workspace.id, surfaceId: panelId))
        XCTAssertTrue(workspace.manualUnreadPanelIds.contains(panelId))
    }

    func testManualPanelUnreadSurvivesFocusNavigation() {
        let workspace = Workspace()
        guard let initialPanelId = workspace.focusedPanelId,
              let splitPanel = workspace.newTerminalSplit(from: initialPanelId, orientation: .horizontal, focus: false) else {
            XCTFail("Expected workspace with a split panel")
            return
        }

        workspace.focusPanel(initialPanelId)
        workspace.markPanelUnread(splitPanel.id)
        workspace.focusPanel(splitPanel.id)

        XCTAssertTrue(workspace.manualUnreadPanelIds.contains(splitPanel.id))
    }

    func testShouldShowUnreadIndicatorWhenNotificationIsUnread() {
        XCTAssertTrue(
            Workspace.shouldShowUnreadIndicator(
                hasUnreadNotification: true,
                isManuallyUnread: false
            )
        )
    }

    func testShouldShowUnreadIndicatorWhenManualUnreadIsSet() {
        XCTAssertTrue(
            Workspace.shouldShowUnreadIndicator(
                hasUnreadNotification: false,
                isManuallyUnread: true
            )
        )
    }

    func testShouldShowUnreadIndicatorWhenWorkspaceManualUnreadTargetsRepresentativePanel() {
        XCTAssertTrue(
            Workspace.shouldShowUnreadIndicator(
                hasUnreadNotification: false,
                isManuallyUnread: false,
                isWorkspaceManuallyUnread: true,
                isWorkspaceManualUnreadRepresentative: true
            )
        )
    }

    func testShouldHideWorkspaceManualUnreadIndicatorOnNonRepresentativePanel() {
        XCTAssertFalse(
            Workspace.shouldShowUnreadIndicator(
                hasUnreadNotification: false,
                isManuallyUnread: false,
                isWorkspaceManuallyUnread: true,
                isWorkspaceManualUnreadRepresentative: false
            )
        )
    }

    func testShouldHideUnreadIndicatorWhenNeitherNotificationNorManualUnreadExists() {
        XCTAssertFalse(
            Workspace.shouldShowUnreadIndicator(
                hasUnreadNotification: false,
                isManuallyUnread: false
            )
        )
    }

    func testWorkspaceManualUnreadRepresentativeTracksFocusedPanel() {
        let workspace = Workspace()
        guard let initialPanelId = workspace.focusedPanelId,
              let splitPanel = workspace.newTerminalSplit(from: initialPanelId, orientation: .horizontal, focus: false) else {
            XCTFail("Expected workspace with a split panel")
            return
        }

        XCTAssertEqual(workspace.representativePanelIdForWorkspaceManualUnread(), initialPanelId)

        workspace.focusPanel(splitPanel.id)

        XCTAssertEqual(workspace.representativePanelIdForWorkspaceManualUnread(), splitPanel.id)
    }

    func testWorkspaceManualUnreadBadgeMovesWhenFocusChanges() {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let store = TerminalNotificationStore.shared
        let originalNotificationStore = appDelegate.notificationStore

        store.replaceNotificationsForTesting([])
        appDelegate.notificationStore = store

        defer {
            store.replaceNotificationsForTesting([])
            appDelegate.notificationStore = originalNotificationStore
        }

        let workspace = Workspace()
        guard let initialPanelId = workspace.focusedPanelId,
              let splitPanel = workspace.newTerminalSplit(from: initialPanelId, orientation: .horizontal, focus: false),
              let initialTabId = workspace.surfaceIdFromPanelId(initialPanelId),
              let splitTabId = workspace.surfaceIdFromPanelId(splitPanel.id) else {
            XCTFail("Expected workspace with a split panel")
            return
        }

        store.markUnread(forTabId: workspace.id)
        workspace.focusPanel(initialPanelId)

        XCTAssertTrue(workspace.bonsplitController.tab(initialTabId)?.showsNotificationBadge ?? false)
        XCTAssertFalse(workspace.bonsplitController.tab(splitTabId)?.showsNotificationBadge ?? true)

        workspace.focusPanel(splitPanel.id)

        XCTAssertFalse(workspace.bonsplitController.tab(initialTabId)?.showsNotificationBadge ?? true)
        XCTAssertTrue(workspace.bonsplitController.tab(splitTabId)?.showsNotificationBadge ?? false)
    }
}

final class CommandPaletteFuzzyMatcherTests: XCTestCase {
    func testExactMatchScoresHigherThanPrefixAndContains() {
        let exact = CommandPaletteFuzzyMatcher.score(query: "rename tab", candidate: "rename tab")
        let prefix = CommandPaletteFuzzyMatcher.score(query: "rename tab", candidate: "rename tab now")
        let contains = CommandPaletteFuzzyMatcher.score(query: "rename tab", candidate: "command rename tab flow")

        XCTAssertNotNil(exact)
        XCTAssertNotNil(prefix)
        XCTAssertNotNil(contains)
        XCTAssertGreaterThan(exact ?? 0, prefix ?? 0)
        XCTAssertGreaterThan(prefix ?? 0, contains ?? 0)
    }

    func testInitialismMatchReturnsScore() {
        let score = CommandPaletteFuzzyMatcher.score(query: "ocdi", candidate: "open current directory in ide")
        XCTAssertNotNil(score)
        XCTAssertGreaterThan(score ?? 0, 0)
    }

    func testLongTokenLooseSubsequenceDoesNotMatch() {
        let score = CommandPaletteFuzzyMatcher.score(query: "rename", candidate: "open current directory in ide")
        XCTAssertNil(score)
    }

    func testStitchedWordPrefixMatchesRetabForRenameTab() {
        let score = CommandPaletteFuzzyMatcher.score(query: "retab", candidate: "Rename Tab…")
        XCTAssertNotNil(score)
        XCTAssertGreaterThan(score ?? 0, 0)
    }

    func testRetabPrefersRenameTabOverDistantTabWord() {
        let renameTabScore = CommandPaletteFuzzyMatcher.score(query: "retab", candidate: "Rename Tab…")
        let reopenTabScore = CommandPaletteFuzzyMatcher.score(query: "retab", candidate: "Reopen Closed Browser Tab")

        XCTAssertNotNil(renameTabScore)
        XCTAssertNotNil(reopenTabScore)
        XCTAssertGreaterThan(renameTabScore ?? 0, reopenTabScore ?? 0)
    }

    func testRenameScoresHigherThanUnrelatedCommand() {
        let renameScore = CommandPaletteFuzzyMatcher.score(
            query: "rename",
            candidates: ["Rename Tab…", "Tab • Terminal 1", "rename", "tab", "title"]
        )
        let unrelatedScore = CommandPaletteFuzzyMatcher.score(
            query: "rename",
            candidates: [
                "Open Current Directory in IDE",
                "Terminal • Terminal 1",
                "terminal",
                "directory",
                "open",
                "ide",
                "code",
                "default app"
            ]
        )

        XCTAssertNotNil(renameScore)
        XCTAssertNotNil(unrelatedScore)
        XCTAssertGreaterThan(renameScore ?? 0, unrelatedScore ?? 0)
    }

    func testTokenMatchingRequiresAllTokens() {
        let match = CommandPaletteFuzzyMatcher.score(
            query: "rename workspace",
            candidates: ["Rename Workspace", "Workspace settings"]
        )
        let miss = CommandPaletteFuzzyMatcher.score(
            query: "rename workspace",
            candidates: ["Rename Tab", "Tab settings"]
        )

        XCTAssertNotNil(match)
        XCTAssertNil(miss)
    }

    func testEmptyQueryReturnsZeroScore() {
        let score = CommandPaletteFuzzyMatcher.score(query: "   ", candidate: "anything")
        XCTAssertEqual(score, 0)
    }

    func testMatchCharacterIndicesForContainsMatch() {
        let indices = CommandPaletteFuzzyMatcher.matchCharacterIndices(
            query: "workspace",
            candidate: "New Workspace"
        )
        XCTAssertTrue(indices.contains(4))
        XCTAssertTrue(indices.contains(12))
        XCTAssertFalse(indices.contains(0))
    }

    func testMatchCharacterIndicesForSubsequenceMatch() {
        let indices = CommandPaletteFuzzyMatcher.matchCharacterIndices(
            query: "nws",
            candidate: "New Workspace"
        )
        XCTAssertTrue(indices.contains(0))
        XCTAssertTrue(indices.contains(2))
        XCTAssertTrue(indices.contains(8))
    }

    func testMatchCharacterIndicesForStitchedWordPrefixMatch() {
        let indices = CommandPaletteFuzzyMatcher.matchCharacterIndices(
            query: "retab",
            candidate: "Rename Tab…"
        )
        XCTAssertTrue(indices.contains(0))
        XCTAssertTrue(indices.contains(1))
        XCTAssertTrue(indices.contains(7))
        XCTAssertTrue(indices.contains(8))
        XCTAssertTrue(indices.contains(9))
    }
}

final class CommandPaletteSwitcherSearchIndexerTests: XCTestCase {
    func testKeywordsIncludeDirectoryBranchAndPortMetadata() {
        let metadata = CommandPaletteSwitcherSearchMetadata(
            directories: ["/Users/example/dev/cmuxterm-hq/worktrees/feat-cmd-palette"],
            branches: ["feature/cmd-palette-indexing"],
            ports: [3000, 9222]
        )

        let keywords = CommandPaletteSwitcherSearchIndexer.keywords(
            baseKeywords: ["workspace", "switch"],
            metadata: metadata
        )

        XCTAssertTrue(keywords.contains("/Users/example/dev/cmuxterm-hq/worktrees/feat-cmd-palette"))
        XCTAssertTrue(keywords.contains("feat-cmd-palette"))
        XCTAssertTrue(keywords.contains("feature/cmd-palette-indexing"))
        XCTAssertTrue(keywords.contains("cmd-palette-indexing"))
        XCTAssertTrue(keywords.contains("3000"))
        XCTAssertTrue(keywords.contains(":9222"))
    }

    func testFuzzyMatcherMatchesDirectoryBranchAndPortMetadata() {
        let metadata = CommandPaletteSwitcherSearchMetadata(
            directories: ["/tmp/cmuxterm/worktrees/issue-123-switcher-search"],
            branches: ["fix/switcher-metadata"],
            ports: [4317]
        )

        let candidates = CommandPaletteSwitcherSearchIndexer.keywords(
            baseKeywords: ["workspace"],
            metadata: metadata
        )

        XCTAssertNotNil(CommandPaletteFuzzyMatcher.score(query: "switcher-search", candidates: candidates))
        XCTAssertNotNil(CommandPaletteFuzzyMatcher.score(query: "switcher-metadata", candidates: candidates))
        XCTAssertNotNil(CommandPaletteFuzzyMatcher.score(query: "4317", candidates: candidates))
    }

    func testWorkspaceDetailOmitsSplitDirectoryAndBranchTokens() {
        let metadata = CommandPaletteSwitcherSearchMetadata(
            directories: ["/Users/example/dev/cmuxterm-hq/worktrees/feat-cmd-palette"],
            branches: ["feature/cmd-palette-indexing"],
            ports: [3000]
        )

        let keywords = CommandPaletteSwitcherSearchIndexer.keywords(
            baseKeywords: ["workspace"],
            metadata: metadata,
            detail: .workspace
        )

        XCTAssertTrue(keywords.contains("/Users/example/dev/cmuxterm-hq/worktrees/feat-cmd-palette"))
        XCTAssertTrue(keywords.contains("feature/cmd-palette-indexing"))
        XCTAssertTrue(keywords.contains("3000"))
        XCTAssertFalse(keywords.contains("feat-cmd-palette"))
        XCTAssertFalse(keywords.contains("cmd-palette-indexing"))
    }

    func testSurfaceDetailOutranksWorkspaceDetailForPathToken() throws {
        let metadata = CommandPaletteSwitcherSearchMetadata(
            directories: ["/tmp/worktrees/cmux"],
            branches: ["feature/cmd-palette"],
            ports: []
        )

        let workspaceKeywords = CommandPaletteSwitcherSearchIndexer.keywords(
            baseKeywords: ["workspace"],
            metadata: metadata,
            detail: .workspace
        )
        let surfaceKeywords = CommandPaletteSwitcherSearchIndexer.keywords(
            baseKeywords: ["surface"],
            metadata: metadata,
            detail: .surface
        )

        let workspaceScore = try XCTUnwrap(
            CommandPaletteFuzzyMatcher.score(query: "cmux", candidates: workspaceKeywords)
        )
        let surfaceScore = try XCTUnwrap(
            CommandPaletteFuzzyMatcher.score(query: "cmux", candidates: surfaceKeywords)
        )

        XCTAssertGreaterThan(
            surfaceScore,
            workspaceScore,
            "Surface rows should rank ahead of workspace rows for directory-token matches."
        )
    }
}

@MainActor
final class CommandPaletteRequestRoutingTests: XCTestCase {
    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
    }

    func testRequestedWindowTargetsOnlyMatchingObservedWindow() {
        let windowA = makeWindow()
        let windowB = makeWindow()

        XCTAssertTrue(
            ContentView.shouldHandleCommandPaletteRequest(
                observedWindow: windowA,
                requestedWindow: windowA,
                keyWindow: windowA,
                mainWindow: windowA
            )
        )
        XCTAssertFalse(
            ContentView.shouldHandleCommandPaletteRequest(
                observedWindow: windowB,
                requestedWindow: windowA,
                keyWindow: windowA,
                mainWindow: windowA
            )
        )
    }

    func testNilRequestedWindowFallsBackToKeyWindow() {
        let key = makeWindow()
        let other = makeWindow()

        XCTAssertTrue(
            ContentView.shouldHandleCommandPaletteRequest(
                observedWindow: key,
                requestedWindow: nil,
                keyWindow: key,
                mainWindow: nil
            )
        )
        XCTAssertFalse(
            ContentView.shouldHandleCommandPaletteRequest(
                observedWindow: other,
                requestedWindow: nil,
                keyWindow: key,
                mainWindow: nil
            )
        )
    }

    func testNilRequestedAndKeyFallsBackToMainWindow() {
        let main = makeWindow()
        let other = makeWindow()

        XCTAssertTrue(
            ContentView.shouldHandleCommandPaletteRequest(
                observedWindow: main,
                requestedWindow: nil,
                keyWindow: nil,
                mainWindow: main
            )
        )
        XCTAssertFalse(
            ContentView.shouldHandleCommandPaletteRequest(
                observedWindow: other,
                requestedWindow: nil,
                keyWindow: nil,
                mainWindow: main
            )
        )
    }

    func testNoObservedWindowNeverHandlesRequest() {
        XCTAssertFalse(
            ContentView.shouldHandleCommandPaletteRequest(
                observedWindow: nil,
                requestedWindow: makeWindow(),
                keyWindow: makeWindow(),
                mainWindow: makeWindow()
            )
        )
    }
}

final class CommandPaletteBackNavigationTests: XCTestCase {
    func testBackspaceOnEmptyRenameInputReturnsToCommandList() {
        XCTAssertTrue(
            ContentView.commandPaletteShouldPopRenameInputOnDelete(
                renameDraft: "",
                modifiers: []
            )
        )
    }

    func testBackspaceWithRenameTextDoesNotReturnToCommandList() {
        XCTAssertFalse(
            ContentView.commandPaletteShouldPopRenameInputOnDelete(
                renameDraft: "Terminal 1",
                modifiers: []
            )
        )
    }

    func testModifiedBackspaceDoesNotReturnToCommandList() {
        XCTAssertFalse(
            ContentView.commandPaletteShouldPopRenameInputOnDelete(
                renameDraft: "",
                modifiers: [.control]
            )
        )
        XCTAssertFalse(
            ContentView.commandPaletteShouldPopRenameInputOnDelete(
                renameDraft: "",
                modifiers: [.command]
            )
        )
    }
}
