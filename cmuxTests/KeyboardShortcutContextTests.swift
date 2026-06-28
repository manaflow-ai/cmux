import XCTest
import CmuxSettings
@testable import CmuxSettingsUI

#if canImport(cmux_DEV)
@testable import cmux_DEV
// The app target still declares legacy duplicates of these CmuxSettings
// value types; with CmuxSettings imported unconditionally the names are
// ambiguous. These tests exercise the app-side paths, so pin the app types.
private typealias StoredShortcut = cmux_DEV.StoredShortcut
#elseif canImport(cmux)
@testable import cmux
private typealias StoredShortcut = cmux.StoredShortcut
#endif

// Line ~253 compares CmuxSettings.ShortcutAction.defaultStroke, so the
// package stroke is the intended type here (unlike StoredShortcut above).
private typealias ShortcutStroke = CmuxSettings.ShortcutStroke

final class KeyboardShortcutContextTests: XCTestCase {
    func testRenameTabAndBrowserReloadCanShareDefaultChordAcrossContexts() {
        let renameTabShortcut = KeyboardShortcutSettings.Action.renameTab.defaultShortcut

        XCTAssertEqual(renameTabShortcut, KeyboardShortcutSettings.Action.browserReload.defaultShortcut)
        XCTAssertEqual(KeyboardShortcutSettings.Action.renameTab.shortcutContext, .nonBrowserPanel)
        XCTAssertEqual(KeyboardShortcutSettings.Action.browserReload.shortcutContext, .browserPanel)
        XCTAssertFalse(
            KeyboardShortcutSettings.Action.renameTab.conflicts(
                with: KeyboardShortcutSettings.Action.browserReload.defaultShortcut,
                proposedAction: .browserReload,
                configuredShortcut: renameTabShortcut
            )
        )
        XCTAssertFalse(
            KeyboardShortcutSettings.Action.browserReload.conflicts(
                with: renameTabShortcut,
                proposedAction: .renameTab,
                configuredShortcut: KeyboardShortcutSettings.Action.browserReload.defaultShortcut
            )
        )
        XCTAssertTrue(
            KeyboardShortcutSettings.Action.renameTab.conflicts(
                with: renameTabShortcut,
                proposedAction: .renameWorkspace,
                configuredShortcut: renameTabShortcut
            )
        )
    }

    func testRenameTabCanReassignCommandRAfterUnbindingWithoutBrowserReloadConflict() throws {
        let originalSettingsFileStore = KeyboardShortcutSettings.settingsFileStore
        let directoryURL = try makeTemporaryDirectory()
        defer {
            KeyboardShortcutSettings.resetAll()
            KeyboardShortcutSettings.settingsFileStore = originalSettingsFileStore
            try? FileManager.default.removeItem(at: directoryURL)
        }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try writeSettingsFile("{}", to: settingsFileURL)
        KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            startWatching: false
        )
        KeyboardShortcutSettings.resetAll()

        let commandR = StoredShortcut(key: "r", command: true, shift: false, option: false, control: false)
        XCTAssertEqual(commandR, KeyboardShortcutSettings.Action.renameTab.defaultShortcut)
        XCTAssertEqual(commandR, KeyboardShortcutSettings.Action.browserReload.defaultShortcut)

        KeyboardShortcutSettings.setShortcut(commandR, for: .renameTab)
        KeyboardShortcutSettings.clearShortcut(for: .renameTab)

        XCTAssertEqual(KeyboardShortcutSettings.shortcut(for: .renameTab), .unbound)
        XCTAssertEqual(KeyboardShortcutSettings.shortcut(for: .browserReload), commandR)
        XCTAssertEqual(
            KeyboardShortcutSettings.Action.renameTab.normalizedRecordedShortcutResult(commandR),
            .accepted(commandR)
        )

        KeyboardShortcutSettings.setShortcut(commandR, for: .renameTab)

