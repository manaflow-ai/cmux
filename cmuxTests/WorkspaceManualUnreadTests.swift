import XCTest
import AppKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class WorkspaceManualUnreadTests: XCTestCase {
    func testShouldClearManualUnreadWhenFocusMovesToDifferentPanel() {
        let previousFocusedPanelId = UUID()
        let nextFocusedPanelId = UUID()

        XCTAssertTrue(
            Workspace.shouldClearManualUnread(
                previousFocusedPanelId: previousFocusedPanelId,
                nextFocusedPanelId: nextFocusedPanelId,
                isManuallyUnread: true,
                markedAt: Date()
            )
        )
    }

    func testShouldNotClearManualUnreadWhenFocusStaysOnSamePanelWithinGrace() {
        let panelId = UUID()
        let now = Date()

        XCTAssertFalse(
            Workspace.shouldClearManualUnread(
                previousFocusedPanelId: panelId,
                nextFocusedPanelId: panelId,
                isManuallyUnread: true,
                markedAt: now.addingTimeInterval(-0.05),
                now: now,
                sameTabGraceInterval: 0.2
            )
        )
    }

    func testShouldClearManualUnreadWhenFocusStaysOnSamePanelAfterGrace() {
        let panelId = UUID()
        let now = Date()

        XCTAssertTrue(
            Workspace.shouldClearManualUnread(
                previousFocusedPanelId: panelId,
                nextFocusedPanelId: panelId,
                isManuallyUnread: true,
                markedAt: now.addingTimeInterval(-0.25),
                now: now,
                sameTabGraceInterval: 0.2
            )
        )
    }

    func testShouldNotClearManualUnreadWhenNotManuallyUnread() {
        XCTAssertFalse(
            Workspace.shouldClearManualUnread(
                previousFocusedPanelId: UUID(),
                nextFocusedPanelId: UUID(),
                isManuallyUnread: false,
                markedAt: Date()
            )
        )
    }

    func testShouldNotClearManualUnreadWhenNoPreviousFocusAndWithinGrace() {
        let now = Date()

        XCTAssertFalse(
            Workspace.shouldClearManualUnread(
                previousFocusedPanelId: nil,
                nextFocusedPanelId: UUID(),
                isManuallyUnread: true,
                markedAt: now.addingTimeInterval(-0.05),
                now: now,
                sameTabGraceInterval: 0.2
            )
        )
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

    func testShouldHideUnreadIndicatorWhenNeitherNotificationNorManualUnreadExists() {
        XCTAssertFalse(
            Workspace.shouldShowUnreadIndicator(
                hasUnreadNotification: false,
                isManuallyUnread: false
            )
        )
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

    func testSurfaceDetailOutranksWorkspaceDetailForPathToken() {
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