        XCTAssertEqual(KeyboardShortcutSettings.shortcut(for: .renameTab), commandR)
        XCTAssertEqual(KeyboardShortcutSettings.shortcut(for: .browserReload), commandR)
    }

    func testSwapPathIgnoresNonOverlappingShortcutContexts() throws {
        let originalSettingsFileStore = KeyboardShortcutSettings.settingsFileStore
        let directoryURL = try makeTemporaryDirectory()
        defer {
            KeyboardShortcutSettings.resetAll()
            KeyboardShortcutSettings.settingsFileStore = originalSettingsFileStore
            try? FileManager.default.removeItem(at: directoryURL)
        }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try writeSettingsFile("{}", to: settingsFileURL)
        KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            startWatching: false
        )
        KeyboardShortcutSettings.resetAll()

        let commandR = KeyboardShortcutSettings.Action.renameTab.defaultShortcut
        KeyboardShortcutSettings.clearShortcut(for: .renameTab)

        KeyboardShortcutSettings.swapShortcutConflict(
            proposedShortcut: commandR,
            currentAction: .renameTab,
            conflictingAction: .browserReload,
            previousShortcut: .unbound
        )

        XCTAssertEqual(KeyboardShortcutSettings.shortcut(for: .renameTab), .unbound)
        XCTAssertEqual(KeyboardShortcutSettings.shortcut(for: .browserReload), commandR)
        XCTAssertNil(
            ShortcutRecorderValidationPresentation(
                attempt: ShortcutRecorderRejectedAttempt(
                    reason: .conflictsWithAction(.browserReload),
                    proposedShortcut: commandR
                ),
                action: .renameTab,
                currentShortcut: .unbound,
                shortcutForAction: { $0.defaultShortcut }
            )
        )
    }

    func testRenameWorkspaceIsScopedOutsideBrowserPanels() {
        XCTAssertEqual(KeyboardShortcutSettings.Action.renameWorkspace.shortcutContext, .nonBrowserPanel)
    }

    func testRightSidebarContextIsOnlyAvailableWhenRightSidebarHasFocus() {
        let context = KeyboardShortcutSettings.Action.switchRightSidebarToFiles.shortcutContext

        XCTAssertEqual(context, .rightSidebarFocus)
        XCTAssertFalse(context.isAvailable(focusedBrowserPanel: false, focusedMarkdownPanel: false, rightSidebarFocused: false))
        XCTAssertTrue(context.isAvailable(focusedBrowserPanel: false, focusedMarkdownPanel: false, rightSidebarFocused: true))
        XCTAssertFalse(
            KeyboardShortcutSettings.Action.renameTab.shortcutContext
                .isAvailable(focusedBrowserPanel: false, focusedMarkdownPanel: false, rightSidebarFocused: true)
        )
        XCTAssertTrue(context.overlaps(KeyboardShortcutSettings.Action.commandPalette.shortcutContext))
        XCTAssertFalse(context.overlaps(KeyboardShortcutSettings.Action.renameTab.shortcutContext))
    }

    func testReactGrabStaysApplicationScopedForTerminalPastebackRouting() {
        XCTAssertEqual(KeyboardShortcutSettings.Action.toggleReactGrab.shortcutContext, .application)
    }

    func testBrowserFocusModeToggleIsBrowserScopedAndDoesNotCollideWithSplitZoom() {
        let focusMode = KeyboardShortcutSettings.Action.toggleBrowserFocusMode

        // Scoped to browser panels so it only claims the key when a browser is focused.
        XCTAssertEqual(focusMode.shortcutContext, .browserPanel)

        // Default is Option+Cmd+Return: a modifier tier web pages rarely bind,
        // distinct from the other Return-based shortcut (Cmd+Shift+Return = toggle
        // split zoom), and clear of the Ctrl+Cmd+Return some screen recorders use.
        let focusModeShortcut = focusMode.defaultShortcut
        XCTAssertEqual(
            focusModeShortcut,
            StoredShortcut(key: "\r", command: true, shift: false, option: true, control: false)
        )
        XCTAssertNotEqual(
            focusModeShortcut,
            KeyboardShortcutSettings.Action.toggleSplitZoom.defaultShortcut
        )
        XCTAssertFalse(
            focusMode.conflicts(
                with: KeyboardShortcutSettings.Action.toggleSplitZoom.defaultShortcut,
                proposedAction: .toggleSplitZoom,
                configuredShortcut: focusModeShortcut
            )
        )
    }

    func testMarkdownZoomIsScopedToFocusedMarkdownPanelAndDoesNotCollideWithBrowserZoom() {
        for action in [
            KeyboardShortcutSettings.Action.markdownZoomIn,
            .markdownZoomOut,
            .markdownZoomReset,
        ] {
            XCTAssertEqual(action.shortcutContext, .markdownPanel)
        }

        let markdown = KeyboardShortcutSettings.Action.markdownZoomIn.shortcutContext
        XCTAssertTrue(markdown.isAvailable(focusedBrowserPanel: false, focusedMarkdownPanel: true, rightSidebarFocused: false))
        XCTAssertFalse(markdown.isAvailable(focusedBrowserPanel: false, focusedMarkdownPanel: false, rightSidebarFocused: false))
        XCTAssertFalse(markdown.isAvailable(focusedBrowserPanel: true, focusedMarkdownPanel: false, rightSidebarFocused: false))

        // Markdown zoom and browser zoom share Cmd-=/-/0 but are mutually
        // exclusive (a panel can't be both), so they must NOT be treated as
        // conflicting bindings.
        let browser = KeyboardShortcutSettings.Action.browserZoomIn.shortcutContext
        XCTAssertFalse(markdown.overlaps(browser))
        XCTAssertTrue(markdown.overlaps(markdown))

        // A focused markdown viewer is also a non-browser panel, so those two
        // contexts CAN be active together and must be treated as overlapping.
        let nonBrowser = KeyboardShortcutSettings.Action.renameTab.shortcutContext
        XCTAssertEqual(nonBrowser, .nonBrowserPanel)
        XCTAssertTrue(markdown.overlaps(nonBrowser))
        XCTAssertTrue(nonBrowser.overlaps(markdown))
    }

    func testSurfaceDigitFamilyCoexistsWithPrioritizedSidebarModeShortcuts() {
        let surfaceDigits = KeyboardShortcutSettings.Action.selectSurfaceByNumber.defaultShortcut
        let sidebarFiles = KeyboardShortcutSettings.Action.switchRightSidebarToFiles.defaultShortcut

        // Re-recording the factory default ⌃1 for Select Surface 1…9 must not be
        // rejected against Show Sidebar Files (⌃1): the key router consumes the
        // sidebar-mode shortcuts before general shortcut matching whenever the
        // right sidebar is focused, so the pair is resolved by priority — the
        // sidebar action owns the overlap and the digit family keeps every other
        // context. The shipped defaults rely on exactly this coexistence.
        XCTAssertFalse(
            KeyboardShortcutSettings.Action.switchRightSidebarToFiles.conflicts(
                with: surfaceDigits,
                proposedAction: .selectSurfaceByNumber,
                configuredShortcut: sidebarFiles
            )
        )
        // Symmetric direction: recording the prioritized sidebar action onto a
        // stroke inside the digit family coexists the same way.
        XCTAssertFalse(
            KeyboardShortcutSettings.Action.selectSurfaceByNumber.conflicts(
                with: sidebarFiles,
                proposedAction: .switchRightSidebarToFiles,
                configuredShortcut: surfaceDigits
            )
        )
        // Two sidebar-mode shortcuts on the same stroke remain a real conflict:
        // both live in the same prioritized context, so nothing decides the overlap.
        XCTAssertTrue(
            KeyboardShortcutSettings.Action.switchRightSidebarToFiles.conflicts(
                with: sidebarFiles,
                proposedAction: .switchRightSidebarToFind,
                configuredShortcut: sidebarFiles
            )
        )
    }

    func testNewBrowserWorkspaceSettingsPackageActionStaysAligned() {
        guard let settingsAction = ShortcutAction(
            rawValue: KeyboardShortcutSettings.Action.newBrowserWorkspace.rawValue
        ) else {
            XCTFail("Expected CmuxSettings.ShortcutAction for newBrowserWorkspace")
            return
        }
        XCTAssertEqual(settingsAction.defaultStroke, ShortcutStroke(key: "n", command: true, option: true))
        XCTAssertEqual(settingsAction.displayName, KeyboardShortcutSettings.Action.newBrowserWorkspace.label)
    }

    func testSettingsPackageDefaultWhenClausesMatchRuntimeShortcutContexts() {
        for action in KeyboardShortcutSettings.Action.allCases {
            guard let settingsAction = ShortcutAction(rawValue: action.rawValue) else {
                continue
            }
            XCTAssertEqual(
                settingsAction.defaultFocusWhenClause,
                action.shortcutContext.defaultWhenClause,
                action.rawValue
            )
            XCTAssertEqual(
                settingsAction.hasPriorityShortcutRouting,
                action.hasPriorityShortcutRouting,
                action.rawValue
            )
        }
    }

    // Regression: on European layouts (German QWERTZ, French AZERTY, Nordic, ...)
    // "+" and "-" are dedicated keys typed WITHOUT Shift, so the event reports
    // character "+"/"-" with no Shift flag and a keyCode that is not the US
    // kVK_ANSI_Equal (24) / kVK_ANSI_Minus (27). The Cmd-=/Cmd-- zoom chords must
    // still match from those keys. See https://github.com/manaflow-ai/cmux/pull/5163.
    func testMarkdownZoomMatchesDedicatedPlusMinusKeysOnNonUSLayout() {
        // German QWERTZ: dedicated "+" key sits at the US RightBracket position
        // (keyCode 30) and produces "+" with no Shift; "-" sits at the US Slash
        // position (keyCode 44) and produces "-" with no Shift.
        let zoomIn = KeyboardShortcutSettings.Action.markdownZoomIn.defaultShortcut
        XCTAssertTrue(
            zoomIn.matches(
                keyCode: 30,
                modifierFlags: [.command],
                eventCharacter: "+",
                layoutCharacterProvider: { _, _ in "+" }
            ),
            "Cmd and the dedicated + key should zoom markdown in on non-US layouts"
        )

        let zoomOut = KeyboardShortcutSettings.Action.markdownZoomOut.defaultShortcut
        XCTAssertTrue(
            zoomOut.matches(
                keyCode: 44,
                modifierFlags: [.command],
                eventCharacter: "-",
                layoutCharacterProvider: { _, _ in "-" }
            ),
            "Cmd and the dedicated - key should zoom markdown out on non-US layouts"
        )
    }

    func testBrowserZoomMatchesDedicatedPlusMinusKeysOnNonUSLayout() {
        let zoomIn = KeyboardShortcutSettings.Action.browserZoomIn.defaultShortcut
        XCTAssertTrue(
            zoomIn.matches(
                keyCode: 30,
                modifierFlags: [.command],
                eventCharacter: "+",
                layoutCharacterProvider: { _, _ in "+" }
            ),
            "Cmd and the dedicated + key should zoom the browser in on non-US layouts"
        )

        let zoomOut = KeyboardShortcutSettings.Action.browserZoomOut.defaultShortcut
        XCTAssertTrue(
            zoomOut.matches(
                keyCode: 44,
                modifierFlags: [.command],
                eventCharacter: "-",
                layoutCharacterProvider: { _, _ in "-" }
            ),
            "Cmd and the dedicated - key should zoom the browser out on non-US layouts"
        )
    }

    // The "_" -> "-" normalization was also moved out of the Shift gate, so a
    // bare "_" (no Shift) from a layout where "_" is a dedicated key must match
    // the "-" zoom-out chord. Without this, a future refactor could re-gate "_"
    // behind Shift with no failing test to catch it.
    func testZoomOutMatchesBareUnderscoreOnNonUSLayout() {
        let markdownZoomOut = KeyboardShortcutSettings.Action.markdownZoomOut.defaultShortcut
        XCTAssertTrue(
            markdownZoomOut.matches(
                keyCode: 27,
                modifierFlags: [.command],
                eventCharacter: "_",
                layoutCharacterProvider: { _, _ in "_" }
            ),
            "Cmd and a dedicated _ key should zoom markdown out (\"_\" normalizes to \"-\")"
        )

        let browserZoomOut = KeyboardShortcutSettings.Action.browserZoomOut.defaultShortcut
        XCTAssertTrue(
            browserZoomOut.matches(
                keyCode: 27,
                modifierFlags: [.command],
                eventCharacter: "_",
                layoutCharacterProvider: { _, _ in "_" }
            ),
            "Cmd and a dedicated _ key should zoom the browser out (\"_\" normalizes to \"-\")"
        )
    }

    func testZoomInDoesNotMatchUnrelatedKeyOnNonUSLayout() {
        // Guard: the layout-aware "+" handling must not make Cmd-= match keys that
        // legitimately produce other characters (e.g. a bare letter key).
        let zoomIn = KeyboardShortcutSettings.Action.browserZoomIn.defaultShortcut
        XCTAssertFalse(
            zoomIn.matches(
                keyCode: 45,
                modifierFlags: [.command],
                eventCharacter: "n",
                layoutCharacterProvider: { _, _ in "n" }
            )
        )
    }

    func testFocusHistoryMenuShortcutsSuppressDuplicateBrowserHistoryKeys() throws {
        let originalSettingsFileStore = KeyboardShortcutSettings.settingsFileStore
        let directoryURL = try makeTemporaryDirectory()
        defer {
            KeyboardShortcutSettings.resetAll()
            KeyboardShortcutSettings.settingsFileStore = originalSettingsFileStore
            try? FileManager.default.removeItem(at: directoryURL)
        }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try writeSettingsFile("{}", to: settingsFileURL)
        KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            startWatching: false
        )
        KeyboardShortcutSettings.resetAll()

        let focusBack = KeyboardShortcutSettings.shortcut(for: .focusHistoryBack)
        let focusForward = KeyboardShortcutSettings.shortcut(for: .focusHistoryForward)

        XCTAssertEqual(focusBack, KeyboardShortcutSettings.shortcut(for: .browserBack))
        XCTAssertEqual(focusForward, KeyboardShortcutSettings.shortcut(for: .browserForward))
        XCTAssertEqual(KeyboardShortcutSettings.menuShortcut(for: .focusHistoryBack), focusBack)
        XCTAssertEqual(KeyboardShortcutSettings.menuShortcut(for: .focusHistoryForward), focusForward)
        XCTAssertEqual(KeyboardShortcutSettings.menuShortcut(for: .browserBack), .unbound)
        XCTAssertEqual(KeyboardShortcutSettings.menuShortcut(for: .browserForward), .unbound)

        KeyboardShortcutSettings.clearShortcut(for: .focusHistoryBack)
        KeyboardShortcutSettings.clearShortcut(for: .focusHistoryForward)

        XCTAssertEqual(KeyboardShortcutSettings.menuShortcut(for: .browserBack), KeyboardShortcutSettings.shortcut(for: .browserBack))
        XCTAssertEqual(KeyboardShortcutSettings.menuShortcut(for: .browserForward), KeyboardShortcutSettings.shortcut(for: .browserForward))
    }

    func testEmptyWhenClauseDoesNotSuppressMenuShortcut() throws {
        let originalSettingsFileStore = KeyboardShortcutSettings.settingsFileStore
        let directoryURL = try makeTemporaryDirectory()
        defer {
            KeyboardShortcutSettings.resetAll()
            KeyboardShortcutSettings.settingsFileStore = originalSettingsFileStore
            try? FileManager.default.removeItem(at: directoryURL)
        }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "shortcuts": {
                "when": {
                  "closeTab": "   "
                }
              }
            }
            """,
            to: settingsFileURL
        )
        KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            startWatching: false
        )
        KeyboardShortcutSettings.resetAll()

        let closeTabShortcut = KeyboardShortcutSettings.shortcut(for: .closeTab)

        XCTAssertEqual(KeyboardShortcutSettings.effectiveWhenClause(for: .closeTab), .always)
        XCTAssertEqual(KeyboardShortcutSettings.menuShortcut(for: .closeTab), closeTabShortcut)
    }

    @MainActor
    func testMenuShortcutsStandDownWhilePackageRecorderIsActive() {
        let button = RecorderHostButton(frame: .zero)
        defer {
            if RecorderHostButton.isActivelyRecording {
                button.debugStopRecording()
            }
        }

        XCTAssertFalse(RecorderHostButton.isActivelyRecording)
        XCTAssertEqual(KeyboardShortcutSettings.menuShortcut(for: .closeTab), KeyboardShortcutSettings.shortcut(for: .closeTab))

        button.debugStartRecording()

        XCTAssertTrue(RecorderHostButton.isActivelyRecording)
        XCTAssertEqual(KeyboardShortcutSettings.menuShortcut(for: .closeTab), .unbound)
    }

    func testFocusHistoryTitlebarHintUsesConfiguredShortcutAndCanBeUnbound() throws {
        let originalSettingsFileStore = KeyboardShortcutSettings.settingsFileStore
        let directoryURL = try makeTemporaryDirectory()
        defer {
            KeyboardShortcutSettings.resetAll()
            KeyboardShortcutSettings.settingsFileStore = originalSettingsFileStore
            try? FileManager.default.removeItem(at: directoryURL)
        }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try writeSettingsFile("{}", to: settingsFileURL)
        KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            startWatching: false
        )
        KeyboardShortcutSettings.resetAll()

        let remappedShortcut = StoredShortcut(key: "b", command: true, shift: true, option: false, control: false)
        KeyboardShortcutSettings.setShortcut(remappedShortcut, for: .focusHistoryBack)

        XCTAssertEqual(KeyboardShortcutSettings.shortcut(for: .focusHistoryBack), remappedShortcut)
        XCTAssertTrue(
            KeyboardShortcutSettings.shortcut(for: .focusHistoryBack).titlebarHintShouldShow(
                alwaysShowShortcutHints: false,
                modifierPressed: true
            )
        )
        XCTAssertTrue(KeyboardShortcutSettings.Action.focusHistoryBack.tooltip("Focus Back").contains(ShortcutDisplayFormatter().displayString(remappedShortcut)))

        KeyboardShortcutSettings.clearShortcut(for: .focusHistoryBack)

        XCTAssertEqual(KeyboardShortcutSettings.shortcut(for: .focusHistoryBack), .unbound)
        XCTAssertFalse(
            KeyboardShortcutSettings.shortcut(for: .focusHistoryBack).titlebarHintShouldShow(
                alwaysShowShortcutHints: false,
                modifierPressed: true
            )
        )
    }

    func testShortcutSettingsFilePreservesConfiguredShortcutWithoutGlobalConflictLookup() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "shortcuts": {
                "newWindow": "cmd+n"
              }
            }
            """,
            to: settingsFileURL
        )

        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertEqual(
            store.override(for: .newWindow),
            StoredShortcut(key: "n", command: true, shift: false, option: false, control: false)
        )
    }

    func testShortcutSettingsFilePreservesUnboundShortcutWithoutGlobalConflictLookup() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "shortcuts": {
                "newWindow": "none"
              }
            }
            """,
            to: settingsFileURL
        )

        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertEqual(store.override(for: .newWindow), StoredShortcut.unbound)
    }

    func testSettingsFileWhenClauseLetsWorkspaceDigitsShareSidebarDigitShortcut() throws {
        let originalSettingsFileStore = KeyboardShortcutSettings.settingsFileStore
        let directoryURL = try makeTemporaryDirectory()
        defer {
            KeyboardShortcutSettings.resetAll()
            KeyboardShortcutSettings.settingsFileStore = originalSettingsFileStore
            try? FileManager.default.removeItem(at: directoryURL)
        }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "shortcuts": {
                "bindings": {
                  "selectWorkspaceByNumber": "ctrl+1"
                },
                "when": {
                  "selectWorkspaceByNumber": "!sidebarFocus"
                }
              }
            }
            """,
            to: settingsFileURL
        )
        KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            startWatching: false
        )

        let ctrl1 = StoredShortcut(key: "1", command: false, shift: false, option: false, control: true)
        XCTAssertEqual(KeyboardShortcutSettings.shortcut(for: .selectWorkspaceByNumber), ctrl1)

        let workspaceWhen = KeyboardShortcutSettings.effectiveWhenClause(for: .selectWorkspaceByNumber)
        XCTAssertTrue(workspaceWhen.evaluate(ShortcutFocusState(browser: false, markdown: false, sidebar: false)))
        XCTAssertFalse(workspaceWhen.evaluate(ShortcutFocusState(browser: false, markdown: false, sidebar: true)))
        XCTAssertFalse(
            KeyboardShortcutSettings.Action.selectWorkspaceByNumber.conflicts(
                with: ctrl1,
                proposedAction: .switchRightSidebarToFiles,
                configuredShortcut: ctrl1
            )
        )
        XCTAssertFalse(
            KeyboardShortcutSettings.Action.switchRightSidebarToFiles.conflicts(
                with: ctrl1,
                proposedAction: .selectWorkspaceByNumber,
                configuredShortcut: ctrl1
            )
        )
    }

    func testSettingsFileWhenClauseSupportsContextComparisons() throws {
        let originalSettingsFileStore = KeyboardShortcutSettings.settingsFileStore
        let directoryURL = try makeTemporaryDirectory()
        defer {
            KeyboardShortcutSettings.resetAll()
            KeyboardShortcutSettings.settingsFileStore = originalSettingsFileStore
            try? FileManager.default.removeItem(at: directoryURL)
        }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "shortcuts": {
                "when": {
                  "selectWorkspaceByNumber": "commandPaletteVisible && paneCount > 1",
                  "selectSurfaceByNumber": "sidebarMode == 'find'"
                }
              }
            }
            """,
            to: settingsFileURL
        )
        KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            startWatching: false
        )

        // A boolean key combined with an integer comparison, parsed from cmux.json.
        let workspaceWhen = KeyboardShortcutSettings.effectiveWhenClause(for: .selectWorkspaceByNumber)
        var matching = ShortcutContext()
        matching.setBool("commandPaletteVisible", true)
        matching.setInt("paneCount", 2)
        XCTAssertTrue(workspaceWhen.evaluate(matching))

        var paletteHidden = ShortcutContext()
        paletteHidden.setBool("commandPaletteVisible", false)
        paletteHidden.setInt("paneCount", 2)
        XCTAssertFalse(workspaceWhen.evaluate(paletteHidden))

        var singlePane = ShortcutContext()
        singlePane.setBool("commandPaletteVisible", true)
        singlePane.setInt("paneCount", 1)
        XCTAssertFalse(workspaceWhen.evaluate(singlePane))

        // A string comparison against the sidebar mode.
        let surfaceWhen = KeyboardShortcutSettings.effectiveWhenClause(for: .selectSurfaceByNumber)
        var findMode = ShortcutContext()
        findMode.setString("sidebarMode", "find")
        XCTAssertTrue(surfaceWhen.evaluate(findMode))

        var filesMode = ShortcutContext()
        filesMode.setString("sidebarMode", "files")
        XCTAssertFalse(surfaceWhen.evaluate(filesMode))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-shortcut-context-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeSettingsFile(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
}
