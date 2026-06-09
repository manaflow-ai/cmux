import XCTest
import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

private let appDelegateLastSurfaceCloseShortcutDefaultsKey = "closeWorkspaceOnLastSurfaceShortcut"

private final class FakeWKInspectorContainerView: NSView {}
private final class FocusableTestView: NSView {
    override var acceptsFirstResponder: Bool { true }
}
private final class FakeTextBoxSubmitSurface: TextBoxSubmitSurfaceControlling {
    var clipboardReadGeneration = 0
    var textBoxSubmitObservationWindow: NSWindow?
    var textBoxSubmitTerminalSurface: TerminalSurface? { nil }
    var visibleTextValue: String?
    var sendKeyTextResult = true
    var sendTextResult = true
    var sendNamedKeyResult: TerminalSurface.NamedKeySendResult = .sent
    var performBindingActionResult = true
    private(set) var sentText: [String] = []
    private(set) var sentKeys: [String] = []

    func visibleText() -> String? {
        visibleTextValue
    }

    @discardableResult
    func sendKeyText(_ text: String) -> Bool {
        sentText.append(text)
        return sendKeyTextResult
    }

    @discardableResult
    func sendText(_ text: String) -> Bool {
        sentText.append(text)
        return sendTextResult
    }

    @discardableResult
    func sendNamedKey(_ keyName: String) -> TerminalSurface.NamedKeySendResult {
        sentKeys.append(keyName)
        return sendNamedKeyResult
    }

    @discardableResult
    func performBindingAction(_ action: String) -> Bool {
        sentKeys.append(action)
        return performBindingActionResult
    }

    func completeClipboardRead() {
        clipboardReadGeneration += 1
        NotificationCenter.default.post(
            name: .terminalSurfaceDidCompleteClipboardRead,
            object: self
        )
    }
}
private final class MenuActionProbe: NSObject {
    var callCount = 0
    @objc func perform(_ sender: Any?) {
        callCount += 1
    }
}
private final class GhosttyCommandEquivalentProbeView: GhosttyNSView {
    var afterMenuMissCallCount = 0
    var keyDownCallCount = 0
    var lastKeyDownCharactersIgnoringModifiers: String?
    var pasteCallCount = 0
    var pasteAsPlainTextCallCount = 0
    var performAfterMenuMissResult = true

    override func performKeyEquivalentAfterMenuMiss(with event: NSEvent) -> Bool {
        afterMenuMissCallCount += 1
        return performAfterMenuMissResult
    }

    override func keyDown(with event: NSEvent) {
        keyDownCallCount += 1
        lastKeyDownCharactersIgnoringModifiers = event.charactersIgnoringModifiers
    }

    override func paste(_ sender: Any?) {
        pasteCallCount += 1
    }

    override func pasteAsPlainText(_ sender: Any?) {
        pasteAsPlainTextCallCount += 1
    }
}

@MainActor
extension AppDelegate {
    func closeMainWindowForXCTest(windowId: UUID) {
        let originalConfirmationHandler = debugCloseMainWindowConfirmationHandler
        debugCloseMainWindowConfirmationHandler = { _ in true }
        defer {
            debugCloseMainWindowConfirmationHandler = originalConfirmationHandler
            forgetRecoverableMainWindowRoute(windowId: windowId)
        }

        if let manager = tabManagerFor(windowId: windowId) {
            for workspace in manager.tabs {
                workspace.withClosedPanelHistorySuppressed {
                    workspace.teardownAllPanels()
                }
                workspace.teardownRemoteConnection()
            }
        }

        forgetRecoverableMainWindowRoute(windowId: windowId)
        if let window = windowForMainWindowId(windowId) {
            window.animationBehavior = .none
            window.orderOut(nil)
            window.close()
        }
        unregisterMainWindowContextForTesting(windowId: windowId)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }
}

private struct TextBoxMentionFileIndexCache {
    private struct CachedIndex {
        let index: TextBoxMentionCandidateIndex
        let createdAt: Date
        var lastAccessedAt: Date

        func isFresh(now: Date) -> Bool {
            now.timeIntervalSince(createdAt) < TextBoxMentionFileIndexCache.fileIndexTTL
        }
    }

    private static let fileIndexTTL: TimeInterval = 2
    static let maxRootIndexes = 8
    private static let suggestionLimit = 8

    private var indexesByRoot: [String: CachedIndex] = [:]

    mutating func suggestions(
        for query: TextBoxMentionQuery,
        rootDirectory: String,
        now: Date = Date(),
        scanFiles: (URL) -> [TextBoxMentionCandidate]
    ) -> [TextBoxMentionSuggestion] {
        pruneExpired(now: now)
        let index = fileIndex(rootDirectory: rootDirectory, now: now, scanFiles: scanFiles)
        let matches = index.rankedCandidates(matching: query.query, limit: Self.suggestionLimit)
        return matches
            .map { $0.suggestion(trigger: query.trigger) }
    }

    private mutating func fileIndex(
        rootDirectory: String,
        now: Date,
        scanFiles: (URL) -> [TextBoxMentionCandidate]
    ) -> TextBoxMentionCandidateIndex {
        if var cached = indexesByRoot[rootDirectory], cached.isFresh(now: now) {
            cached.lastAccessedAt = now
            indexesByRoot[rootDirectory] = cached
            return cached.index
        }
        return refreshFileIndex(rootDirectory: rootDirectory, now: now, scanFiles: scanFiles)
    }

    private mutating func refreshFileIndex(
        rootDirectory: String,
        now: Date,
        scanFiles: (URL) -> [TextBoxMentionCandidate]
    ) -> TextBoxMentionCandidateIndex {
        let rootURL = URL(fileURLWithPath: rootDirectory, isDirectory: true)
        let index = TextBoxMentionCandidateIndex(candidates: scanFiles(rootURL))
        indexesByRoot[rootDirectory] = CachedIndex(index: index, createdAt: now, lastAccessedAt: now)
        pruneOverflow()
        return index
    }

    private mutating func pruneExpired(now: Date) {
        indexesByRoot = indexesByRoot.filter { _, cached in
            cached.isFresh(now: now)
        }
    }

    private mutating func pruneOverflow() {
        guard indexesByRoot.count > Self.maxRootIndexes else { return }
        let overflowCount = indexesByRoot.count - Self.maxRootIndexes
        let rootsToRemove = indexesByRoot
            .sorted { lhs, rhs in
                if lhs.value.lastAccessedAt == rhs.value.lastAccessedAt {
                    return lhs.key < rhs.key
                }
                return lhs.value.lastAccessedAt < rhs.value.lastAccessedAt
            }
            .prefix(overflowCount)
            .map(\.key)

        for root in rootsToRemove {
            indexesByRoot.removeValue(forKey: root)
        }
    }
}

@MainActor
final class AppDelegateShortcutRoutingTests: XCTestCase {
    private static var retainedTextBoxUndoWindows: [NSWindow] = []
    private static var retainedTextBoxRenderScrollViews: [NSScrollView] = []
    private static var retainedTextBoxRestoreViews: [TextBoxInputTextView] = []
    private var savedShortcutsByAction: [KeyboardShortcutSettings.Action: StoredShortcut] = [:]
    private var actionsWithPersistedShortcut: Set<KeyboardShortcutSettings.Action> = []
    private var mainWindowIdsAtTestStart: Set<UUID> = []
    private var originalSettingsFileStore: KeyboardShortcutSettingsFileStore!
#if DEBUG
    private var originalRuntimeSurfaceCreationSuppression = false
    private var testOwnedTabManagers: [TabManager] = []
#endif

    private func makeKeyEvent(
        modifierFlags: NSEvent.ModifierFlags,
        characters: String,
        charactersIgnoringModifiers: String,
        keyCode: UInt16
    ) -> NSEvent {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            isARepeat: false,
            keyCode: keyCode
        ) else {
            fatalError("Failed to construct key event")
        }
        return event
    }

    private func ghosttyConfigKeyIsBinding(
        _ config: ghostty_config_t,
        key: String,
        modifiers: NSEvent.ModifierFlags,
        keyCode: UInt32
    ) -> Bool {
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = GHOSTTY_ACTION_PRESS
        keyEvent.keycode = keyCode
        keyEvent.mods = ghosttyMods(from: modifiers)
        keyEvent.consumed_mods = GHOSTTY_MODS_NONE
        keyEvent.unshifted_codepoint = key.unicodeScalars.first.map { UInt32($0.value) } ?? 0
        keyEvent.composing = false

        return key.withCString { ptr in
            keyEvent.text = ptr
            return ghostty_config_key_is_binding(config, keyEvent)
        }
    }

    private func ghosttyMods(from modifiers: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var rawValue = GHOSTTY_MODS_NONE.rawValue
        if modifiers.contains(.shift) { rawValue |= GHOSTTY_MODS_SHIFT.rawValue }
        if modifiers.contains(.control) { rawValue |= GHOSTTY_MODS_CTRL.rawValue }
        if modifiers.contains(.option) { rawValue |= GHOSTTY_MODS_ALT.rawValue }
        if modifiers.contains(.command) { rawValue |= GHOSTTY_MODS_SUPER.rawValue }
        return ghostty_input_mods_e(rawValue: rawValue)
    }

    override func setUp() {
        super.setUp()
        // Prevent a single hanging test from consuming the entire CI timeout budget.
        executionTimeAllowance = 30
        #if DEBUG
        originalRuntimeSurfaceCreationSuppression = TerminalSurface.debugSuppressRuntimeSurfaceCreationForTesting
        TerminalSurface.debugSuppressRuntimeSurfaceCreationForTesting = true
        testOwnedTabManagers.removeAll(keepingCapacity: false)
        KeyboardShortcutRecorderActivity.resetForTesting()
        AppDelegate.shared?.debugResetShortcutRoutingStateForTesting()
        #endif
        mainWindowIdsAtTestStart = mainWindowIds()
        actionsWithPersistedShortcut = Set(
            KeyboardShortcutSettings.Action.allCases.filter {
                UserDefaults.standard.object(forKey: $0.defaultsKey) != nil
            }
        )
        savedShortcutsByAction = Dictionary(
            uniqueKeysWithValues: actionsWithPersistedShortcut.map { action in
                (action, KeyboardShortcutSettings.shortcut(for: action))
            }
        )
        originalSettingsFileStore = KeyboardShortcutSettings.installIsolatedTestFileStore(prefix: "cmux-shortcut-routing")
        KeyboardShortcutSettings.resetAll()
        #if DEBUG
        AppDelegate.shared?.debugResetShortcutRoutingStateForTesting()
        #endif
    }

    override func tearDown() {
        for windowId in mainWindowIds().subtracting(mainWindowIdsAtTestStart) {
            closeWindow(withId: windowId)
        }
        mainWindowIdsAtTestStart.removeAll()
        #if DEBUG
        KeyboardShortcutRecorderActivity.resetForTesting()
        AppDelegate.shared?.debugResetShortcutRoutingStateForTesting()
        KeyboardShortcutSettings.shortcutLookupObserver = nil
        TextBoxSubmit.debugResetForTesting()
        #endif
        KeyboardShortcutSettings.settingsFileStore = originalSettingsFileStore
        AppDelegate.shared?.shortcutLayoutCharacterProvider = KeyboardLayout.character(forKeyCode:modifierFlags:)
        AppDelegate.shared?.debugCloseMainWindowConfirmationHandler = nil
        AppDelegate.shared?.debugCreateMainWindowSourceIsNativeFullScreenOverride = nil
        if AppDelegate.shared?.dismissNotificationsPopoverIfShown() == true {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        for action in KeyboardShortcutSettings.Action.allCases {
            if actionsWithPersistedShortcut.contains(action),
               let savedShortcut = savedShortcutsByAction[action] {
                KeyboardShortcutSettings.setShortcut(savedShortcut, for: action)
            } else {
                KeyboardShortcutSettings.resetShortcut(for: action)
            }
        }
        #if DEBUG
        AppDelegate.shared?.debugResetShortcutRoutingStateForTesting()
        #endif
        for window in Self.retainedTextBoxUndoWindows {
            window.orderOut(nil)
            window.close()
        }
        Self.retainedTextBoxUndoWindows.removeAll()
        Self.retainedTextBoxRenderScrollViews.removeAll()
        Self.retainedTextBoxRestoreViews.removeAll()
        #if DEBUG
        tearDownShortcutRoutingTabManagers()
        TerminalSurface.debugSuppressRuntimeSurfaceCreationForTesting = originalRuntimeSurfaceCreationSuppression
        #endif
        super.tearDown()
    }

    private func makeShortcutRoutingTabManager(
        autoWelcomeIfNeeded: Bool = true,
        createInitialWorkspace: Bool = true
    ) -> TabManager {
#if DEBUG
        let previousSuppression = TerminalSurface.debugSuppressRuntimeSurfaceCreationForTesting
        TerminalSurface.debugSuppressRuntimeSurfaceCreationForTesting = true
        defer { TerminalSurface.debugSuppressRuntimeSurfaceCreationForTesting = previousSuppression }
        let manager = TabManager(
            autoWelcomeIfNeeded: autoWelcomeIfNeeded,
            debugCreateInitialWorkspace: createInitialWorkspace
        )
        testOwnedTabManagers.append(manager)
        return manager
#else
        return TabManager(autoWelcomeIfNeeded: autoWelcomeIfNeeded)
#endif
    }

#if DEBUG
    private func tearDownShortcutRoutingTabManagers() {
        defer { testOwnedTabManagers.removeAll(keepingCapacity: false) }
        guard let appDelegate = AppDelegate.shared else { return }

        for manager in testOwnedTabManagers.reversed() {
            appDelegate.debugTeardownTabManagerForTesting(manager)
        }
    }
#endif

    func testShortcutMonitorIgnoresSystemDefinedEvents() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }
        guard let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            subtype: 7,
            data1: 1,
            data2: 1
        ) else {
            XCTFail("Failed to construct system-defined event")
            return
        }

#if DEBUG
        XCTAssertFalse(appDelegate.debugHandleShortcutMonitorEvent(event: event))
#else
        XCTFail("debugHandleShortcutMonitorEvent is only available in DEBUG")
#endif
    }

    func testStopAllRecordingClearsStaleRecorderActivityCount() {
        defer { KeyboardShortcutRecorderActivity.stopAllRecording() }

        KeyboardShortcutRecorderActivity.beginRecording()
        KeyboardShortcutRecorderActivity.beginRecording()
        XCTAssertTrue(KeyboardShortcutRecorderActivity.isAnyRecorderActive)

        KeyboardShortcutRecorderActivity.stopAllRecording()

        XCTAssertFalse(KeyboardShortcutRecorderActivity.isAnyRecorderActive)
    }

    func testFocusHistoryShortcutsConsumeEventWhenNoHistoryIsAvailable() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }
        let originalTabManager = appDelegate.tabManager
        let manager = makeShortcutRoutingTabManager(createInitialWorkspace: false)
        appDelegate.tabManager = manager
        defer {
            appDelegate.tabManager = originalTabManager
        }

        XCTAssertFalse(manager.canNavigateBack)
        XCTAssertFalse(manager.canNavigateForward)
        let backEvent = makeKeyEvent(
            modifierFlags: [.command],
            characters: "[",
            charactersIgnoringModifiers: "[",
            keyCode: 33
        )
        let forwardEvent = makeKeyEvent(
            modifierFlags: [.command],
            characters: "]",
            charactersIgnoringModifiers: "]",
            keyCode: 30
        )

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: backEvent))
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: forwardEvent))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
    }

    func testCmdNUsesEventWindowContextWhenActiveManagerIsStale() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        guard let event = makeKeyDownEvent(
            key: "n",
            modifiers: [.command],
            keyCode: 45,
            windowNumber: 904
        ) else {
            XCTFail("Failed to construct Cmd+N event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugMatchesConfiguredShortcut(event: event, action: .newTab))

        let staleActiveWindowId = UUID()
        let eventWindowId = UUID()
        let shortcutSelection = selectShortcutRoutingContextAfterEventResolution(
            debugPreferredWindowId: nil,
            eventWindowId: eventWindowId,
            hasAddressableEventWindow: true,
            eventWindowAllowsFallback: false,
            keyWindowId: staleActiveWindowId,
            mainWindowId: staleActiveWindowId,
            activeManagerWindowId: staleActiveWindowId,
            fallbackWindowId: staleActiveWindowId
        )
        XCTAssertEqual(shortcutSelection.reason, .eventWindow)
        XCTAssertEqual(shortcutSelection.windowId, eventWindowId)
        XCTAssertNotEqual(
            shortcutSelection.windowId,
            staleActiveWindowId,
            "Cmd+N shortcut routing should not use the stale active manager"
        )

        let workspaceCreationSelection = AppDelegate.selectWorkspaceCreationContext(
            eventWindowId: eventWindowId,
            hasAddressableEventWindow: true,
            debugPreferredWindowId: nil,
            keyWindowId: staleActiveWindowId,
            mainWindowId: staleActiveWindowId,
            orderedWindowIds: [staleActiveWindowId],
            fallbackCandidates: [
                AppDelegate.WorkspaceCreationContextCandidate(
                    windowId: staleActiveWindowId,
                    hasResolvedWindow: true
                )
            ]
        )
        XCTAssertEqual(workspaceCreationSelection.reason, .eventWindow)
        XCTAssertEqual(workspaceCreationSelection.windowId, eventWindowId)
        XCTAssertNotEqual(
            workspaceCreationSelection.windowId,
            staleActiveWindowId,
            "Cmd+N workspace creation should not add a workspace to the stale active window"
        )
#else
        XCTFail("Cmd+N routing helpers are only available in DEBUG")
#endif
    }

    func testChordedNewWorkspaceShortcutConsumesPrefixAndTriggersOnSecondKey() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let shortcut = StoredShortcut(
            key: "b",
            command: false,
            shift: false,
            option: false,
            control: true,
            chordKey: "n"
        )
        let windowNumber = 501

        withTemporaryShortcut(action: .newTab, shortcut: shortcut) {
            guard let prefixEvent = makeKeyDownEvent(
                key: "b",
                modifiers: [.control],
                keyCode: 11,
                windowNumber: windowNumber
            ) else {
                XCTFail("Failed to construct Ctrl+B prefix event")
                return
            }

            guard let actionEvent = makeKeyDownEvent(
                key: "n",
                modifiers: [],
                keyCode: 45,
                windowNumber: windowNumber
            ) else {
                XCTFail("Failed to construct N action event")
                return
            }

            XCTAssertFalse(appDelegate.debugMatchesConfiguredShortcut(event: prefixEvent, action: .newTab))
            XCTAssertTrue(appDelegate.debugArmConfiguredShortcutChordForTesting(event: prefixEvent, actions: [.newTab]))
            XCTAssertEqual(appDelegate.debugPendingConfiguredShortcutChordWindowNumberForTesting(), windowNumber)

            XCTAssertTrue(
                appDelegate.debugMatchConfiguredShortcutConsumingPendingChordForTesting(
                    event: actionEvent,
                    action: .newTab
                )
            )
            XCTAssertNil(appDelegate.debugPendingConfiguredShortcutChordWindowNumberForTesting())
        }
    }

    func testSettingsFileChordDispatchesNewWorkspaceShortcut() throws {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try """
        {
          "shortcuts": {
            "newTab": ["ctrl+b", "n"]
          }
        }
        """.write(to: settingsFileURL, atomically: true, encoding: .utf8)

        KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )
        appDelegate.debugResetShortcutRoutingStateForTesting()

        let windowNumber = 502

        guard let prefixEvent = makeKeyDownEvent(
            key: "b",
            modifiers: [.control],
            keyCode: 11,
            windowNumber: windowNumber
        ) else {
            XCTFail("Failed to construct Ctrl+B prefix event")
            return
        }

        guard let actionEvent = makeKeyDownEvent(
            key: "n",
            modifiers: [],
            keyCode: 45,
            windowNumber: windowNumber
        ) else {
            XCTFail("Failed to construct N action event")
            return
        }

        XCTAssertTrue(appDelegate.debugArmConfiguredShortcutChordForTesting(event: prefixEvent, actions: [.newTab]))
        XCTAssertEqual(appDelegate.debugPendingConfiguredShortcutChordWindowNumberForTesting(), windowNumber)
        XCTAssertTrue(
            appDelegate.debugMatchConfiguredShortcutConsumingPendingChordForTesting(
                event: actionEvent,
                action: .newTab
            )
        )
    }

    func testConfiguredChordPrefixIsClearedWhenAppResignsActive() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let shortcut = StoredShortcut(
            key: "b",
            command: false,
            shift: false,
            option: false,
            control: true,
            chordKey: "n"
        )
        let windowNumber = 503

        withTemporaryShortcut(action: .newTab, shortcut: shortcut) {
            guard let prefixEvent = makeKeyDownEvent(
                key: "b",
                modifiers: [.control],
                keyCode: 11,
                windowNumber: windowNumber
            ) else {
                XCTFail("Failed to construct Ctrl+B prefix event")
                return
            }

            guard let actionEvent = makeKeyDownEvent(
                key: "n",
                modifiers: [],
                keyCode: 45,
                windowNumber: windowNumber
            ) else {
                XCTFail("Failed to construct N action event")
                return
            }

            XCTAssertTrue(appDelegate.debugArmConfiguredShortcutChordForTesting(event: prefixEvent, actions: [.newTab]))
            XCTAssertEqual(appDelegate.debugPendingConfiguredShortcutChordWindowNumberForTesting(), windowNumber)
            appDelegate.applicationWillResignActive(Notification(name: NSApplication.willResignActiveNotification))
            XCTAssertFalse(
                appDelegate.debugMatchConfiguredShortcutConsumingPendingChordForTesting(
                    event: actionEvent,
                    action: .newTab
                )
            )
        }
    }

    func testConfiguredChordPrefixBeatsConflictingSingleStrokeShortcut() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let shortcut = StoredShortcut(
            key: ",",
            command: true,
            shift: false,
            option: false,
            control: false,
            chordKey: "n"
        )
        let windowNumber = 504

        withTemporaryShortcut(action: .newTab, shortcut: shortcut) {
            guard let prefixEvent = makeKeyDownEvent(
                key: ",",
                modifiers: [.command],
                keyCode: 43,
                windowNumber: windowNumber
            ) else {
                XCTFail("Failed to construct Cmd+, prefix event")
                return
            }

            guard let actionEvent = makeKeyDownEvent(
                key: "n",
                modifiers: [],
                keyCode: 45,
                windowNumber: windowNumber
            ) else {
                XCTFail("Failed to construct N action event")
                return
            }

            XCTAssertTrue(appDelegate.debugMatchesConfiguredShortcut(event: prefixEvent, action: .openSettings))
            XCTAssertTrue(appDelegate.debugArmConfiguredShortcutChordForTesting(event: prefixEvent, actions: [.newTab]))
            XCTAssertTrue(
                appDelegate.debugMatchConfiguredShortcutConsumingPendingChordForTesting(
                    event: actionEvent,
                    action: .newTab
                )
            )
        }
    }

    func testConfiguredChordPrefixBlocksUnrelatedSingleStrokeShortcutOnSecondKey() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let shortcut = StoredShortcut(
            key: "b",
            command: false,
            shift: false,
            option: false,
            control: true,
            chordKey: "d"
        )
        let windowNumber = 505

        withTemporaryShortcut(action: .splitRight, shortcut: shortcut) {
            guard let prefixEvent = makeKeyDownEvent(
                key: "b",
                modifiers: [.control],
                keyCode: 11,
                windowNumber: windowNumber
            ) else {
                XCTFail("Failed to construct Ctrl+B prefix event")
                return
            }

            guard let conflictingSingleStrokeEvent = makeKeyDownEvent(
                key: "n",
                modifiers: [.command],
                keyCode: 45,
                windowNumber: windowNumber
            ) else {
                XCTFail("Failed to construct Cmd+N event")
                return
            }

            XCTAssertTrue(appDelegate.debugArmConfiguredShortcutChordForTesting(event: prefixEvent, actions: [.splitRight]))
            XCTAssertFalse(
                appDelegate.debugMatchConfiguredShortcutConsumingPendingChordForTesting(
                    event: conflictingSingleStrokeEvent,
                    action: .newTab
                )
            )
        }
    }

    func testConfiguredChordDoesNotCrossWindowBoundary() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let shortcut = StoredShortcut(
            key: "b",
            command: false,
            shift: false,
            option: false,
            control: true,
            chordKey: "n"
        )
        let firstWindowNumber = 506
        let secondWindowNumber = 507

        withTemporaryShortcut(action: .newTab, shortcut: shortcut) {
            guard let prefixEvent = makeKeyDownEvent(
                key: "b",
                modifiers: [.control],
                keyCode: 11,
                windowNumber: firstWindowNumber
            ) else {
                XCTFail("Failed to construct Ctrl+B prefix event")
                return
            }

            guard let actionEvent = makeKeyDownEvent(
                key: "n",
                modifiers: [],
                keyCode: 45,
                windowNumber: secondWindowNumber
            ) else {
                XCTFail("Failed to construct N action event")
                return
            }

            XCTAssertTrue(appDelegate.debugArmConfiguredShortcutChordForTesting(event: prefixEvent, actions: [.newTab]))
            XCTAssertEqual(appDelegate.debugPendingConfiguredShortcutChordWindowNumberForTesting(), firstWindowNumber)
            XCTAssertFalse(
                appDelegate.debugMatchConfiguredShortcutConsumingPendingChordForTesting(
                    event: actionEvent,
                    action: .newTab
                )
            )
        }
    }

    func testShortcutChangeClearsPendingConfiguredChord() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let chordShortcut = StoredShortcut(
            key: "b",
            command: false,
            shift: false,
            option: false,
            control: true,
            chordKey: "d"
        )
        let windowNumber = 508

        withTemporaryShortcut(action: .splitRight, shortcut: chordShortcut) {
            guard let prefixEvent = makeKeyDownEvent(
                key: "b",
                modifiers: [.control],
                keyCode: 11,
                windowNumber: windowNumber
            ) else {
                XCTFail("Failed to construct Ctrl+B prefix event")
                return
            }

            guard let suffixEvent = makeKeyDownEvent(
                key: "d",
                modifiers: [],
                keyCode: 2,
                windowNumber: windowNumber
            ) else {
                XCTFail("Failed to construct D suffix event")
                return
            }

            XCTAssertTrue(appDelegate.debugArmConfiguredShortcutChordForTesting(event: prefixEvent, actions: [.splitRight]))
            XCTAssertEqual(appDelegate.debugPendingConfiguredShortcutChordWindowNumberForTesting(), windowNumber)

            KeyboardShortcutSettings.setShortcut(
                StoredShortcut(key: "d", command: true, shift: false, option: false, control: false),
                for: .splitRight
            )

            XCTAssertFalse(
                appDelegate.debugMatchConfiguredShortcutConsumingPendingChordForTesting(
                    event: suffixEvent,
                    action: .splitRight
                )
            )
        }
    }

    func testChordedShortcutMismatchDoesNotConsumeSecondKey() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let shortcut = StoredShortcut(
            key: "b",
            command: false,
            shift: false,
            option: false,
            control: true,
            chordKey: "d"
        )
        let windowNumber = 509

        withTemporaryShortcut(action: .splitRight, shortcut: shortcut) {
            guard let prefixEvent = makeKeyDownEvent(
                key: "b",
                modifiers: [.control],
                keyCode: 11,
                windowNumber: windowNumber
            ) else {
                XCTFail("Failed to construct Ctrl+B prefix event")
                return
            }

            guard let mismatchEvent = makeKeyDownEvent(
                key: "x",
                modifiers: [],
                keyCode: 7,
                windowNumber: windowNumber
            ) else {
                XCTFail("Failed to construct mismatch event")
                return
            }

            XCTAssertTrue(appDelegate.debugArmConfiguredShortcutChordForTesting(event: prefixEvent, actions: [.splitRight]))
            XCTAssertFalse(
                appDelegate.debugMatchConfiguredShortcutConsumingPendingChordForTesting(
                    event: mismatchEvent,
                    action: .splitRight
                )
            )
        }
    }

    func testCreateMainWindowDoesNotDisallowFullScreenTilingByDefault() {
        let shouldTemporarilyDisallowFullScreenTiling =
            AppDelegate.shouldTemporarilyDisallowFullScreenTilingForNewMainWindow(
                hasSessionWindowSnapshot: false,
                sourceWindowIsNativeFullScreen: false
            )
        let collectionBehavior = AppDelegate.mainWindowCollectionBehavior(
            [],
            temporarilyDisallowsFullScreenTiling: shouldTemporarilyDisallowFullScreenTiling
        )

        XCTAssertFalse(
            collectionBehavior.contains(.fullScreenDisallowsTiling),
            "Main windows should still support standard macOS Split View when not created from a fullscreen source"
        )
    }

    func testCreateMainWindowTemporarilyDisallowsFullScreenTilingFromFullscreenSource() {
        let shouldTemporarilyDisallowFullScreenTiling =
            AppDelegate.shouldTemporarilyDisallowFullScreenTilingForNewMainWindow(
                hasSessionWindowSnapshot: false,
                sourceWindowIsNativeFullScreen: true
            )
        let initialCollectionBehavior = AppDelegate.mainWindowCollectionBehavior(
            [],
            temporarilyDisallowsFullScreenTiling: shouldTemporarilyDisallowFullScreenTiling
        )

        XCTAssertTrue(
            initialCollectionBehavior.contains(.fullScreenDisallowsTiling),
            "New windows should temporarily opt out of fullscreen tiling while opening from a fullscreen source"
        )

        let restoredCollectionBehavior = AppDelegate.mainWindowCollectionBehavior(
            [],
            temporarilyDisallowsFullScreenTiling:
                AppDelegate.shouldTemporarilyDisallowFullScreenTilingForNewMainWindow(
                    hasSessionWindowSnapshot: true,
                    sourceWindowIsNativeFullScreen: true
                )
        )
        XCTAssertFalse(
            restoredCollectionBehavior.contains(.fullScreenDisallowsTiling),
            "Session restore should preserve normal Split View behavior even when the source window is fullscreen"
        )

        let clearedCollectionBehavior =
            AppDelegate.collectionBehaviorByClearingFullScreenTilingOptOut(initialCollectionBehavior)

        XCTAssertFalse(
            clearedCollectionBehavior.contains(.fullScreenDisallowsTiling),
            "The fullscreen tiling opt-out should be cleared after initial presentation so Split View keeps working"
        )
    }

    func testAddWorkspaceInPreferredMainWindowIgnoresStaleTabManagerPointer() {
#if DEBUG
        let staleActiveWindowId = UUID()
        let preferredWindowId = UUID()

        let selection = AppDelegate.selectWorkspaceCreationContextAfterEventResolution(
            debugPreferredWindowId: preferredWindowId,
            keyWindowId: nil,
            mainWindowId: nil,
            orderedWindowIds: [],
            fallbackCandidates: [
                AppDelegate.WorkspaceCreationContextCandidate(
                    windowId: staleActiveWindowId,
                    hasResolvedWindow: true
                ),
                AppDelegate.WorkspaceCreationContextCandidate(
                    windowId: preferredWindowId,
                    hasResolvedWindow: true
                )
            ]
        )

        XCTAssertEqual(selection.windowId, preferredWindowId)
        XCTAssertEqual(selection.reason, .debugPreferredWindow)
        XCTAssertNotEqual(
            selection.windowId,
            staleActiveWindowId,
            "Workspace creation should target the preferred main window instead of the stale app-level tab manager pointer"
        )
#else
        XCTFail("Workspace creation context selection is only available in DEBUG")
#endif
    }

    func testToggleSidebarInActiveMainWindowIgnoresStaleTabManagerPointer() {
#if DEBUG
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let firstContext = makeRegisteredLightweightMainWindowContext(appDelegate: appDelegate)
        let secondContext = makeRegisteredLightweightMainWindowContext(appDelegate: appDelegate)
        let originalTabManager = appDelegate.tabManager

        defer {
            appDelegate.tabManager = originalTabManager
            appDelegate.unregisterMainWindowContextForTesting(windowId: firstContext.windowId, notifyObservers: false)
            appDelegate.unregisterMainWindowContextForTesting(windowId: secondContext.windowId, notifyObservers: false)
            closeTestWindow(firstContext.window)
            closeTestWindow(secondContext.window)
        }

        guard let firstVisibleBefore = appDelegate.sidebarVisibility(windowId: firstContext.windowId),
              let secondVisibleBefore = appDelegate.sidebarVisibility(windowId: secondContext.windowId) else {
            XCTFail("Expected both window contexts to exist")
            return
        }

        secondContext.window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        // Force a stale app-level pointer to another manager. Window-local UI
        // controls should still target the key/main window, not this stale pointer.
        appDelegate.tabManager = firstContext.tabManager
        XCTAssertTrue(appDelegate.tabManager === firstContext.tabManager)

        XCTAssertTrue(appDelegate.toggleSidebarInActiveMainWindow())

        XCTAssertEqual(
            appDelegate.sidebarVisibility(windowId: firstContext.windowId),
            firstVisibleBefore,
            "Stale active-manager pointer must not receive sidebar toggles"
        )
        XCTAssertEqual(
            appDelegate.sidebarVisibility(windowId: secondContext.windowId),
            !secondVisibleBefore,
            "Sidebar toggle should target the key/main window context"
        )
#else
        XCTFail("Shortcut routing test hooks are only available in DEBUG")
#endif
    }

    func testWelcomeWindowSidebarShortcutsUseSharedToggleCommands() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        XCTAssertEqual(
            KeyboardShortcutSettings.Action.toggleSidebar.label,
            String(localized: "shortcut.toggleLeftSidebar.label", defaultValue: "Toggle Left Sidebar"),
            "Welcome should expose the shared left-sidebar toggle command"
        )
        XCTAssertEqual(
            KeyboardShortcutSettings.Action.toggleSidebar.defaultShortcut,
            StoredShortcut(key: "b", command: true, shift: false, option: false, control: false)
        )
        XCTAssertEqual(
            KeyboardShortcutSettings.Action.toggleRightSidebar.label,
            String(localized: "shortcut.toggleRightSidebar.label", defaultValue: "Toggle Right Sidebar"),
            "Welcome should expose the shared right-sidebar toggle command, not a File Explorer-only action"
        )
        XCTAssertEqual(
            KeyboardShortcutSettings.Action.toggleRightSidebar.defaultShortcut,
            StoredShortcut(key: "b", command: true, shift: false, option: true, control: false)
        )

        guard let leftSidebarEvent = makeKeyDownEvent(
            key: "b",
            modifiers: [.command],
            keyCode: 11,
            windowNumber: 0
        ), let rightSidebarEvent = makeKeyDownEvent(
            key: "b",
            modifiers: [.command, .option],
            keyCode: 11,
            windowNumber: 0
        ) else {
            XCTFail("Failed to construct sidebar shortcut events")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugMatchesConfiguredShortcut(
            event: leftSidebarEvent,
            action: .toggleSidebar
        ))
        XCTAssertFalse(appDelegate.debugMatchesConfiguredShortcut(
            event: leftSidebarEvent,
            action: .toggleRightSidebar
        ))
        XCTAssertTrue(appDelegate.debugMatchesConfiguredShortcut(
            event: rightSidebarEvent,
            action: .toggleRightSidebar
        ))
        XCTAssertFalse(appDelegate.debugMatchesConfiguredShortcut(
            event: rightSidebarEvent,
            action: .toggleSidebar
        ))
#else
        XCTFail("debugMatchesConfiguredShortcut is only available in DEBUG")
#endif
    }

    func testCmdNResolvesEventWindowWhenObjectKeyLookupIsMismatched() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

#if DEBUG
        guard let event = makeKeyDownEvent(
            key: "n",
            modifiers: [.command],
            keyCode: 45,
            windowNumber: 905
        ) else {
            XCTFail("Failed to construct Cmd+N event")
            return
        }

        XCTAssertTrue(appDelegate.debugMatchesConfiguredShortcut(event: event, action: .newTab))

        let staleActiveWindowId = UUID()
        let eventWindowId = UUID()
        let shortcutSelection = selectShortcutRoutingContextAfterEventResolution(
            debugPreferredWindowId: nil,
            eventWindowId: eventWindowId,
            hasAddressableEventWindow: true,
            eventWindowAllowsFallback: false,
            keyWindowId: staleActiveWindowId,
            mainWindowId: staleActiveWindowId,
            activeManagerWindowId: staleActiveWindowId,
            fallbackWindowId: staleActiveWindowId
        )
        XCTAssertEqual(shortcutSelection.reason, .eventWindow)
        XCTAssertEqual(shortcutSelection.windowId, eventWindowId)
        XCTAssertNotEqual(
            shortcutSelection.windowId,
            staleActiveWindowId,
            "Cmd+N should not route to another window when object-key lookup misses"
        )

        let workspaceCreationSelection = AppDelegate.selectWorkspaceCreationContext(
            eventWindowId: eventWindowId,
            hasAddressableEventWindow: true,
            debugPreferredWindowId: nil,
            keyWindowId: staleActiveWindowId,
            mainWindowId: staleActiveWindowId,
            orderedWindowIds: [staleActiveWindowId],
            fallbackCandidates: [
                AppDelegate.WorkspaceCreationContextCandidate(
                    windowId: staleActiveWindowId,
                    hasResolvedWindow: true
                )
            ]
        )
        XCTAssertEqual(workspaceCreationSelection.reason, .eventWindow)
        XCTAssertEqual(workspaceCreationSelection.windowId, eventWindowId)
        XCTAssertNotEqual(
            workspaceCreationSelection.windowId,
            staleActiveWindowId,
            "Cmd+N workspace creation should not target the stale active window when object-key lookup misses"
        )
#else
        XCTFail("Cmd+N routing helpers are only available in DEBUG")
#endif
    }

    func testDockMenuNewWindowItemCreatesMainWindow() {
#if DEBUG
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let previousHandler = appDelegate.debugOpenNewMainWindowHandler
        var receivedSender: Any?
        defer {
            appDelegate.debugOpenNewMainWindowHandler = previousHandler
        }
        appDelegate.debugOpenNewMainWindowHandler = { sender in
            receivedSender = sender
        }

        let delegate: NSApplicationDelegate = appDelegate
        guard let dockMenu = delegate.applicationDockMenu?(NSApp) else {
            XCTFail("Expected Dock menu")
            return
        }

        let expectedTitle = String(localized: "menu.file.newWindow", defaultValue: "New Window")
        guard let item = dockMenu.items.first(where: { $0.action == #selector(AppDelegate.openNewMainWindow(_:)) }) else {
            XCTFail("Expected New Window item in Dock menu")
            return
        }

        XCTAssertEqual(item.title, expectedTitle)
        XCTAssertTrue(item.target === appDelegate)
        XCTAssertTrue(NSApp.sendAction(#selector(AppDelegate.openNewMainWindow(_:)), to: item.target, from: item))
        XCTAssertTrue(receivedSender as? NSMenuItem === item)
#else
        XCTFail("Dock menu action test hook is only available in DEBUG")
#endif
    }

    func testRestorePreviousSessionSnapshotCreatesNewWindowWithoutClosingCurrentWindows() throws {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let baselineWindowIds = mainWindowIds()
        let liveWindowId = appDelegate.createMainWindow(shouldActivate: false)
        defer {
            for windowId in mainWindowIds().subtracting(baselineWindowIds) {
                closeWindow(withId: windowId)
            }
        }

        guard let liveManager = appDelegate.tabManagerFor(windowId: liveWindowId),
              let liveWorkspace = liveManager.selectedWorkspace else {
            XCTFail("Expected live window manager and workspace")
            return
        }
        liveWorkspace.setCustomTitle("Current Work")
        let windowIdsAfterLiveWindow = mainWindowIds()

        let restoredManager = makeShortcutRoutingTabManager(autoWelcomeIfNeeded: false)
        let restoredWorkspace = try XCTUnwrap(restoredManager.selectedWorkspace)
        restoredWorkspace.setCustomTitle("Previous Work")
        let snapshot = AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion,
            createdAt: 1_700_000_000,
            windows: [sessionWindowSnapshot(tabManager: restoredManager)]
        )

        XCTAssertTrue(appDelegate.restorePreviousSessionSnapshot(snapshot, shouldActivate: false))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        let finalWindowIds = mainWindowIds()
        XCTAssertTrue(finalWindowIds.contains(liveWindowId))
        XCTAssertEqual(liveManager.selectedWorkspace?.customTitle, "Current Work")

        let createdWindowIds = finalWindowIds.subtracting(windowIdsAfterLiveWindow)
        XCTAssertEqual(createdWindowIds.count, 1)
        let restoredWindowId = try XCTUnwrap(createdWindowIds.first)
        let restoredWindowManager = try XCTUnwrap(appDelegate.tabManagerFor(windowId: restoredWindowId))
        XCTAssertEqual(restoredWindowManager.selectedWorkspace?.customTitle, "Previous Work")
    }

    func testRestorePreviousSessionSnapshotRemapsClosedWorkspaceWindowIds() throws {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        ClosedItemHistoryStore.shared.removeAll()
        defer { ClosedItemHistoryStore.shared.removeAll() }

        let baselineWindowIds = mainWindowIds()
        let liveWindowId = appDelegate.createMainWindow(shouldActivate: false)
        defer {
            for windowId in mainWindowIds().subtracting(baselineWindowIds) {
                closeWindow(withId: windowId)
            }
        }

        let liveManager = try XCTUnwrap(appDelegate.tabManagerFor(windowId: liveWindowId))
        let oldRestoredWindowId = UUID()

        let restoredManager = makeShortcutRoutingTabManager(autoWelcomeIfNeeded: false)
        let restoredWorkspace = try XCTUnwrap(restoredManager.selectedWorkspace)
        restoredWorkspace.setCustomTitle("Previous Work")

        let closedWorkspaceManager = makeShortcutRoutingTabManager(autoWelcomeIfNeeded: false)
        let closedWorkspace = try XCTUnwrap(closedWorkspaceManager.selectedWorkspace)
        closedWorkspace.setCustomTitle("Closed Previous Workspace")
        let closedRecordId = UUID()
        ClosedItemHistoryStore.shared.push(ClosedItemHistoryRecord(
            id: closedRecordId,
            closedAt: Date(timeIntervalSince1970: 1_700_000_000),
            entry: .workspace(ClosedWorkspaceHistoryEntry(
                workspaceId: closedWorkspace.id,
                windowId: oldRestoredWindowId,
                workspaceIndex: 1,
                snapshot: closedWorkspace.sessionSnapshot(includeScrollback: false)
            ))
        ))

        let snapshot = AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion,
            createdAt: 1_700_000_001,
            windows: [sessionWindowSnapshot(tabManager: restoredManager, windowId: oldRestoredWindowId)]
        )

        XCTAssertTrue(appDelegate.restorePreviousSessionSnapshot(snapshot, shouldActivate: false))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        let restoredWindowIds = mainWindowIds().subtracting(baselineWindowIds).subtracting([liveWindowId])
        XCTAssertEqual(restoredWindowIds.count, 1)
        let restoredWindowId = try XCTUnwrap(restoredWindowIds.first)
        let restoredWindowManager = try XCTUnwrap(appDelegate.tabManagerFor(windowId: restoredWindowId))

        XCTAssertTrue(
            appDelegate.reopenClosedHistoryItem(
                id: closedRecordId,
                preferredTabManager: liveManager,
                shouldActivate: false
            )
        )
        XCTAssertTrue(restoredWindowManager.tabs.contains { $0.customTitle == "Closed Previous Workspace" })
        XCTAssertFalse(liveManager.tabs.contains { $0.customTitle == "Closed Previous Workspace" })
    }

    func testFailedClosedWindowRestoreDoesNotRemapClosedPanelHistoryToDiscardedWindow() throws {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        ClosedItemHistoryStore.shared.removeAll()
        defer { ClosedItemHistoryStore.shared.removeAll() }

        let baselineWindowIds = mainWindowIds()
        defer {
            for windowId in mainWindowIds().subtracting(baselineWindowIds) {
                closeWindow(withId: windowId)
            }
        }

        let sourceManager = makeShortcutRoutingTabManager(autoWelcomeIfNeeded: false)
        let sourceWorkspace = try XCTUnwrap(sourceManager.selectedWorkspace)
        let originalWorkspaceId = sourceWorkspace.id
        var closedPanelSnapshot = try XCTUnwrap(sourceWorkspace.sessionSnapshot(includeScrollback: false).panels.first)
        closedPanelSnapshot.customTitle = "Panel From Failed Window"
        let closedPanelRecordId = UUID()
        ClosedItemHistoryStore.shared.push(ClosedItemHistoryRecord(
            id: closedPanelRecordId,
            closedAt: Date(timeIntervalSince1970: 1_700_000_000),
            entry: .panel(ClosedPanelHistoryEntry(
                workspaceId: originalWorkspaceId,
                paneId: UUID(),
                tabIndex: 0,
                snapshot: closedPanelSnapshot
            ))
        ))

        var invalidWorkspaceSnapshot = sourceWorkspace.sessionSnapshot(includeScrollback: false)
        var invalidPanelSnapshot = try XCTUnwrap(invalidWorkspaceSnapshot.panels.first)
        invalidPanelSnapshot.type = .markdown
        invalidPanelSnapshot.title = "Broken Markdown"
        invalidPanelSnapshot.customTitle = "Broken Markdown"
        invalidPanelSnapshot.terminal = nil
        invalidPanelSnapshot.browser = nil
        invalidPanelSnapshot.markdown = nil
        invalidPanelSnapshot.filePreview = nil
        invalidPanelSnapshot.rightSidebarTool = nil
        invalidWorkspaceSnapshot.panels = [invalidPanelSnapshot]
        invalidWorkspaceSnapshot.layout = .pane(SessionPaneLayoutSnapshot(
            panelIds: [invalidPanelSnapshot.id],
            selectedPanelId: invalidPanelSnapshot.id
        ))

        let originalWindowId = UUID()
        let failedWindowRecordId = UUID()
        let failedWindowSnapshot = SessionWindowSnapshot(
            windowId: originalWindowId,
            frame: nil,
            display: nil,
            tabManager: SessionTabManagerSnapshot(
                selectedWorkspaceIndex: 0,
                workspaces: [invalidWorkspaceSnapshot]
            ),
            sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: nil)
        )
        ClosedItemHistoryStore.shared.push(ClosedItemHistoryRecord(
            id: failedWindowRecordId,
            closedAt: Date(timeIntervalSince1970: 1_700_000_001),
            entry: .window(ClosedWindowHistoryEntry(
                windowId: originalWindowId,
                snapshot: failedWindowSnapshot,
                workspaceIds: [originalWorkspaceId]
            ))
        ))

        XCTAssertFalse(appDelegate.reopenClosedHistoryItem(
            id: failedWindowRecordId,
            shouldActivate: false
        ))

        let record = try XCTUnwrap(ClosedItemHistoryStore.shared.removeRecord(id: closedPanelRecordId)?.record)
        guard case .panel(let panelEntry) = record.entry else {
            return XCTFail("Expected closed panel history")
        }
        XCTAssertEqual(panelEntry.workspaceId, originalWorkspaceId)
        XCTAssertTrue(panelEntry.restoreInOriginalPane)
    }

    func testCmdShiftNPlansNewWindowFromEventWindowWithoutAddingWorkspace() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

#if DEBUG
        guard let event = makeKeyDownEvent(
            key: "n",
            modifiers: [.command, .shift],
            keyCode: 45,
            windowNumber: 906
        ) else {
            XCTFail("Failed to construct Cmd+Shift+N event")
            return
        }

        XCTAssertTrue(appDelegate.debugMatchesConfiguredShortcut(event: event, action: .newWindow))
        XCTAssertFalse(
            appDelegate.debugMatchesConfiguredShortcut(event: event, action: .newTab),
            "Cmd+Shift+N must stay routed to new-window behavior instead of add-workspace behavior"
        )

        let staleActiveWindowId = UUID()
        let eventWindowId = UUID()
        let shortcutSelection = selectShortcutRoutingContextAfterEventResolution(
            debugPreferredWindowId: nil,
            eventWindowId: eventWindowId,
            hasAddressableEventWindow: true,
            eventWindowAllowsFallback: false,
            keyWindowId: staleActiveWindowId,
            mainWindowId: staleActiveWindowId,
            activeManagerWindowId: staleActiveWindowId,
            fallbackWindowId: staleActiveWindowId
        )
        XCTAssertEqual(shortcutSelection.reason, .eventWindow)
        XCTAssertEqual(shortcutSelection.windowId, eventWindowId)
        XCTAssertNotEqual(
            shortcutSelection.windowId,
            staleActiveWindowId,
            "Cmd+Shift+N should create the new window from the event window, not a stale key or active window"
        )

        let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        let visibleFrame = NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let eventSourceFrame = NSRect(x: 180, y: 260, width: 560, height: 380)
        let initialGeometry = AppDelegate.resolvedMainWindowInitialGeometry(
            styleMask: styleMask,
            restoredFrame: nil,
            sourceFrame: eventSourceFrame,
            persistedGeometryFrame: nil
        )
        XCTAssertNil(initialGeometry.explicitFrame)

        let initialFrame = NSWindow.frameRect(forContentRect: initialGeometry.contentRect, styleMask: styleMask)
        let positionedFrame = AppDelegate.positionedNewMainWindowFrame(
            relativeToSourceFrame: eventSourceFrame,
            initialFrame: initialFrame,
            visibleFrame: visibleFrame
        )
        XCTAssertEqual(positionedFrame.width, eventSourceFrame.width, accuracy: 1)
        XCTAssertEqual(positionedFrame.height, eventSourceFrame.height, accuracy: 1)
        XCTAssertTrue(
            visibleFrame.contains(positionedFrame),
            "New window should be placed inside the source window display"
        )
#else
        XCTFail("Cmd+Shift+N routing helpers are only available in DEBUG")
#endif
    }

    func testAddWorkspaceInPreferredMainWindowUsesKeyWindowWhenObjectKeyLookupIsMismatched() {
#if DEBUG
        let staleActiveWindowId = UUID()
        let keyWindowId = UUID()

        let selection = AppDelegate.selectWorkspaceCreationContextAfterEventResolution(
            debugPreferredWindowId: nil,
            keyWindowId: keyWindowId,
            mainWindowId: staleActiveWindowId,
            orderedWindowIds: [staleActiveWindowId],
            fallbackCandidates: [
                AppDelegate.WorkspaceCreationContextCandidate(
                    windowId: staleActiveWindowId,
                    hasResolvedWindow: true
                ),
                AppDelegate.WorkspaceCreationContextCandidate(
                    windowId: keyWindowId,
                    hasResolvedWindow: true
                )
            ]
        )

        XCTAssertEqual(selection.windowId, keyWindowId)
        XCTAssertEqual(selection.reason, .keyWindow)
        XCTAssertNotEqual(
            selection.windowId,
            staleActiveWindowId,
            "Menu-driven add workspace should still route to the key window context when direct object-key lookup misses"
        )
#else
        XCTFail("Workspace creation context selection is only available in DEBUG")
#endif
    }

    func testAddWorkspaceInPreferredMainWindowPrunesOrphanedContextWithoutLiveWindow() {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        defer { AppDelegate.shared = previousAppDelegate }

        let orphanManager = makeShortcutRoutingTabManager(createInitialWorkspace: false)
#if DEBUG
        let orphanWindowId = appDelegate.registerMainWindowContextForTesting(tabManager: orphanManager)
#else
        XCTFail("registerMainWindowContextForTesting is only available in DEBUG")
        return
#endif

        XCTAssertNil(appDelegate.mainWindow(for: orphanWindowId), "Test precondition: orphaned context should not have a live window")

        let orphanCount = orphanManager.tabs.count
        XCTAssertNil(
            appDelegate.addWorkspaceInPreferredMainWindow(),
            "Workspace creation should refuse orphaned contexts with no live window"
        )
        XCTAssertEqual(orphanManager.tabs.count, orphanCount, "Orphaned manager must not receive a new workspace")
        XCTAssertNil(appDelegate.tabManagerFor(windowId: orphanWindowId), "Orphaned context should be pruned after failed resolution")
    }

    func testCustomCmdTNewWorkspacePrunesOrphanedContextWithoutLiveWindow() {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        defer { AppDelegate.shared = previousAppDelegate }

        let orphanManager = makeShortcutRoutingTabManager(createInitialWorkspace: false)
#if DEBUG
        let orphanWindowId = appDelegate.registerMainWindowContextForTesting(tabManager: orphanManager)
        let previousOpenNewMainWindowHandler = appDelegate.debugOpenNewMainWindowHandler
        var didRequestFallbackNewWindow = false
        appDelegate.debugOpenNewMainWindowHandler = { sender in
            XCTAssertNil(sender)
            didRequestFallbackNewWindow = true
        }
#else
        XCTFail("registerMainWindowContextForTesting is only available in DEBUG")
        return
#endif
        defer {
#if DEBUG
            appDelegate.debugOpenNewMainWindowHandler = previousOpenNewMainWindowHandler
#endif
        }

        XCTAssertNil(appDelegate.mainWindow(for: orphanWindowId), "Test precondition: orphaned context should not have a live window")

        let orphanCount = orphanManager.tabs.count
        let remappedCmdT = StoredShortcut(key: "t", command: true, shift: false, option: false, control: false)

        withTemporaryShortcut(action: .newTab, shortcut: remappedCmdT) {
            guard let event = makeKeyDownEvent(
                key: "t",
                modifiers: [.command],
                keyCode: 17, // kVK_ANSI_T
                windowNumber: 0
            ) else {
                XCTFail("Failed to construct remapped Cmd+T event")
                return
            }

#if DEBUG
            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
            XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
        }

        XCTAssertEqual(orphanManager.tabs.count, orphanCount, "Orphaned manager must not receive a new workspace from remapped Cmd+T")
        XCTAssertNil(appDelegate.tabManagerFor(windowId: orphanWindowId), "Remapped Cmd+T should prune the orphaned context after failed resolution")
#if DEBUG
        XCTAssertTrue(didRequestFallbackNewWindow, "Remapped Cmd+T should request a fallback new window after pruning the orphaned context")
#endif
    }

    func testCmdDigitRoutesToEventWindowWhenActiveManagerIsStale() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        guard let event = makeKeyDownEvent(
            key: "1",
            modifiers: [.command],
            keyCode: 18, // kVK_ANSI_1
            windowNumber: 902
        ) else {
            XCTFail("Failed to construct Cmd+1 event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugMatchesConfiguredShortcut(event: event, action: .selectWorkspaceByNumber))
#else
        XCTFail("debugMatchesConfiguredShortcut is only available in DEBUG")
#endif

        let staleActiveWindowId = UUID()
        let eventWindowId = UUID()
        let selection = selectShortcutRoutingContextAfterEventResolution(
            debugPreferredWindowId: nil,
            eventWindowId: eventWindowId,
            hasAddressableEventWindow: true,
            eventWindowAllowsFallback: false,
            keyWindowId: nil,
            mainWindowId: nil,
            activeManagerWindowId: staleActiveWindowId,
            fallbackWindowId: staleActiveWindowId
        )
        XCTAssertEqual(selection.reason, .eventWindow)
        XCTAssertEqual(selection.windowId, eventWindowId)
        XCTAssertNotEqual(selection.windowId, staleActiveWindowId, "Cmd+1 must not route through the stale active manager")

        var selectedIndexByWindowId = [
            staleActiveWindowId: 1,
            eventWindowId: 1,
        ]
        if selection.windowId == eventWindowId,
           let targetIndex = WorkspaceShortcutMapper.workspaceIndex(forDigit: 1, workspaceCount: 2) {
            selectedIndexByWindowId[eventWindowId] = targetIndex
        } else if selection.windowId == staleActiveWindowId,
                  let targetIndex = WorkspaceShortcutMapper.workspaceIndex(forDigit: 1, workspaceCount: 2) {
            selectedIndexByWindowId[staleActiveWindowId] = targetIndex
        }

        XCTAssertEqual(selectedIndexByWindowId[staleActiveWindowId], 1, "Cmd+1 must leave the stale active window unchanged")
        XCTAssertEqual(selectedIndexByWindowId[eventWindowId], 0, "Cmd+1 should select the first workspace in the event window")
    }

    func testCmdTRoutesToEventWindowWhenActiveManagerIsStale() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        guard let event = makeKeyDownEvent(
            key: "t",
            modifiers: [.command],
            keyCode: 17, // kVK_ANSI_T
            windowNumber: 903
        ) else {
            XCTFail("Failed to construct Cmd+T event")
            return
        }

        let staleActiveWindowId = UUID()
        let eventWindowId = UUID()

        withTemporaryShortcut(
            action: .toggleSidebar,
            shortcut: StoredShortcut(key: "t", command: true, shift: false, option: false, control: false)
        ) {
#if DEBUG
            XCTAssertTrue(appDelegate.debugMatchesConfiguredShortcut(event: event, action: .toggleSidebar))
#else
            XCTFail("debugMatchesConfiguredShortcut is only available in DEBUG")
#endif
        }

        let selection = selectShortcutRoutingContextAfterEventResolution(
            debugPreferredWindowId: nil,
            eventWindowId: eventWindowId,
            hasAddressableEventWindow: true,
            eventWindowAllowsFallback: false,
            keyWindowId: nil,
            mainWindowId: nil,
            activeManagerWindowId: staleActiveWindowId,
            fallbackWindowId: staleActiveWindowId
        )
        XCTAssertEqual(selection.reason, .eventWindow)
        XCTAssertEqual(selection.windowId, eventWindowId)
        XCTAssertNotEqual(selection.windowId, staleActiveWindowId, "Remapped Cmd+T must not route to the stale active window")

        var sidebarVisibilityByWindowId = [
            staleActiveWindowId: true,
            eventWindowId: true,
        ]
        if let selectedWindowId = selection.windowId,
           let isVisible = sidebarVisibilityByWindowId[selectedWindowId] {
            sidebarVisibilityByWindowId[selectedWindowId] = !isVisible
        }

        XCTAssertEqual(sidebarVisibilityByWindowId[staleActiveWindowId], true, "Cmd+T must leave the stale active window sidebar unchanged")
        XCTAssertEqual(sidebarVisibilityByWindowId[eventWindowId], false, "Cmd+T should toggle the event window sidebar")
    }

    func testCmdDRoutesSplitToEventWindowWhenKeyWindowIsDifferent() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        guard let event = makeKeyDownEvent(
            key: "d",
            modifiers: [.command],
            keyCode: 2, // kVK_ANSI_D
            windowNumber: 904
        ) else {
            XCTFail("Failed to construct Cmd+D event")
            return
        }

        withTemporaryShortcut(
            action: .toggleSidebar,
            shortcut: StoredShortcut(key: "d", command: true, shift: false, option: false, control: false)
        ) {
#if DEBUG
            XCTAssertTrue(appDelegate.debugMatchesConfiguredShortcut(event: event, action: .toggleSidebar))
#else
            XCTFail("debugMatchesConfiguredShortcut is only available in DEBUG")
#endif
        }

        let keyWindowId = UUID()
        let eventWindowId = UUID()
        let selection = selectShortcutRoutingContextAfterEventResolution(
            debugPreferredWindowId: nil,
            eventWindowId: eventWindowId,
            hasAddressableEventWindow: true,
            eventWindowAllowsFallback: false,
            keyWindowId: keyWindowId,
            mainWindowId: nil,
            activeManagerWindowId: keyWindowId,
            fallbackWindowId: keyWindowId
        )
        XCTAssertEqual(selection.reason, .eventWindow)
        XCTAssertEqual(selection.windowId, eventWindowId)
        XCTAssertNotEqual(selection.windowId, keyWindowId, "Cmd+D must not route to the stale key window")

        var sidebarVisibilityByWindowId = [
            keyWindowId: true,
            eventWindowId: true,
        ]
        if let selectedWindowId = selection.windowId,
           let isVisible = sidebarVisibilityByWindowId[selectedWindowId] {
            sidebarVisibilityByWindowId[selectedWindowId] = !isVisible
        }

        XCTAssertEqual(sidebarVisibilityByWindowId[keyWindowId], true, "Cmd+D must leave the stale key window unchanged")
        XCTAssertEqual(sidebarVisibilityByWindowId[eventWindowId], false, "Cmd+D should toggle the event window sidebar")
    }

    func testCmdDPropagatesWhenSplitRightShortcutIsCleared() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        withTemporaryShortcut(action: .splitRight, shortcut: .unbound) {
            guard let event = makeKeyDownEvent(
                key: "d",
                modifiers: [.command],
                keyCode: 2,
                windowNumber: 0
            ) else {
                XCTFail("Failed to construct Cmd+D event")
                return
            }

#if DEBUG
            XCTAssertFalse(
                appDelegate.debugMatchesConfiguredShortcut(event: event, action: .splitRight),
                "Cleared Cmd+D split shortcut should not match splitRight"
            )
            XCTAssertFalse(
                appDelegate.debugHandleCustomShortcut(event: event),
                "Cleared Cmd+D split shortcut should not be consumed by cmux"
            )
#else
            XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
        }
    }

    func testPerformSplitShortcutSplitsFocusedTerminalSurfaceWhenSelectedWorkspaceIsStale() {
        let focusedWorkspaceId = UUID()
        let focusedPanelId = UUID()
        let staleSelectedWorkspaceId = UUID()
        let staleSelectedPanelId = UUID()

        XCTAssertEqual(
            splitShortcutTarget(
                focusedTerminalWorkspaceId: focusedWorkspaceId,
                focusedTerminalPanelId: focusedPanelId,
                activeWorkspaceId: staleSelectedWorkspaceId,
                activeFocusedPanelId: staleSelectedPanelId
            ),
            SplitShortcutTarget(
                workspaceId: focusedWorkspaceId,
                panelId: focusedPanelId,
                source: .focusedTerminal
            ),
            "Split shortcuts must use the focused terminal surface before stale workspace selection"
        )

        XCTAssertEqual(
            splitShortcutTarget(
                focusedTerminalWorkspaceId: nil,
                focusedTerminalPanelId: nil,
                activeWorkspaceId: staleSelectedWorkspaceId,
                activeFocusedPanelId: staleSelectedPanelId
            ),
            SplitShortcutTarget(
                workspaceId: staleSelectedWorkspaceId,
                panelId: staleSelectedPanelId,
                source: .activeSelection
            ),
            "Split shortcuts should keep the active workspace fallback when no terminal responder owns the shortcut"
        )
    }

    func testOpenDiffViewerShortcutDefaultsToCmdCtrlDAndRoutesToSharedDiffPath() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        // Default is Cmd+Ctrl+Shift+D. Plain Cmd+Ctrl+D is reserved by macOS ("Look Up")
        // and never reaches the app, and the rest of the Cmd+D family is taken by split
        // actions; the default must be conflict-free so the recorder accepts it as-is.
        let cmdCtrlShiftD = StoredShortcut(key: "d", command: true, shift: true, option: false, control: true)
        XCTAssertEqual(KeyboardShortcutSettings.shortcut(for: .openDiffViewer), cmdCtrlShiftD)
        XCTAssertEqual(
            KeyboardShortcutSettings.Action.openDiffViewer.normalizedRecordedShortcutResult(cmdCtrlShiftD),
            .accepted(cmdCtrlShiftD),
            "Default Open Diff Viewer shortcut must not conflict with any other action"
        )
        XCTAssertTrue(
            KeyboardShortcutSettings.settingsVisibleActions.contains(.openDiffViewer),
            "Open Diff Viewer must be visible/editable in Settings → Keyboard Shortcuts"
        )

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }
        guard let targetWindow = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

        // Intercept the shared diff-open path so the dispatch test never spawns a
        // subprocess; we only assert the shortcut routes here.
        var openDiffViewerCount = 0
        appDelegate.debugOpenDiffViewerHandler = { openDiffViewerCount += 1 }
        defer { appDelegate.debugOpenDiffViewerHandler = nil }

        guard let event = makeKeyDownEvent(
            key: "d",
            modifiers: [.command, .control, .shift],
            keyCode: 2, // kVK_ANSI_D
            windowNumber: targetWindow.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+Ctrl+Shift+D event")
            return
        }

#if DEBUG
        XCTAssertTrue(
            appDelegate.debugHandleCustomShortcut(event: event),
            "Cmd+Ctrl+Shift+D should be consumed by the Open Diff Viewer shortcut"
        )
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
        XCTAssertEqual(
            openDiffViewerCount,
            1,
            "Cmd+Ctrl+Shift+D must route to the shared diff-open path (same path as the command palette)"
        )
    }

    func testCmdCtrlWPromptsBeforeClosingWindow() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

#if DEBUG
        guard let event = makeKeyDownEvent(
            key: "w",
            modifiers: [.command, .control],
            keyCode: 13,
            windowNumber: 601
        ) else {
            XCTFail("Failed to construct Cmd+Ctrl+W event")
            return
        }

        XCTAssertTrue(appDelegate.debugMatchesConfiguredShortcut(event: event, action: .closeWindow))

        let targetWindowId = UUID()
        var promptedWindowId: UUID?
        var closedWindowId: UUID?

        XCTAssertTrue(
            performConfirmedCloseWindowShortcut(
                targetWindow: targetWindowId,
                confirm: { candidate in
                    promptedWindowId = candidate
                    return false
                },
                close: { closedWindowId = $0 }
            )
        )

        XCTAssertEqual(promptedWindowId, targetWindowId, "Cmd+Ctrl+W should prompt for the target main window")
        XCTAssertNil(closedWindowId, "Cancelling the confirmation should keep the window open")
#else
        XCTFail("debugMatchesConfiguredShortcut is only available in DEBUG")
#endif
    }

    func testCmdCtrlWClosesWindowAfterConfirmation() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

#if DEBUG
        guard let event = makeKeyDownEvent(
            key: "w",
            modifiers: [.command, .control],
            keyCode: 13,
            windowNumber: 602
        ) else {
            XCTFail("Failed to construct Cmd+Ctrl+W event")
            return
        }

        XCTAssertTrue(appDelegate.debugMatchesConfiguredShortcut(event: event, action: .closeWindow))

        let targetWindowId = UUID()
        var confirmedWindowId: UUID?
        var closedWindowId: UUID?

        XCTAssertTrue(
            performConfirmedCloseWindowShortcut(
                targetWindow: targetWindowId,
                confirm: { candidate in
                    confirmedWindowId = candidate
                    return true
                },
                close: { closedWindowId = $0 }
            )
        )

        XCTAssertEqual(confirmedWindowId, targetWindowId, "Cmd+Ctrl+W should confirm the target main window")
        XCTAssertEqual(closedWindowId, targetWindowId, "Confirming Cmd+Ctrl+W should close the window")
#else
        XCTFail("debugMatchesConfiguredShortcut is only available in DEBUG")
#endif
    }

    func testCmdWClosesWindowWhenClosingLastSurfaceInLastWorkspace() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

#if DEBUG
        guard let event = makeKeyDownEvent(
            key: "w",
            modifiers: [.command],
            keyCode: 13,
            windowNumber: 605
        ) else {
            XCTFail("Failed to construct Cmd+W event")
            return
        }

        XCTAssertTrue(appDelegate.debugMatchesConfiguredShortcut(event: event, action: .closeTab))
        XCTAssertTrue(
            shouldMarkExplicitCloseForLastSurfaceShortcut(
                closesWorkspaceOnLastSurfaceShortcut: true,
                panelCount: 1,
                panelExists: true
            ),
            "Cmd+W should mark the final surface as an explicit close when the preference closes workspaces"
        )
        XCTAssertEqual(
            workspaceCloseDestination(workspaceCount: 1),
            .window,
            "Closing the last workspace after the last surface should close the window"
        )
#else
        XCTFail("debugMatchesConfiguredShortcut is only available in DEBUG")
#endif
    }

    func testCmdWKeepsLastSurfaceWorkspaceOpenWhenKeepWorkspaceOpenPreferenceIsEnabled() throws {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

#if DEBUG
        guard let event = makeKeyDownEvent(
            key: "w",
            modifiers: [.command],
            keyCode: 13,
            windowNumber: 606
        ) else {
            XCTFail("Failed to construct Cmd+W event")
            return
        }

        XCTAssertTrue(appDelegate.debugMatchesConfiguredShortcut(event: event, action: .closeTab))
        XCTAssertFalse(
            shouldMarkExplicitCloseForLastSurfaceShortcut(
                closesWorkspaceOnLastSurfaceShortcut: false,
                panelCount: 1,
                panelExists: true
            ),
            "Cmd+W should leave the final surface as a normal close when the preference keeps workspaces open"
        )
#else
        XCTFail("debugMatchesConfiguredShortcut is only available in DEBUG")
#endif
    }

    func testCloseShortcutsTargetFocusedWindowWhenEventWindowMetadataIsStale() {
        assertCloseShortcutsTargetFocusedWindowWhenEventWindowMetadataIsStale([
            (actionName: "Cmd+W", modifiers: [.command], expectedAction: .closeTab),
            (actionName: "Cmd+Shift+W", modifiers: [.command, .shift], expectedAction: .closeWorkspace),
        ])
    }

    func testRemappedCloseTabDoesNotLetCmdWReachGhosttyCloseSurfaceFallback() throws {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        guard let ghosttyConfig = GhosttyApp.shared.config else {
            XCTFail("Expected loaded Ghostty config")
            return
        }

        let routingWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 160, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        routingWindow.isReleasedWhenClosed = false
        let routingManager = makeShortcutRoutingTabManager()
#if DEBUG
        appDelegate.registerMainWindowContextForTesting(tabManager: routingManager, window: routingWindow)
#endif
        routingWindow.makeKeyAndOrderFront(nil)
        defer {
            routingWindow.orderOut(nil)
            routingWindow.close()
        }

        let remappedCloseTab = StoredShortcut(
            key: "w",
            command: true,
            shift: false,
            option: true,
            control: false
        )

        withTemporaryShortcut(action: .closeTab, shortcut: remappedCloseTab) {
            guard let staleCmdW = makeKeyDownEvent(
                key: "w",
                modifiers: [.command],
                keyCode: 13,
                windowNumber: routingWindow.windowNumber
            ) else {
                XCTFail("Failed to construct Cmd+W event")
                return
            }

            XCTAssertFalse(
                KeyboardShortcutSettings.shortcut(for: .closeTab).matches(event: staleCmdW),
                "After Close Tab is remapped, Cmd+W must not match the cmux Close Tab action"
            )
            if ghosttyConfigKeyIsBinding(ghosttyConfig, key: "w", modifiers: [.command], keyCode: 13) {
                XCTFail("After Close Tab is remapped, Ghostty must not retain its super+w close_surface fallback")
                return
            }
            XCTAssertTrue(
                appDelegate.shouldSuppressStaleCmuxMenuShortcut(event: staleCmdW),
                "A remapped-away Cmd+W Close Tab shortcut must suppress stale menu fallback"
            )

            guard let remappedCmdOptionW = makeKeyDownEvent(
                key: "w",
                modifiers: [.command, .option],
                keyCode: 13,
                windowNumber: routingWindow.windowNumber
            ) else {
                XCTFail("Failed to construct Cmd+Option+W event")
                return
            }

            XCTAssertTrue(
                KeyboardShortcutSettings.shortcut(for: .closeTab).matches(event: remappedCmdOptionW),
                "The remapped Cmd+Option+W shortcut should match the cmux Close Tab action"
            )
#if DEBUG
            XCTAssertTrue(
                appDelegate.debugHandleShortcutMonitorEvent(event: remappedCmdOptionW, preferredWindow: routingWindow),
                "The remapped Cmd+Option+W shortcut should trigger the cmux Close Tab action"
            )
#else
            XCTFail("debugHandleShortcutMonitorEvent is only available in DEBUG")
#endif
        }
    }

    func testBrowserPopupPanelCloseShortcutFollowsCloseTabRemap() throws {
        let defaultCloseTab = KeyboardShortcutSettings.Action.closeTab.defaultShortcut
        let previousMainMenu = NSApp.mainMenu
        let menuProbe = MenuActionProbe()
        let staleMenu = NSMenu(title: "Stale Close Tab")
        let staleCloseItem = NSMenuItem(
            title: "Close Tab",
            action: #selector(MenuActionProbe.perform(_:)),
            keyEquivalent: defaultCloseTab.menuItemKeyEquivalent ?? ""
        )
        staleCloseItem.keyEquivalentModifierMask = defaultCloseTab.modifierFlags
        staleCloseItem.target = menuProbe
        staleMenu.addItem(staleCloseItem)
        NSApp.mainMenu = staleMenu
        defer { NSApp.mainMenu = previousMainMenu }

        let remappedCloseTab = StoredShortcut(
            key: defaultCloseTab.key,
            command: defaultCloseTab.command,
            shift: defaultCloseTab.shift,
            option: !defaultCloseTab.option,
            control: defaultCloseTab.control,
            keyCode: defaultCloseTab.keyCode
        )

        withTemporaryShortcut(action: .closeTab, shortcut: remappedCloseTab) {
            let panel = BrowserPopupPanel(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            panel.isReleasedWhenClosed = false
            panel.identifier = NSUserInterfaceItemIdentifier("cmux.browser-popup")
            panel.orderFront(nil)
            defer { panel.orderOut(nil) }

            guard let staleDefaultCloseTab = makeKeyDownEvent(
                shortcut: defaultCloseTab,
                windowNumber: panel.windowNumber
            ) else {
                XCTFail("Failed to construct default Close Tab event")
                return
            }

            XCTAssertTrue(
                panel.performKeyEquivalent(with: staleDefaultCloseTab),
                "After Close Tab is remapped, the default Close Tab shortcut should be consumed without closing a browser popup"
            )
            XCTAssertTrue(panel.isVisible, "Remapped-away default Close Tab shortcut should leave the browser popup open")
            XCTAssertEqual(menuProbe.callCount, 0, "Stale Close Tab menu items must not close the parent browser tab")

            guard let remappedCloseTabEvent = makeKeyDownEvent(
                shortcut: remappedCloseTab,
                windowNumber: panel.windowNumber
            ) else {
                XCTFail("Failed to construct remapped Close Tab event")
                return
            }

            XCTAssertTrue(
                panel.performKeyEquivalent(with: remappedCloseTabEvent),
                "The configured Close Tab shortcut should close the browser popup"
            )
            XCTAssertFalse(panel.isVisible, "Remapped Close Tab shortcut should close the browser popup")
        }
    }

    func testBrowserPopupPanelCloseShortcutSupportsChordedCloseTabRemap() throws {
        guard AppDelegate.shared != nil else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let chordedCloseTab = StoredShortcut(
            key: "b",
            command: false,
            shift: false,
            option: false,
            control: true,
            keyCode: 11,
            chordKey: "n",
            chordCommand: false,
            chordShift: false,
            chordOption: false,
            chordControl: false,
            chordKeyCode: 45
        )

        withTemporaryShortcut(action: .closeTab, shortcut: chordedCloseTab) {
            let panel = BrowserPopupPanel(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            panel.isReleasedWhenClosed = false
            panel.identifier = NSUserInterfaceItemIdentifier("cmux.browser-popup")
            panel.orderFront(nil)
            defer { panel.orderOut(nil) }

            guard let prefixEvent = makeKeyDownEvent(
                key: "b",
                modifiers: [.control],
                keyCode: 11,
                windowNumber: panel.windowNumber
            ) else {
                XCTFail("Failed to construct Ctrl+B prefix event")
                return
            }

            guard let suffixEvent = makeKeyDownEvent(
                key: "n",
                modifiers: [],
                keyCode: 45,
                windowNumber: panel.windowNumber
            ) else {
                XCTFail("Failed to construct N suffix event")
                return
            }

            XCTAssertTrue(
                panel.performKeyEquivalent(with: prefixEvent),
                "A chorded Close Tab prefix should be consumed without closing the browser popup"
            )
            XCTAssertTrue(panel.isVisible, "Chord prefix alone should leave the browser popup open")

            XCTAssertTrue(
                panel.performKeyEquivalent(with: suffixEvent),
                "The chorded Close Tab suffix should close the browser popup"
            )
            XCTAssertFalse(panel.isVisible, "Chorded Close Tab shortcut should close the browser popup")
        }
    }

    func testBrowserPopupPanelLeavesDefaultCloseTabShortcutAloneWhenCloseTabIsUnbound() throws {
        let defaultCloseTab = KeyboardShortcutSettings.Action.closeTab.defaultShortcut
        withTemporaryShortcut(action: .closeTab, shortcut: .unbound) {
            let panel = BrowserPopupPanel(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            panel.isReleasedWhenClosed = false
            panel.identifier = NSUserInterfaceItemIdentifier("cmux.browser-popup")
            panel.orderFront(nil)
            defer { panel.orderOut(nil) }

            guard let defaultCloseTabEvent = makeKeyDownEvent(
                shortcut: defaultCloseTab,
                windowNumber: panel.windowNumber
            ) else {
                XCTFail("Failed to construct default Close Tab event")
                return
            }

            XCTAssertTrue(
                panel.performKeyEquivalent(with: defaultCloseTabEvent),
                "Unbinding Close Tab should consume the default Close Tab shortcut without closing a browser popup"
            )
            XCTAssertTrue(panel.isVisible, "Unbound Close Tab should leave the browser popup open")
        }
    }

    func testCmdWTargetsAuxiliaryWindowInsteadOfMainTerminalPanel() throws {
        struct CloseShortcutWindowProbe: Equatable {
            let id: UUID
            let ownsCloseShortcut: Bool
        }

        let terminalPanelWindow = CloseShortcutWindowProbe(id: UUID(), ownsCloseShortcut: false)
        let auxiliaryWindow = CloseShortcutWindowProbe(id: UUID(), ownsCloseShortcut: true)

        guard let event = makeKeyDownEvent(
            key: "w",
            modifiers: [.command],
            keyCode: 13,
            windowNumber: 0
        ) else {
            XCTFail("Failed to construct Cmd+W event")
            return
        }

        XCTAssertTrue(KeyboardShortcutSettings.shortcut(for: .closeTab).matches(event: event))
        XCTAssertEqual(
            selectAuxiliaryCloseShortcutTarget(
                debugWindow: auxiliaryWindow,
                keyWindow: nil,
                mainWindow: terminalPanelWindow,
                eventWindow: nil,
                ownsCloseShortcut: { $0.ownsCloseShortcut }
            ),
            auxiliaryWindow,
            "Cmd+W should target the auxiliary window before the active terminal manager"
        )
    }

    func testCmdPhysicalIWithDvorakCharactersDoesNotTriggerShowNotifications() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        withTemporaryShortcut(action: .showNotifications) {
            // Dvorak: physical ANSI "I" key can produce the character "c".
            // This should behave like Cmd+C (copy), not match the Cmd+I app shortcut.
            let event = makeKeyEvent(
                modifierFlags: [.command],
                characters: "c",
                charactersIgnoringModifiers: "c",
                keyCode: 34 // kVK_ANSI_I
            )

#if DEBUG
            XCTAssertFalse(appDelegate.debugMatchesConfiguredShortcut(event: event, action: .showNotifications))
#else
            XCTFail("debugMatchesConfiguredShortcut is only available in DEBUG")
#endif
        }
    }

    func testMinimalModeUsesZeroTopSafeAreaForMainWindowContentView() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let defaults = UserDefaults.standard
        let savedMode = defaults.object(forKey: WorkspacePresentationModeSettings.modeKey)
        let savedLegacyTitlebar = defaults.object(forKey: WorkspaceTitlebarSettings.showTitlebarKey)
        defaults.set(WorkspacePresentationModeSettings.Mode.minimal.rawValue, forKey: WorkspacePresentationModeSettings.modeKey)
        defaults.removeObject(forKey: WorkspaceTitlebarSettings.showTitlebarKey)
        defer {
            restoreDefaultsValue(savedMode, forKey: WorkspacePresentationModeSettings.modeKey, defaults: defaults)
            restoreDefaultsValue(savedLegacyTitlebar, forKey: WorkspaceTitlebarSettings.showTitlebarKey, defaults: defaults)
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let contentView = window.contentView else {
            XCTFail("Expected main window content view")
            return
        }

        contentView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertEqual(
            contentView.safeAreaInsets.top,
            0,
            accuracy: 0.5,
            "Minimal mode should not leave a top safe-area inset in the main window content view"
        )
    }

    func testMinimalModeTitlebarPaddingOnlyCancelsHostingSafeArea() {
        XCTAssertEqual(
            ContentView.effectiveTitlebarPadding(
                isMinimalMode: false,
                isFullScreen: false,
                titlebarPadding: 32,
                hostingSafeAreaTop: 0
            ),
            WindowChromeMetrics.appTitlebarHeight,
            accuracy: 0.5,
            "Standard mode should align terminal content with cmux's visual titlebar height even when AppKit reports a taller native titlebar zone"
        )

        XCTAssertEqual(
            ContentView.effectiveTitlebarPadding(
                isMinimalMode: true,
                isFullScreen: true,
                titlebarPadding: 32,
                hostingSafeAreaTop: 32
            ),
            0,
            accuracy: 0.5,
            "Fullscreen minimal mode should not offset for a titlebar"
        )

        XCTAssertEqual(
            ContentView.effectiveTitlebarPadding(
                isMinimalMode: true,
                isFullScreen: false,
                titlebarPadding: 32,
                hostingSafeAreaTop: 0
            ),
            0,
            accuracy: 0.5,
            "Manually hosted minimal windows already have zero safe area, so the Bonsplit strip must not be pulled offscreen"
        )

        XCTAssertEqual(
            ContentView.effectiveTitlebarPadding(
                isMinimalMode: true,
                isFullScreen: false,
                titlebarPadding: 32,
                hostingSafeAreaTop: 28
            ),
            -28,
            accuracy: 0.5,
            "SwiftUI WindowGroup windows still need their native titlebar safe area cancelled"
        )
    }

    func testNotificationsPopoverVisibilityIsScopedByWindow() {
        let state = NotificationsPopoverVisibilityState.shared
        state.resetForTesting()
        defer { state.resetForTesting() }

        let firstPopover = NSObject()
        let secondPopover = NSObject()

        state.setShown(true, source: firstPopover, windowNumber: 101)
        XCTAssertTrue(state.isShown)
        XCTAssertTrue(state.isShown(in: 101))
        XCTAssertFalse(state.isShown(in: 202))

        state.setShown(true, source: secondPopover, windowNumber: 202)
        XCTAssertTrue(state.isShown(in: 101))
        XCTAssertTrue(state.isShown(in: 202))

        state.setShown(false, source: firstPopover)
        XCTAssertTrue(state.isShown)
        XCTAssertFalse(state.isShown(in: 101))
        XCTAssertTrue(state.isShown(in: 202))

        state.setShown(false, source: secondPopover)
        XCTAssertFalse(state.isShown)
        XCTAssertFalse(state.isShown(in: 101))
        XCTAssertFalse(state.isShown(in: 202))
    }

    func testWindowChromeTitlebarHeightClampsToSharedRange() {
        [WindowChromeMetrics.appTitlebarHeight, WindowChromeMetrics.bonsplitTabBarHeight, WindowChromeMetrics.secondaryTitlebarHeight, MinimalModeChromeMetrics.titlebarHeight, RightSidebarChromeMetrics.titlebarHeight, RightSidebarChromeMetrics.secondaryBarHeight].forEach { XCTAssertEqual($0, WindowChromeMetrics.sharedChromeBarHeight) }
        XCTAssertEqual(WindowChromeMetrics.clampedTitlebarHeight(12), 28)
        XCTAssertEqual(WindowChromeMetrics.clampedTitlebarHeight(32), 32)
        XCTAssertEqual(WindowChromeMetrics.clampedTitlebarHeight(96), 72)
    }

    func testRightSidebarHeaderChromeUsesSharedButtonsWithCompactIcons() {
        let titlebarConfig = TitlebarControlsStyle.classic.config

        XCTAssertEqual(HeaderChromeControlMetrics.buttonSize, titlebarConfig.buttonSize, accuracy: 0.001)
        XCTAssertEqual(HeaderChromeControlMetrics.iconSize, titlebarConfig.iconSize, accuracy: 0.001)
        XCTAssertEqual(HeaderChromeControlMetrics.cornerRadius, titlebarConfig.buttonCornerRadius, accuracy: 0.001)
        XCTAssertEqual(RightSidebarChromeMetrics.headerControlSize, titlebarConfig.buttonSize, accuracy: 0.001)
        XCTAssertEqual(RightSidebarChromeMetrics.headerIconSize, 10, accuracy: 0.001)
        XCTAssertEqual(
            RightSidebarChromeMetrics.headerIconFrameSize,
            RightSidebarChromeMetrics.headerIconSize,
            accuracy: 0.001
        )
        XCTAssertLessThan(RightSidebarChromeMetrics.headerIconSize, titlebarConfig.iconSize)
        XCTAssertLessThan(
            RightSidebarChromeMetrics.headerIconFrameSize,
            HeaderChromeIconStyle.iconFrameSize(forIconSize: titlebarConfig.iconSize)
        )
        XCTAssertEqual(RightSidebarChromeMetrics.headerControlCornerRadius, titlebarConfig.buttonCornerRadius, accuracy: 0.001)
        XCTAssertEqual(RightSidebarChromeMetrics.controlHeight, RightSidebarChromeMetrics.headerControlSize, accuracy: 0.001)
        XCTAssertEqual(RightSidebarChromeMetrics.barVerticalPadding, 4, accuracy: 0.001)
        XCTAssertEqual(RightSidebarChromeMetrics.headerControlCenterAlignmentAdjustment, 0, accuracy: 0.001)
    }

    func testRightSidebarPillChromeUsesHeaderIconColorAndWeight() {
        XCTAssertEqual(RightSidebarChromeControlStyle.iconWeight, HeaderChromeIconStyle.weight)
        XCTAssertEqual(RightSidebarChromeControlStyle.labelWeight, HeaderChromeIconStyle.weight)
        XCTAssertEqual(RightSidebarChromeControlStyle.modeIconSize, 11, accuracy: 0.001)
        XCTAssertEqual(RightSidebarChromeControlStyle.secondaryIconSize, 10, accuracy: 0.001)
        XCTAssertEqual(RightSidebarChromeControlStyle.labelSize, 11, accuracy: 0.001)
        XCTAssertEqual(
            RightSidebarChromeControlStyle.foregroundOpacity(isSelected: false, isHovered: false),
            HeaderChromeIconStyle.foregroundOpacity(isHovering: false, isPressed: false),
            accuracy: 0.001
        )
        XCTAssertEqual(
            RightSidebarChromeControlStyle.foregroundOpacity(isSelected: false, isHovered: true),
            HeaderChromeIconStyle.foregroundOpacity(isHovering: true, isPressed: false),
            accuracy: 0.001
        )
        XCTAssertEqual(
            RightSidebarChromeControlStyle.foregroundOpacity(isSelected: true, isHovered: false),
            HeaderChromeIconStyle.pressedOpacity,
            accuracy: 0.001
        )
        XCTAssertEqual(
            RightSidebarChromeControlStyle.foregroundOpacity(isSelected: false, isHovered: true, isEnabled: false),
            HeaderChromeIconStyle.disabledOpacity,
            accuracy: 0.001
        )
    }

    func testMinimalModeCollapsedSidebarResyncsTrafficLightInsetAfterNewWorkspaceCreation() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let defaults = UserDefaults.standard
        let savedMode = defaults.object(forKey: WorkspacePresentationModeSettings.modeKey)
        defaults.set(WorkspacePresentationModeSettings.Mode.minimal.rawValue, forKey: WorkspacePresentationModeSettings.modeKey)
        defer {
            restoreDefaultsValue(savedMode, forKey: WorkspacePresentationModeSettings.modeKey, defaults: defaults)
        }

        let snapshot = SessionWindowSnapshot(
            frame: nil,
            display: nil,
            tabManager: SessionTabManagerSnapshot(selectedWorkspaceIndex: nil, workspaces: []),
            sidebar: SessionSidebarSnapshot(isVisible: false, selection: .tabs, width: nil)
        )
        let windowId = appDelegate.createMainWindow(sessionWindowSnapshot: snapshot)
        defer { closeWindow(withId: windowId) }

        guard let manager = appDelegate.tabManagerFor(windowId: windowId) else {
            XCTFail("Expected tab manager for created window")
            return
        }

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        XCTAssertEqual(appDelegate.sidebarVisibility(windowId: windowId), false)

        guard let sourceWorkspace = manager.selectedWorkspace else {
            XCTFail("Expected selected workspace")
            return
        }

        // Recreate the regression shape: the window chrome state says minimal +
        // collapsed sidebar, but the selected workspace's live Bonsplit inset is stale.
        sourceWorkspace.bonsplitController.configuration.appearance.tabBarLeadingInset = 0

        guard let newWorkspaceId = appDelegate.addWorkspaceInPreferredMainWindow(debugSource: "test.issue2737") else {
            XCTFail("Expected workspace creation to route to the test window")
            return
        }

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        guard let newWorkspace = manager.tabs.first(where: { $0.id == newWorkspaceId }) else {
            XCTFail("Expected new workspace in test window")
            return
        }

        XCTAssertEqual(
            newWorkspace.bonsplitController.configuration.appearance.tabBarLeadingInset,
            80,
            accuracy: 0.5,
            "New minimal-mode workspaces should reserve traffic-light space immediately even when the source workspace inset is stale"
        )
    }

    func testMinimalModeCollapsedSidebarSeedsTrafficLightInsetOnNewWindowCreation() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let defaults = UserDefaults.standard
        let savedMode = defaults.object(forKey: WorkspacePresentationModeSettings.modeKey)
        defaults.set(WorkspacePresentationModeSettings.Mode.minimal.rawValue, forKey: WorkspacePresentationModeSettings.modeKey)
        defer {
            restoreDefaultsValue(savedMode, forKey: WorkspacePresentationModeSettings.modeKey, defaults: defaults)
        }

        // Simulate the new-window flow: createMainWindow with a snapshot that forces
        // sidebar collapsed. The initial workspace is created inside TabManager.init,
        // before ContentView.onAppear can run syncTrafficLightInset — so the seed in
        // createMainWindow is what protects the first render.
        let snapshot = SessionWindowSnapshot(
            frame: nil,
            display: nil,
            tabManager: SessionTabManagerSnapshot(selectedWorkspaceIndex: nil, workspaces: []),
            sidebar: SessionSidebarSnapshot(isVisible: false, selection: .tabs, width: nil)
        )
        let windowId = appDelegate.createMainWindow(sessionWindowSnapshot: snapshot)
        defer { closeWindow(withId: windowId) }

        guard let manager = appDelegate.tabManagerFor(windowId: windowId) else {
            XCTFail("Expected tab manager for created window")
            return
        }

        XCTAssertEqual(appDelegate.sidebarVisibility(windowId: windowId), false)

        guard let initialWorkspace = manager.selectedWorkspace else {
            XCTFail("Expected selected workspace in fresh window")
            return
        }

        // No RunLoop spin before reading the inset — the seed must be applied by the
        // time createMainWindow returns, not lazily after onAppear runs.
        XCTAssertEqual(
            initialWorkspace.bonsplitController.configuration.appearance.tabBarLeadingInset,
            80,
            accuracy: 0.5,
            "New minimal-mode windows with collapsed sidebar should reserve traffic-light space on the initial workspace before first render"
        )
    }

    func testAttachUpdateAccessoryHidesTitlebarAccessoryWhenMinimalModeEnabled() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let defaults = UserDefaults.standard
        let savedMode = defaults.object(forKey: WorkspacePresentationModeSettings.modeKey)
        let savedLegacyTitlebar = defaults.object(forKey: WorkspaceTitlebarSettings.showTitlebarKey)
        defaults.set(WorkspacePresentationModeSettings.Mode.standard.rawValue, forKey: WorkspacePresentationModeSettings.modeKey)
        defaults.removeObject(forKey: WorkspaceTitlebarSettings.showTitlebarKey)
        defer {
            restoreDefaultsValue(savedMode, forKey: WorkspacePresentationModeSettings.modeKey, defaults: defaults)
            restoreDefaultsValue(savedLegacyTitlebar, forKey: WorkspaceTitlebarSettings.showTitlebarKey, defaults: defaults)
        }

        let window = makeRegisteredShortcutRoutingWindow(id: UUID())
        defer { closeTestWindow(window) }

        appDelegate.attachUpdateAccessory(to: window)

        let titlebarAccessory: () -> NSTitlebarAccessoryViewController? = {
            window.titlebarAccessoryViewControllers.first {
                $0.view.identifier?.rawValue == "cmux.titlebarControls"
            }
        }

        guard let initialAccessory = titlebarAccessory() else {
            XCTFail("Expected visible-titlebar mode to attach the titlebar accessory")
            return
        }
        XCTAssertFalse(initialAccessory.isHidden, "Expected visible-titlebar mode to show the titlebar accessory")

        defaults.set(WorkspacePresentationModeSettings.Mode.minimal.rawValue, forKey: WorkspacePresentationModeSettings.modeKey)
        appDelegate.attachUpdateAccessory(to: window)

        guard let minimalAccessory = titlebarAccessory() else {
            XCTFail("Minimal mode should keep a hidden titlebar accessory so shortcut-driven popovers still have a controller")
            return
        }
        XCTAssertTrue(minimalAccessory.isHidden, "Minimal mode should hide titlebar accessories")
        XCTAssertTrue(minimalAccessory.view.isHidden, "Minimal mode should hide the titlebar accessory view")
        XCTAssertEqual(minimalAccessory.view.alphaValue, 0, accuracy: 0.01)
    }

    func testWorkspaceButtonFadeModeDefaultsOffWhenTitlebarVisible() {
        let defaults = UserDefaults.standard
        let savedMode = defaults.object(forKey: WorkspaceButtonFadeSettings.modeKey)
        let savedTitlebarVisibility = defaults.object(forKey: WorkspaceTitlebarSettings.showTitlebarKey)
        let savedLegacyTitlebarMode = defaults.object(forKey: WorkspaceButtonFadeSettings.legacyTitlebarControlsVisibilityModeKey)
        let savedLegacyPaneMode = defaults.object(forKey: WorkspaceButtonFadeSettings.legacyPaneTabBarControlsVisibilityModeKey)
        defer {
            restoreDefaultsValue(savedMode, forKey: WorkspaceButtonFadeSettings.modeKey, defaults: defaults)
            restoreDefaultsValue(savedTitlebarVisibility, forKey: WorkspaceTitlebarSettings.showTitlebarKey, defaults: defaults)
            restoreDefaultsValue(savedLegacyTitlebarMode, forKey: WorkspaceButtonFadeSettings.legacyTitlebarControlsVisibilityModeKey, defaults: defaults)
            restoreDefaultsValue(savedLegacyPaneMode, forKey: WorkspaceButtonFadeSettings.legacyPaneTabBarControlsVisibilityModeKey, defaults: defaults)
        }

        defaults.removeObject(forKey: WorkspaceButtonFadeSettings.modeKey)
        defaults.removeObject(forKey: WorkspaceButtonFadeSettings.legacyTitlebarControlsVisibilityModeKey)
        defaults.removeObject(forKey: WorkspaceButtonFadeSettings.legacyPaneTabBarControlsVisibilityModeKey)
        defaults.set(true, forKey: WorkspaceTitlebarSettings.showTitlebarKey)

        WorkspaceButtonFadeSettings.initializeStoredModeIfNeeded(defaults: defaults)

        XCTAssertEqual(
            defaults.string(forKey: WorkspaceButtonFadeSettings.modeKey),
            WorkspaceButtonFadeSettings.Mode.disabled.rawValue
        )
    }

    func testWorkspaceButtonFadeModeDefaultsOnWhenTitlebarHidden() {
        let defaults = UserDefaults.standard
        let savedMode = defaults.object(forKey: WorkspaceButtonFadeSettings.modeKey)
        let savedTitlebarVisibility = defaults.object(forKey: WorkspaceTitlebarSettings.showTitlebarKey)
        let savedLegacyTitlebarMode = defaults.object(forKey: WorkspaceButtonFadeSettings.legacyTitlebarControlsVisibilityModeKey)
        let savedLegacyPaneMode = defaults.object(forKey: WorkspaceButtonFadeSettings.legacyPaneTabBarControlsVisibilityModeKey)
        defer {
            restoreDefaultsValue(savedMode, forKey: WorkspaceButtonFadeSettings.modeKey, defaults: defaults)
            restoreDefaultsValue(savedTitlebarVisibility, forKey: WorkspaceTitlebarSettings.showTitlebarKey, defaults: defaults)
            restoreDefaultsValue(savedLegacyTitlebarMode, forKey: WorkspaceButtonFadeSettings.legacyTitlebarControlsVisibilityModeKey, defaults: defaults)
            restoreDefaultsValue(savedLegacyPaneMode, forKey: WorkspaceButtonFadeSettings.legacyPaneTabBarControlsVisibilityModeKey, defaults: defaults)
        }

        defaults.removeObject(forKey: WorkspaceButtonFadeSettings.modeKey)
        defaults.removeObject(forKey: WorkspaceButtonFadeSettings.legacyTitlebarControlsVisibilityModeKey)
        defaults.removeObject(forKey: WorkspaceButtonFadeSettings.legacyPaneTabBarControlsVisibilityModeKey)
        defaults.set(false, forKey: WorkspaceTitlebarSettings.showTitlebarKey)

        WorkspaceButtonFadeSettings.initializeStoredModeIfNeeded(defaults: defaults)

        XCTAssertEqual(
            defaults.string(forKey: WorkspaceButtonFadeSettings.modeKey),
            WorkspaceButtonFadeSettings.Mode.enabled.rawValue
        )
    }

    func testWorkspaceButtonFadeModeMigratesLegacyHoverVisibilityPreference() {
        let defaults = UserDefaults.standard
        let savedMode = defaults.object(forKey: WorkspaceButtonFadeSettings.modeKey)
        let savedTitlebarVisibility = defaults.object(forKey: WorkspaceTitlebarSettings.showTitlebarKey)
        let savedLegacyTitlebarMode = defaults.object(forKey: WorkspaceButtonFadeSettings.legacyTitlebarControlsVisibilityModeKey)
        let savedLegacyPaneMode = defaults.object(forKey: WorkspaceButtonFadeSettings.legacyPaneTabBarControlsVisibilityModeKey)
        defer {
            restoreDefaultsValue(savedMode, forKey: WorkspaceButtonFadeSettings.modeKey, defaults: defaults)
            restoreDefaultsValue(savedTitlebarVisibility, forKey: WorkspaceTitlebarSettings.showTitlebarKey, defaults: defaults)
            restoreDefaultsValue(savedLegacyTitlebarMode, forKey: WorkspaceButtonFadeSettings.legacyTitlebarControlsVisibilityModeKey, defaults: defaults)
            restoreDefaultsValue(savedLegacyPaneMode, forKey: WorkspaceButtonFadeSettings.legacyPaneTabBarControlsVisibilityModeKey, defaults: defaults)
        }

        defaults.removeObject(forKey: WorkspaceButtonFadeSettings.modeKey)
        defaults.set(true, forKey: WorkspaceTitlebarSettings.showTitlebarKey)
        defaults.set("always", forKey: WorkspaceButtonFadeSettings.legacyTitlebarControlsVisibilityModeKey)
        defaults.set("onHover", forKey: WorkspaceButtonFadeSettings.legacyPaneTabBarControlsVisibilityModeKey)

        WorkspaceButtonFadeSettings.initializeStoredModeIfNeeded(defaults: defaults)

        XCTAssertEqual(
            defaults.string(forKey: WorkspaceButtonFadeSettings.modeKey),
            WorkspaceButtonFadeSettings.Mode.enabled.rawValue
        )
    }

    func testWorkspaceButtonFadeModePreservesExistingStoredMode() {
        let defaults = UserDefaults.standard
        let savedMode = defaults.object(forKey: WorkspaceButtonFadeSettings.modeKey)
        let savedTitlebarVisibility = defaults.object(forKey: WorkspaceTitlebarSettings.showTitlebarKey)
        let savedLegacyTitlebarMode = defaults.object(forKey: WorkspaceButtonFadeSettings.legacyTitlebarControlsVisibilityModeKey)
        let savedLegacyPaneMode = defaults.object(forKey: WorkspaceButtonFadeSettings.legacyPaneTabBarControlsVisibilityModeKey)
        defer {
            restoreDefaultsValue(savedMode, forKey: WorkspaceButtonFadeSettings.modeKey, defaults: defaults)
            restoreDefaultsValue(savedTitlebarVisibility, forKey: WorkspaceTitlebarSettings.showTitlebarKey, defaults: defaults)
            restoreDefaultsValue(savedLegacyTitlebarMode, forKey: WorkspaceButtonFadeSettings.legacyTitlebarControlsVisibilityModeKey, defaults: defaults)
            restoreDefaultsValue(savedLegacyPaneMode, forKey: WorkspaceButtonFadeSettings.legacyPaneTabBarControlsVisibilityModeKey, defaults: defaults)
        }

        defaults.set(WorkspaceButtonFadeSettings.Mode.disabled.rawValue, forKey: WorkspaceButtonFadeSettings.modeKey)
        defaults.set(false, forKey: WorkspaceTitlebarSettings.showTitlebarKey)
        defaults.set("onHover", forKey: WorkspaceButtonFadeSettings.legacyTitlebarControlsVisibilityModeKey)
        defaults.set("onHover", forKey: WorkspaceButtonFadeSettings.legacyPaneTabBarControlsVisibilityModeKey)

        WorkspaceButtonFadeSettings.initializeStoredModeIfNeeded(defaults: defaults)

        XCTAssertEqual(
            defaults.string(forKey: WorkspaceButtonFadeSettings.modeKey),
            WorkspaceButtonFadeSettings.Mode.disabled.rawValue
        )
    }

    func testWorkspaceMinimalModeDefaultsToStandardPresentation() {
        let defaults = UserDefaults.standard
        let savedMode = defaults.object(forKey: WorkspacePresentationModeSettings.modeKey)
        let savedLegacyTitlebar = defaults.object(forKey: WorkspaceTitlebarSettings.showTitlebarKey)
        let savedLegacyFade = defaults.object(forKey: WorkspaceButtonFadeSettings.modeKey)
        defer {
            restoreDefaultsValue(savedMode, forKey: WorkspacePresentationModeSettings.modeKey, defaults: defaults)
            restoreDefaultsValue(savedLegacyTitlebar, forKey: WorkspaceTitlebarSettings.showTitlebarKey, defaults: defaults)
            restoreDefaultsValue(savedLegacyFade, forKey: WorkspaceButtonFadeSettings.modeKey, defaults: defaults)
        }

        defaults.removeObject(forKey: WorkspacePresentationModeSettings.modeKey)
        defaults.set(false, forKey: WorkspaceTitlebarSettings.showTitlebarKey)
        defaults.set(WorkspaceButtonFadeSettings.Mode.enabled.rawValue, forKey: WorkspaceButtonFadeSettings.modeKey)

        XCTAssertEqual(
            WorkspacePresentationModeSettings.mode(defaults: defaults),
            .standard
        )
    }

    func testKeyboardShortcutSettingsSetShortcutPostsSpecificChangeNotification() {
        let notificationName = Notification.Name("cmux.keyboardShortcutSettingsDidChange")
        let expectedAction = KeyboardShortcutSettings.Action.toggleSidebar.rawValue
        let expectation = expectation(forNotification: notificationName, object: nil) { notification in
            notification.userInfo?["action"] as? String == expectedAction
        }

        KeyboardShortcutSettings.setShortcut(
            StoredShortcut(key: "s", command: true, shift: false, option: false, control: true),
            for: .toggleSidebar
        )

        wait(for: [expectation], timeout: 0.2)
    }

    func testCmdPhysicalPWithDvorakCharactersDoesNotTriggerCommandPaletteSwitcher() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        // Dvorak: physical ANSI "P" key can produce "l".
        // This should behave as Cmd+L, not as physical Cmd+P.
        let event = makeKeyEvent(
            modifierFlags: [.command],
            characters: "l",
            charactersIgnoringModifiers: "l",
            keyCode: 35 // kVK_ANSI_P
        )

#if DEBUG
        XCTAssertFalse(appDelegate.debugMatchesConfiguredShortcut(event: event, action: .goToWorkspace))
#else
        XCTFail("debugMatchesConfiguredShortcut is only available in DEBUG")
#endif
    }

    func testCmdPWithCapsLockStillTriggersCommandPaletteSwitcher() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let event = makeKeyEvent(
            modifierFlags: [.command, .capsLock],
            characters: "p",
            charactersIgnoringModifiers: "p",
            keyCode: 35 // kVK_ANSI_P
        )

#if DEBUG
        XCTAssertTrue(appDelegate.debugMatchesConfiguredShortcut(event: event, action: .goToWorkspace))
#else
        XCTFail("debugMatchesConfiguredShortcut is only available in DEBUG")
#endif
    }

    func testCmdPFallsBackToANSIKeyCodeWhenCharactersAndLayoutTranslationAreUnavailable() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        appDelegate.shortcutLayoutCharacterProvider = { _, _ in nil }
        defer {
            appDelegate.shortcutLayoutCharacterProvider = KeyboardLayout.character(forKeyCode:modifierFlags:)
        }

        let event = makeKeyEvent(
            modifierFlags: [.command],
            characters: "",
            charactersIgnoringModifiers: "",
            keyCode: 35 // kVK_ANSI_P
        )

#if DEBUG
        XCTAssertTrue(appDelegate.debugMatchesConfiguredShortcut(event: event, action: .goToWorkspace))
#else
        XCTFail("debugMatchesConfiguredShortcut is only available in DEBUG")
#endif
    }

    func testCmdPDoesNotFallbackToANSIKeyCodeWhenLayoutTranslationProvidesDifferentLetter() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        appDelegate.shortcutLayoutCharacterProvider = { _, _ in "b" }
        defer {
            appDelegate.shortcutLayoutCharacterProvider = KeyboardLayout.character(forKeyCode:modifierFlags:)
        }

        let event = makeKeyEvent(
            modifierFlags: [.command],
            characters: "",
            charactersIgnoringModifiers: "",
            keyCode: 35 // kVK_ANSI_P
        )

#if DEBUG
        XCTAssertFalse(appDelegate.debugMatchesConfiguredShortcut(event: event, action: .goToWorkspace))
#else
        XCTFail("debugMatchesConfiguredShortcut is only available in DEBUG")
#endif
    }

    func testCmdPFallsBackToCommandAwareLayoutTranslationWhenCharactersAreUnavailable() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        appDelegate.shortcutLayoutCharacterProvider = { keyCode, modifierFlags in
            guard keyCode == 35 else { return nil } // kVK_ANSI_P
            return modifierFlags.contains(.command) ? "p" : "r"
        }
        defer {
            appDelegate.shortcutLayoutCharacterProvider = KeyboardLayout.character(forKeyCode:modifierFlags:)
        }

        let event = makeKeyEvent(
            modifierFlags: [.command],
            characters: "",
            charactersIgnoringModifiers: "",
            keyCode: 35 // kVK_ANSI_P
        )

#if DEBUG
        XCTAssertTrue(appDelegate.debugMatchesConfiguredShortcut(event: event, action: .goToWorkspace))
#else
        XCTFail("debugMatchesConfiguredShortcut is only available in DEBUG")
#endif
    }

    func testCmdShiftPhysicalPWithDvorakCharactersDoesNotTriggerCommandPalette() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        // Dvorak: physical ANSI "P" key can produce "l".
        // This should behave as Cmd+Shift+L, not as physical Cmd+Shift+P.
        let event = makeKeyEvent(
            modifierFlags: [.command, .shift],
            characters: "l",
            charactersIgnoringModifiers: "l",
            keyCode: 35 // kVK_ANSI_P
        )

#if DEBUG
        XCTAssertFalse(appDelegate.debugMatchesConfiguredShortcut(event: event, action: .commandPalette))
#else
        XCTFail("debugMatchesConfiguredShortcut is only available in DEBUG")
#endif
    }

    func testCmdOptionPhysicalTWithDvorakCharactersDoesNotTriggerCloseOtherTabsShortcut() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        // Dvorak: physical ANSI "T" key can produce "y".
        // This should not match the Cmd+Option+T app shortcut.
        let event = makeKeyEvent(
            modifierFlags: [.command, .option],
            characters: "y",
            charactersIgnoringModifiers: "y",
            keyCode: 17 // kVK_ANSI_T
        )

#if DEBUG
        XCTAssertFalse(appDelegate.debugMatchesConfiguredShortcut(event: event, action: .closeOtherTabsInPane))
#else
        XCTFail("debugMatchesConfiguredShortcut is only available in DEBUG")
#endif
    }

    func testCmdShiftPMatchesCommandPaletteCommandsShortcut() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let event = makeKeyEvent(
            modifierFlags: [.command, .shift],
            characters: "P",
            charactersIgnoringModifiers: "p",
            keyCode: 35 // kVK_ANSI_P
        )

#if DEBUG
        XCTAssertTrue(appDelegate.debugMatchesConfiguredShortcut(event: event, action: .commandPalette))
        XCTAssertFalse(appDelegate.debugMatchesConfiguredShortcut(event: event, action: .goToWorkspace))
#else
        XCTFail("debugMatchesConfiguredShortcut is only available in DEBUG")
#endif
    }

    func testCmdPStillRequestsCommandPaletteSwitcherWhilePaletteIsVisible() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let window = makeCommandPaletteShortcutTestWindow()
        defer { window.close() }

        appDelegate.setCommandPaletteVisible(true, for: window)
        defer { appDelegate.setCommandPaletteVisible(false, for: window) }

        let switcherExpectation = expectation(description: "Expected switcher request while command palette is visible")
        var observedSwitcherWindow: NSWindow?
        let switcherToken = NotificationCenter.default.addObserver(
            forName: .commandPaletteSwitcherRequested,
            object: nil,
            queue: nil
        ) { notification in
            observedSwitcherWindow = notification.object as? NSWindow
            switcherExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(switcherToken) }

        guard let event = makeKeyDownEvent(
            key: "p",
            modifiers: [.command],
            keyCode: 35,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+P event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event, preferredWindow: window))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        wait(for: [switcherExpectation], timeout: 1.0)
        XCTAssertEqual(observedSwitcherWindow?.windowNumber, window.windowNumber)
    }

    func testCmdShiftPStillRequestsCommandPaletteCommandsWhilePaletteIsVisible() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let window = makeCommandPaletteShortcutTestWindow()
        defer { window.close() }

        appDelegate.setCommandPaletteVisible(true, for: window)
        defer { appDelegate.setCommandPaletteVisible(false, for: window) }

        let paletteExpectation = expectation(description: "Expected commands request while command palette is visible")
        var observedPaletteWindow: NSWindow?
        let paletteToken = NotificationCenter.default.addObserver(
            forName: .commandPaletteRequested,
            object: nil,
            queue: nil
        ) { notification in
            observedPaletteWindow = notification.object as? NSWindow
            paletteExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(paletteToken) }

        guard let event = makeKeyDownEvent(
            key: "P",
            modifiers: [.command, .shift],
            keyCode: 35,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+Shift+P event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event, preferredWindow: window))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        wait(for: [paletteExpectation], timeout: 1.0)
        XCTAssertEqual(observedPaletteWindow?.windowNumber, window.windowNumber)
    }

    func testCmdFFocusedBrowserOpensBrowserFind() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let manager = makeShortcutRoutingTabManager()

        guard let workspace = manager.selectedWorkspace,
              let browserPanelId = manager.openBrowser(inWorkspace: workspace.id),
              let browserPanel = manager.focusedBrowserPanel else {
            XCTFail("Expected focused browser panel")
            return
        }
        defer {
            BrowserWindowPortalRegistry.detach(webView: browserPanel.webView)
            browserPanel.close()
            browserPanel.webView.cmuxSetUnitTestInspector(nil)
            browserPanel.webView.removeFromSuperview()
        }

        XCTAssertEqual(browserPanel.id, browserPanelId)
        XCTAssertNil(browserPanel.searchState)

        guard let event = makeKeyDownEvent(
            key: "f",
            modifiers: [.command],
            keyCode: 3,
            windowNumber: 0
        ) else {
            XCTFail("Failed to construct Cmd+F event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugMatchesConfiguredShortcut(event: event, action: .find))
#else
        XCTFail("debugMatchesConfiguredShortcut is only available in DEBUG")
#endif

        let controller = MainWindowFocusController(
            windowId: UUID(),
            window: nil,
            tabManager: manager,
            fileExplorerState: appDelegate.fileExplorerState
        )
        controller.noteRightSidebarInteraction(mode: .files)

        XCTAssertEqual(
            controller.findShortcutTarget(currentResponder: FocusableTestView()),
            .mainPanelFind,
            "Cmd+F should open browser find instead of right-sidebar file search when browser web content is focused"
        )
        XCTAssertTrue(manager.startSearch())
        XCTAssertNotNil(browserPanel.searchState)
    }

    func testOmnibarArrowSelectionUsesResponderResolvedPanelWhenTrackedFocusWasCleared() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let contentView = window.contentView,
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace,
              let browserPanelId = manager.openBrowser(inWorkspace: workspace.id) else {
            XCTFail("Expected focused browser panel")
            return
        }

        let field = OmnibarNativeTextField(frame: NSRect(x: 8, y: 8, width: 240, height: 24))
        field.identifier = browserOmnibarTextFieldIdentifier
        field.panelId = browserPanelId
        field.stringValue = "example"
        contentView.addSubview(field)
        BrowserOmnibarNativeFieldRegistry.shared.register(field, panelId: browserPanelId)
        defer {
            BrowserOmnibarNativeFieldRegistry.shared.unregister(field, panelId: browserPanelId)
            field.removeFromSuperview()
        }

        XCTAssertTrue(window.makeFirstResponder(field))
        XCTAssertNotNil(field.currentEditor())

        NotificationCenter.default.post(name: .browserDidBlurAddressBar, object: browserPanelId)

        let moveExpectation = expectation(
            description: "Expected omnibar move-selection notification for responder-resolved panel"
        )
        var observedPanelId: UUID?
        var observedDelta: Int?
        let moveToken = NotificationCenter.default.addObserver(
            forName: .browserMoveOmnibarSelection,
            object: nil,
            queue: nil
        ) { notification in
            observedPanelId = notification.object as? UUID
            observedDelta = notification.userInfo?["delta"] as? Int
            moveExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(moveToken) }

        guard let downArrowEvent = makeKeyDownEvent(
            key: String(UnicodeScalar(NSDownArrowFunctionKey)!),
            modifiers: [],
            keyCode: 125,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Down Arrow event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: downArrowEvent))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        wait(for: [moveExpectation], timeout: 1.0)
        XCTAssertEqual(observedPanelId, browserPanelId)
        XCTAssertEqual(observedDelta, 1)
    }

    func testOmnibarArrowSelectionDoesNotInterceptMarkedTextComposition() {
        XCTAssertEqual(
            browserOmnibarSelectionDeltaForArrowNavigation(
                hasFocusedAddressBar: true,
                flags: [],
                keyCode: 125
            ),
            1,
            "Plain Down Arrow normally moves omnibar selection"
        )
        XCTAssertTrue(
            browserOmnibarShouldBypassShortcutRoutingForMarkedText(
                hasFocusedAddressBar: true,
                firstResponderHasMarkedText: true,
                flags: []
            ),
            "Down Arrow belongs to the input method while omnibar marked text is active"
        )
        XCTAssertFalse(
            browserOmnibarShouldBypassShortcutRoutingForMarkedText(
                hasFocusedAddressBar: true,
                firstResponderHasMarkedText: true,
                flags: [.command]
            ),
            "Command shortcuts should remain available during omnibar marked text"
        )
    }

    func testOmnibarArrowSelectionSurvivesTransientWindowFirstResponder() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let contentView = window.contentView,
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace,
              let browserPanelId = manager.openBrowser(inWorkspace: workspace.id) else {
            XCTFail("Expected focused browser panel")
            return
        }
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        let field = OmnibarNativeTextField(frame: NSRect(x: 8, y: 8, width: 240, height: 24))
        field.identifier = browserOmnibarTextFieldIdentifier
        field.panelId = browserPanelId
        field.stringValue = "example"
        contentView.addSubview(field)
        BrowserOmnibarNativeFieldRegistry.shared.register(field, panelId: browserPanelId)
        defer {
            NotificationCenter.default.post(name: .browserDidBlurAddressBar, object: browserPanelId)
            BrowserOmnibarNativeFieldRegistry.shared.unregister(field, panelId: browserPanelId)
            field.removeFromSuperview()
        }

        XCTAssertTrue(appDelegate.requestBrowserAddressBarFocus(panelId: browserPanelId))
        XCTAssertEqual(appDelegate.focusedBrowserAddressBarPanelId(), browserPanelId)
        _ = window.makeFirstResponder(nil)
        XCTAssertTrue(window.firstResponder === window)

        let moveExpectation = expectation(
            description: "Expected omnibar move-selection notification while first responder is transiently the window"
        )
        var observedPanelId: UUID?
        var observedDelta: Int?
        let moveToken = NotificationCenter.default.addObserver(
            forName: .browserMoveOmnibarSelection,
            object: nil,
            queue: nil
        ) { notification in
            observedPanelId = notification.object as? UUID
            observedDelta = notification.userInfo?["delta"] as? Int
            moveExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(moveToken) }

        guard let downArrowEvent = makeKeyDownEvent(
            key: String(UnicodeScalar(NSDownArrowFunctionKey)!),
            modifiers: [],
            keyCode: 125,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Down Arrow event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: downArrowEvent))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        wait(for: [moveExpectation], timeout: 1.0)
        XCTAssertEqual(observedPanelId, browserPanelId)
        XCTAssertEqual(observedDelta, 1)
    }

    func testCmdPhysicalWWithDvorakCharactersDoesNotTriggerClosePanelShortcut() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        // Dvorak: physical ANSI "W" key can produce ",".
        // This should not match the Cmd+W close-panel shortcut.
        let event = makeKeyEvent(
            modifierFlags: [.command],
            characters: ",",
            charactersIgnoringModifiers: ",",
            keyCode: 13 // kVK_ANSI_W
        )

#if DEBUG
        XCTAssertFalse(appDelegate.debugMatchesConfiguredShortcut(event: event, action: .closeTab))
#else
        XCTFail("debugMatchesConfiguredShortcut is only available in DEBUG")
#endif
    }

    func testCmdIStillTriggersShowNotificationsShortcut() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        withTemporaryShortcut(action: .showNotifications) {
            let event = makeKeyEvent(
                modifierFlags: [.command],
                characters: "i",
                charactersIgnoringModifiers: "i",
                keyCode: 34 // kVK_ANSI_I
            )

#if DEBUG
            XCTAssertTrue(appDelegate.debugMatchesConfiguredShortcut(event: event, action: .showNotifications))
#else
            XCTFail("debugMatchesConfiguredShortcut is only available in DEBUG")
#endif
        }
    }

    func testCmdUnshiftedSymbolDoesNotMatchDigitShortcut() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        withTemporaryShortcut(
            action: .showNotifications,
            shortcut: StoredShortcut(key: "8", command: true, shift: false, option: false, control: false)
        ) {
            // Some non-US layouts can produce "*" without Shift.
            // This must not be coerced into "8" for a Cmd+8 shortcut match.
            let event = makeKeyEvent(
                modifierFlags: [.command],
                characters: "*",
                charactersIgnoringModifiers: "*",
                keyCode: 30 // kVK_ANSI_RightBracket
            )

#if DEBUG
            XCTAssertFalse(appDelegate.debugMatchesConfiguredShortcut(event: event, action: .showNotifications))
#else
            XCTFail("debugMatchesConfiguredShortcut is only available in DEBUG")
#endif
        }
    }

    func testCmdDigitShortcutFallsBackByKeyCodeOnSymbolFirstLayouts() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        withTemporaryShortcut(
            action: .showNotifications,
            shortcut: StoredShortcut(key: "1", command: true, shift: false, option: false, control: false)
        ) {
            // Symbol-first layouts (for example AZERTY) can report "&" for the ANSI 1 key.
            // Cmd+1 shortcuts should still match via keyCode fallback in this case.
            let event = makeKeyEvent(
                modifierFlags: [.command],
                characters: "&",
                charactersIgnoringModifiers: "&",
                keyCode: 18 // kVK_ANSI_1
            )

#if DEBUG
            XCTAssertTrue(appDelegate.debugMatchesConfiguredShortcut(event: event, action: .showNotifications))
#else
            XCTFail("debugMatchesConfiguredShortcut is only available in DEBUG")
#endif
        }
    }

    func testCmdShiftNonDigitKeySymbolDoesNotMatchShiftedDigitShortcut() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        withTemporaryShortcut(
            action: .showNotifications,
            shortcut: StoredShortcut(key: "8", command: true, shift: true, option: false, control: false)
        ) {
            // On some non-US layouts, Shift+RightBracket can produce "*".
            // This must not be interpreted as Shift+8.
            let event = makeKeyEvent(
                modifierFlags: [.command, .shift],
                characters: "*",
                charactersIgnoringModifiers: "*",
                keyCode: 30 // kVK_ANSI_RightBracket
            )

#if DEBUG
            XCTAssertFalse(appDelegate.debugMatchesConfiguredShortcut(event: event, action: .showNotifications))
#else
            XCTFail("debugMatchesConfiguredShortcut is only available in DEBUG")
#endif
        }
    }

    func testCmdShiftDigitShortcutMatchesShiftedDigitKey() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        withTemporaryShortcut(
            action: .showNotifications,
            shortcut: StoredShortcut(key: "8", command: true, shift: true, option: false, control: false)
        ) {
            let event = makeKeyEvent(
                modifierFlags: [.command, .shift],
                characters: "*",
                charactersIgnoringModifiers: "*",
                keyCode: 28 // kVK_ANSI_8
            )

#if DEBUG
            XCTAssertTrue(appDelegate.debugMatchesConfiguredShortcut(event: event, action: .showNotifications))
#else
            XCTFail("debugMatchesConfiguredShortcut is only available in DEBUG")
#endif
        }
    }

    func testCmdShiftQuestionMarkMatchesSlashShortcut() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        withTemporaryShortcut(
            action: .triggerFlash,
            shortcut: StoredShortcut(key: "/", command: true, shift: true, option: false, control: false)
        ) {
            let event = makeKeyEvent(
                modifierFlags: [.command, .shift],
                characters: "?",
                charactersIgnoringModifiers: "?",
                keyCode: 44 // kVK_ANSI_Slash
            )

#if DEBUG
            XCTAssertTrue(appDelegate.debugMatchesConfiguredShortcut(event: event, action: .triggerFlash))
#else
            XCTFail("debugMatchesConfiguredShortcut is only available in DEBUG")
#endif
        }
    }

    func testReactGrabShortcutIsConsumedWhenNoBrowserRouteExists() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

        withTemporaryShortcut(action: .toggleReactGrab) {
            guard let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.command, .shift],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: "G",
                charactersIgnoringModifiers: "g",
                isARepeat: false,
                keyCode: 5
            ) else {
                XCTFail("Failed to construct Cmd+Shift+G event")
                return
            }

#if DEBUG
            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
            XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
        }
    }

    func testCmdShiftISOAngleBracketDoesNotMatchCommaShortcut() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        withTemporaryShortcut(
            action: .showNotifications,
            shortcut: StoredShortcut(key: ",", command: true, shift: true, option: false, control: false)
        ) {
            let event = makeKeyEvent(
                modifierFlags: [.command, .shift],
                characters: "<",
                charactersIgnoringModifiers: "<",
                keyCode: 10 // kVK_ISO_Section
            )

#if DEBUG
            XCTAssertFalse(appDelegate.debugMatchesConfiguredShortcut(event: event, action: .showNotifications))
#else
            XCTFail("debugMatchesConfiguredShortcut is only available in DEBUG")
#endif
        }
    }

    func testCmdShiftRightBracketCanFallbackByKeyCodeOnNonUSLayouts() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        withTemporaryShortcut(action: .nextSurface) {
            // Non-US layouts can report "*" (or other symbols) for kVK_ANSI_RightBracket with Shift.
            // Shortcut matching should still allow Cmd+Shift+] via keyCode fallback.
            let event = makeKeyEvent(
                modifierFlags: [.command, .shift],
                characters: "*",
                charactersIgnoringModifiers: "*",
                keyCode: 30 // kVK_ANSI_RightBracket
            )

#if DEBUG
            XCTAssertTrue(appDelegate.debugMatchesConfiguredShortcut(event: event, action: .nextSurface))
#else
            XCTFail("debugMatchesConfiguredShortcut is only available in DEBUG")
#endif
        }
    }

    func testConfiguredCmdPhysicalOWithDvorakCharactersTriggersRenameTabShortcut() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        withTemporaryShortcut(action: .renameTab) {
            // Dvorak: physical ANSI "O" key can produce "r".
            // This should behave as semantic Cmd+R (rename tab), not Cmd+P.
            let event = makeKeyEvent(
                modifierFlags: [.command],
                characters: "r",
                charactersIgnoringModifiers: "r",
                keyCode: 31 // kVK_ANSI_O
            )

#if DEBUG
            XCTAssertTrue(appDelegate.debugMatchesConfiguredShortcut(event: event, action: .renameTab))
            XCTAssertFalse(appDelegate.debugMatchesConfiguredShortcut(event: event, action: .goToWorkspace))
#else
            XCTFail("debugMatchesConfiguredShortcut is only available in DEBUG")
#endif
        }
    }

    func testCmdPhysicalRWithDvorakCharactersTriggersCommandPaletteSwitcher() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        // Dvorak: physical ANSI "R" key can produce "p".
        // This should behave as semantic Cmd+P (palette switcher), not Cmd+R.
        let event = makeKeyEvent(
            modifierFlags: [.command],
            characters: "p",
            charactersIgnoringModifiers: "p",
            keyCode: 15 // kVK_ANSI_R
        )

#if DEBUG
        XCTAssertTrue(appDelegate.debugMatchesConfiguredShortcut(event: event, action: .goToWorkspace))
        XCTAssertFalse(appDelegate.debugMatchesConfiguredShortcut(event: event, action: .renameTab))
#else
        XCTFail("debugMatchesConfiguredShortcut is only available in DEBUG")
#endif
    }

    func testConfiguredCmdShiftRRoutesToRenameWorkspaceCommandPaletteRequest() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let event = makeKeyEvent(
            modifierFlags: [.command, .shift],
            characters: "R",
            charactersIgnoringModifiers: "r",
            keyCode: 15 // kVK_ANSI_R
        )

#if DEBUG
        XCTAssertTrue(appDelegate.debugMatchesConfiguredShortcut(event: event, action: .renameWorkspace))
        XCTAssertFalse(appDelegate.debugMatchesConfiguredShortcut(event: event, action: .renameTab))
        XCTAssertEqual(appDelegate.debugCommandPaletteShortcutRequest(for: event), .renameWorkspace)
#else
        XCTFail("command palette shortcut routing debug hooks are only available in DEBUG")
#endif
    }

    func testCmdOptionEMatchesEditWorkspaceDescriptionShortcut() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let event = makeKeyEvent(
            modifierFlags: [.command, .option],
            characters: "e",
            charactersIgnoringModifiers: "e",
            keyCode: 14 // kVK_ANSI_E
        )

#if DEBUG
        XCTAssertTrue(appDelegate.debugMatchesConfiguredShortcut(event: event, action: .editWorkspaceDescription))
        XCTAssertFalse(appDelegate.debugMatchesConfiguredShortcut(event: event, action: .renameWorkspace))
#else
        XCTFail("debugMatchesConfiguredShortcut is only available in DEBUG")
#endif
    }

    func testEscapeDismissesVisibleCommandPaletteAndIsConsumed() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let window = makeCommandPaletteShortcutTestWindow()
        defer { closeTestWindow(window) }

        appDelegate.setCommandPaletteVisible(true, for: window)
        defer {
            appDelegate.setCommandPaletteVisible(false, for: window)
        }

        guard let event = makeKeyDownEvent(
            key: "\u{1b}",
            modifiers: [],
            keyCode: 53, // kVK_Escape
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Escape event")
            return
        }

#if DEBUG
        withCommandPaletteDismissRequestObserver(appDelegate: appDelegate) { observedDismissWindow in
            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event, preferredWindow: window))
            XCTAssertEqual(observedDismissWindow()?.windowNumber, window.windowNumber)
        }
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
    }

    func testEscapeDoesNotDismissCommandPaletteWhenInputHasMarkedText() {
        XCTAssertTrue(
            shouldBypassCommandPaletteEscapeForMarkedText(
                isCommandPaletteEffectivelyVisible: true,
                hasMarkedTextInput: true
            ),
            "Escape should pass through to IME composition instead of dismissing command palette"
        )
        XCTAssertFalse(
            shouldBypassCommandPaletteEscapeForMarkedText(
                isCommandPaletteEffectivelyVisible: true,
                hasMarkedTextInput: false
            ),
            "Escape should dismiss the palette when no IME composition is active"
        )
        XCTAssertFalse(
            shouldBypassCommandPaletteEscapeForMarkedText(
                isCommandPaletteEffectivelyVisible: false,
                hasMarkedTextInput: true
            ),
            "Marked text should only affect Escape while the command palette is active"
        )
    }

    func testEscapeDismissesCommandPaletteWhenVisibilitySyncLagsAfterOpenRequest() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let window = makeCommandPaletteShortcutTestWindow()
        defer { closeTestWindow(window) }

#if DEBUG
        appDelegate.debugMarkCommandPaletteOpenPending(window: window)
#else
        XCTFail("debugMarkCommandPaletteOpenPending is only available in DEBUG")
#endif

        // Model the normal open-palette state so the test reads like the user-facing scenario.
        appDelegate.setCommandPaletteVisible(true, for: window)

        guard let escapeEvent = makeKeyDownEvent(
            key: "\u{1b}",
            modifiers: [],
            keyCode: 53,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Escape event")
            return
        }

#if DEBUG
        withCommandPaletteDismissRequestObserver(appDelegate: appDelegate) { observedDismissWindow in
            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: escapeEvent, preferredWindow: window))
            XCTAssertEqual(observedDismissWindow()?.windowNumber, window.windowNumber)
        }
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
    }

    func testArrowNavigationRoutesWhileCommandPaletteOverlayIsInteractiveBeforeVisibilitySync() {
        let delta = commandPaletteSelectionDeltaForKeyboardNavigation(
            flags: [],
            chars: String(UnicodeScalar(NSDownArrowFunctionKey)!),
            keyCode: 125,
            nextShortcut: KeyboardShortcutSettings.Action.commandPaletteNext.defaultShortcut,
            previousShortcut: KeyboardShortcutSettings.Action.commandPalettePrevious.defaultShortcut
        )

        XCTAssertEqual(delta, 1)
        XCTAssertTrue(
            shouldRouteCommandPaletteSelectionNavigation(
                delta: delta,
                isInteractive: true,
                usesInlineTextHandling: false
            ),
            "Visible overlay state should be enough to route palette selection before visibility sync catches up"
        )
        XCTAssertFalse(
            shouldRouteCommandPaletteSelectionNavigation(
                delta: delta,
                isInteractive: false,
                usesInlineTextHandling: false
            ),
            "Stale visibility without an interactive overlay must not route palette selection"
        )
    }

    func testControlKDoesNotRoutePaletteMoveSelectionWhenSearchFieldIsFocused() {
        let delta = commandPaletteSelectionDeltaForKeyboardNavigation(
            flags: [.control],
            chars: "\u{0b}",
            keyCode: 40,
            nextShortcut: KeyboardShortcutSettings.Action.commandPaletteNext.defaultShortcut,
            previousShortcut: KeyboardShortcutSettings.Action.commandPalettePrevious.defaultShortcut
        )

        XCTAssertNil(delta, "Ctrl+K should not be treated as command palette navigation")
        XCTAssertFalse(
            shouldRouteCommandPaletteSelectionNavigation(
                delta: delta,
                isInteractive: true,
                usesInlineTextHandling: false
            )
        )
    }

    func testEscapeDismissesCommandPaletteWhenVisibilityStateStaysStalePastInitialPendingWindow() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let window = makeCommandPaletteShortcutTestWindow()
        defer { closeTestWindow(window) }

#if DEBUG
        XCTAssertTrue(
            appDelegate.debugSetCommandPalettePendingOpenAge(window: window, age: 1.3),
            "Expected to backdate pending-open age for stale visibility test"
        )
#else
        XCTFail("debugSetCommandPalettePendingOpenAge is only available in DEBUG")
#endif

        // Simulate stale app-level visibility bookkeeping.
        appDelegate.setCommandPaletteVisible(false, for: window)

        guard let escapeEvent = makeKeyDownEvent(
            key: "\u{1b}",
            modifiers: [],
            keyCode: 53,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Escape event")
            return
        }

#if DEBUG
        withCommandPaletteDismissRequestObserver(appDelegate: appDelegate) { observedDismissWindow in
            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: escapeEvent, preferredWindow: window))
            XCTAssertEqual(observedDismissWindow()?.windowNumber, window.windowNumber)
        }
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
    }

    func testEscapeDismissesCommandPaletteWhenVisibilityStateRemainsStaleForExtendedDelay() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let window = makeCommandPaletteShortcutTestWindow()
        defer { closeTestWindow(window) }

#if DEBUG
        XCTAssertTrue(
            appDelegate.debugSetCommandPalettePendingOpenAge(window: window, age: 2.25),
            "Expected to backdate pending-open age for extended stale visibility test"
        )
#else
        XCTFail("debugSetCommandPalettePendingOpenAge is only available in DEBUG")
#endif

        // Simulate stale app-level visibility bookkeeping for a longer user delay.
        appDelegate.setCommandPaletteVisible(false, for: window)

        guard let escapeEvent = makeKeyDownEvent(
            key: "\u{1b}",
            modifiers: [],
            keyCode: 53,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Escape event")
            return
        }

#if DEBUG
        withCommandPaletteDismissRequestObserver(appDelegate: appDelegate) { observedDismissWindow in
            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: escapeEvent, preferredWindow: window))
            XCTAssertEqual(observedDismissWindow()?.windowNumber, window.windowNumber)
        }
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
    }

    func testEscapeDoesNotConsumeWhenMenuTriggeredPendingOpenStateExpires() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

#if DEBUG
        let windowId = UUID()
        XCTAssertTrue(
            appDelegate.debugSetCommandPalettePendingOpenAge(windowId: windowId, age: 20.0),
            "Expected to seed an expired pending-open request state"
        )
        XCTAssertNil(
            appDelegate.debugRecentCommandPaletteRequestAge(windowId: windowId),
            "Escape should pass through once pending-open grace has expired"
        )
        XCTAssertFalse(
            appDelegate.debugIsCommandPalettePendingOpen(windowId: windowId),
            "Expired pending-open state should be pruned before Escape routing"
        )
#else
        XCTFail("command palette pending-open debug hooks are only available in DEBUG")
#endif
    }

    func testEscapeDismissesMenuTriggeredCommandPaletteWhenVisibilitySyncIsStale() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let window = makeCommandPaletteShortcutTestWindow()
        defer { closeTestWindow(window) }

        // Reproduce the menu-command path (Cmd+Shift+P/Cmd+P) routed via AppDelegate.
        appDelegate.requestCommandPaletteCommands(
            preferredWindow: window,
            source: "test.menuCommandPalette"
        )
        // Simulate delayed/stale visibility sync from SwiftUI overlay state.
        appDelegate.setCommandPaletteVisible(false, for: window)
#if DEBUG
        XCTAssertTrue(
            appDelegate.debugSetCommandPalettePendingOpenAge(window: window, age: 0.1),
            "Expected deterministic pending-open state for menu-triggered stale-visibility path"
        )
#else
        XCTFail("debugSetCommandPalettePendingOpenAge is only available in DEBUG")
#endif

        guard let escapeEvent = makeKeyDownEvent(
            key: "\u{1b}",
            modifiers: [],
            keyCode: 53,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Escape event")
            return
        }

#if DEBUG
        withCommandPaletteDismissRequestObserver(appDelegate: appDelegate) { observedDismissWindow in
            XCTAssertTrue(
                appDelegate.debugHandleCustomShortcut(event: escapeEvent, preferredWindow: window),
                "Escape should still be consumed for menu-triggered command palette opens"
            )
            XCTAssertEqual(observedDismissWindow()?.windowNumber, window.windowNumber)
        }
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
    }

    func testEscapeRepeatIsConsumedImmediatelyAfterPaletteDismiss() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let window = makeCommandPaletteShortcutTestWindow()
        defer { closeTestWindow(window) }

        appDelegate.setCommandPaletteVisible(true, for: window)
        defer {
            appDelegate.setCommandPaletteVisible(false, for: window)
        }

        guard let firstEscape = makeKeyDownEvent(
            key: "\u{1b}",
            modifiers: [],
            keyCode: 53,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct first Escape event")
            return
        }

        guard let repeatedEscape = makeKeyDownEvent(
            key: "\u{1b}",
            modifiers: [],
            keyCode: 53,
            windowNumber: window.windowNumber,
            isARepeat: true
        ) else {
            XCTFail("Failed to construct repeated Escape event")
            return
        }

#if DEBUG
        withCommandPaletteDismissRequestObserver(appDelegate: appDelegate) { observedDismissWindow in
            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: firstEscape, preferredWindow: window))
            XCTAssertEqual(observedDismissWindow()?.windowNumber, window.windowNumber)
        }
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        // Simulate the palette overlay synchronizing to closed state while the Escape key is still held.
        appDelegate.setCommandPaletteVisible(false, for: window)

#if DEBUG
        XCTAssertTrue(
            appDelegate.debugHandleCustomShortcut(event: repeatedEscape, preferredWindow: window),
            "Repeated Escape immediately after dismiss should be consumed to prevent terminal passthrough"
        )
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
    }

    func testEscapeKeyUpIsConsumedAfterPaletteDismissToPreventTerminalLeak() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let window = makeCommandPaletteShortcutTestWindow()
        defer { closeTestWindow(window) }

        appDelegate.setCommandPaletteVisible(true, for: window)
        defer {
            appDelegate.setCommandPaletteVisible(false, for: window)
        }

        guard let escapeKeyDown = makeKeyEvent(
            type: .keyDown,
            key: "\u{1b}",
            modifiers: [],
            keyCode: 53,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Escape keyDown event")
            return
        }

        guard let escapeKeyUp = makeKeyEvent(
            type: .keyUp,
            key: "\u{1b}",
            modifiers: [],
            keyCode: 53,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Escape keyUp event")
            return
        }

#if DEBUG
        withCommandPaletteDismissRequestObserver(appDelegate: appDelegate) { observedDismissWindow in
            XCTAssertTrue(appDelegate.debugHandleShortcutMonitorEvent(event: escapeKeyDown, preferredWindow: window))
            XCTAssertEqual(observedDismissWindow()?.windowNumber, window.windowNumber)
        }
#else
        XCTFail("debugHandleShortcutMonitorEvent is only available in DEBUG")
#endif

        // Simulate the palette overlay synchronizing to closed state before Escape key-up arrives.
        appDelegate.setCommandPaletteVisible(false, for: window)

#if DEBUG
        XCTAssertTrue(
            appDelegate.debugHandleShortcutMonitorEvent(event: escapeKeyUp, preferredWindow: window),
            "Escape keyUp after palette dismiss should be consumed to prevent terminal passthrough"
        )
#else
        XCTFail("debugHandleShortcutMonitorEvent is only available in DEBUG")
#endif
    }

    func testEscapeKeyUpIsConsumedAfterCmdPSwitcherDismiss() {
        assertEscapeKeyUpIsConsumedAfterCommandPaletteOpenRequest { appDelegate, window in
            appDelegate.requestCommandPaletteSwitcher(
                preferredWindow: window,
                source: "test.cmdP"
            )
        }
    }

    func testEscapeKeyUpIsConsumedAfterCmdShiftPCommandsDismiss() {
        assertEscapeKeyUpIsConsumedAfterCommandPaletteOpenRequest { appDelegate, window in
            appDelegate.requestCommandPaletteCommands(
                preferredWindow: window,
                source: "test.cmdShiftP"
            )
        }
    }

    func testEscapeDoesNotDismissPaletteInDifferentWindow() {
        XCTAssertEqual(
            commandPaletteEscapeTargetResolution(
                hasTargetWindow: true,
                targetWindowIsEffective: false,
                hasActivePaletteWindow: true
            ),
            .none,
            "Escape in an inactive target window should not dismiss a palette in another window"
        )
        XCTAssertEqual(
            commandPaletteEscapeTargetResolution(
                hasTargetWindow: true,
                targetWindowIsEffective: true,
                hasActivePaletteWindow: true
            ),
            .targetWindow,
            "Escape should dismiss the palette scoped to the event target window"
        )
        XCTAssertEqual(
            commandPaletteEscapeTargetResolution(
                hasTargetWindow: false,
                targetWindowIsEffective: false,
                hasActivePaletteWindow: true
            ),
            .activePaletteWindow,
            "Escape without a target window should fall back to the active palette"
        )
    }

    func testCmdDigitDoesNotFallbackToOtherWindowWhenEventWindowContextIsMissing() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        guard let event = makeKeyDownEvent(
            key: "1",
            modifiers: [.command],
            keyCode: 18,
            windowNumber: Int.max
        ) else {
            XCTFail("Failed to construct Cmd+1 event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugMatchesConfiguredShortcut(event: event, action: .selectWorkspaceByNumber))
#else
        XCTFail("debugMatchesConfiguredShortcut is only available in DEBUG")
#endif

        XCTAssertTrue(
            shouldBypassShortcutRoutingForUnresolvedEventWindow(
                hasEventWindowContext: true,
                didSynchronizeShortcutContext: false,
                allowsFocusedCloseShortcutFallback: false
            ),
            "Unresolved event window must not route Cmd+1 into a stale manager or key/main fallback manager"
        )
    }

    func testCmdNDoesNotFallbackToOtherWindowWhenEventWindowContextIsMissing() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        guard let event = makeKeyDownEvent(
            key: "n",
            modifiers: [.command],
            keyCode: 45,
            windowNumber: Int.max
        ) else {
            XCTFail("Failed to construct Cmd+N event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugMatchesConfiguredShortcut(event: event, action: .newTab))
#else
        XCTFail("debugMatchesConfiguredShortcut is only available in DEBUG")
#endif

        XCTAssertTrue(
            shouldBypassShortcutRoutingForUnresolvedEventWindow(
                hasEventWindowContext: true,
                didSynchronizeShortcutContext: false,
                allowsFocusedCloseShortcutFallback: false
            ),
            "Unresolved event window must not create a workspace in a stale manager or fallback window"
        )
    }

    func testCmdShiftMReturnsFalseWhenNoFocusedTerminalCanHandle() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let originalTabManager = appDelegate.tabManager
        appDelegate.debugSuppressShortcutRoutingContextForTesting = true
        appDelegate.tabManager = nil
        defer {
            appDelegate.debugSuppressShortcutRoutingContextForTesting = false
            appDelegate.tabManager = originalTabManager
        }

        let event = makeKeyEvent(
            modifierFlags: [.command, .shift],
            characters: "M",
            charactersIgnoringModifiers: "m",
            keyCode: 46 // kVK_ANSI_M
        )

#if DEBUG
        XCTAssertTrue(appDelegate.debugMatchesConfiguredShortcut(event: event, action: .toggleTerminalCopyMode))
        XCTAssertFalse(
            appDelegate.debugHandleCustomShortcut(event: event),
            "Cmd+Shift+M should not be consumed when no terminal can toggle copy mode"
        )
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
    }

    func testPresentPreferencesWindowShowsCustomSettingsWindowAndActivates() {
        var showFallbackSettingsWindowCallCount = 0
        var activateApplicationCallCount = 0
        var receivedNavigationTargets: [SettingsNavigationTarget?] = []

        AppDelegate.presentPreferencesWindow(
            showFallbackSettingsWindow: { navigationTarget in
                receivedNavigationTargets.append(navigationTarget)
                showFallbackSettingsWindowCallCount += 1
            },
            activateApplication: {
                activateApplicationCallCount += 1
            }
        )

        XCTAssertEqual(showFallbackSettingsWindowCallCount, 1)
        XCTAssertEqual(activateApplicationCallCount, 1)
        XCTAssertEqual(receivedNavigationTargets, [nil])
    }

    func testPresentPreferencesWindowSupportsRepeatedCalls() {
        var showFallbackSettingsWindowCallCount = 0
        var activateApplicationCallCount = 0
        var receivedNavigationTargets: [SettingsNavigationTarget?] = []

        AppDelegate.presentPreferencesWindow(
            showFallbackSettingsWindow: { navigationTarget in
                receivedNavigationTargets.append(navigationTarget)
                showFallbackSettingsWindowCallCount += 1
            },
            activateApplication: {
                activateApplicationCallCount += 1
            }
        )

        AppDelegate.presentPreferencesWindow(
            showFallbackSettingsWindow: { navigationTarget in
                receivedNavigationTargets.append(navigationTarget)
                showFallbackSettingsWindowCallCount += 1
            },
            activateApplication: {
                activateApplicationCallCount += 1
            }
        )

        XCTAssertEqual(showFallbackSettingsWindowCallCount, 2)
        XCTAssertEqual(activateApplicationCallCount, 2)
        XCTAssertEqual(receivedNavigationTargets, [nil, nil])
    }

    func testPresentPreferencesWindowForwardsNavigationTarget() {
        var receivedNavigationTarget: SettingsNavigationTarget?
        var activateApplicationCallCount = 0

        AppDelegate.presentPreferencesWindow(
            navigationTarget: .keyboardShortcuts,
            showFallbackSettingsWindow: { navigationTarget in
                receivedNavigationTarget = navigationTarget
            },
            activateApplication: {
                activateApplicationCallCount += 1
            }
        )

        XCTAssertEqual(receivedNavigationTarget, .keyboardShortcuts)
        XCTAssertEqual(activateApplicationCallCount, 1)
    }

    func testPresentPreferencesWindowForwardsBrowserImportNavigationTarget() {
        var receivedNavigationTarget: SettingsNavigationTarget?
        var activateApplicationCallCount = 0

        AppDelegate.presentPreferencesWindow(
            navigationTarget: .browserImport,
            showFallbackSettingsWindow: { navigationTarget in
                receivedNavigationTarget = navigationTarget
            },
            activateApplication: {
                activateApplicationCallCount += 1
            }
        )

        XCTAssertEqual(receivedNavigationTarget, .browserImport)
        XCTAssertEqual(activateApplicationCallCount, 1)
    }

    // MARK: - Shortcut settings consultation regression tests

    func testExampleShortcutRoutingConsultsConfiguredShortcutSettings() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

        let cases: [(action: KeyboardShortcutSettings.Action, modifiers: NSEvent.ModifierFlags, key: String, keyCode: UInt16)] = [
            (
                .toggleRightSidebar,
                [.command, .option],
                "b",
                11
            ),
            (
                .focusRightSidebar,
                [.command, .shift],
                "e",
                14
            ),
            (
                .findInDirectory,
                [.command, .shift],
                "f",
                3
            ),
            (
                .toggleUnread,
                [.command, .option],
                "u",
                32
            ),
        ]

        for testCase in cases {
            var observedActions: [KeyboardShortcutSettings.Action] = []
            #if DEBUG
            KeyboardShortcutSettings.shortcutLookupObserver = { action in
                observedActions.append(action)
            }
            #else
            XCTFail("shortcutLookupObserver is only available in DEBUG")
            #endif

            guard let event = makeKeyDownEvent(
                key: testCase.key,
                modifiers: testCase.modifiers,
                keyCode: testCase.keyCode,
                windowNumber: window.windowNumber
            ) else {
                XCTFail("Failed to construct \(testCase.action.rawValue) shortcut event")
                return
            }

            #if DEBUG
            _ = appDelegate.debugHandleCustomShortcut(event: event)
            #else
            XCTFail("debugHandleCustomShortcut is only available in DEBUG")
            #endif

            XCTAssertTrue(
                observedActions.contains(testCase.action),
                "\(testCase.action.rawValue) routing must read KeyboardShortcutSettings.shortcut(for:) instead of matching a literal combo"
            )
        }
    }

    func testBrowserFindCommandPreflightConsultsConfiguredFindFamilyShortcuts() {
        #if DEBUG
        let cases: [(action: KeyboardShortcutSettings.Action, modifiers: NSEvent.ModifierFlags, key: String, keyCode: UInt16)] = [
            (.find, [.command], "f", 3),
            (.findInDirectory, [.command, .shift], "f", 3),
            (.findNext, [.command], "g", 5),
            (.findPrevious, [.command, .option], "g", 5),
            (.hideFind, [.command, .option, .shift], "f", 3),
            (.useSelectionForFind, [.command], "e", 14),
        ]

        for testCase in cases {
            var observedActions: [KeyboardShortcutSettings.Action] = []
            KeyboardShortcutSettings.shortcutLookupObserver = { action in
                observedActions.append(action)
            }

            let event = makeKeyEvent(
                modifierFlags: testCase.modifiers,
                characters: testCase.key,
                charactersIgnoringModifiers: testCase.key,
                keyCode: testCase.keyCode
            )

            _ = shouldRouteBrowserFindCommandEquivalentThroughWebContentFirst(event)

            XCTAssertTrue(
                observedActions.contains(testCase.action),
                "Browser find command preflight must read the configured \(testCase.action.rawValue) shortcut instead of matching a literal combo"
            )
        }
        #else
        XCTFail("shortcutLookupObserver is only available in DEBUG")
        #endif
    }

    // MARK: - Browser find shortcut routing tests

    func testBrowserFirstFindShortcutRoutingRecognizesBrowserLocalFindCommandFamily() {
        let cases: [(name: String, modifiers: NSEvent.ModifierFlags, chars: String, keyCode: UInt16)] = [
            ("cmd-g", [.command], "g", 5),
            ("cmd-option-g", [.command, .option], "g", 5),
            ("cmd-option-shift-f", [.command, .option, .shift], "f", 3),
            ("cmd-e", [.command], "e", 14),
        ]

        for testCase in cases {
            let event = makeKeyEvent(
                modifierFlags: testCase.modifiers,
                characters: testCase.chars,
                charactersIgnoringModifiers: testCase.chars,
                keyCode: testCase.keyCode
            )
            XCTAssertTrue(
                shouldRouteBrowserFindCommandEquivalentThroughWebContentFirst(event),
                "Expected browser-first routing for \(testCase.name)"
            )
        }
    }

    func testBrowserFirstFindShortcutRoutingExcludesAppOwnedFindCommands() {
        let cases: [(name: String, modifiers: NSEvent.ModifierFlags, chars: String, keyCode: UInt16)] = [
            ("cmd-f", [.command], "f", 3),
            ("cmd-shift-f", [.command, .shift], "f", 3),
        ]

        for testCase in cases {
            let event = makeKeyEvent(
                modifierFlags: testCase.modifiers,
                characters: testCase.chars,
                charactersIgnoringModifiers: testCase.chars,
                keyCode: testCase.keyCode
            )

            XCTAssertFalse(
                shouldRouteBrowserFindCommandEquivalentThroughWebContentFirst(event),
                "\(testCase.name) belongs to cmux find routing, not browser-first routing"
            )
        }
    }

    func testBrowserFirstFindShortcutRoutingFallsBackToKeyCodeForNonLatinInput() {
        let event = makeKeyEvent(
            modifierFlags: [.command],
            characters: "",
            charactersIgnoringModifiers: "п", // Cyrillic p from a non-Latin input source
            keyCode: 5 // kVK_ANSI_G
        )

        XCTAssertTrue(
            shouldRouteBrowserFindCommandEquivalentThroughWebContentFirst(event),
            "Expected browser-first routing to keep Cmd+G eligible under non-Latin input"
        )
    }

    func testBrowserFirstFindShortcutRoutingDoesNotUseANSIPositionsForMismatchedASCIICharacters() {
        let cases: [(name: String, modifiers: NSEvent.ModifierFlags, chars: String, keyCode: UInt16)] = [
            ("cmd-u-on-ansi-f", [.command], "u", 3),
            ("cmd-o-on-ansi-g", [.command], "o", 5),
            ("cmd-period-on-ansi-e", [.command], ".", 14),
            ("cmd-shift-u-on-ansi-f", [.command, .shift], "u", 3),
            ("cmd-shift-o-on-ansi-g", [.command, .shift], "o", 5),
        ]

        for testCase in cases {
            let event = makeKeyEvent(
                modifierFlags: testCase.modifiers,
                characters: testCase.chars,
                charactersIgnoringModifiers: testCase.chars,
                keyCode: testCase.keyCode
            )

            XCTAssertFalse(
                shouldRouteBrowserFindCommandEquivalentThroughWebContentFirst(event),
                "Did not expect browser-first routing for mismatched ASCII shortcut \(testCase.name)"
            )
        }
    }

    func testBrowserFirstFindShortcutRoutingExcludesWebInspectorResponders() {
        let inspectorContainer = FakeWKInspectorContainerView(frame: .zero)
        let inspectorChild = NSView(frame: .zero)
        inspectorContainer.addSubview(inspectorChild)

        let event = makeKeyEvent(
            modifierFlags: [.command],
            characters: "g",
            charactersIgnoringModifiers: "g",
            keyCode: 5
        )

        XCTAssertFalse(
            shouldRouteBrowserFindCommandEquivalentThroughWebContentFirst(
                event,
                responder: inspectorChild
            ),
            "Did not expect browser-first routing while a Web Inspector responder is focused"
        )
    }

    func testBrowserFirstFindShortcutRoutingExcludesNonFindCommands() {
        let cases: [(name: String, modifiers: NSEvent.ModifierFlags, chars: String, keyCode: UInt16)] = [
            ("cmd-n", [.command], "n", 45),
            ("cmd-w", [.command], "w", 13),
            ("cmd-l", [.command], "l", 37),
            ("cmd-option-f", [.command, .option], "f", 3),
            ("cmd-shift-g-toggle-react-grab", [.command, .shift], "g", 5),
        ]

        for testCase in cases {
            let event = makeKeyEvent(
                modifierFlags: testCase.modifiers,
                characters: testCase.chars,
                charactersIgnoringModifiers: testCase.chars,
                keyCode: testCase.keyCode
            )
            XCTAssertFalse(
                shouldRouteBrowserFindCommandEquivalentThroughWebContentFirst(event),
                "Did not expect browser-first routing for \(testCase.name)"
            )
        }
    }

    func testInlineVSCodeCommandPaletteShortcutRoutesThroughWebContentForTrackedServeWebOrigin() {
        let event = makeKeyEvent(
            modifierFlags: [.command, .shift],
            characters: "P",
            charactersIgnoringModifiers: "p",
            keyCode: 35
        )
        let pageURL = URL(string: "http://127.0.0.1:63266/?folder=%2FUsers%2Ftester%2Fproject")!

        XCTAssertTrue(
            shouldRouteInlineVSCodeCommandPaletteShortcutThroughWebContentFirst(
                event,
                pageURL: pageURL,
                inlineVSCodeURLMatcher: { $0 == pageURL },
                shortcutForAction: { action in
                    XCTAssertEqual(action, .commandPalette)
                    return StoredShortcut(key: "p", command: true, shift: true, option: false, control: false, keyCode: 35)
                }
            ),
            "Expected Cmd+Shift+P to stay inside inline VS Code when the focused browser URL belongs to the live serve-web process"
        )
    }

    func testInlineVSCodeCommandPaletteShortcutDoesNotRouteForUntrackedLocalhostPage() {
        let event = makeKeyEvent(
            modifierFlags: [.command, .shift],
            characters: "P",
            charactersIgnoringModifiers: "p",
            keyCode: 35
        )
        let pageURL = URL(string: "http://127.0.0.1:3000/?folder=%2FUsers%2Ftester%2Fproject")!

        XCTAssertFalse(
            shouldRouteInlineVSCodeCommandPaletteShortcutThroughWebContentFirst(
                event,
                pageURL: pageURL,
                inlineVSCodeURLMatcher: { _ in false },
                shortcutForAction: { _ in
                    StoredShortcut(key: "p", command: true, shift: true, option: false, control: false, keyCode: 35)
                }
            ),
            "A localhost page with a folder query must not steal cmux's command palette shortcut unless it is the tracked VS Code serve-web origin"
        )
    }

    func testInlineVSCodeCommandPaletteShortcutDoesNotRouteUnrelatedShortcut() {
        let event = makeKeyEvent(
            modifierFlags: [.command],
            characters: "l",
            charactersIgnoringModifiers: "l",
            keyCode: 37
        )
        let pageURL = URL(string: "http://127.0.0.1:63266/?folder=%2FUsers%2Ftester%2Fproject")!

        XCTAssertFalse(
            shouldRouteInlineVSCodeCommandPaletteShortcutThroughWebContentFirst(
                event,
                pageURL: pageURL,
                inlineVSCodeURLMatcher: { $0 == pageURL },
                shortcutForAction: { _ in
                    StoredShortcut(key: "p", command: true, shift: true, option: false, control: false, keyCode: 35)
                }
            ),
            "Only the configured command palette shortcut should bypass cmux for inline VS Code"
        )
    }

    // MARK: - Non-Latin keyboard layout shortcut tests

    func testCmdTWorksWithRussianKeyboardLayout() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        // Simulate Russian keyboard: layout provider returns "t" via ASCII fallback,
        // but event.charactersIgnoringModifiers returns Cyrillic "е".
        appDelegate.shortcutLayoutCharacterProvider = { keyCode, _ in
            keyCode == 17 ? "t" : nil
        }
        defer {
            appDelegate.shortcutLayoutCharacterProvider = KeyboardLayout.character(forKeyCode:modifierFlags:)
        }

        let event = makeKeyEvent(
            modifierFlags: [.command],
            characters: "t",
            charactersIgnoringModifiers: "е", // Cyrillic е (Russian layout)
            keyCode: 17 // kVK_ANSI_T
        )

#if DEBUG
        XCTAssertTrue(
            appDelegate.debugMatchesConfiguredShortcut(event: event, action: .newSurface),
            "Cmd+T should match the new surface shortcut with Russian keyboard layout"
        )
#else
        XCTFail("debugMatchesConfiguredShortcut is only available in DEBUG")
#endif
    }

    func testCmdTFallsBackToKeyCodeWithNonLatinLayoutWhenLayoutTranslationFails() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        // Simulate non-Latin layout where layout translation also fails (returns nil).
        // The ANSI keyCode fallback should still match the physical T key.
        appDelegate.shortcutLayoutCharacterProvider = { _, _ in nil }
        defer {
            appDelegate.shortcutLayoutCharacterProvider = KeyboardLayout.character(forKeyCode:modifierFlags:)
        }

        let event = makeKeyEvent(
            modifierFlags: [.command],
            characters: "",
            charactersIgnoringModifiers: "е", // Cyrillic е — non-ASCII
            keyCode: 17 // kVK_ANSI_T
        )

#if DEBUG
        XCTAssertTrue(
            appDelegate.debugMatchesConfiguredShortcut(event: event, action: .newSurface),
            "Cmd+T should fall back to keyCode with non-Latin layout"
        )
#else
        XCTFail("debugMatchesConfiguredShortcut is only available in DEBUG")
#endif
    }

    func testFocusedTerminalTypingRepairCoversLostFirstResponderStates() {
        XCTAssertTrue(
            focusedTerminalKeyRepairNeeded(
                responderIsWindow: true,
                responderHasViableKeyRoutingOwner: true,
                responderMatchesPreferredKeyboardFocus: true
            ),
            "Typing should repair focus when the first responder has fallen back to the window"
        )
        XCTAssertTrue(
            focusedTerminalKeyRepairNeeded(
                responderIsWindow: false,
                responderHasViableKeyRoutingOwner: false,
                responderMatchesPreferredKeyboardFocus: true
            ),
            "Typing should repair focus when the responder no longer has a viable key-routing owner"
        )
    }

    func testPrintableOptionTextBypassesConfiguredShortcutRouting() throws {
#if DEBUG
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let manager = appDelegate.tabManagerFor(windowId: windowId) else {
            XCTFail("Expected test window context")
            return
        }

        let workspaceCountBefore = manager.tabs.count
        let optionQShortcut = StoredShortcut(
            key: "q",
            command: false,
            shift: false,
            option: true,
            control: false
        )

        withTemporaryShortcut(action: .newTab, shortcut: optionQShortcut) {
            guard let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.option],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: "@",
                charactersIgnoringModifiers: "q",
                isARepeat: false,
                keyCode: 12 // kVK_ANSI_Q
            ) else {
                XCTFail("Failed to construct Turkish-Q Option+Q event")
                return
            }

            XCTAssertFalse(
                appDelegate.debugHandleCustomShortcut(event: event),
                "Option+Q that produces @ on Turkish Q should pass through as text input"
            )
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

            XCTAssertEqual(
                manager.tabs.count,
                workspaceCountBefore,
                "Printable Option text should not trigger the remapped New Workspace shortcut"
            )
        }
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG builds")
#endif
    }

    func testWindowSendEventRepairsLostFirstResponderForFocusedTerminalTyping() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let contentView = window.contentView,
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let terminalPanel = workspace.terminalPanel(for: panelId),
              let terminalView = surfaceView(in: terminalPanel.hostedView) else {
            XCTFail("Expected focused terminal surface")
            return
        }

        let driftedResponder = FocusableTestView(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        contentView.addSubview(driftedResponder)
        defer { driftedResponder.removeFromSuperview() }

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        terminalPanel.hostedView.setVisibleInUI(true)
        terminalPanel.hostedView.setActive(true)
        terminalPanel.hostedView.moveFocus()
        waitFor(timeout: 1.0, until: { terminalPanel.hostedView.isSurfaceViewFirstResponder() })

        XCTAssertTrue(
            terminalPanel.hostedView.isSurfaceViewFirstResponder(),
            "Expected terminal surface to own first responder before repair test"
        )

        XCTAssertTrue(window.makeFirstResponder(driftedResponder), "Expected test responder to accept first responder")
        waitFor(timeout: 1.0, until: { window.firstResponder === driftedResponder })

        XCTAssertFalse(
            terminalPanel.hostedView.isSurfaceViewFirstResponder(),
            "Expected terminal surface to lose first responder before repaired typing"
        )
        XCTAssertTrue(window.firstResponder === driftedResponder, "Expected a drifted key-routing responder")

        guard let keyDown = makeKeyDownEvent(
            key: "a",
            modifiers: [],
            keyCode: 0,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct typing event")
            return
        }

        window.sendEvent(keyDown)
        waitFor(timeout: 1.0, until: { terminalPanel.hostedView.isSurfaceViewFirstResponder() })

        XCTAssertTrue(
            terminalPanel.hostedView.isSurfaceViewFirstResponder(),
            "Typing should repair first responder back to the focused terminal surface"
        )
        XCTAssertTrue(
            window.firstResponder === terminalView,
            "Typing repair should restore the Ghostty surface view as first responder"
        )
    }

    func testWindowPerformKeyEquivalentDefersTerminalPasteMenuMissToGhosttyBindingResolution() {
        let previousMainMenu = NSApp.mainMenu
        let probeWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let contentView = NSView(frame: probeWindow.contentRect(forFrameRect: probeWindow.frame))
        let probeView = GhosttyCommandEquivalentProbeView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))

        defer {
            NSApp.mainMenu = previousMainMenu
            probeWindow.orderOut(nil)
        }

        let emptyMenu = NSMenu(title: "Test")
        emptyMenu.addItem(withTitle: "Placeholder", action: nil, keyEquivalent: "")
        NSApp.mainMenu = emptyMenu

        probeWindow.contentView = contentView
        contentView.addSubview(probeView)
        probeWindow.makeKeyAndOrderFront(nil)
        probeWindow.displayIfNeeded()
        XCTAssertTrue(probeWindow.makeFirstResponder(probeView), "Expected probe Ghostty view to own first responder")

        guard let event = makeKeyDownEvent(
            key: "v",
            modifiers: [.command],
            keyCode: 9,
            windowNumber: probeWindow.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+V event")
            return
        }

        XCTAssertTrue(
            probeWindow.performKeyEquivalent(with: event),
            "Cmd+V menu miss should still route through Ghostty binding resolution"
        )
        XCTAssertEqual(probeView.afterMenuMissCallCount, 1, "Ghostty binding resolution should run after the menu miss")
        XCTAssertEqual(probeView.pasteCallCount, 0, "Window routing must not force paste before Ghostty inspects bindings")
        XCTAssertEqual(
            probeView.pasteAsPlainTextCallCount,
            0,
            "Window routing must not force plain-text paste before Ghostty inspects bindings"
        )
    }

    func testClearedCmdDSuppressesStaleSplitRightMenuShortcut() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        guard let event = makeKeyDownEvent(
            key: "d",
            modifiers: [.command],
            keyCode: 2,
            windowNumber: 0
        ) else {
            XCTFail("Failed to construct Cmd+D event")
            return
        }

        withTemporaryShortcut(action: .splitRight, shortcut: .unbound) {
            XCTAssertTrue(
                appDelegate.shouldSuppressStaleCmuxMenuShortcut(event: event),
                "Cleared Cmd+D should suppress the stale split-right menu equivalent"
            )
#if DEBUG
            XCTAssertFalse(
                appDelegate.debugMatchesConfiguredShortcut(event: event, action: .splitRight),
                "Cleared Cmd+D should not still match splitRight"
            )
#endif
        }
    }

    func testRemappedSplitRightSuppressesStaleCmdDMenuShortcut() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        guard let staleCmdD = makeKeyDownEvent(
            key: "d",
            modifiers: [.command],
            keyCode: 2,
            windowNumber: 0
        ), let remappedCmdJ = makeKeyDownEvent(
            key: "j",
            modifiers: [.command],
            keyCode: 38,
            windowNumber: 0
        ) else {
            XCTFail("Failed to construct split-right shortcut events")
            return
        }

        let remappedSplitRight = StoredShortcut(
            key: "j",
            command: true,
            shift: false,
            option: false,
            control: false
        )

        withTemporaryShortcut(action: .splitRight, shortcut: remappedSplitRight) {
            XCTAssertTrue(
                appDelegate.shouldSuppressStaleCmuxMenuShortcut(event: staleCmdD),
                "Cmd+D should suppress its stale split-right menu equivalent after splitRight is remapped"
            )
            XCTAssertFalse(
                appDelegate.shouldSuppressStaleCmuxMenuShortcut(event: remappedCmdJ),
                "The current splitRight shortcut should not be treated as a stale menu shortcut"
            )
#if DEBUG
            XCTAssertFalse(
                appDelegate.debugMatchesConfiguredShortcut(event: staleCmdD, action: .splitRight),
                "Stale Cmd+D should not still match splitRight after remapping"
            )
            XCTAssertTrue(
                appDelegate.debugMatchesConfiguredShortcut(event: remappedCmdJ, action: .splitRight),
                "Remapped Cmd+J should match splitRight"
            )
#endif
        }
    }

    func testCurrentGlobalSearchShortcutIsNotSuppressedAsStaleMenuShortcut() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        guard let event = makeKeyDownEvent(
            key: "d",
            modifiers: [.command],
            keyCode: 2,
            windowNumber: 0
        ) else {
            XCTFail("Failed to construct Cmd+D event")
            return
        }

        let remappedGlobalSearch = StoredShortcut(
            key: "d",
            command: true,
            shift: false,
            option: false,
            control: false
        )

        withTemporaryShortcut(action: .globalSearch, shortcut: remappedGlobalSearch) {
            XCTAssertFalse(
                appDelegate.shouldSuppressStaleCmuxMenuShortcut(event: event),
                "Current globalSearch remaps must not be treated as stale menu shortcuts"
            )
        }
    }

    func testCurrentNumberedDigitShortcutIsNotSuppressedAsStaleMenuShortcut() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        guard let event = makeKeyDownEvent(
            key: "2",
            modifiers: [.command],
            keyCode: 19,
            windowNumber: 0
        ) else {
            XCTFail("Failed to construct Cmd+2 event")
            return
        }

        let remappedWorkspaceNumber = StoredShortcut(
            key: "1",
            command: false,
            shift: false,
            option: false,
            control: true
        )
        let currentSurfaceNumber = StoredShortcut(
            key: "1",
            command: true,
            shift: false,
            option: false,
            control: false
        )

        withTemporaryShortcut(action: .selectWorkspaceByNumber, shortcut: remappedWorkspaceNumber) {
            withTemporaryShortcut(action: .selectSurfaceByNumber, shortcut: currentSurfaceNumber) {
                XCTAssertFalse(
                    appDelegate.shouldSuppressStaleCmuxMenuShortcut(event: event),
                    "A current numbered-digit shortcut must own Cmd+2 before stale menu suppression"
                )
            }
        }
    }

    func testStaleCloseDefaultShortcutsSuppressMenuFallbackAfterReassignment() {
        assertStaleCloseDefaultShortcutSuppressesMenuFallback(
            staleAction: .closeTab,
            replacementAction: .newTab,
            replacementShortcut: StoredShortcut(key: "w", command: true, shift: false, option: false, control: false),
            remappedStaleShortcut: StoredShortcut(key: "w", command: true, shift: false, option: true, control: false)
        )

        assertStaleCloseDefaultShortcutSuppressesMenuFallback(
            staleAction: .closeWorkspace,
            replacementAction: .newWindow,
            replacementShortcut: StoredShortcut(key: "w", command: true, shift: true, option: false, control: false),
            remappedStaleShortcut: StoredShortcut(key: "w", command: true, shift: true, option: true, control: false)
        )

        assertStaleCloseDefaultShortcutSuppressesMenuFallback(
            staleAction: .closeWindow,
            replacementAction: .toggleFullScreen,
            replacementShortcut: StoredShortcut(key: "w", command: true, shift: false, option: false, control: true),
            remappedStaleShortcut: StoredShortcut(key: "w", command: true, shift: false, option: true, control: true)
        )
    }

    func testReassignedCmdWSuppressesStaleCloseTabMenuAndRunsCurrentAction() {
#if DEBUG
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let context = makeRegisteredLightweightMainWindowContext(appDelegate: appDelegate)
        guard let initialSidebarVisible = appDelegate.sidebarVisibility(windowId: context.windowId) else {
            appDelegate.unregisterMainWindowContextForTesting(windowId: context.windowId, notifyObservers: false)
            closeTestWindow(context.window)
            XCTFail("Expected a main window context")
            return
        }

        let previousFocusContext = appDelegate.debugShortcutEventFocusContextOverride

        defer {
            appDelegate.debugShortcutEventFocusContextOverride = previousFocusContext
            appDelegate.unregisterMainWindowContextForTesting(windowId: context.windowId, notifyObservers: false)
            closeTestWindow(context.window)
        }
        appDelegate.debugShortcutEventFocusContextOverride = ShortcutEventFocusContext(
            browserPanel: nil,
            markdownPanel: nil,
            rightSidebarFocused: false
        )

        guard let event = makeKeyDownEvent(
            key: "w",
            modifiers: [.command],
            keyCode: 13,
            windowNumber: 0
        ) else {
            XCTFail("Failed to construct Cmd+W event")
            return
        }

        appDelegate.tabManager = context.tabManager

        let remappedCloseTab = StoredShortcut(key: "w", command: true, shift: false, option: true, control: false)
        let reassignedSidebarToggle = StoredShortcut(key: "w", command: true, shift: false, option: false, control: false)

        withTemporaryShortcut(action: .closeTab, shortcut: remappedCloseTab) {
            withTemporaryShortcut(action: .toggleSidebar, shortcut: reassignedSidebarToggle) {
                XCTAssertTrue(
                    appDelegate.shouldSuppressStaleCmuxMenuShortcut(event: event),
                    "A stale Cmd+W Close Tab menu item should be suppressed after Close Tab is remapped"
                )
                XCTAssertFalse(
                    appDelegate.debugMatchesConfiguredShortcut(event: event, action: .closeTab),
                    "Plain Cmd+W must not match Close Tab after Close Tab is remapped away"
                )
                XCTAssertTrue(
                    appDelegate.debugMatchesConfiguredShortcut(event: event, action: .toggleSidebar),
                    "Plain Cmd+W should match the action currently assigned to Cmd+W"
                )
                XCTAssertTrue(
                    appDelegate.toggleSidebarInActiveMainWindow(preferredWindow: context.window),
                    "The current Cmd+W action should run in the preferred window scope"
                )
            }
        }

        XCTAssertEqual(
            appDelegate.sidebarVisibility(windowId: context.windowId),
            !initialSidebarVisible,
            "The action currently assigned to Cmd+W should run before stale Close Tab menu fallback"
        )
#else
        XCTFail("Shortcut routing test hooks are only available in DEBUG")
#endif
    }

    func testApplicationSendEventSuppressesRemappedCmdDStaleMenuShortcut() {
        let previousMainMenu = NSApp.mainMenu
        let probeWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let contentView = NSView(frame: probeWindow.contentRect(forFrameRect: probeWindow.frame))
        let focusableView = FocusableTestView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
        let menuProbe = MenuActionProbe()

        defer {
            NSApp.mainMenu = previousMainMenu
            probeWindow.orderOut(nil)
        }

        let staleMenu = NSMenu(title: "Test")
        let staleSplitItem = NSMenuItem(
            title: "Split Right",
            action: #selector(MenuActionProbe.perform(_:)),
            keyEquivalent: "d"
        )
        staleSplitItem.keyEquivalentModifierMask = [.command]
        staleSplitItem.target = menuProbe
        staleMenu.addItem(staleSplitItem)
        NSApp.mainMenu = staleMenu

        probeWindow.contentView = contentView
        contentView.addSubview(focusableView)
        probeWindow.makeKeyAndOrderFront(nil)
        probeWindow.displayIfNeeded()
        XCTAssertTrue(probeWindow.makeFirstResponder(focusableView), "Expected probe view to own first responder")

        guard let event = makeKeyDownEvent(
            key: "d",
            modifiers: [.command],
            keyCode: 2,
            windowNumber: probeWindow.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+D event")
            return
        }

        let remappedSplitRight = StoredShortcut(
            key: "j",
            command: true,
            shift: false,
            option: false,
            control: false
        )
        withTemporaryShortcut(action: .splitRight, shortcut: remappedSplitRight) {
            NSApp.sendEvent(event)
        }

        XCTAssertEqual(menuProbe.callCount, 0, "App-level Cmd+D dispatch must not fire a stale split menu item after remap")
    }

    func testApplicationSendEventRoutesCmdDMenuEquivalentToActiveShortcutRecorder() {
#if DEBUG
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }
        let previousMainMenu = NSApp.mainMenu
        let recorder = ShortcutRecorderNSButton(frame: NSRect(x: 0, y: 0, width: 160, height: 28))
        let menuProbe = MenuActionProbe()
        var recordedShortcut: StoredShortcut?

        defer {
            KeyboardShortcutRecorderActivity.stopAllRecording()
            NSApp.mainMenu = previousMainMenu
        }

        let menu = NSMenu(title: "Test")
        let splitItem = NSMenuItem(
            title: "Split Right",
            action: #selector(MenuActionProbe.perform(_:)),
            keyEquivalent: "d"
        )
        splitItem.keyEquivalentModifierMask = [.command]
        splitItem.target = menuProbe
        menu.addItem(splitItem)
        NSApp.mainMenu = menu

        recorder.onShortcutRecorded = { recordedShortcut = $0 }
        recorder.debugBeginRecordingWithoutEventMonitorForTesting()
        XCTAssertTrue(recorder.debugIsRecording)

        guard let event = makeKeyDownEvent(
            key: "d",
            modifiers: [.command],
            keyCode: 2,
            windowNumber: 0
        ) else {
            XCTFail("Failed to construct Cmd+D event")
            return
        }

        withTemporaryShortcut(action: .splitRight) {
            XCTAssertTrue(
                appDelegate.handleApplicationSendEventPreflight(
                    event: event,
                    preferredWindow: nil,
                    keyWindow: nil,
                    mainWindow: nil
                ),
                "App-level sendEvent preflight should route active shortcut recorder events before menu equivalents"
            )
        }

        XCTAssertEqual(
            recordedShortcut,
            StoredShortcut(key: "d", command: true, shift: false, option: false, control: false, keyCode: 2),
            "Cmd+D must remain recordable while the same menu equivalent is installed"
        )
        XCTAssertEqual(menuProbe.callCount, 0, "The menu equivalent must not fire while the recorder is capturing")
#else
        XCTFail("Shortcut recorder debug hooks are only available in DEBUG")
#endif
    }

    func testFocusedTerminalTypingRepairCoversVisibleSameWindowResponderDrift() {
        XCTAssertTrue(
            focusedTerminalKeyRepairNeeded(
                responderIsWindow: false,
                responderHasViableKeyRoutingOwner: true,
                responderMatchesPreferredKeyboardFocus: false
            ),
            "Typing should repair focus when a visible same-window responder is not the focused terminal's preferred keyboard target"
        )
        XCTAssertFalse(
            focusedTerminalKeyRepairNeeded(
                responderIsWindow: false,
                responderHasViableKeyRoutingOwner: true,
                responderMatchesPreferredKeyboardFocus: true
            ),
            "Typing should not repair focus away from a live responder that already matches the focused terminal's preferred keyboard target"
        )
    }

    func testFocusTextBoxShortcutMovesFocusBackToTerminalWhenTextBoxIsFirstResponder() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let contentView = window.contentView,
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let terminalPanel = workspace.terminalPanel(for: panelId),
              let terminalView = surfaceView(in: terminalPanel.hostedView) else {
            XCTFail("Expected focused terminal surface")
            return
        }

        let textBoxView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        textBoxView.onFocusTextBox = { terminalPanel.textBoxDidBecomeFocused() }
        textBoxView.onToggleFocus = { _ = terminalPanel.focusTextBoxInputOrTerminal() }
        let textBoxScrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        textBoxScrollView.documentView = textBoxView
        contentView.addSubview(textBoxScrollView)
        defer { textBoxScrollView.removeFromSuperview() }

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        terminalPanel.hostedView.setVisibleInUI(true)
        terminalPanel.hostedView.setActive(true)
        terminalPanel.hostedView.moveFocus()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertTrue(
            terminalPanel.hostedView.isSurfaceViewFirstResponder(),
            "Expected terminal surface to own first responder before TextBox focus"
        )

        terminalPanel.registerTextBoxInputView(textBoxView)
        XCTAssertTrue(terminalPanel.toggleTextBoxInput())
        waitFor(
            timeout: 1.0,
            until: { window.firstResponder === textBoxView }
        )

        XCTAssertTrue(window.firstResponder === textBoxView, "Expected TextBox to own first responder")
        XCTAssertEqual(
            terminalPanel.captureFocusIntent(in: window),
            .terminal(.textBoxInput),
            "TextBox focus must be represented as a terminal panel focus intent"
        )

        let focusTextBoxShortcut = StoredShortcut(
            key: "a",
            command: true,
            shift: true,
            option: false,
            control: false,
            keyCode: 0
        )
        guard let event = makeKeyDownEvent(
            shortcut: focusTextBoxShortcut,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+Shift+A event")
            return
        }

        withTemporaryShortcut(action: .focusTextBoxInput, shortcut: focusTextBoxShortcut) {
#if DEBUG
            XCTAssertTrue(
                appDelegate.debugHandleCustomShortcut(event: event),
                "Cmd+Shift+A from TextBox should route through the configured TextBox focus shortcut"
            )
#else
            XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
        }
        waitFor(
            timeout: 1.0,
            until: { terminalPanel.hostedView.isSurfaceViewFirstResponder() }
        )

        XCTAssertTrue(
            terminalPanel.hostedView.isSurfaceViewFirstResponder(),
            "Cmd+Shift+A from TextBox must move AppKit first responder back to the terminal"
        )
        XCTAssertTrue(window.firstResponder === terminalView, "Terminal must be the only focused input endpoint")
        XCTAssertEqual(terminalPanel.captureFocusIntent(in: window), .terminal(.surface))
    }

    func testTextBoxSecondEscapeDoesNotHideWhenAnotherResponderOwnsFocus() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let contentView = window.contentView,
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let terminalPanel = workspace.terminalPanel(for: panelId) else {
            XCTFail("Expected focused terminal panel")
            return
        }

        let textBoxView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        let textBoxScrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        textBoxScrollView.documentView = textBoxView
        let otherView = FocusableTestView(frame: NSRect(x: 0, y: 36, width: 120, height: 24))
        contentView.addSubview(textBoxScrollView)
        contentView.addSubview(otherView)
        defer {
            textBoxScrollView.removeFromSuperview()
            otherView.removeFromSuperview()
        }

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        terminalPanel.hostedView.setVisibleInUI(true)
        terminalPanel.hostedView.setActive(true)
        terminalPanel.registerTextBoxInputView(textBoxView)
        XCTAssertTrue(terminalPanel.toggleTextBoxInput())
        waitFor(
            timeout: 1.0,
            until: { window.firstResponder === textBoxView }
        )

        XCTAssertTrue(window.firstResponder === textBoxView)
        terminalPanel.handleTextBoxEscape()
        XCTAssertTrue(terminalPanel.isTextBoxActive)
        XCTAssertTrue(window.makeFirstResponder(otherView))

        XCTAssertFalse(terminalPanel.consumeTextBoxHideEscapeIfArmed(in: window))
        XCTAssertTrue(
            terminalPanel.isTextBoxActive,
            "Second Escape must not hide TextBox while another main-window control owns focus"
        )
    }

    func testTextBoxSecondEscapeHidesWhenTerminalSurfaceOwnsFocus() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let contentView = window.contentView,
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let terminalPanel = workspace.terminalPanel(for: panelId) else {
            XCTFail("Expected focused terminal panel")
            return
        }

        let textBoxView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        let textBoxScrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        textBoxScrollView.documentView = textBoxView
        contentView.addSubview(textBoxScrollView)
        defer { textBoxScrollView.removeFromSuperview() }

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        terminalPanel.hostedView.setVisibleInUI(true)
        terminalPanel.hostedView.setActive(true)
        terminalPanel.hostedView.moveFocus()
        terminalPanel.registerTextBoxInputView(textBoxView)
        XCTAssertTrue(terminalPanel.toggleTextBoxInput())
        waitFor(
            timeout: 1.0,
            until: { window.firstResponder === textBoxView }
        )

        terminalPanel.handleTextBoxEscape()
        waitFor(
            timeout: 1.0,
            until: { terminalPanel.hostedView.isSurfaceViewFirstResponder() }
        )

        XCTAssertTrue(terminalPanel.hostedView.isSurfaceViewFirstResponder())
        XCTAssertTrue(terminalPanel.consumeTextBoxHideEscapeIfArmed(in: window))
        XCTAssertFalse(terminalPanel.isTextBoxActive)
    }

    func testTextBoxSecondEscapeAfterFocusMovesToAnotherSplitClearsArmWithoutHiding() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let contentView = window.contentView,
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace,
              let leftPanelId = workspace.focusedPanelId,
              let leftPanel = workspace.terminalPanel(for: leftPanelId),
              let rightPanel = workspace.newTerminalSplit(from: leftPanelId, orientation: .horizontal, focus: false) else {
            XCTFail("Expected split terminal panels")
            return
        }

        let textBoxView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        let textBoxScrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        textBoxScrollView.documentView = textBoxView
        contentView.addSubview(textBoxScrollView)
        defer { textBoxScrollView.removeFromSuperview() }

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        leftPanel.hostedView.setVisibleInUI(true)
        leftPanel.hostedView.setActive(true)
        leftPanel.hostedView.moveFocus()
        leftPanel.registerTextBoxInputView(textBoxView)
        XCTAssertTrue(leftPanel.toggleTextBoxInput())
        waitFor(timeout: 1.0, until: { window.firstResponder === textBoxView })

        leftPanel.handleTextBoxEscape()
        XCTAssertTrue(leftPanel.isTextBoxActive)
#if DEBUG
        XCTAssertTrue(leftPanel.debugHasTextBoxHideEscapeArm)
#endif
        workspace.focusPanel(rightPanel.id)
        XCTAssertEqual(workspace.focusedPanelId, rightPanel.id)
#if DEBUG
        XCTAssertFalse(leftPanel.debugHasTextBoxHideEscapeArm)
#endif

        XCTAssertFalse(manager.consumeFocusedTerminalTextBoxHideEscapeIfArmed(in: window))
        XCTAssertTrue(
            leftPanel.isTextBoxActive,
            "Escape after moving to another split should not hide or refocus the stale split"
        )
    }

    func testTextBoxFilePanelFocusRestorerRefocusesAfterSheetEnds() {
        let hostWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 80),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 80))
        let otherView = FocusableTestView(frame: NSRect(x: 0, y: 40, width: 320, height: 40))
        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        let textBoxScrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textBoxScrollView.documentView = textView
        contentView.addSubview(otherView)
        contentView.addSubview(textBoxScrollView)
        hostWindow.animationBehavior = .none
        hostWindow.isReleasedWhenClosed = false
        hostWindow.contentView = contentView
        hostWindow.makeKeyAndOrderFront(nil)
        Self.retainedTextBoxUndoWindows.append(hostWindow)
        defer { hostWindow.orderOut(nil) }

        XCTAssertTrue(hostWindow.makeFirstResponder(otherView))
        XCTAssertTrue(hostWindow.firstResponder === otherView)

        let restorer = TextBoxFilePanelFocusRestorer(textView: textView)
        restorer.install(parentWindow: hostWindow)
        NotificationCenter.default.post(name: NSWindow.didEndSheetNotification, object: hostWindow)
        waitFor(timeout: 1.0, until: { hostWindow.firstResponder === textView })

        XCTAssertTrue(hostWindow.firstResponder === textView)

        XCTAssertTrue(hostWindow.makeFirstResponder(otherView))
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: hostWindow)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertTrue(hostWindow.firstResponder === otherView)
    }

    func testFocusTextBoxShortcutRoutesToEventWindowWhenActiveManagerIsStale() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let firstWindowId = appDelegate.createMainWindow()
        let secondWindowId = appDelegate.createMainWindow()

        defer {
            closeWindow(withId: firstWindowId)
            closeWindow(withId: secondWindowId)
        }

        guard let firstManager = appDelegate.tabManagerFor(windowId: firstWindowId),
              let secondManager = appDelegate.tabManagerFor(windowId: secondWindowId),
              let secondWindow = window(withId: secondWindowId),
              let firstPanel = firstManager.selectedWorkspace?.focusedTerminalPanel,
              let secondPanel = secondManager.selectedWorkspace?.focusedTerminalPanel else {
            XCTFail("Expected both window contexts to exist")
            return
        }

        appDelegate.tabManager = firstManager
        XCTAssertTrue(appDelegate.tabManager === firstManager)

        let focusTextBoxShortcut = StoredShortcut(
            key: "a",
            command: true,
            shift: true,
            option: false,
            control: false,
            keyCode: 0
        )
        guard let event = makeKeyDownEvent(
            shortcut: focusTextBoxShortcut,
            windowNumber: secondWindow.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+Shift+A event")
            return
        }

        withTemporaryShortcut(action: .focusTextBoxInput, shortcut: focusTextBoxShortcut) {
#if DEBUG
            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
            XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
        }

        XCTAssertFalse(firstPanel.isTextBoxActive, "Cmd+Shift+A must not activate TextBox in the stale active window")
        XCTAssertTrue(secondPanel.isTextBoxActive, "Cmd+Shift+A should activate TextBox in the event window")
    }

    func testTextBoxFocusIntentRestoresAfterYieldToAnotherPanel() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let contentView = window.contentView,
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let terminalPanel = workspace.terminalPanel(for: panelId) else {
            XCTFail("Expected focused terminal surface")
            return
        }

        let textBoxView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        textBoxView.onFocusTextBox = { terminalPanel.textBoxDidBecomeFocused() }
        let textBoxScrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        textBoxScrollView.documentView = textBoxView
        contentView.addSubview(textBoxScrollView)
        defer { textBoxScrollView.removeFromSuperview() }

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        terminalPanel.hostedView.setVisibleInUI(true)
        terminalPanel.hostedView.setActive(true)

        terminalPanel.registerTextBoxInputView(textBoxView)
        XCTAssertTrue(terminalPanel.toggleTextBoxInput())
        waitFor(
            timeout: 1.0,
            until: { window.firstResponder === textBoxView }
        )

        XCTAssertTrue(window.firstResponder === textBoxView, "Expected TextBox focus before yielding")
        XCTAssertTrue(terminalPanel.yieldFocusIntent(.terminal(.textBoxInput), in: window))
        XCTAssertFalse(window.firstResponder === textBoxView, "Yielding to another panel must release AppKit first responder")
        XCTAssertEqual(
            terminalPanel.preferredFocusIntentForActivation(),
            .terminal(.textBoxInput),
            "Yielding TextBox focus should preserve the user's preferred left-pane input target"
        )

        XCTAssertTrue(terminalPanel.restoreFocusIntent(.terminal(.textBoxInput)))
        waitFor(
            timeout: 1.0,
            until: { window.firstResponder === textBoxView }
        )
        XCTAssertTrue(window.firstResponder === textBoxView, "Returning to the panel should restore TextBox focus")
        XCTAssertEqual(terminalPanel.captureFocusIntent(in: window), .terminal(.textBoxInput))
    }

    func testTextBoxShortcutReturnsToTextBoxAfterTerminalRegainsFocus() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let contentView = window.contentView,
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let terminalPanel = workspace.terminalPanel(for: panelId),
              let terminalView = surfaceView(in: terminalPanel.hostedView) else {
            XCTFail("Expected focused terminal surface")
            return
        }

        let textBoxView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        textBoxView.onFocusTextBox = { terminalPanel.textBoxDidBecomeFocused() }
        let textBoxScrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        textBoxScrollView.documentView = textBoxView
        contentView.addSubview(textBoxScrollView)
        defer { textBoxScrollView.removeFromSuperview() }

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        terminalPanel.hostedView.setVisibleInUI(true)
        terminalPanel.hostedView.setActive(true)
        terminalPanel.registerTextBoxInputView(textBoxView)
        XCTAssertTrue(terminalPanel.toggleTextBoxInput())
        waitFor(timeout: 1.0, until: { window.firstResponder === textBoxView })

        XCTAssertTrue(window.makeFirstResponder(terminalView))
        terminalPanel.terminalDidBecomeFocused()
        XCTAssertEqual(terminalPanel.captureFocusIntent(in: window), .terminal(.surface))

        XCTAssertTrue(terminalPanel.focusTextBoxInputOrTerminal())
        waitFor(timeout: 1.0, until: { window.firstResponder === textBoxView })
        XCTAssertTrue(window.firstResponder === textBoxView, "Shortcut should focus the TextBox after terminal focus is recorded")
        XCTAssertEqual(terminalPanel.captureFocusIntent(in: window), .terminal(.textBoxInput))
    }

    func testTextBoxFocusInNonFocusedSplitUpdatesFocusedPanel() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let contentView = window.contentView,
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace,
              let leftPanelId = workspace.focusedPanelId,
              let leftPanel = workspace.terminalPanel(for: leftPanelId),
              let rightPanel = workspace.newTerminalSplit(from: leftPanelId, orientation: .horizontal) else {
            XCTFail("Expected split terminal panels")
            return
        }

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        workspace.focusPanel(leftPanel.id)
        waitFor(
            timeout: 1.0,
            until: { workspace.focusedPanelId == leftPanel.id }
        )
        XCTAssertEqual(workspace.focusedPanelId, leftPanel.id, "Test should start with the left split focused")

        let rightTextBoxInputView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        rightTextBoxInputView.onFocusTextBox = {
            rightPanel.textBoxDidBecomeFocused()
            workspace.focusPanel(rightPanel.id, trigger: .terminalFirstResponder)
        }
        let textBoxScrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        textBoxScrollView.documentView = rightTextBoxInputView
        contentView.addSubview(textBoxScrollView)
        defer { textBoxScrollView.removeFromSuperview() }
        rightPanel.registerTextBoxInputView(rightTextBoxInputView)

        window.makeFirstResponder(rightTextBoxInputView)
        waitFor(
            timeout: 2.0,
            until: {
                return workspace.focusedPanelId == rightPanel.id &&
                    window.firstResponder === rightTextBoxInputView
            }
        )

        XCTAssertEqual(
            workspace.focusedPanelId,
            rightPanel.id,
            "Focusing a TextBox in another split must move the workspace focus to its owning panel"
        )
        XCTAssertTrue(
            window.firstResponder === rightPanel.textBoxInputView,
            "The TextBox should remain the only focused input endpoint after the split focus update"
        )
        XCTAssertEqual(rightPanel.captureFocusIntent(in: window), .terminal(.textBoxInput))
    }

    func testTextBoxPendingFocusIsCanceledOnUnfocusBeforeViewRegisters() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let terminalPanel = workspace.terminalPanel(for: panelId) else {
            XCTFail("Expected focused terminal surface")
            return
        }

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        XCTAssertTrue(terminalPanel.focusTextBoxInputOrTerminal())
#if DEBUG
        XCTAssertTrue(terminalPanel.debugHasPendingTextBoxFocusRequest)
#endif
        terminalPanel.unfocus()
#if DEBUG
        XCTAssertFalse(
            terminalPanel.debugHasPendingTextBoxFocusRequest,
            "Panel unfocus must cancel stale pending TextBox focus and file picker requests"
        )
#endif
    }

    func testTextBoxPendingFocusRunsWhenTextViewMovesToWindow() {
        let terminalPanel = TerminalPanel(workspaceId: UUID())
        defer { terminalPanel.surface.teardownSurface() }

        XCTAssertTrue(terminalPanel.focusTextBoxInputOrTerminal())
#if DEBUG
        XCTAssertTrue(terminalPanel.debugHasPendingTextBoxFocusRequest)
#endif

        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        textView.onMoveToWindow = { [weak terminalPanel] view in
            terminalPanel?.textBoxInputViewDidMoveToWindow(view)
        }
        terminalPanel.registerTextBoxInputView(textView)
#if DEBUG
        XCTAssertTrue(terminalPanel.debugHasPendingTextBoxFocusRequest)
#endif

        let textBoxScrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        let hostWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 30),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        hostWindow.animationBehavior = .none
        hostWindow.isReleasedWhenClosed = false
        hostWindow.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        hostWindow.contentView?.addSubview(textBoxScrollView)
        hostWindow.makeKeyAndOrderFront(nil)
        Self.retainedTextBoxUndoWindows.append(hostWindow)
        defer {
            textView.onMoveToWindow = { _ in }
            hostWindow.orderOut(nil)
        }
        textBoxScrollView.documentView = textView
        XCTAssertTrue(textView.window === hostWindow)

#if DEBUG
        waitFor(timeout: 1.0, until: {
            hostWindow.firstResponder === textView
                && !terminalPanel.debugHasPendingTextBoxFocusRequest
        })
#else
        waitFor(timeout: 1.0, until: { hostWindow.firstResponder === textView })
#endif
        XCTAssertTrue(hostWindow.firstResponder === textView)
#if DEBUG
        XCTAssertFalse(terminalPanel.debugHasPendingTextBoxFocusRequest)
#endif
    }

    func testTextBoxFocusShortcutReportsUnhandledWhenTerminalCannotReceiveFocus() {
        let terminalPanel = TerminalPanel(workspaceId: UUID())
        defer { terminalPanel.surface.teardownSurface() }

        XCTAssertTrue(terminalPanel.focusTextBoxInputOrTerminal())
        XCTAssertFalse(
            terminalPanel.focusTextBoxInputOrTerminal(),
            "Returning from TextBox focus to the terminal should only consume the shortcut when terminal focus succeeds"
        )
    }

    func testTextBoxSessionRestoreShowsDraftWithoutStealingFocus() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let terminalPanel = workspace.terminalPanel(for: panelId) else {
            XCTFail("Expected focused terminal surface")
            return
        }

        terminalPanel.restoreSessionTextBoxDraft(SessionTextBoxInputDraftSnapshot(
            isActive: true,
            parts: [.text("restore me")]
        ))

        XCTAssertTrue(terminalPanel.isTextBoxActive)
        XCTAssertEqual(terminalPanel.textBoxContent, "restore me")
        XCTAssertEqual(terminalPanel.preferredFocusIntentForActivation(), .terminal(.textBoxInput))
#if DEBUG
        XCTAssertFalse(
            terminalPanel.debugHasPendingTextBoxFocusRequest,
            "Visible restored TextBox drafts must not queue first-responder focus"
        )
#endif
    }

    func testTextBoxMentionCompletionDetectsFileAndSkillTokens() {
        let filePrompt = "open @Sources/TextBox"
        let fileQuery = TextBoxMentionCompletionDetector.query(
            in: filePrompt,
            selectedRange: NSRange(location: (filePrompt as NSString).length, length: 0)
        )
        XCTAssertEqual(fileQuery?.kind, .file)
        XCTAssertEqual(fileQuery?.trigger, "@")
        XCTAssertEqual(fileQuery?.query, "Sources/TextBox")
        XCTAssertEqual(fileQuery?.range, NSRange(location: 5, length: 16))

        let skillPrompt = "use /swift-guidance before editing"
        let cursor = (skillPrompt as NSString).range(of: " before").location
        let skillQuery = TextBoxMentionCompletionDetector.query(
            in: skillPrompt,
            selectedRange: NSRange(location: cursor, length: 0)
        )
        XCTAssertEqual(skillQuery?.kind, .skill)
        XCTAssertEqual(skillQuery?.trigger, "/")
        XCTAssertEqual(skillQuery?.query, "swift-guidance")
        XCTAssertEqual(skillQuery?.range, NSRange(location: 4, length: 15))

        let dollarSkillPrompt = "use $axiom-swift now"
        let dollarCursor = (dollarSkillPrompt as NSString).range(of: " now").location
        let dollarSkillQuery = TextBoxMentionCompletionDetector.query(
            in: dollarSkillPrompt,
            selectedRange: NSRange(location: dollarCursor, length: 0)
        )
        XCTAssertEqual(dollarSkillQuery?.kind, .skill)
        XCTAssertEqual(dollarSkillQuery?.trigger, "$")
        XCTAssertEqual(dollarSkillQuery?.query, "axiom-swift")
        XCTAssertEqual(dollarSkillQuery?.range, NSRange(location: 4, length: 12))

        let bareSlashPrompt = "cd /"
        let bareSlashQuery = TextBoxMentionCompletionDetector.query(
            in: bareSlashPrompt,
            selectedRange: NSRange(location: (bareSlashPrompt as NSString).length, length: 0)
        )
        XCTAssertEqual(bareSlashQuery?.kind, .skill)
        XCTAssertEqual(bareSlashQuery?.trigger, "/")
        XCTAssertEqual(bareSlashQuery?.query, "")

        let bareDollarPrompt = "echo $"
        let bareDollarQuery = TextBoxMentionCompletionDetector.query(
            in: bareDollarPrompt,
            selectedRange: NSRange(location: (bareDollarPrompt as NSString).length, length: 0)
        )
        XCTAssertEqual(bareDollarQuery?.kind, .skill)
        XCTAssertEqual(bareDollarQuery?.trigger, "$")
        XCTAssertEqual(bareDollarQuery?.query, "")

        let emailPrompt = "mail lawrence@example.com"
        XCTAssertNil(TextBoxMentionCompletionDetector.query(
            in: emailPrompt,
            selectedRange: NSRange(location: (emailPrompt as NSString).length, length: 0)
        ))
    }

    func testTextBoxMentionFileSuggestionsUseCommandPaletteSearchIndex() throws {
        var cache = TextBoxMentionFileIndexCache()
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-textbox-mentions-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: root) }

        let sourceDirectory = root.appendingPathComponent("Sources", isDirectory: true)
        try fileManager.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try "struct TextBoxInput {}".write(
            to: sourceDirectory.appendingPathComponent("TextBoxInput.swift"),
            atomically: true,
            encoding: .utf8
        )
        try "notes".write(
            to: root.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        let scanFiles: (URL) -> [TextBoxMentionCandidate] = { scannedRootURL in
            XCTAssertEqual(scannedRootURL.path, root.path)
            return [
                self.makeTextBoxMentionFileCandidate(
                    relativePath: "Sources/TextBoxInput.swift",
                    rootDirectory: root.path
                ),
                self.makeTextBoxMentionFileCandidate(
                    relativePath: "README.md",
                    rootDirectory: root.path
                )
            ]
        }

        let suggestions = cache.suggestions(
            for: TextBoxMentionQuery(
                kind: .file,
                range: NSRange(location: 0, length: 13),
                query: "TextBoxInput",
                trigger: "@"
            ),
            rootDirectory: root.path,
            scanFiles: scanFiles
        )

        XCTAssertEqual(suggestions.first?.title, "@Sources/TextBoxInput.swift")
        XCTAssertEqual(suggestions.first?.systemImageName, "doc")
        XCTAssertTrue(suggestions.first?.insertionText.hasPrefix("[@Sources/TextBoxInput.swift](") == true)
    }

    func testTextBoxMentionFileSuggestionsDoNotSynchronouslyRefreshCachedMisses() {
        var cache = TextBoxMentionFileIndexCache()
        let root = "/tmp/cmux-textbox-mentions-refresh"
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        let now = Date(timeIntervalSince1970: 100)
        var scanCount = 0

        let scanFiles: (URL) -> [TextBoxMentionCandidate] = { scannedRootURL in
            XCTAssertEqual(scannedRootURL.path, rootURL.path)
            scanCount += 1

            var candidates = [
                self.makeTextBoxMentionFileCandidate(relativePath: "old-file.txt", rootDirectory: root)
            ]
            if scanCount >= 2 {
                candidates.append(self.makeTextBoxMentionFileCandidate(
                    relativePath: "new-file.txt",
                    rootDirectory: root
                ))
            }
            return candidates
        }

        let oldSuggestions = cache.suggestions(
            for: TextBoxMentionQuery(
                kind: .file,
                range: NSRange(location: 0, length: 8),
                query: "old-file",
                trigger: "@"
            ),
            rootDirectory: root,
            now: now,
            scanFiles: scanFiles
        )
        XCTAssertEqual(oldSuggestions.first?.title, "@old-file.txt")
        XCTAssertEqual(scanCount, 1)

        let immediateMissSuggestions = cache.suggestions(
            for: TextBoxMentionQuery(
                kind: .file,
                range: NSRange(location: 0, length: 8),
                query: "new-file",
                trigger: "@"
            ),
            rootDirectory: root,
            now: now.addingTimeInterval(0.1),
            scanFiles: scanFiles
        )
        XCTAssertTrue(immediateMissSuggestions.isEmpty)
        XCTAssertEqual(scanCount, 1)

        let refreshedSuggestions = cache.suggestions(
            for: TextBoxMentionQuery(
                kind: .file,
                range: NSRange(location: 0, length: 8),
                query: "new-file",
                trigger: "@"
            ),
            rootDirectory: root,
            now: now.addingTimeInterval(2.1),
            scanFiles: scanFiles
        )
        XCTAssertEqual(refreshedSuggestions.first?.title, "@new-file.txt")
        XCTAssertEqual(scanCount, 2)
    }

    func testTextBoxMentionFileSuggestionsEvictLeastRecentlyUsedRoots() {
        var cache = TextBoxMentionFileIndexCache()
        let now = Date(timeIntervalSince1970: 200)
        let roots = (0...TextBoxMentionFileIndexCache.maxRootIndexes).map { index in
            "/tmp/cmux-textbox-mentions-root-\(index)"
        }
        var scanCounts: [String: Int] = [:]

        let scanFiles: (URL) -> [TextBoxMentionCandidate] = { scannedRootURL in
            let root = scannedRootURL.path
            scanCounts[root, default: 0] += 1
            let rootIndex = roots.firstIndex(of: root) ?? -1
            return [
                self.makeTextBoxMentionFileCandidate(
                    relativePath: "file-\(rootIndex).txt",
                    rootDirectory: root
                )
            ]
        }

        for rootIndex in 0..<TextBoxMentionFileIndexCache.maxRootIndexes {
            _ = cache.suggestions(
                for: TextBoxMentionQuery(
                    kind: .file,
                    range: NSRange(location: 0, length: 6),
                    query: "file-\(rootIndex)",
                    trigger: "@"
                ),
                rootDirectory: roots[rootIndex],
                now: now.addingTimeInterval(Double(rootIndex) * 0.01),
                scanFiles: scanFiles
            )
        }

        _ = cache.suggestions(
            for: TextBoxMentionQuery(
                kind: .file,
                range: NSRange(location: 0, length: 6),
                query: "file-0",
                trigger: "@"
            ),
            rootDirectory: roots[0],
            now: now.addingTimeInterval(0.5),
            scanFiles: scanFiles
        )

        _ = cache.suggestions(
            for: TextBoxMentionQuery(
                kind: .file,
                range: NSRange(location: 0, length: 6),
                query: "file-\(TextBoxMentionFileIndexCache.maxRootIndexes)",
                trigger: "@"
            ),
            rootDirectory: roots[TextBoxMentionFileIndexCache.maxRootIndexes],
            now: now.addingTimeInterval(0.6),
            scanFiles: scanFiles
        )

        let evictedRootScanCount = scanCounts[roots[1]] ?? 0
        let retainedRootScanCount = scanCounts[roots[0]] ?? 0

        _ = cache.suggestions(
            for: TextBoxMentionQuery(
                kind: .file,
                range: NSRange(location: 0, length: 6),
                query: "file-1",
                trigger: "@"
            ),
            rootDirectory: roots[1],
            now: now.addingTimeInterval(0.7),
            scanFiles: scanFiles
        )
        XCTAssertEqual(scanCounts[roots[1]], evictedRootScanCount + 1)

        let retainedSuggestions = cache.suggestions(
            for: TextBoxMentionQuery(
                kind: .file,
                range: NSRange(location: 0, length: 6),
                query: "file-0",
                trigger: "@"
            ),
            rootDirectory: roots[0],
            now: now.addingTimeInterval(0.8),
            scanFiles: scanFiles
        )
        XCTAssertEqual(retainedSuggestions.first?.title, "@file-0.txt")
        XCTAssertEqual(scanCounts[roots[0]], retainedRootScanCount)
    }

    private nonisolated func makeTextBoxMentionFileCandidate(
        relativePath: String,
        rootDirectory: String
    ) -> TextBoxMentionCandidate {
        let absolutePath = URL(fileURLWithPath: rootDirectory, isDirectory: true)
            .appendingPathComponent(relativePath)
            .path
        return TextBoxMentionCandidate(
            title: "@\(relativePath)",
            subtitle: absolutePath,
            targetPath: absolutePath,
            systemImageName: "doc",
            searchKey: "\(relativePath) \(URL(fileURLWithPath: relativePath).lastPathComponent)".lowercased(),
            priority: min(relativePath.split(separator: "/").count, 20)
        )
    }

    func testTextBoxMentionSkillSuggestionsUseTypedDollarTrigger() {
        let index = TextBoxMentionCandidateIndex(candidates: [
            makeTextBoxMentionSkillCandidate(
                skillName: "sample-dollar-skill",
                skillPath: "/tmp/cmux-textbox-skills/sample-dollar-skill/SKILL.md"
            )
        ])
        let suggestions = index.rankedCandidates(matching: "sample-dollar", limit: 8, shouldCancel: { false })
            .map { $0.suggestion(trigger: "$") }

        XCTAssertEqual(suggestions.first?.title, "$sample-dollar-skill")
        XCTAssertEqual(suggestions.first?.systemImageName, "sparkle.magnifyingglass")
        XCTAssertEqual(suggestions.first?.insertionText, "$sample-dollar-skill")
    }

    private nonisolated func makeTextBoxMentionSkillCandidate(
        skillName: String,
        skillPath: String
    ) -> TextBoxMentionCandidate {
        TextBoxMentionCandidate(
            title: "/\(skillName)",
            subtitle: skillPath,
            targetPath: skillPath,
            systemImageName: "sparkle.magnifyingglass",
            searchKey: "\(skillName) \(skillPath)".lowercased(),
            priority: 0
        )
    }

    func testTextBoxMentionRefreshClearsRowsOnSameTriggerEditAndTriggerChange() {
        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.string = "@a"
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        let staleSuggestion = TextBoxMentionSuggestion(
            id: "alpha",
            title: "@alpha.txt",
            subtitle: "alpha.txt",
            insertionText: "[@alpha.txt](/tmp/alpha.txt)",
            systemImageName: "doc"
        )

        textView.debugSetMentionCompletionState(
            query: TextBoxMentionQuery(kind: .file, range: NSRange(location: 0, length: 2), query: "a"),
            suggestions: [staleSuggestion]
        )
        XCTAssertEqual(textView.debugMentionSuggestionCount(), 1)

        textView.string = "@z"
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        textView.refreshMentionCompletions()
        XCTAssertEqual(textView.debugMentionSuggestionCount(), 0)
        XCTAssertFalse(textView.debugMentionSuggestionsAreCurrent())
        XCTAssertFalse(textView.debugAcceptMentionCompletion())
        XCTAssertFalse(textView.debugAcceptMentionCompletion(suggestion: staleSuggestion))
        XCTAssertEqual(textView.string, "@z")
        var submitCount = 0
        textView.onSubmit = { submitCount += 1 }
        textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(submitCount, 1)
        XCTAssertEqual(textView.string, "@z")

        textView.string = "/z"
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        textView.refreshMentionCompletions()
        XCTAssertEqual(textView.debugMentionSuggestionCount(), 0)
    }

    func testTextBoxSubmitUsesPastePayloadAndSeparateReturn() throws {
        XCTAssertEqual(TextBoxSubmit.submittedPasteText(for: "hello"), "hello")
        XCTAssertEqual(TextBoxSubmit.submittedPasteText(for: "hello\nworld"), "hello\nworld")
        XCTAssertNil(TextBoxSubmit.submittedPasteText(for: "\n"))
        XCTAssertNil(TextBoxSubmit.submittedPasteText(for: " \t\n"))
        XCTAssertEqual(TextBoxSubmit.submittedPasteText(for: " echo hi "), " echo hi ")

        let imageURL = try makeTemporaryPNGFile(named: "moon.png")
        let attachment = TextBoxAttachment(
            localURL: imageURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: imageURL)
        )
        let imageSubmissionText = TextBoxAttachment.submissionText(forLocalFileURL: imageURL)
        XCTAssertEqual(
            TextBoxSubmit.dispatchEvents(
                for: [.text("what is "), .attachment(attachment), .text("now")],
                terminalAgentContext: "restoredAgent:claude"
            ),
            [
                .captureVisibleTextBaseline,
                .pasteText("what is "),
                .waitForVisibleText("what is "),
                .captureClaudeImageTokenBaseline,
                .captureClipboardReadBaseline,
                .pasteFilePath(imageURL.path),
                .waitForClipboardRead,
                .waitForClaudeImageToken(imageSubmissionText),
                .captureVisibleTextBaseline,
                .pasteText(" now"),
                .waitForVisibleText(" now"),
                .namedKey("return")
            ]
        )
        XCTAssertEqual(
            TextBoxSubmit.dispatchEvents(
                for: [.text("what is "), .attachment(attachment), .text("now")],
                terminalAgentContext: "initialCommand:/bin/zsh -lc claude --resume"
            ),
            TextBoxSubmit.dispatchEvents(
                for: [.text("what is "), .attachment(attachment), .text("now")],
                terminalAgentContext: "restoredAgent:claude"
            )
        )
        XCTAssertEqual(
            TextBoxSubmit.dispatchEvents(
                for: [.text("what is "), .attachment(attachment), .text("now")],
                terminalAgentContext: "initialCommand:/bin/zsh -lc 'claude --resume'"
            ),
            TextBoxSubmit.dispatchEvents(
                for: [.text("what is "), .attachment(attachment), .text("now")],
                terminalAgentContext: "restoredAgent:claude"
            )
        )
        XCTAssertEqual(
            TextBoxSubmit.dispatchEvents(
                for: [.text("what is "), .attachment(attachment), .text(" now")],
                terminalAgentContext: "restoredAgent:claude"
            ),
            [
                .captureVisibleTextBaseline,
                .pasteText("what is "),
                .waitForVisibleText("what is "),
                .captureClaudeImageTokenBaseline,
                .captureClipboardReadBaseline,
                .pasteFilePath(imageURL.path),
                .waitForClipboardRead,
                .waitForClaudeImageToken(imageSubmissionText),
                .captureVisibleTextBaseline,
                .pasteText(" now"),
                .waitForVisibleText(" now"),
                .namedKey("return")
            ]
        )
        XCTAssertEqual(
            TextBoxSubmit.dispatchEvents(
                for: [.text("what is "), .attachment(attachment)],
                terminalAgentContext: "restoredAgent:claude"
            ),
            [
                .captureVisibleTextBaseline,
                .pasteText("what is "),
                .waitForVisibleText("what is "),
                .captureClaudeImageTokenBaseline,
                .captureClipboardReadBaseline,
                .pasteFilePath(imageURL.path),
                .waitForClipboardRead,
                .waitForClaudeImageToken(imageSubmissionText),
                .pasteText(" "),
                .namedKey("return")
            ]
        )
        XCTAssertEqual(
            TextBoxSubmit.dispatchEvents(
                for: [.text("what is "), .attachment(attachment), .text("now")],
                terminalAgentContext: "restoredAgent:codex"
            ),
            [
                .pasteText("what is \(imageSubmissionText) now"),
                .namedKey("return")
            ]
        )
        XCTAssertEqual(
            TextBoxSubmit.dispatchEvents(
                for: [.text("what is "), .attachment(attachment), .text("now")],
                terminalAgentContext: "panelTitle:Claude Code"
            ),
            [
                .pasteText("what is \(imageSubmissionText) now"),
                .namedKey("return")
            ]
        )
        XCTAssertEqual(
            TextBoxSubmit.dispatchEvents(
                for: [.text("what is "), .attachment(attachment), .text("now")],
                terminalAgentContext: "initialCommand:echo Claude Code"
            ),
            [
                .pasteText("what is \(imageSubmissionText) now"),
                .namedKey("return")
            ]
        )
        XCTAssertEqual(
            TextBoxSubmit.dispatchEvents(
                for: [.text("hello\nworld")],
                terminalAgentContext: "restoredAgent:claude"
            ),
            [.pasteText("hello\nworld"), .namedKey("ctrl+enter")]
        )
    }

    func testTextBoxSubmitStagesClaudeImagePromptWithMultilineTail() throws {
        let imageURL = try makeTemporaryPNGFile(named: "moon.png")
        let attachment = TextBoxAttachment(
            localURL: imageURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: imageURL)
        )
        let imageSubmissionText = TextBoxAttachment.submissionText(forLocalFileURL: imageURL)

        XCTAssertEqual(
            TextBoxSubmit.dispatchEvents(
                for: [
                    .text("how are you "),
                    .attachment(attachment),
                    .text("what does this say?\n\n3+3")
                ],
                terminalAgentContext: "restoredAgent:claude"
            ),
            [
                .captureVisibleTextBaseline,
                .pasteText("how are you "),
                .waitForVisibleText("how are you "),
                .captureClaudeImageTokenBaseline,
                .captureClipboardReadBaseline,
                .pasteFilePath(imageURL.path),
                .waitForClipboardRead,
                .waitForClaudeImageToken(imageSubmissionText),
                .captureVisibleTextBaseline,
                .pasteText(" what does this say?\n\n3+3"),
                .waitForVisibleText(" what does this say?\n\n3+3"),
                .namedKey("ctrl+enter")
            ]
        )
    }

    func testTextBoxSubmitBoundsVisibleWaitForLongClaudePromptSegments() throws {
        let imageURL = try makeTemporaryPNGFile(named: "moon.png")
        let attachment = TextBoxAttachment(
            localURL: imageURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: imageURL)
        )
        let longPrompt = "\(String(repeating: "alpha ", count: 60))\nshort visible tail"

        let events = TextBoxSubmit.dispatchEvents(
            for: [.text(longPrompt), .attachment(attachment)],
            terminalAgentContext: "restoredAgent:claude"
        )
        let visibleWaitTexts = events.compactMap { event -> String? in
            if case .waitForVisibleText(let text) = event { return text }
            return nil
        }

        XCTAssertTrue(events.contains(.pasteText(longPrompt)))
        XCTAssertFalse(events.contains(.waitForVisibleText(longPrompt)))
        XCTAssertEqual(visibleWaitTexts.first, "short visible tail")
    }

    func testTextBoxSubmitUsesLocalPreviewPathForClaudeRemoteImage() throws {
        let previewURL = try makeTemporaryPNGFile(named: "moon.png")
        let remotePath = "/tmp/cmux-upload/moon.png"
        let attachment = TextBoxAttachment(
            localURL: previewURL,
            submissionText: TextBoxAttachment.submissionText(forPath: remotePath),
            submissionPath: remotePath,
            cleanupLocalURLWhenDisposed: true
        )

        let events = TextBoxSubmit.dispatchEvents(
            for: [.text("what is "), .attachment(attachment), .text("now")],
            terminalAgentContext: "restoredAgent:claude"
        )

        XCTAssertEqual(
            events.compactMap { event -> String? in
                if case .pasteFilePath(let path) = event { return path }
                return nil
            },
            [previewURL.path]
        )
        XCTAssertTrue(events.contains(.waitForClaudeImageToken(attachment.submissionText)))
        XCTAssertFalse(events.contains(.pasteFilePath(remotePath)))
        XCTAssertEqual(
            TextBoxSubmit.cleanupAttachmentsAfterSubmit(
                from: [.attachment(attachment)],
                terminalAgentContext: "restoredAgent:claude",
                completionContext: TextBoxSubmit.CompletionContext(
                    confirmedClaudeImageSubmissionTexts: [
                        attachment.submissionText: 1
                    ]
                )
            ).map(\.displayName),
            ["moon.png"]
        )
    }

    func testTextBoxSubmitVisibleWaitAcceptsMultilinePromptRendering() {
        let baseline = """
        > how are you [Image #3]
        """
        let visible = """
        > how are you [Image #3] what does this say?

        3+3
        """

        XCTAssertTrue(
            TextBoxSubmit.visibleTextReady(
                expectedText: " what does this say?\n\n3+3",
                visibleText: visible,
                baseline: baseline
            )
        )
        XCTAssertFalse(
            TextBoxSubmit.visibleTextReady(
                expectedText: " what does this say?\n\n3+3",
                visibleText: baseline,
                baseline: baseline
            )
        )
    }

    func testTextBoxSubmitClipboardReadWaitStaysPendingUntilCompletionNotification() {
#if DEBUG
        let surface = FakeTextBoxSubmitSurface()
        TextBoxSubmit.debugWaitTimeoutSecondsOverride = 10
        defer { TextBoxSubmit.debugWaitTimeoutSecondsOverride = nil }

        var completionContext: TextBoxSubmit.CompletionContext?
        TextBoxSubmit.debugRunDispatchEvents(
            [
                .captureClipboardReadBaseline,
                .waitForClipboardRead,
                .pasteText("after")
            ],
            via: surface
        ) { context in
            completionContext = context
        }

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(surface.sentText, [])
        XCTAssertNil(completionContext)

        surface.completeClipboardRead()
        waitFor(timeout: 1.0, until: { surface.sentText == ["after"] })

        XCTAssertEqual(surface.sentText, ["after"])
        XCTAssertEqual(completionContext, TextBoxSubmit.CompletionContext.empty)
#else
        XCTFail("debugRunDispatchEvents is only available in DEBUG")
#endif
    }

    func testTextBoxSubmitReportsRejectedTerminalWriteWithoutContinuing() {
#if DEBUG
        let surface = FakeTextBoxSubmitSurface()
        surface.sendTextResult = false

        var completionContext: TextBoxSubmit.CompletionContext?
        TextBoxSubmit.debugRunDispatchEvents(
            [
                .pasteText("draft"),
                .namedKey("return")
            ],
            via: surface
        ) { context in
            completionContext = context
        }

        XCTAssertEqual(surface.sentText, ["draft"])
        XCTAssertEqual(surface.sentKeys, [])
        XCTAssertEqual(completionContext?.failure, .terminalWriteRejected)
#else
        XCTFail("debugRunDispatchEvents is only available in DEBUG")
#endif
    }

    func testTextBoxFailedSubmitRollbackOnlyRestoresUnchangedClearedDraft() {
        let rollbackSnapshot = TextBoxFailedSubmitRollbackSnapshot(
            revision: 4,
            text: "",
            attachmentCount: 0
        )

        XCTAssertTrue(TextBoxFailedSubmitRollbackPolicy.shouldRestore(
            rollbackSnapshot: rollbackSnapshot,
            currentSnapshot: TextBoxFailedSubmitRollbackSnapshot(
                revision: 4,
                text: "",
                attachmentCount: 0
            )
        ))
        XCTAssertFalse(TextBoxFailedSubmitRollbackPolicy.shouldRestore(
            rollbackSnapshot: rollbackSnapshot,
            currentSnapshot: TextBoxFailedSubmitRollbackSnapshot(
                revision: 4,
                text: "new draft",
                attachmentCount: 0
            )
        ))
        XCTAssertFalse(TextBoxFailedSubmitRollbackPolicy.shouldRestore(
            rollbackSnapshot: rollbackSnapshot,
            currentSnapshot: TextBoxFailedSubmitRollbackSnapshot(
                revision: 4,
                text: "",
                attachmentCount: 1
            )
        ))
        XCTAssertFalse(TextBoxFailedSubmitRollbackPolicy.shouldRestore(
            rollbackSnapshot: rollbackSnapshot,
            currentSnapshot: TextBoxFailedSubmitRollbackSnapshot(
                revision: 5,
                text: "",
                attachmentCount: 0
            )
        ))
    }

    func testTextBoxSubmitClipboardReadTimeoutRestoresPasteboard() throws {
#if DEBUG
        try withPreservedGeneralPasteboard {
            let surface = FakeTextBoxSubmitSurface()
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.declareTypes([.string], owner: nil)
            XCTAssertTrue(pasteboard.setString("user clipboard", forType: .string))
            TextBoxSubmit.debugWaitTimeoutSecondsOverride = 0
            defer { TextBoxSubmit.debugWaitTimeoutSecondsOverride = nil }

            let imageURL = try makeTemporaryPNGFile(named: "moon.png")
            var completed = false
            TextBoxSubmit.debugRunDispatchEvents(
                [
                    .captureClipboardReadBaseline,
                    .pasteFilePath(imageURL.path),
                    .waitForClipboardRead
                ],
                via: surface
            ) { _ in
                completed = true
            }

            XCTAssertEqual(surface.sentKeys, ["paste_from_clipboard"])
            waitFor(timeout: 1.0, until: { completed })

            XCTAssertTrue(completed)
            XCTAssertEqual(pasteboard.string(forType: .string), "user clipboard")
        }
#else
        XCTFail("debugRunDispatchEvents is only available in DEBUG")
#endif
    }

    func testTextBoxSubmitSerializesRunsPerSurface() throws {
#if DEBUG
        try withPreservedGeneralPasteboard {
            let surface = FakeTextBoxSubmitSurface()
            TextBoxSubmit.debugWaitTimeoutSecondsOverride = 10
            defer { TextBoxSubmit.debugWaitTimeoutSecondsOverride = nil }
            let imageURL = try makeTemporaryPNGFile(named: "moon.png")
            var completions: [String] = []

            TextBoxSubmit.debugRunDispatchEvents(
                [
                    .captureClipboardReadBaseline,
                    .pasteFilePath(imageURL.path),
                    .waitForClipboardRead,
                    .pasteText("first")
                ],
                via: surface
            ) { _ in
                completions.append("first")
            }
            TextBoxSubmit.debugRunDispatchEvents(
                [.pasteText("second")],
                via: surface
            ) { _ in
                completions.append("second")
            }

            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            XCTAssertEqual(surface.sentText, [])
            XCTAssertEqual(completions, [])
            XCTAssertEqual(surface.sentKeys, ["paste_from_clipboard"])

            surface.completeClipboardRead()
            waitFor(timeout: 1.0, until: { completions == ["first", "second"] })

            XCTAssertEqual(surface.sentText, ["first", "second"])
            XCTAssertEqual(completions, ["first", "second"])
        }
#else
        XCTFail("debugRunDispatchEvents is only available in DEBUG")
#endif
    }

    func testTextBoxSubmitSerializesPasteboardRunsAcrossSurfaces() throws {
#if DEBUG
        try withPreservedGeneralPasteboard {
            let firstSurface = FakeTextBoxSubmitSurface()
            let secondSurface = FakeTextBoxSubmitSurface()
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.declareTypes([.string], owner: nil)
            XCTAssertTrue(pasteboard.setString("user clipboard", forType: .string))
            TextBoxSubmit.debugWaitTimeoutSecondsOverride = 10
            defer { TextBoxSubmit.debugWaitTimeoutSecondsOverride = nil }

            let firstURL = try makeTemporaryPNGFile(named: "first.png")
            let secondURL = try makeTemporaryPNGFile(named: "second.png")
            var completions: [String] = []

            TextBoxSubmit.debugRunDispatchEvents(
                [
                    .captureClipboardReadBaseline,
                    .pasteFilePath(firstURL.path),
                    .waitForClipboardRead,
                    .pasteText("first")
                ],
                via: firstSurface
            ) { _ in
                completions.append("first")
            }
            TextBoxSubmit.debugRunDispatchEvents(
                [
                    .captureClipboardReadBaseline,
                    .pasteFilePath(secondURL.path),
                    .waitForClipboardRead,
                    .pasteText("second")
                ],
                via: secondSurface
            ) { _ in
                completions.append("second")
            }

            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            XCTAssertEqual(firstSurface.sentKeys, ["paste_from_clipboard"])
            XCTAssertEqual(secondSurface.sentKeys, [])
            XCTAssertEqual(completions, [])

            firstSurface.completeClipboardRead()
            waitFor(timeout: 1.0, until: {
                completions == ["first"] &&
                    secondSurface.sentKeys == ["paste_from_clipboard"]
            })

            XCTAssertEqual(firstSurface.sentText, ["first"])
            XCTAssertEqual(secondSurface.sentText, [])
            XCTAssertEqual(completions, ["first"])

            secondSurface.completeClipboardRead()
            waitFor(timeout: 1.0, until: { completions == ["first", "second"] })

            XCTAssertEqual(secondSurface.sentText, ["second"])
            XCTAssertEqual(completions, ["first", "second"])
            XCTAssertEqual(pasteboard.string(forType: .string), "user clipboard")
        }
#else
        XCTFail("debugRunDispatchEvents is only available in DEBUG")
#endif
    }

    func testTextBoxSubmitKeepsQueuedRunForStillActiveSurfaceWhenAnotherSurfaceFinishes() throws {
#if DEBUG
        try withPreservedGeneralPasteboard {
            let activeSurface = FakeTextBoxSubmitSurface()
            let finishingSurface = FakeTextBoxSubmitSurface()
            TextBoxSubmit.debugWaitTimeoutSecondsOverride = 10
            defer { TextBoxSubmit.debugWaitTimeoutSecondsOverride = nil }
            let imageURL = try makeTemporaryPNGFile(named: "moon.png")
            var completions: [String] = []

            TextBoxSubmit.debugRunDispatchEvents(
                [
                    .captureClipboardReadBaseline,
                    .pasteFilePath(imageURL.path),
                    .waitForClipboardRead,
                    .pasteText("active-first")
                ],
                via: activeSurface
            ) { _ in
                completions.append("active-first")
            }
            TextBoxSubmit.debugRunDispatchEvents(
                [.pasteText("active-second")],
                via: activeSurface
            ) { _ in
                completions.append("active-second")
            }
            TextBoxSubmit.debugRunDispatchEvents(
                [.pasteText("finishing")],
                via: finishingSurface
            ) { _ in
                completions.append("finishing")
            }

            waitFor(timeout: 1.0, until: { completions == ["finishing"] })
            XCTAssertEqual(finishingSurface.sentText, ["finishing"])
            XCTAssertEqual(activeSurface.sentText, [])
            XCTAssertEqual(activeSurface.sentKeys, ["paste_from_clipboard"])

            activeSurface.completeClipboardRead()
            waitFor(timeout: 1.0, until: {
                completions == ["finishing", "active-first", "active-second"]
            })

            XCTAssertEqual(activeSurface.sentText, ["active-first", "active-second"])
            XCTAssertEqual(completions, ["finishing", "active-first", "active-second"])
        }
#else
        XCTFail("debugRunDispatchEvents is only available in DEBUG")
#endif
    }

    func testTextBoxSubmitStressMatrixKeepsClaudeImagesInterspersedWithText() throws {
        let firstURL = try makeTemporaryPNGFile(named: "first.png")
        let secondURL = try makeTemporaryPNGFile(named: "second.png")
        let firstAttachment = TextBoxAttachment(
            localURL: firstURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: firstURL)
        )
        let secondAttachment = TextBoxAttachment(
            localURL: secondURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: secondURL)
        )

        let cases: [(parts: [TextBoxSubmissionPart], paths: [String], submitKey: String)] = [
            (
                [.attachment(firstAttachment), .text("describe this")],
                [firstURL.path],
                "return"
            ),
            (
                [.text("compare "), .attachment(firstAttachment), .text(" and "), .attachment(secondAttachment)],
                [firstURL.path, secondURL.path],
                "return"
            ),
            (
                [.text("first line\n"), .attachment(firstAttachment), .text("second line")],
                [firstURL.path],
                "ctrl+enter"
            ),
            (
                [.attachment(firstAttachment), .attachment(secondAttachment), .text(" done")],
                [firstURL.path, secondURL.path],
                "return"
            ),
        ]

        for testCase in cases {
            let events = TextBoxSubmit.dispatchEvents(
                for: testCase.parts,
                terminalAgentContext: "restoredAgent:claude"
            )
            let pastedFilePaths = events.compactMap { event -> String? in
                if case .pasteFilePath(let path) = event {
                    return path
                }
                return nil
            }
            let imageWaitCount = events.filter { event in
                if case .waitForClaudeImageToken = event {
                    return true
                }
                return false
            }.count

            XCTAssertEqual(pastedFilePaths, testCase.paths)
            XCTAssertEqual(imageWaitCount, testCase.paths.count)
            XCTAssertEqual(events.last, .namedKey(testCase.submitKey))
        }
    }

    func testTextBoxClaudeImageSubmissionDoesNotUseCursorOffsetsForWideCharacters() throws {
        let imageURL = try makeTemporaryPNGFile(named: "wide.png")
        let attachment = TextBoxAttachment(
            localURL: imageURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: imageURL)
        )

        let events = TextBoxSubmit.dispatchEvents(
            for: [
                .text("分析🙂 "),
                .attachment(attachment),
                .text(" これは?")
            ],
            terminalAgentContext: "restoredAgent:claude"
        )

        XCTAssertFalse(events.contains(.namedKeyRepeat(TextBoxTerminalKey.arrowLeft.rawValue, 1)))
        XCTAssertFalse(events.contains(.namedKeyRepeat(TextBoxTerminalKey.arrowRight.rawValue, 1)))
        XCTAssertEqual(
            events,
            [
                .captureVisibleTextBaseline,
                .pasteText("分析🙂 "),
                .waitForVisibleText("分析🙂 "),
                .captureClaudeImageTokenBaseline,
                .captureClipboardReadBaseline,
                .pasteFilePath(imageURL.path),
                .waitForClipboardRead,
                .waitForClaudeImageToken(attachment.submissionText),
                .captureVisibleTextBaseline,
                .pasteText(" これは?"),
                .waitForVisibleText(" これは?"),
                .namedKey(TextBoxTerminalKey.returnKey.rawValue)
            ]
        )
    }

    func testTextBoxSubmissionPreservesNonBMPUnicode() {
        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.string = "hello 🙂 world"

        XCTAssertEqual(textView.submissionText(), "hello 🙂 world")
    }

    func testTextBoxSubmissionPreservesInlineAttachmentOrder() throws {
        let firstURL = try makeTemporaryPNGFile(named: "moon.png")
        let secondURL = try makeTemporaryPNGFile(named: "sun.png")
        let firstAttachment = TextBoxAttachment(
            localURL: firstURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: firstURL)
        )
        let secondAttachment = TextBoxAttachment(
            localURL: secondURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: secondURL)
        )
        let firstSubmissionText = TextBoxAttachment.submissionText(forLocalFileURL: firstURL)
        let secondSubmissionText = TextBoxAttachment.submissionText(forLocalFileURL: secondURL)

        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.string = "what is "
        textView.setSelectedRange(NSRange(location: ("what is " as NSString).length, length: 0))
        textView.insertAttachments([firstAttachment])
        textView.insertText("and ", replacementRange: textView.selectedRange())
        textView.insertAttachments([secondAttachment])

        XCTAssertEqual(
            textView.submissionText(),
            "what is \(firstSubmissionText) and \(secondSubmissionText) "
        )
        XCTAssertEqual(
            submissionPartSummaries(textView.submissionParts()),
            [
                .text("what is "),
                .attachment(firstSubmissionText),
                .text(" and "),
                .attachment(secondSubmissionText),
                .text(" ")
            ]
        )
        XCTAssertEqual(
            TextBoxSubmit.dispatchEvents(
                for: textView.submissionParts(),
                terminalAgentContext: "restoredAgent:claude"
            ),
            [
                .captureVisibleTextBaseline,
                .pasteText("what is "),
                .waitForVisibleText("what is "),
                .captureClaudeImageTokenBaseline,
                .captureClipboardReadBaseline,
                .pasteFilePath(firstURL.path),
                .waitForClipboardRead,
                .waitForClaudeImageToken(firstSubmissionText),
                .captureVisibleTextBaseline,
                .pasteText(" and "),
                .waitForVisibleText(" and "),
                .captureClaudeImageTokenBaseline,
                .captureClipboardReadBaseline,
                .pasteFilePath(secondURL.path),
                .waitForClipboardRead,
                .waitForClaudeImageToken(secondSubmissionText),
                .pasteText(" "),
                .namedKey("return")
            ]
        )
    }

    func testTextBoxSubmissionPreservesRepeatedAttachmentsInOrder() throws {
        let imageURL = try makeTemporaryPNGFile(named: "moon.png")
        let attachment = TextBoxAttachment(
            localURL: imageURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: imageURL)
        )

        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.insertAttachments([attachment])
        textView.insertText("what is this ", replacementRange: textView.selectedRange())
        textView.insertAttachments([attachment])
        textView.insertText("lol", replacementRange: textView.selectedRange())

        XCTAssertEqual(
            textView.submissionText(),
            "\(TextBoxAttachment.submissionText(forLocalFileURL: imageURL)) what is this \(TextBoxAttachment.submissionText(forLocalFileURL: imageURL)) lol"
        )
    }

    func testTextBoxSessionDraftRoundTripsInterspersedImages() throws {
        let firstURL = try makeTemporaryPNGFile(named: "moon.png")
        let secondURL = try makeTemporaryPNGFile(named: "sun.png")
        let firstAttachment = TextBoxAttachment(
            localURL: firstURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: firstURL)
        )
        let secondAttachment = TextBoxAttachment(
            localURL: secondURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: secondURL)
        )

        let textView = makeRetainedTextBoxInputTextView()
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.string = "hello "
        textView.setSelectedRange(NSRange(location: ("hello " as NSString).length, length: 0))
        textView.insertAttachments([firstAttachment])
        textView.insertText(" middle ", replacementRange: textView.selectedRange())
        textView.insertAttachments([secondAttachment])
        textView.insertText(" done", replacementRange: textView.selectedRange())

        let draft = try XCTUnwrap(textView.sessionDraftSnapshot(isActive: true))
        let terminalSnapshot = SessionTerminalPanelSnapshot(
            workingDirectory: "/tmp",
            scrollback: nil,
            agent: nil,
            tmuxStartCommand: nil,
            textBoxDraft: draft
        )

        let data = try JSONEncoder().encode(terminalSnapshot)
        let decoded = try JSONDecoder().decode(SessionTerminalPanelSnapshot.self, from: data)
        let decodedDraft = try XCTUnwrap(decoded.textBoxDraft)
        XCTAssertEqual(decodedDraft, draft)

        let restoredTextView = makeRetainedTextBoxInputTextView()
        restoredTextView.font = NSFont.systemFont(ofSize: 14)
        restoredTextView.textColor = .labelColor
        restoredTextView.installSessionDraft(decodedDraft)

        XCTAssertEqual(restoredTextView.inlineAttachments().map(\.displayName), ["moon.png", "sun.png"])
        XCTAssertEqual(
            submissionPartSummaries(restoredTextView.submissionParts()),
            submissionPartSummaries(textView.submissionParts())
        )
        XCTAssertEqual(restoredTextView.submissionText(), textView.submissionText())
    }

    func testTextBoxSessionDraftCopiesOwnedTemporaryImageToDurableStorage() throws {
        let temporaryURL = try makeTemporaryPNGFile(named: "moon.png")
        GhosttyPasteboardHelper.debugRegisterOwnedTemporaryImageFile(temporaryURL)
        let attachment = TextBoxAttachment(
            localURL: temporaryURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: temporaryURL)
        )

        let snapshot = try preparedSessionAttachmentSnapshot(attachment)
        let durablePath = try XCTUnwrap(snapshot.localPath)
        let durableURL = URL(fileURLWithPath: durablePath).standardizedFileURL
        addTeardownBlock {
            try? FileManager.default.removeItem(at: durableURL)
        }

        XCTAssertNotEqual(durableURL.path, temporaryURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: durableURL.path))
        XCTAssertEqual(snapshot.submissionPath, durableURL.path)
        XCTAssertEqual(snapshot.submissionText, TextBoxAttachment.submissionText(forLocalFileURL: durableURL))
        XCTAssertTrue(snapshot.cleanupLocalPathWhenDisposed)

        GhosttyPasteboardHelper.cleanupTransferredTemporaryImageFiles([temporaryURL])
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: durableURL.path))

        let restoredAttachment = snapshot.textBoxAttachment()
        XCTAssertEqual(restoredAttachment.localURL?.standardizedFileURL.path, durableURL.path)
        XCTAssertEqual(restoredAttachment.submissionPath, durableURL.path)
    }

    func testTextBoxSessionDraftSnapshotDoesNotSynchronouslyCopyUnpreparedTemporaryImage() throws {
        let temporaryURL = try makeTemporaryPNGFile(named: "moon.png")
        GhosttyPasteboardHelper.debugRegisterOwnedTemporaryImageFile(temporaryURL)
        let attachment = TextBoxAttachment(
            localURL: temporaryURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: temporaryURL),
            cleanupLocalURLWhenDisposed: true
        )
        addTeardownBlock {
            attachment.debugCancelSessionDraftCopyForTesting()
            GhosttyPasteboardHelper.cleanupTransferredTemporaryImageFiles([temporaryURL])
        }

        let snapshot = SessionTextBoxInputAttachmentSnapshot(attachment)

        let durablePath = try XCTUnwrap(snapshot.localPath)
        XCTAssertNotEqual(durablePath, temporaryURL.path)
        XCTAssertEqual(snapshot.submissionPath, durablePath)
        XCTAssertEqual(
            snapshot.submissionText,
            TextBoxAttachment.submissionText(forLocalFileURL: URL(fileURLWithPath: durablePath))
        )
        XCTAssertTrue(snapshot.cleanupLocalPathWhenDisposed)
    }

    func testTextBoxSessionDraftKeepsOwnedTemporaryImageWhenDurableCopyFails() throws {
        let temporaryURL = try makeTemporaryPNGFile(named: "moon.png")
        GhosttyPasteboardHelper.debugRegisterOwnedTemporaryImageFile(temporaryURL)
        let attachment = TextBoxAttachment(
            localURL: temporaryURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: temporaryURL),
            cleanupLocalURLWhenDisposed: true
        )

        try FileManager.default.removeItem(at: temporaryURL)
        let draft = try XCTUnwrap(
            TextBoxInputTextView.sessionDraftSnapshot(
                text: "",
                attachments: [attachment],
                isActive: true
            )
        )
        let snapshot = try XCTUnwrap(draft.parts.first?.attachment)

        XCTAssertEqual(draft.parts.count, 1)
        XCTAssertEqual(snapshot.localPath, temporaryURL.path)
        XCTAssertEqual(snapshot.submissionPath, temporaryURL.path)
        XCTAssertEqual(snapshot.submissionText, TextBoxAttachment.submissionText(forLocalFileURL: temporaryURL))
        XCTAssertTrue(snapshot.cleanupLocalPathWhenDisposed)
    }

    func testTextBoxSessionDraftPreservesRemoteSubmissionPathWhenCopyingPreviewImage() throws {
        let temporaryURL = try makeTemporaryPNGFile(named: "moon.png")
        GhosttyPasteboardHelper.debugRegisterOwnedTemporaryImageFile(temporaryURL)
        let remotePath = "/tmp/cmux-upload/moon.png"
        let attachment = TextBoxAttachment(
            localURL: temporaryURL,
            submissionText: TextBoxAttachment.submissionText(forPath: remotePath),
            submissionPath: remotePath,
            cleanupLocalURLWhenDisposed: true
        )

        let snapshot = try preparedSessionAttachmentSnapshot(attachment)
        let durablePath = try XCTUnwrap(snapshot.localPath)
        let durableURL = URL(fileURLWithPath: durablePath).standardizedFileURL
        addTeardownBlock {
            try? FileManager.default.removeItem(at: durableURL)
        }

        XCTAssertNotEqual(durableURL.path, temporaryURL.path)
        XCTAssertEqual(snapshot.submissionPath, remotePath)
        XCTAssertEqual(snapshot.submissionText, TextBoxAttachment.submissionText(forPath: remotePath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: durableURL.path))

        let restoredAttachment = snapshot.textBoxAttachment()
        XCTAssertEqual(restoredAttachment.localURL?.standardizedFileURL.path, durableURL.path)
        XCTAssertEqual(restoredAttachment.submissionPath, remotePath)
        XCTAssertEqual(restoredAttachment.submissionText, TextBoxAttachment.submissionText(forPath: remotePath))
    }

    func testTextBoxDraftCopyIsRemovedWhenOriginalTemporaryAttachmentIsDisposed() throws {
        let temporaryURL = try makeTemporaryPNGFile(named: "moon.png")
        GhosttyPasteboardHelper.debugRegisterOwnedTemporaryImageFile(temporaryURL)
        let attachment = TextBoxAttachment(
            localURL: temporaryURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: temporaryURL),
            cleanupLocalURLWhenDisposed: true
        )

        let snapshot = try preparedSessionAttachmentSnapshot(attachment)
        let durablePath = try XCTUnwrap(snapshot.localPath)
        let durableURL = URL(fileURLWithPath: durablePath).standardizedFileURL
        addTeardownBlock {
            try? FileManager.default.removeItem(at: durableURL)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: temporaryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: durableURL.path))

        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.cleanupDisposableAttachmentFiles([attachment])

        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: durableURL.path))
    }

    func testTextBoxLocalPathSubmitDropsDraftCopyButKeepsSubmittedFile() throws {
        let temporaryURL = try makeTemporaryPNGFile(named: "moon.png")
        GhosttyPasteboardHelper.debugRegisterOwnedTemporaryImageFile(temporaryURL)
        let attachment = TextBoxAttachment(
            localURL: temporaryURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: temporaryURL),
            cleanupLocalURLWhenDisposed: true
        )

        let snapshot = try preparedSessionAttachmentSnapshot(attachment)
        let durablePath = try XCTUnwrap(snapshot.localPath)
        let durableURL = URL(fileURLWithPath: durablePath).standardizedFileURL
        addTeardownBlock {
            try? FileManager.default.removeItem(at: durableURL)
            GhosttyPasteboardHelper.cleanupTransferredTemporaryImageFiles([temporaryURL])
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: temporaryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: durableURL.path))
        XCTAssertTrue(
            TextBoxSubmit.cleanupAttachmentsAfterSubmit(
                from: [.attachment(attachment)],
                terminalAgentContext: "restoredAgent:opencode"
            ).isEmpty
        )

        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.cleanupCopiedDraftFilesForPreservedLocalPathSubmissions([attachment])

        XCTAssertTrue(FileManager.default.fileExists(atPath: temporaryURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: durableURL.path))
    }

    func testTextBoxDraftCopyIsRemovedWhenAttachmentPillIsDeleted() throws {
        let temporaryURL = try makeTemporaryPNGFile(named: "moon.png")
        GhosttyPasteboardHelper.debugRegisterOwnedTemporaryImageFile(temporaryURL)
        let attachment = TextBoxAttachment(
            localURL: temporaryURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: temporaryURL),
            cleanupLocalURLWhenDisposed: true
        )

        let snapshot = try preparedSessionAttachmentSnapshot(attachment)
        let durablePath = try XCTUnwrap(snapshot.localPath)
        let durableURL = URL(fileURLWithPath: durablePath).standardizedFileURL
        addTeardownBlock {
            try? FileManager.default.removeItem(at: durableURL)
        }
        let restoredAttachment = snapshot.textBoxAttachment()

        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.insertAttachments([restoredAttachment])

        XCTAssertTrue(FileManager.default.fileExists(atPath: durableURL.path))
        _ = textView.debugInteract(action: "close_first_attachment")
        XCTAssertFalse(FileManager.default.fileExists(atPath: durableURL.path))
        XCTAssertTrue(textView.inlineAttachments().isEmpty)
    }

    func testTextBoxCutAttachmentPreservesClipboardFile() throws {
        try withPreservedGeneralPasteboard {
            let temporaryURL = try makeTemporaryPNGFile(named: "moon.png")
            GhosttyPasteboardHelper.debugRegisterOwnedTemporaryImageFile(temporaryURL)
            let attachment = TextBoxAttachment(
                localURL: temporaryURL,
                submissionText: TextBoxAttachment.submissionText(forLocalFileURL: temporaryURL),
                cleanupLocalURLWhenDisposed: true
            )

            let snapshot = try preparedSessionAttachmentSnapshot(attachment)
            let durablePath = try XCTUnwrap(snapshot.localPath)
            let durableURL = URL(fileURLWithPath: durablePath).standardizedFileURL
            addTeardownBlock {
                try? FileManager.default.removeItem(at: durableURL)
            }
            let restoredAttachment = snapshot.textBoxAttachment()

            let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
            textView.font = NSFont.systemFont(ofSize: 14)
            textView.textColor = .labelColor
            textView.insertAttachments([restoredAttachment])
            _ = textView.debugInteract(action: "select_first_attachment")

            XCTAssertTrue(FileManager.default.fileExists(atPath: durableURL.path))
            textView.cut(nil)

            XCTAssertTrue(textView.inlineAttachments().isEmpty)
            XCTAssertTrue(FileManager.default.fileExists(atPath: durableURL.path))
            XCTAssertEqual(NSPasteboard.general.string(forType: .fileURL), durableURL.absoluteString)
            XCTAssertEqual(
                NSPasteboard.general.string(forType: .string),
                TextBoxAttachment.submissionText(forLocalFileURL: durableURL)
            )
        }
    }

    func testTextBoxCutRestoredAttachmentClearsDeferredCleanup() throws {
        try withPreservedGeneralPasteboard {
            let temporaryURL = try makeTemporaryPNGFile(named: "moon.png")
            GhosttyPasteboardHelper.debugRegisterOwnedTemporaryImageFile(temporaryURL)
            let attachment = TextBoxAttachment(
                localURL: temporaryURL,
                submissionText: TextBoxAttachment.submissionText(forLocalFileURL: temporaryURL),
                cleanupLocalURLWhenDisposed: true
            )

            let snapshot = try preparedSessionAttachmentSnapshot(attachment)
            let durablePath = try XCTUnwrap(snapshot.localPath)
            let durableURL = URL(fileURLWithPath: durablePath).standardizedFileURL
            addTeardownBlock {
                try? FileManager.default.removeItem(at: durableURL)
                GhosttyPasteboardHelper.cleanupTransferredTemporaryImageFiles([temporaryURL])
            }

            let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
            textView.font = NSFont.systemFont(ofSize: 14)
            textView.textColor = .labelColor
            textView.allowsUndo = true

            let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
            scrollView.documentView = textView
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 30),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = scrollView
            window.makeFirstResponder(textView)
            Self.retainedTextBoxUndoWindows.append(window)

            textView.installDebugInlineFixture(snapshot.textBoxAttachment(), beforeText: "hello ", afterText: " world")
            _ = textView.debugInteract(action: "close_first_attachment")
            XCTAssertTrue(textView.undoManager?.canUndo == true)
            textView.undoManager?.undo()
            XCTAssertEqual(textView.inlineAttachments().map(\.displayName), ["moon.png"])

            _ = textView.debugInteract(action: "select_first_attachment")
            textView.cut(nil)

            XCTAssertTrue(textView.inlineAttachments().isEmpty)
            XCTAssertTrue(FileManager.default.fileExists(atPath: durableURL.path))
            XCTAssertEqual(NSPasteboard.general.string(forType: .fileURL), durableURL.absoluteString)

            textView.prepareForSubmit()
            textView.discardUndoHistoryAndCleanupPendingAttachmentFiles()

            XCTAssertTrue(FileManager.default.fileExists(atPath: durableURL.path))
        }
    }

    func testTextBoxRepastedDraftCopyRemainsDisposable() throws {
        let temporaryURL = try makeTemporaryPNGFile(named: "moon.png")
        GhosttyPasteboardHelper.debugRegisterOwnedTemporaryImageFile(temporaryURL)
        let attachment = TextBoxAttachment(
            localURL: temporaryURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: temporaryURL),
            cleanupLocalURLWhenDisposed: true
        )
        let snapshot = try preparedSessionAttachmentSnapshot(attachment)
        let durablePath = try XCTUnwrap(snapshot.localPath)
        let durableURL = URL(fileURLWithPath: durablePath).standardizedFileURL
        addTeardownBlock {
            try? FileManager.default.removeItem(at: durableURL)
            GhosttyPasteboardHelper.cleanupTransferredTemporaryImageFiles([temporaryURL])
        }

        let repastedAttachment = TextBoxAttachment(
            localURL: durableURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: durableURL),
            cleanupLocalURLWhenDisposed: TextBoxAttachment.shouldCleanupLocalURLWhenDisposed(durableURL)
        )
        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.insertAttachments([repastedAttachment])

        XCTAssertTrue(TextBoxAttachment.shouldCleanupLocalURLWhenDisposed(durableURL))
        XCTAssertTrue(FileManager.default.fileExists(atPath: durableURL.path))

        _ = textView.debugInteract(action: "close_first_attachment")
        XCTAssertTrue(textView.inlineAttachments().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: durableURL.path))
    }

    func testTextBoxKeyboardDeleteAttachmentCleansDraftCopy() throws {
        let temporaryURL = try makeTemporaryPNGFile(named: "moon.png")
        GhosttyPasteboardHelper.debugRegisterOwnedTemporaryImageFile(temporaryURL)
        let attachment = TextBoxAttachment(
            localURL: temporaryURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: temporaryURL),
            cleanupLocalURLWhenDisposed: true
        )

        let snapshot = try preparedSessionAttachmentSnapshot(attachment)
        let durablePath = try XCTUnwrap(snapshot.localPath)
        let durableURL = URL(fileURLWithPath: durablePath).standardizedFileURL
        addTeardownBlock {
            try? FileManager.default.removeItem(at: durableURL)
        }
        let restoredAttachment = snapshot.textBoxAttachment()

        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.insertAttachments([restoredAttachment])
        _ = textView.debugInteract(action: "select_first_attachment")

        XCTAssertTrue(FileManager.default.fileExists(atPath: durableURL.path))
        textView.doCommand(by: #selector(NSResponder.deleteBackward(_:)))

        XCTAssertTrue(textView.inlineAttachments().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: durableURL.path))
    }

    func testTextBoxTypingOverSelectedAttachmentCleansDisposableFile() throws {
        let temporaryURL = try makeTemporaryPNGFile(named: "moon.png")
        GhosttyPasteboardHelper.debugRegisterOwnedTemporaryImageFile(temporaryURL)
        addTeardownBlock {
            GhosttyPasteboardHelper.cleanupTransferredTemporaryImageFiles([temporaryURL])
        }
        let attachment = TextBoxAttachment(
            localURL: temporaryURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: temporaryURL),
            cleanupLocalURLWhenDisposed: true
        )
        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.allowsUndo = false
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        scrollView.documentView = textView
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 30),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        window.makeFirstResponder(textView)
        Self.retainedTextBoxUndoWindows.append(window)
        textView.installDebugInlineFixture(attachment, beforeText: "hello ", afterText: " world")
        _ = textView.debugInteract(action: "select_first_attachment")

        XCTAssertTrue(FileManager.default.fileExists(atPath: temporaryURL.path))
        guard let keyEvent = makeKeyDownEvent(
            key: "x",
            modifiers: [],
            keyCode: UInt16(kVK_ANSI_X),
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct key event")
            return
        }
        textView.keyDown(with: keyEvent)

        XCTAssertTrue(textView.inlineAttachments().isEmpty)
        XCTAssertEqual(textView.plainText(), "hello x world")
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryURL.path))
    }

    func testTextBoxKeyboardDeleteTextSelectionAfterAttachmentKeepsAttachment() {
        let attachment = TextBoxAttachment(
            displayName: "moon.png",
            submissionText: "[Image #1]",
            submissionPath: "/tmp/moon.png",
            localURL: nil
        )
        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.installDebugInlineFixture(attachment, beforeText: "hello ", afterText: " world")

        let selectionStart = ("hello " as NSString).length + 1
        textView.setSelectedRange(NSRange(location: selectionStart, length: (" world" as NSString).length))
        textView.doCommand(by: #selector(NSResponder.deleteBackward(_:)))

        XCTAssertEqual(textView.inlineAttachments().map(\.displayName), ["moon.png"])
        XCTAssertEqual(textView.plainText(), "hello ")
    }

    func testTextBoxUndoableDraftAttachmentDeleteDefersCleanupUntilDismantle() throws {
        let temporaryURL = try makeTemporaryPNGFile(named: "moon.png")
        GhosttyPasteboardHelper.debugRegisterOwnedTemporaryImageFile(temporaryURL)
        let attachment = TextBoxAttachment(
            localURL: temporaryURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: temporaryURL),
            cleanupLocalURLWhenDisposed: true
        )

        let snapshot = try preparedSessionAttachmentSnapshot(attachment)
        let durablePath = try XCTUnwrap(snapshot.localPath)
        let durableURL = URL(fileURLWithPath: durablePath).standardizedFileURL
        addTeardownBlock {
            try? FileManager.default.removeItem(at: durableURL)
        }
        let restoredAttachment = snapshot.textBoxAttachment()

        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.allowsUndo = true

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        scrollView.documentView = textView
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 30),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        window.makeFirstResponder(textView)
        Self.retainedTextBoxUndoWindows.append(window)

        textView.installDebugInlineFixture(restoredAttachment, beforeText: "hello ", afterText: " world")
        _ = textView.debugInteract(action: "close_first_attachment")

        XCTAssertTrue(textView.inlineAttachments().isEmpty)
        XCTAssertTrue(textView.undoManager?.canUndo == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: durableURL.path))

        textView.undoManager?.undo()
        XCTAssertEqual(textView.inlineAttachments().map(\.displayName), ["moon.png"])
        XCTAssertEqual(
            textView.submissionText(),
            expectedImageSubmission(before: "hello ", url: durableURL, after: " world")
        )
        textView.cleanupPendingUndoableAttachmentFiles()
        XCTAssertTrue(FileManager.default.fileExists(atPath: durableURL.path))

        _ = textView.debugInteract(action: "close_first_attachment")
        textView.discardUndoHistoryAndCleanupPendingAttachmentFiles()
        XCTAssertFalse(FileManager.default.fileExists(atPath: durableURL.path))
    }

    func testTextBoxPrepareForSubmitFlushesDeletedAttachmentCleanup() throws {
        let deletedTemporaryURL = try makeTemporaryPNGFile(named: "moon.png")
        let inlineTemporaryURL = try makeTemporaryPNGFile(named: "sun.png")
        GhosttyPasteboardHelper.debugRegisterOwnedTemporaryImageFile(deletedTemporaryURL)
        GhosttyPasteboardHelper.debugRegisterOwnedTemporaryImageFile(inlineTemporaryURL)
        let deletedAttachment = TextBoxAttachment(
            localURL: deletedTemporaryURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: deletedTemporaryURL),
            cleanupLocalURLWhenDisposed: true
        )
        let inlineAttachment = TextBoxAttachment(
            localURL: inlineTemporaryURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: inlineTemporaryURL),
            cleanupLocalURLWhenDisposed: true
        )
        let deletedSnapshot = try preparedSessionAttachmentSnapshot(deletedAttachment)
        let inlineSnapshot = try preparedSessionAttachmentSnapshot(inlineAttachment)
        let deletedDurablePath = try XCTUnwrap(deletedSnapshot.localPath)
        let inlineDurablePath = try XCTUnwrap(inlineSnapshot.localPath)
        let deletedDurableURL = URL(fileURLWithPath: deletedDurablePath).standardizedFileURL
        let inlineDurableURL = URL(fileURLWithPath: inlineDurablePath).standardizedFileURL
        addTeardownBlock {
            try? FileManager.default.removeItem(at: deletedDurableURL)
            try? FileManager.default.removeItem(at: inlineDurableURL)
            GhosttyPasteboardHelper.cleanupTransferredTemporaryImageFiles([deletedTemporaryURL, inlineTemporaryURL])
        }

        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.allowsUndo = true

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        scrollView.documentView = textView
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 30),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        window.makeFirstResponder(textView)
        Self.retainedTextBoxUndoWindows.append(window)

        textView.insertAttachments([deletedSnapshot.textBoxAttachment()])
        _ = textView.debugInteract(action: "close_first_attachment")
        XCTAssertTrue(textView.inlineAttachments().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: deletedDurableURL.path))
        XCTAssertTrue(textView.undoManager?.canUndo == true)

        textView.insertAttachments([inlineSnapshot.textBoxAttachment()])
        textView.prepareForSubmit()

        XCTAssertFalse(FileManager.default.fileExists(atPath: deletedDurableURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: inlineDurableURL.path))
        XCTAssertEqual(textView.inlineAttachments().map(\.displayName), ["sun.png"])
        XCTAssertFalse(textView.undoManager?.canUndo == true)
    }

    func testTextBoxPrepareForSubmitDropsPendingCleanupForRestoredAttachment() throws {
        let temporaryURL = try makeTemporaryPNGFile(named: "moon.png")
        GhosttyPasteboardHelper.debugRegisterOwnedTemporaryImageFile(temporaryURL)
        let attachment = TextBoxAttachment(
            localURL: temporaryURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: temporaryURL),
            cleanupLocalURLWhenDisposed: true
        )
        let snapshot = try preparedSessionAttachmentSnapshot(attachment)
        let durablePath = try XCTUnwrap(snapshot.localPath)
        let durableURL = URL(fileURLWithPath: durablePath).standardizedFileURL
        addTeardownBlock {
            try? FileManager.default.removeItem(at: durableURL)
            GhosttyPasteboardHelper.cleanupTransferredTemporaryImageFiles([temporaryURL])
        }

        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.allowsUndo = true

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        scrollView.documentView = textView
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 30),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        window.makeFirstResponder(textView)
        Self.retainedTextBoxUndoWindows.append(window)

        textView.installDebugInlineFixture(
            snapshot.textBoxAttachment(),
            beforeText: "hello ",
            afterText: " world"
        )
        _ = textView.debugInteract(action: "close_first_attachment")
        XCTAssertTrue(textView.inlineAttachments().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: durableURL.path))

        textView.undoManager?.undo()
        XCTAssertEqual(textView.inlineAttachments().map(\.displayName), ["moon.png"])

        textView.prepareForSubmit()
        textView.clearContent(cleanupAttachmentFiles: false)
        textView.discardUndoHistoryAndCleanupPendingAttachmentFiles()

        XCTAssertTrue(FileManager.default.fileExists(atPath: durableURL.path))
    }

    func testTextBoxSubmitClearDefersDraftCopyCleanup() throws {
        let temporaryURL = try makeTemporaryPNGFile(named: "moon.png")
        GhosttyPasteboardHelper.debugRegisterOwnedTemporaryImageFile(temporaryURL)
        let attachment = TextBoxAttachment(
            localURL: temporaryURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: temporaryURL)
        )
        let snapshot = try preparedSessionAttachmentSnapshot(attachment)
        let durablePath = try XCTUnwrap(snapshot.localPath)
        let durableURL = URL(fileURLWithPath: durablePath).standardizedFileURL
        addTeardownBlock {
            try? FileManager.default.removeItem(at: durableURL)
        }
        let restoredAttachment = snapshot.textBoxAttachment()

        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.insertAttachments([restoredAttachment])

        XCTAssertTrue(FileManager.default.fileExists(atPath: durableURL.path))
        textView.clearContent(cleanupAttachmentFiles: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: durableURL.path))

        XCTAssertTrue(
            TextBoxSubmit.cleanupAttachmentsAfterSubmit(
                from: [.attachment(restoredAttachment)],
                terminalAgentContext: "restoredAgent:opencode"
            ).isEmpty
        )
        XCTAssertTrue(
            TextBoxSubmit.cleanupAttachmentsAfterSubmit(
                from: [.attachment(restoredAttachment)],
                terminalAgentContext: "restoredAgent:claude"
            ).isEmpty
        )
        XCTAssertEqual(
            TextBoxSubmit.cleanupAttachmentsAfterSubmit(
                from: [.attachment(restoredAttachment)],
                terminalAgentContext: "restoredAgent:claude",
                completionContext: TextBoxSubmit.CompletionContext(
                    confirmedClaudeImageSubmissionTexts: [
                        restoredAttachment.submissionText: 1
                    ]
                )
            ).map(\.displayName),
            ["moon.png"]
        )

        textView.cleanupDisposableAttachmentFiles([restoredAttachment])
        XCTAssertFalse(FileManager.default.fileExists(atPath: durableURL.path))
    }

    func testTextBoxSubmitCleanupPreservesReinsertedActiveAttachment() throws {
        let imageURL = try makeTemporaryPNGFile(named: "moon.png")
        GhosttyPasteboardHelper.debugRegisterOwnedTemporaryImageFile(imageURL)
        let attachment = TextBoxAttachment(
            localURL: imageURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: imageURL),
            cleanupLocalURLWhenDisposed: true
        )
        let textView = makeRetainedTextBoxInputTextView()
        textView.installDebugInlineFixture(
            attachment,
            beforeText: "new ",
            afterText: " prompt"
        )

        textView.cleanupDisposableAttachmentFiles([attachment])
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: imageURL.path),
            "Async submit cleanup must not delete a disposable file that is active in the next prompt"
        )

        textView.clearContent()
        XCTAssertFalse(FileManager.default.fileExists(atPath: imageURL.path))
    }

    func testTextBoxSubmitCleanupDisposesSynchronousRemoteAttachmentAfterEditorClears() throws {
        let temporaryURL = try makeTemporaryPNGFile(named: "moon.png")
        GhosttyPasteboardHelper.debugRegisterOwnedTemporaryImageFile(temporaryURL)
        let remotePath = "/tmp/cmux-upload/moon.png"
        let attachment = TextBoxAttachment(
            localURL: temporaryURL,
            submissionText: TextBoxAttachment.submissionText(forPath: remotePath),
            submissionPath: remotePath,
            cleanupLocalURLWhenDisposed: true
        )
        let textView = makeRetainedTextBoxInputTextView()
        textView.installDebugInlineFixture(
            attachment,
            beforeText: "describe ",
            afterText: ""
        )

        textView.prepareForSubmit()
        textView.clearContent(cleanupAttachmentFiles: false)
        let cleanupAttachments = TextBoxSubmit.cleanupAttachmentsAfterSubmit(
            from: [.attachment(attachment)],
            terminalAgentContext: "restoredAgent:opencode"
        )
        textView.cleanupDisposableAttachmentFiles(cleanupAttachments)

        XCTAssertTrue(textView.inlineAttachments().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryURL.path))
    }

    func testTextBoxSubmitCleanupCanDisposeRemotePreviewImage() throws {
        let temporaryURL = try makeTemporaryPNGFile(named: "moon.png")
        let remotePath = "/tmp/cmux-upload/moon.png"
        let attachment = TextBoxAttachment(
            localURL: temporaryURL,
            submissionText: TextBoxAttachment.submissionText(forPath: remotePath),
            submissionPath: remotePath,
            cleanupLocalURLWhenDisposed: true
        )

        XCTAssertEqual(
            TextBoxSubmit.cleanupAttachmentsAfterSubmit(
                from: [.attachment(attachment)],
                terminalAgentContext: "restoredAgent:opencode"
            ).map(\.displayName),
            ["moon.png"]
        )
    }

    func testTextBoxSubmitCleanupKeepsClaudeImageUntilTokenIsConfirmed() throws {
        let temporaryURL = try makeTemporaryPNGFile(named: "moon.png")
        let attachment = TextBoxAttachment(
            localURL: temporaryURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: temporaryURL),
            cleanupLocalURLWhenDisposed: true
        )

        XCTAssertTrue(
            TextBoxSubmit.cleanupAttachmentsAfterSubmit(
                from: [.attachment(attachment)],
                terminalAgentContext: "restoredAgent:claude"
            ).isEmpty
        )
        XCTAssertEqual(
            TextBoxSubmit.cleanupAttachmentsAfterSubmit(
                from: [.attachment(attachment)],
                terminalAgentContext: "restoredAgent:claude",
                completionContext: TextBoxSubmit.CompletionContext(
                    confirmedClaudeImageSubmissionTexts: [
                        attachment.submissionText: 1
                    ]
                )
            ).map(\.displayName),
            ["moon.png"]
        )
    }

    func testTextBoxSessionDraftRejectsInvalidPartPayloads() throws {
        let invalidTextPart = Data("""
        {
          "kind": "text",
          "attachment": {
            "displayName": "moon.png",
            "submissionText": "/tmp/moon.png",
            "submissionPath": "/tmp/moon.png",
            "localPath": "/tmp/moon.png",
            "cleanupLocalPathWhenDisposed": false
          }
        }
        """.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(SessionTextBoxInputDraftPart.self, from: invalidTextPart))

        let invalidAttachmentPart = Data("""
        {
          "kind": "attachment",
          "text": "moon"
        }
        """.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(SessionTextBoxInputDraftPart.self, from: invalidAttachmentPart))
    }

    func testTextBoxPasteboardRestorationSkipsAfterUserClipboardChange() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("cmux.textbox.restore.\(UUID().uuidString)"))
        defer {
            pasteboard.clearContents()
            pasteboard.releaseGlobally()
        }
        let fileURL = try makeTemporaryPNGFile(named: "moon.png")

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([fileURL as NSURL]))
        let token = TextBoxPasteboardRestorationGuard.token(
            afterWritingTemporaryFileURL: fileURL,
            to: pasteboard
        )
        XCTAssertTrue(TextBoxPasteboardRestorationGuard.shouldRestore(pasteboard: pasteboard, token: token))

        pasteboard.clearContents()
        pasteboard.setString("new user clipboard", forType: .string)

        XCTAssertFalse(TextBoxPasteboardRestorationGuard.shouldRestore(pasteboard: pasteboard, token: token))
    }

    func testTextBoxPasteboardRestorationAllowsSameTemporaryFileAfterChangeCountAdvance() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("cmux.textbox.restore.\(UUID().uuidString)"))
        defer {
            pasteboard.clearContents()
            pasteboard.releaseGlobally()
        }
        let fileURL = try makeTemporaryPNGFile(named: "moon.png")

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([fileURL as NSURL]))
        let token = TextBoxPasteboardRestorationGuard.token(
            afterWritingTemporaryFileURL: fileURL,
            to: pasteboard
        )
        let staleChangeCountToken = TextBoxPasteboardRestorationToken(
            changeCount: token.changeCount - 1,
            fileURL: token.fileURL
        )

        XCTAssertTrue(
            TextBoxPasteboardRestorationGuard.shouldRestore(
                pasteboard: pasteboard,
                token: staleChangeCountToken
            )
        )
    }

    func testTextBoxPasteboardRestorationRecognizesUserChangeBetweenTemporaryWrites() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("cmux.textbox.restore.\(UUID().uuidString)"))
        defer {
            pasteboard.clearContents()
            pasteboard.releaseGlobally()
        }
        let firstURL = try makeTemporaryPNGFile(named: "moon.png")
        let secondURL = try makeTemporaryPNGFile(named: "sun.png")

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([firstURL as NSURL]))
        let firstToken = TextBoxPasteboardRestorationGuard.token(
            afterWritingTemporaryFileURL: firstURL,
            to: pasteboard
        )
        XCTAssertTrue(
            TextBoxPasteboardRestorationGuard.isCurrentTemporaryWrite(
                pasteboard: pasteboard,
                token: firstToken
            )
        )

        pasteboard.clearContents()
        pasteboard.setString("new user clipboard", forType: .string)
        XCTAssertFalse(
            TextBoxPasteboardRestorationGuard.isCurrentTemporaryWrite(
                pasteboard: pasteboard,
                token: firstToken
            )
        )
        let userClipboardSnapshot = snapshotPasteboardItems(pasteboard)

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([secondURL as NSURL]))
        let secondToken = TextBoxPasteboardRestorationGuard.token(
            afterWritingTemporaryFileURL: secondURL,
            to: pasteboard
        )
        XCTAssertTrue(
            TextBoxPasteboardRestorationGuard.isCurrentTemporaryWrite(
                pasteboard: pasteboard,
                token: secondToken
            )
        )

        restorePasteboardItems(userClipboardSnapshot, to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "new user clipboard")
    }

    func testTextBoxImageAttachmentInsertionAddsTrailingEditorSpace() throws {
        let imageURL = try makeTemporaryPNGFile(named: "moon.png")
        let attachment = TextBoxAttachment(
            localURL: imageURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: imageURL)
        )

        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.string = "hello "
        textView.setSelectedRange(NSRange(location: ("hello " as NSString).length, length: 0))
        textView.insertAttachments([attachment])

        XCTAssertEqual(textView.inlineAttachments().count, 1)
        XCTAssertTrue(textView.attributedString().string.hasSuffix(" "))
        XCTAssertEqual(textView.selectedRange(), NSRange(location: textView.attributedString().length, length: 0))
    }

    func testTextBoxImageAttachmentInsertionDoesNotDuplicateExistingFollowingSpace() throws {
        let imageURL = try makeTemporaryPNGFile(named: "moon.png")
        let attachment = TextBoxAttachment(
            localURL: imageURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: imageURL)
        )

        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.string = "hello world"
        textView.setSelectedRange(NSRange(location: ("hello" as NSString).length, length: 0))
        textView.insertAttachments([attachment])

        XCTAssertEqual(
            submissionPartSummaries(textView.submissionParts()),
            [
                .text("hello "),
                .attachment(TextBoxAttachment.submissionText(forLocalFileURL: imageURL)),
                .text(" world")
            ]
        )
    }

    func testTextBoxImageAttachmentDoesNotMoveRenderedSingleLineText() throws {
        let imageURL = try makeTemporaryPNGFile(named: "moon.png")
        let attachment = TextBoxAttachment(
            localURL: imageURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: imageURL)
        )

        let textView = makeRenderableTextBoxInput(width: 420, height: 30)
        let text = "hello world"
        textView.string = text
        textView.normalizeTextBaselineOffsets()
        textView.recenterSingleLineTextContainer()

        let textRange = NSRange(location: 0, length: (text as NSString).length)
        let scanRange = NSRange(location: 0, length: ("hello" as NSString).length)
        let scanRect = try renderedTextScanRect(in: textView, characterRange: scanRange)
        let beforeBounds = try renderedNonBackgroundPixelBounds(in: textView, scanRect: scanRect)

        textView.setSelectedRange(NSRange(location: textRange.upperBound, length: 0))
        textView.insertAttachments([attachment])

        let afterBounds = try renderedNonBackgroundPixelBounds(in: textView, scanRect: scanRect)
        assertRenderedVerticalBoundsUnchanged(beforeBounds, afterBounds, accuracy: 1)
    }

    func testTextBoxImageAttachmentDoesNotMoveRenderedMultilineText() throws {
        let imageURL = try makeTemporaryPNGFile(named: "moon.png")
        let attachment = TextBoxAttachment(
            localURL: imageURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: imageURL)
        )

        let textView = makeRenderableTextBoxInput(width: 420, height: 64)
        let firstLine = "hello world"
        let secondLine = "second line"
        let text = "\(firstLine)\n\(secondLine)"
        textView.string = text
        textView.normalizeTextBaselineOffsets()
        textView.recenterSingleLineTextContainer()

        let firstLineRange = NSRange(location: 0, length: (firstLine as NSString).length)
        let firstScanRange = NSRange(location: 0, length: ("hello" as NSString).length)
        let secondScanRange = NSRange(
            location: firstLineRange.upperBound + 1,
            length: ("second" as NSString).length
        )
        let firstScanRect = try renderedTextScanRect(in: textView, characterRange: firstScanRange)
        let secondScanRect = try renderedTextScanRect(in: textView, characterRange: secondScanRange)
        let beforeFirstBounds = try renderedNonBackgroundPixelBounds(in: textView, scanRect: firstScanRect)
        let beforeSecondBounds = try renderedNonBackgroundPixelBounds(in: textView, scanRect: secondScanRect)

        textView.setSelectedRange(NSRange(location: firstLineRange.upperBound, length: 0))
        textView.insertAttachments([attachment])

        let afterFirstBounds = try renderedNonBackgroundPixelBounds(in: textView, scanRect: firstScanRect)
        let afterSecondBounds = try renderedNonBackgroundPixelBounds(in: textView, scanRect: secondScanRect)
        assertRenderedVerticalBoundsUnchanged(beforeFirstBounds, afterFirstBounds, accuracy: 1)
        assertRenderedVerticalBoundsUnchanged(beforeSecondBounds, afterSecondBounds, accuracy: 1)
    }

    func testTextBoxInlineAttachmentPixelsDoNotSitAboveTextPixelsWithoutChangingTextBaseline() throws {
        let imageURL = try makeTemporaryPNGFile(named: "moon.png")
        let attachment = TextBoxAttachment(
            localURL: imageURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: imageURL)
        )

        let textView = makeRenderableTextBoxInput(width: 420, height: 30)
        let text = "hello world"
        textView.string = text
        textView.normalizeTextBaselineOffsets()
        textView.recenterSingleLineTextContainer()

        let textRange = NSRange(location: 0, length: (text as NSString).length)

        textView.setSelectedRange(NSRange(location: textRange.upperBound, length: 0))
        textView.insertAttachments([attachment])

        let textPixelBounds = try renderedNonBackgroundPixelBounds(
            in: textView,
            scanRect: renderedTextScanRect(
                in: textView,
                characterRange: NSRange(location: 0, length: ("hello" as NSString).length)
            )
        )
        let attachmentPixelBounds = try renderedNonBackgroundPixelBounds(
            in: textView,
            scanRect: try visibleAttachmentCellFrame(in: textView).insetBy(dx: -2, dy: -10)
        )

        XCTAssertEqual(baselineOffsetsForTextRuns(in: textView), [0])
        XCTAssertGreaterThanOrEqual(
            attachmentPixelBounds.midY,
            textPixelBounds.midY,
            "Inline image pills should not sit above adjacent text or move the text baseline."
        )
        XCTAssertLessThan(
            attachmentPixelBounds.midY - textPixelBounds.midY,
            8,
            "Inline image pills should not be pushed so low that they look detached from text."
        )
    }

    func testTextBoxInlineAttachmentVerticalPaddingIsBalancedAcrossLineStates() throws {
        let imageURL = try makeTemporaryPNGFile(named: "moon.png")
        let attachment = TextBoxAttachment(
            localURL: imageURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: imageURL)
        )

        let pillOnly = makeRenderableTextBoxInput(width: 420, height: 30)
        pillOnly.insertAttachments([attachment])
        let pillOnlyCell = try visibleAttachmentCellFrame(in: pillOnly)
        let pillOnlyPixels = try renderedNonBackgroundPixelBounds(
            in: pillOnly,
            scanRect: pillOnlyCell.insetBy(dx: -2, dy: -12)
        )

        let inline = makeRenderableTextBoxInput(width: 420, height: 30)
        inline.string = "hello "
        inline.normalizeTextBaselineOffsets()
        inline.recenterSingleLineTextContainer()
        inline.setSelectedRange(NSRange(location: ("hello " as NSString).length, length: 0))
        inline.insertAttachments([attachment])
        inline.insertText(" world", replacementRange: inline.selectedRange())
        let inlineCell = try visibleAttachmentCellFrame(in: inline)
        let inlinePillPixels = try renderedNonBackgroundPixelBounds(
            in: inline,
            scanRect: inlineCell.insetBy(dx: -2, dy: -12)
        )
        let inlineTextPixels = try renderedNonBackgroundPixelBounds(
            in: inline,
            scanRect: renderedTextScanRect(
                in: inline,
                characterRange: NSRange(location: 0, length: ("hello" as NSString).length)
            )
        )

        let multiline = makeRenderableTextBoxInput(width: 420, height: 64)
        let multilinePrefix = "x\n          "
        multiline.string = multilinePrefix
        multiline.normalizeTextBaselineOffsets()
        multiline.recenterSingleLineTextContainer()
        multiline.setSelectedRange(NSRange(location: (multilinePrefix as NSString).length, length: 0))
        multiline.insertAttachments([attachment])
        multiline.insertText(" world", replacementRange: multiline.selectedRange())
        let multilineCell = try visibleAttachmentCellFrame(in: multiline)
        let multilinePillPixels = try renderedNonBackgroundPixelBounds(
            in: multiline,
            scanRect: multilineCell.insetBy(dx: -2, dy: -12)
        )
        XCTAssertLessThanOrEqual(
            pillOnlyPixels.verticalPaddingDelta,
            2,
            "Pill-only TextBox padding should stay visually centered. Got \(pillOnlyPixels.debugDescription())."
        )
        XCTAssertLessThanOrEqual(
            inlinePillPixels.verticalPaddingDelta,
            1,
            "Inline pill padding should stay centered inside the single-line TextBox. Got \(inlinePillPixels.debugDescription())."
        )
        XCTAssertLessThanOrEqual(
            multilinePillPixels.verticalPaddingDelta,
            1,
            "Multiline pill padding should stay centered in the expanded TextBox. Got \(multilinePillPixels.debugDescription())."
        )
        XCTAssertEqual(baselineOffsetsForTextRuns(in: inline), [0])
        XCTAssertEqual(baselineOffsetsForTextRuns(in: multiline), [0])
        XCTAssertGreaterThan(
            inlinePillPixels.midY,
            inlineTextPixels.midY,
            "The inline pill should remain slightly lower than adjacent text."
        )
    }

    func testTextBoxArrowMovementUsesComposedCharacters() {
        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.string = "a🙂b"
        textView.setSelectedRange(NSRange(location: ("a🙂" as NSString).length, length: 0))

        guard let leftEvent = makeKeyDownEvent(
            key: "",
            modifiers: [],
            keyCode: UInt16(kVK_LeftArrow),
            windowNumber: 0
        ), let rightEvent = makeKeyDownEvent(
            key: "",
            modifiers: [],
            keyCode: UInt16(kVK_RightArrow),
            windowNumber: 0
        ) else {
            XCTFail("Failed to construct arrow events")
            return
        }

        textView.keyDown(with: leftEvent)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: ("a" as NSString).length, length: 0))

        textView.keyDown(with: rightEvent)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: ("a🙂" as NSString).length, length: 0))
    }

    func testTextBoxPlainArrowsDeferDuringIMEComposition() {
        XCTAssertFalse(shouldHandleTextBoxPlainArrowLocally(
            keyCode: UInt16(kVK_LeftArrow),
            firstResponderHasMarkedText: true,
            flags: []
        ))
        XCTAssertTrue(shouldHandleTextBoxPlainArrowLocally(
            keyCode: UInt16(kVK_LeftArrow),
            firstResponderHasMarkedText: false,
            flags: []
        ))
        XCTAssertFalse(shouldHandleTextBoxPlainArrowLocally(
            keyCode: UInt16(kVK_LeftArrow),
            firstResponderHasMarkedText: false,
            flags: [.command]
        ))
    }

    func testTextBoxReturnDoesNotSubmitWhileIMEHasMarkedText() {
        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        var submitCount = 0
        textView.onSubmit = {
            submitCount += 1
        }

        textView.setMarkedText(
            "かな",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        XCTAssertTrue(textView.hasMarkedText())

        guard let returnEvent = makeKeyDownEvent(
            key: "\r",
            modifiers: [],
            keyCode: UInt16(kVK_Return),
            windowNumber: 0
        ) else {
            XCTFail("Failed to construct Return event")
            return
        }

        textView.keyDown(with: returnEvent)
        XCTAssertEqual(submitCount, 0, "Return should let the input method commit marked text")

        textView.unmarkText()
        XCTAssertFalse(textView.hasMarkedText())
        textView.string = "committed draft"
        textView.keyDown(with: returnEvent)
        XCTAssertEqual(submitCount, 1, "Return should submit after marked text is committed")
    }

    func testTextBoxReturnDoesNotSubmitWhileAttachmentUploadPending() {
        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.string = "hello world"
        textView.setSelectedRange(NSRange(location: ("hello " as NSString).length, length: 0))
        var submitCount = 0
        textView.onSubmit = {
            submitCount += 1
        }

        let uploadID = UUID()
        textView.insertPendingAttachmentUploadPlaceholder(id: uploadID)
        XCTAssertTrue(textView.hasPendingAttachmentUploadPlaceholder())

        guard let returnEvent = makeKeyDownEvent(
            key: "\r",
            modifiers: [],
            keyCode: UInt16(kVK_Return),
            windowNumber: 0
        ) else {
            XCTFail("Failed to construct Return event")
            return
        }

        textView.keyDown(with: returnEvent)
        textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(submitCount, 0)

        XCTAssertTrue(textView.removePendingAttachmentUploadPlaceholder(id: uploadID))
        textView.keyDown(with: returnEvent)
        XCTAssertEqual(submitCount, 1)
    }

    func testTextBoxReturnDoesNotSubmitEmptyContent() {
        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        var submitCount = 0
        textView.onSubmit = {
            submitCount += 1
        }

        guard let returnEvent = makeKeyDownEvent(
            key: "\r",
            modifiers: [],
            keyCode: UInt16(kVK_Return),
            windowNumber: 0
        ) else {
            XCTFail("Failed to construct Return event")
            return
        }

        textView.keyDown(with: returnEvent)
        XCTAssertEqual(submitCount, 0)

        textView.string = "  \n\t  "
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(submitCount, 0)

        textView.string = "hello"
        textView.setSelectedRange(NSRange(location: ("hello" as NSString).length, length: 0))
        textView.keyDown(with: returnEvent)
        XCTAssertEqual(submitCount, 1)
    }

    func testTextBoxEscapeDoesNotLeaveIMEComposition() {
        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        var escapeCount = 0
        textView.onEscape = {
            escapeCount += 1
        }

        textView.setMarkedText(
            "かな",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        XCTAssertTrue(textView.hasMarkedText())

        guard let escapeEvent = makeKeyDownEvent(
            key: "\u{1b}",
            modifiers: [],
            keyCode: UInt16(kVK_Escape),
            windowNumber: 0
        ) else {
            XCTFail("Failed to construct Escape event")
            return
        }

        textView.keyDown(with: escapeEvent)
        XCTAssertEqual(escapeCount, 0, "Escape should stay inside active IME composition")

        textView.unmarkText()
        textView.keyDown(with: escapeEvent)
        XCTAssertEqual(escapeCount, 1, "Escape should leave TextBox only after IME composition is gone")
    }

    func testTextBoxMentionCompletionDoesNotConsumeIMECommands() {
        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.string = "@a"
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        textView.debugSetMentionCompletionState(
            query: TextBoxMentionQuery(kind: .file, range: NSRange(location: 0, length: 2), query: "a"),
            suggestions: [
                TextBoxMentionSuggestion(
                    id: "alpha",
                    title: "@alpha.txt",
                    subtitle: "alpha.txt",
                    insertionText: "[@alpha.txt](/tmp/alpha.txt)",
                    systemImageName: "doc"
                )
            ]
        )

        var submitCount = 0
        textView.onSubmit = {
            submitCount += 1
        }
        textView.setMarkedText(
            "かな",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        XCTAssertTrue(textView.hasMarkedText())

        guard let returnEvent = makeKeyDownEvent(
            key: "\r",
            modifiers: [],
            keyCode: UInt16(kVK_Return),
            windowNumber: 0
        ) else {
            XCTFail("Failed to construct Return event")
            return
        }

        textView.keyDown(with: returnEvent)
        XCTAssertEqual(submitCount, 0)
        XCTAssertFalse(textView.submissionText().contains("alpha.txt"))

        textView.setMarkedText(
            "かな",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        XCTAssertTrue(textView.hasMarkedText())

        textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(submitCount, 0)
        XCTAssertFalse(textView.submissionText().contains("alpha.txt"))
    }

    func testTextBoxShiftReturnInsertsNewlineWhenMentionCompletionOpen() {
        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.string = "@a"
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        textView.debugSetMentionCompletionState(
            query: TextBoxMentionQuery(kind: .file, range: NSRange(location: 0, length: 2), query: "a"),
            suggestions: [
                TextBoxMentionSuggestion(
                    id: "alpha",
                    title: "@alpha.txt",
                    subtitle: "alpha.txt",
                    insertionText: "[@alpha.txt](/tmp/alpha.txt)",
                    systemImageName: "doc"
                )
            ]
        )

        var submitCount = 0
        textView.onSubmit = {
            submitCount += 1
        }

        guard let shiftReturnEvent = makeKeyDownEvent(
            key: "\r",
            modifiers: .shift,
            keyCode: UInt16(kVK_Return),
            windowNumber: 0
        ) else {
            XCTFail("Failed to construct Shift-Return event")
            return
        }

        textView.keyDown(with: shiftReturnEvent)

        XCTAssertEqual(submitCount, 0)
        XCTAssertEqual(textView.attributedString().string, "@a\n")
        XCTAssertFalse(textView.submissionText().contains("alpha.txt"))
    }

    func testFocusedTextBoxFirstEscapeBypassesTerminalFindShortcutHandling() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let contentView = window.contentView,
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let terminalPanel = workspace.terminalPanel(for: panelId) else {
            XCTFail("Expected a main window with a focused terminal")
            return
        }

        let textBoxView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        textBoxView.onFocusTextBox = { terminalPanel.textBoxDidBecomeFocused() }
        let textBoxScrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        textBoxScrollView.documentView = textBoxView
        contentView.addSubview(textBoxScrollView)
        defer { textBoxScrollView.removeFromSuperview() }

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        terminalPanel.hostedView.setVisibleInUI(true)
        terminalPanel.hostedView.setActive(true)
        terminalPanel.registerTextBoxInputView(textBoxView)
        XCTAssertTrue(terminalPanel.toggleTextBoxInput())
        waitFor(timeout: 1.0, until: { window.firstResponder === textBoxView })
        XCTAssertTrue(window.firstResponder === textBoxView)

        terminalPanel.searchState = TerminalSurface.SearchState(needle: "")
        defer { terminalPanel.searchState = nil }

        guard let escapeEvent = makeKeyDownEvent(
            key: "\u{1b}",
            modifiers: [],
            keyCode: UInt16(kVK_Escape),
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Escape event")
            return
        }

#if DEBUG
        XCTAssertFalse(
            cmuxCloseFocusedTerminalFindForEscape(event: escapeEvent, appDelegate: appDelegate),
            "The app-level find escape preflight must not close find while TextBox owns focus"
        )
        XCTAssertFalse(appDelegate.debugHandleCustomShortcut(event: escapeEvent))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
        XCTAssertNotNil(terminalPanel.searchState, "First Escape should reach the TextBox instead of closing find")
    }

    func testTextBoxFocusedAttachmentCopyCutPasteUseFilePasteboard() throws {
        let originalURL = try makeTemporaryPNGFile(named: "moon.png")
        let replacementURL = try makeTemporaryPNGFile(named: "sun.png")
        let originalAttachment = TextBoxAttachment(
            localURL: originalURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: originalURL)
        )

        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.onPaste = { pasteboard, textView in
            switch TerminalImageTransferPlanner.prepare(pasteboard: pasteboard, mode: .paste) {
            case .fileURLs(let fileURLs):
                textView.insertAttachments(
                    fileURLs.map {
                        TextBoxAttachment(
                            localURL: $0,
                            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: $0)
                        )
                    }
                )
                return true
            case .insertText(let text):
                textView.insertText(text, replacementRange: textView.selectedRange())
                return true
            case .reject:
                return false
            }
        }

        guard let copyEvent = makeKeyDownEvent(
            key: "c",
            modifiers: .command,
            keyCode: UInt16(kVK_ANSI_C),
            windowNumber: 0
        ), let cutEvent = makeKeyDownEvent(
            key: "x",
            modifiers: .command,
            keyCode: UInt16(kVK_ANSI_X),
            windowNumber: 0
        ), let pasteEvent = makeKeyDownEvent(
            key: "v",
            modifiers: .command,
            keyCode: UInt16(kVK_ANSI_V),
            windowNumber: 0
        ) else {
            XCTFail("Failed to construct edit command events")
            return
        }

        try withPreservedGeneralPasteboard {
            textView.installDebugInlineFixture(originalAttachment, beforeText: "hello ", afterText: " world")
            _ = textView.debugInteract(action: "select_first_attachment")

            XCTAssertEqual(textView.selectedRange(), NSRange(location: 6, length: 1))
            XCTAssertTrue(textView.performKeyEquivalent(with: copyEvent))
            XCTAssertEqual(PasteboardFileURLReader.fileURLs(from: .general).map(\.path), [originalURL.path])
            XCTAssertEqual(textView.inlineAttachments().map(\.displayName), ["moon.png"])

            XCTAssertTrue(textView.performKeyEquivalent(with: cutEvent))
            XCTAssertEqual(PasteboardFileURLReader.fileURLs(from: .general).map(\.path), [originalURL.path])
            XCTAssertTrue(textView.inlineAttachments().isEmpty)

            textView.installDebugInlineFixture(originalAttachment, beforeText: "hello ", afterText: " world")
            _ = textView.debugInteract(action: "select_first_attachment")
            writeFileURLs([replacementURL], to: .general)

            XCTAssertTrue(textView.performKeyEquivalent(with: pasteEvent))
            XCTAssertEqual(textView.inlineAttachments().map(\.displayName), ["sun.png"])
            XCTAssertEqual(
                textView.submissionText(),
                expectedImageSubmission(before: "hello ", url: replacementURL, after: " world")
            )
        }
    }

    func testTextBoxFocusedAttachmentCopyFollowsSelectionAfterSelectionChanges() throws {
        let originalURL = try makeTemporaryPNGFile(named: "moon.png")
        let originalAttachment = TextBoxAttachment(
            localURL: originalURL,
            submissionText: TerminalImageTransferPlanner.escapeForShell(originalURL.path)
        )

        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = .labelColor

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        scrollView.documentView = textView
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 30),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        window.makeFirstResponder(textView)
        Self.retainedTextBoxUndoWindows.append(window)

        guard let copyEvent = makeKeyDownEvent(
            key: "c",
            modifiers: .command,
            keyCode: UInt16(kVK_ANSI_C),
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct copy event")
            return
        }

        try withPreservedGeneralPasteboard {
            textView.installDebugInlineFixture(originalAttachment, beforeText: "hello ", afterText: " world")
            _ = textView.debugInteract(action: "select_first_attachment")
            XCTAssertEqual(textView.selectedRange(), NSRange(location: 6, length: 1))

            textView.setSelectedRange(NSRange(location: 0, length: 5))
            textView.refreshInlineAttachmentFocus()
            NSPasteboard.general.clearContents()

            XCTAssertTrue(textView.performKeyEquivalent(with: copyEvent))
            XCTAssertTrue(PasteboardFileURLReader.fileURLs(from: .general).isEmpty)
            XCTAssertEqual(NSPasteboard.general.string(forType: .string), "hello")
        }
    }

    func testTextBoxFocusedAttachmentClearsWhenTextBoxLosesFocus() throws {
        let originalURL = try makeTemporaryPNGFile(named: "moon.png")
        let originalAttachment = TextBoxAttachment(
            localURL: originalURL,
            submissionText: TerminalImageTransferPlanner.escapeForShell(originalURL.path)
        )

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 60))
        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = .labelColor
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        scrollView.documentView = textView
        let otherView = FocusableTestView(frame: NSRect(x: 0, y: 32, width: 24, height: 24))
        contentView.addSubview(scrollView)
        contentView.addSubview(otherView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 60),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = contentView
        window.makeFirstResponder(textView)
        Self.retainedTextBoxUndoWindows.append(window)

        textView.installDebugInlineFixture(originalAttachment, beforeText: "hello ", afterText: " world")
        let focusedState = textView.debugInteract(action: "select_first_attachment")
        XCTAssertEqual(focusedState["focused_attachment_index"] as? Int, 6)

        XCTAssertTrue(window.makeFirstResponder(otherView))
        let unfocusedState = textView.debugInteractionState()
        XCTAssertEqual(unfocusedState["focused_attachment_index"] as? Int, -1)
    }

    func testTextBoxInlineAttachmentsSurviveViewRemount() throws {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let terminalPanel = workspace.terminalPanel(for: panelId) else {
            XCTFail("Expected focused terminal surface")
            return
        }

        let originalURL = try makeTemporaryPNGFile(named: "moon.png")
        let originalAttachment = TextBoxAttachment(
            localURL: originalURL,
            submissionText: TerminalImageTransferPlanner.escapeForShell(originalURL.path)
        )

        let originalTextView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        originalTextView.font = NSFont.systemFont(ofSize: 14)
        originalTextView.textColor = .labelColor
        originalTextView.installDebugInlineFixture(originalAttachment, beforeText: "hello ", afterText: " world")

        terminalPanel.preserveTextBoxContentForUnmount(from: originalTextView)

        let remountedTextView = makeRetainedTextBoxInputTextView()
        terminalPanel.registerTextBoxInputView(remountedTextView)

        XCTAssertEqual(remountedTextView.inlineAttachments().map(\.displayName), ["moon.png"])
        XCTAssertEqual(
            remountedTextView.submissionText(),
            expectedImageSubmission(before: "hello ", url: originalURL, after: " world")
        )
    }

    func testTerminalPanelPreservesTextBoxDraftForUnmountWithoutPublishing() throws {
        let workspace = Workspace()
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let terminalPanel = try XCTUnwrap(workspace.terminalPanel(for: panelId))
        let originalTextView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        originalTextView.string = "preserve this"

        var objectWillChangeCount = 0
        let cancellable = terminalPanel.objectWillChange.sink {
            objectWillChangeCount += 1
        }

        terminalPanel.preserveTextBoxContentForUnmount(from: originalTextView)

        let draft = try XCTUnwrap(terminalPanel.sessionTextBoxDraftSnapshot())
        XCTAssertEqual(textBoxSessionDraftPartSummaries(draft.parts), [.text("preserve this")])
        XCTAssertEqual(
            objectWillChangeCount,
            0,
            "TextBox unmount preservation runs from NSViewRepresentable.dismantleNSView and must not publish during SwiftUI teardown"
        )
        withExtendedLifetime(cancellable) {}
    }

    func testTerminalPanelCloseDisposesTextBoxAttachmentDrafts() throws {
        let workspace = Workspace()
        guard let panelId = workspace.focusedPanelId,
              let terminalPanel = workspace.terminalPanel(for: panelId) else {
            XCTFail("Expected focused terminal surface")
            return
        }

        let temporaryURL = try makeTemporaryPNGFile(named: "moon.png")
        GhosttyPasteboardHelper.debugRegisterOwnedTemporaryImageFile(temporaryURL)
        let attachment = TextBoxAttachment(
            localURL: temporaryURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: temporaryURL),
            cleanupLocalURLWhenDisposed: true
        )
        let snapshot = try preparedSessionAttachmentSnapshot(attachment)
        let durablePath = try XCTUnwrap(snapshot.localPath)
        let durableURL = URL(fileURLWithPath: durablePath).standardizedFileURL
        addTeardownBlock {
            try? FileManager.default.removeItem(at: temporaryURL)
            try? FileManager.default.removeItem(at: durableURL)
        }

        let textView = makeRetainedTextBoxInputTextView()
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.installDebugInlineFixture(attachment, beforeText: "close ", afterText: " draft")
        terminalPanel.registerTextBoxInputView(textView)
        terminalPanel.isTextBoxActive = true

        XCTAssertTrue(FileManager.default.fileExists(atPath: temporaryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: durableURL.path))

        terminalPanel.close()

        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: durableURL.path))
        XCTAssertNil(terminalPanel.sessionTextBoxDraftSnapshot())
        XCTAssertTrue(textView.inlineAttachments().isEmpty)
    }

    func testWorkspaceSessionRestoreRestoresActiveTextBoxDraftWithImage() throws {
        let workspace = Workspace()
        guard let panelId = workspace.focusedPanelId,
              let terminalPanel = workspace.terminalPanel(for: panelId) else {
            XCTFail("Expected focused terminal surface")
            return
        }

        let originalURL = try makeTemporaryPNGFile(named: "moon.png")
        let originalAttachment = TextBoxAttachment(
            localURL: originalURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: originalURL)
        )
        let originalTextView = makeRetainedTextBoxInputTextView()
        originalTextView.font = NSFont.systemFont(ofSize: 14)
        originalTextView.textColor = .labelColor
        originalTextView.installDebugInlineFixture(originalAttachment, beforeText: "restore ", afterText: " now")

        terminalPanel.preserveTextBoxContentForUnmount(from: originalTextView)
        terminalPanel.isTextBoxActive = true

        let snapshot = workspace.sessionSnapshot(includeScrollback: false)
        let panelSnapshot = try XCTUnwrap(snapshot.panels.first { $0.id == panelId })
        XCTAssertEqual(panelSnapshot.terminal?.textBoxDraft?.isActive, true)

        let restoredWorkspace = Workspace()
        restoredWorkspace.restoreSessionSnapshot(snapshot)

        let restoredPanelId = try XCTUnwrap(restoredWorkspace.focusedPanelId)
        let restoredPanel = try XCTUnwrap(restoredWorkspace.terminalPanel(for: restoredPanelId))
        XCTAssertTrue(restoredPanel.isTextBoxActive)

        let remountedTextView = makeRetainedTextBoxInputTextView()
        remountedTextView.font = NSFont.systemFont(ofSize: 14)
        remountedTextView.textColor = .labelColor
        restoredPanel.registerTextBoxInputView(remountedTextView)

        XCTAssertEqual(remountedTextView.inlineAttachments().map(\.displayName), ["moon.png"])
        XCTAssertEqual(
            remountedTextView.submissionText(),
            expectedImageSubmission(before: "restore ", url: originalURL, after: " now")
        )
    }

    func testWorkspaceSessionRestoreKeepsHiddenTextBoxDraftUntilOpened() throws {
        let workspace = Workspace()
        guard let panelId = workspace.focusedPanelId,
              let terminalPanel = workspace.terminalPanel(for: panelId) else {
            XCTFail("Expected focused terminal surface")
            return
        }

        let originalURL = try makeTemporaryPNGFile(named: "moon.png")
        let originalAttachment = TextBoxAttachment(
            localURL: originalURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: originalURL)
        )
        let originalTextView = makeRetainedTextBoxInputTextView()
        originalTextView.font = NSFont.systemFont(ofSize: 14)
        originalTextView.textColor = .labelColor
        originalTextView.installDebugInlineFixture(originalAttachment, beforeText: "hidden ", afterText: " draft")

        terminalPanel.preserveTextBoxContentForUnmount(from: originalTextView)
        terminalPanel.isTextBoxActive = false

        let snapshot = workspace.sessionSnapshot(includeScrollback: false)
        let panelSnapshot = try XCTUnwrap(snapshot.panels.first { $0.id == panelId })
        XCTAssertEqual(panelSnapshot.terminal?.textBoxDraft?.isActive, false)

        let restoredWorkspace = Workspace()
        restoredWorkspace.restoreSessionSnapshot(snapshot)

        let restoredPanelId = try XCTUnwrap(restoredWorkspace.focusedPanelId)
        let restoredPanel = try XCTUnwrap(restoredWorkspace.terminalPanel(for: restoredPanelId))
        XCTAssertFalse(restoredPanel.isTextBoxActive)

        XCTAssertTrue(restoredPanel.focusTextBoxInputOrTerminal())
        let remountedTextView = makeRetainedTextBoxInputTextView()
        remountedTextView.font = NSFont.systemFont(ofSize: 14)
        remountedTextView.textColor = .labelColor
        restoredPanel.registerTextBoxInputView(remountedTextView)

        XCTAssertEqual(remountedTextView.inlineAttachments().map(\.displayName), ["moon.png"])
        XCTAssertEqual(
            remountedTextView.submissionText(),
            expectedImageSubmission(before: "hidden ", url: originalURL, after: " draft")
        )
    }

    func testWorkspaceSessionRestoreRestoresTextBoxDraftsAcrossSplits() throws {
        let workspace = Workspace()
        let firstPanelId = try XCTUnwrap(workspace.focusedPanelId)
        let firstPanel = try XCTUnwrap(workspace.terminalPanel(for: firstPanelId))
        let secondPanel = try XCTUnwrap(workspace.newTerminalSplit(
            from: firstPanelId,
            orientation: .horizontal,
            focus: false
        ))

        try installTextBoxSessionDraft(
            on: firstPanel,
            imageName: "left.png",
            beforeText: "left split ",
            afterText: " draft",
            isActive: true
        )
        try installTextBoxSessionDraft(
            on: secondPanel,
            imageName: "right.png",
            beforeText: "right split ",
            afterText: " draft",
            isActive: false
        )

        let snapshot = workspace.sessionSnapshot(includeScrollback: false)
        XCTAssertEqual(snapshot.panels.compactMap { $0.terminal?.textBoxDraft }.count, 2)

        let restoredWorkspace = Workspace()
        restoredWorkspace.restoreSessionSnapshot(snapshot)

        let restoredDrafts = restoredTextBoxDraftSummaries(in: restoredWorkspace)
        XCTAssertEqual(Set(restoredDrafts), Set([
            TextBoxSessionDraftSummary(isActive: true, parts: [.text("left split "), .attachment("left.png"), .text(" draft")]),
            TextBoxSessionDraftSummary(isActive: false, parts: [.text("right split "), .attachment("right.png"), .text(" draft")])
        ]))
    }

    func testTabManagerSessionRestoreRestoresTextBoxDraftsAcrossWorkspaces() throws {
        let manager = makeShortcutRoutingTabManager(autoWelcomeIfNeeded: false)
        let firstWorkspace = try XCTUnwrap(manager.tabs.first)
        let secondWorkspace = manager.addWorkspace(
            title: "Second",
            inheritWorkingDirectory: false,
            autoWelcomeIfNeeded: false
        )

        try installTextBoxSessionDraft(
            on: XCTUnwrap(firstWorkspace.focusedTerminalPanel),
            imageName: "first-workspace.png",
            beforeText: "first workspace ",
            afterText: " draft",
            isActive: true
        )
        try installTextBoxSessionDraft(
            on: XCTUnwrap(secondWorkspace.focusedTerminalPanel),
            imageName: "second-workspace.png",
            beforeText: "second workspace ",
            afterText: " draft",
            isActive: false
        )

        let snapshot = manager.sessionSnapshot(includeScrollback: false)
        XCTAssertEqual(snapshot.workspaces.count, 2)
        XCTAssertEqual(snapshot.selectedWorkspaceIndex, 1)

        let restoredManager = makeShortcutRoutingTabManager(autoWelcomeIfNeeded: false)
        restoredManager.restoreSessionSnapshot(snapshot)

        XCTAssertEqual(restoredManager.tabs.count, 2)
        XCTAssertEqual(restoredManager.selectedTabId, restoredManager.tabs.last?.id)
        XCTAssertEqual(Set(restoredManager.tabs.flatMap(restoredTextBoxDraftSummaries(in:))), Set([
            TextBoxSessionDraftSummary(isActive: true, parts: [.text("first workspace "), .attachment("first-workspace.png"), .text(" draft")]),
            TextBoxSessionDraftSummary(isActive: false, parts: [.text("second workspace "), .attachment("second-workspace.png"), .text(" draft")])
        ]))
    }

    func testAppSessionSnapshotRoundTripsTextBoxDraftsAcrossWindows() throws {
        let firstManager = makeShortcutRoutingTabManager(autoWelcomeIfNeeded: false)
        let secondManager = makeShortcutRoutingTabManager(autoWelcomeIfNeeded: false)

        try installTextBoxSessionDraft(
            on: XCTUnwrap(firstManager.selectedWorkspace?.focusedTerminalPanel),
            imageName: "first-window.png",
            beforeText: "first window ",
            afterText: " draft",
            isActive: true
        )
        try installTextBoxSessionDraft(
            on: XCTUnwrap(secondManager.selectedWorkspace?.focusedTerminalPanel),
            imageName: "second-window.png",
            beforeText: "second window ",
            afterText: " draft",
            isActive: true
        )

        let snapshot = AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion,
            createdAt: 1_700_000_000,
            windows: [
                sessionWindowSnapshot(tabManager: firstManager),
                sessionWindowSnapshot(tabManager: secondManager)
            ]
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(AppSessionSnapshot.self, from: data)
        XCTAssertEqual(decoded.windows.count, 2)

        let restoredFirstManager = makeShortcutRoutingTabManager(autoWelcomeIfNeeded: false)
        let restoredSecondManager = makeShortcutRoutingTabManager(autoWelcomeIfNeeded: false)
        restoredFirstManager.restoreSessionSnapshot(decoded.windows[0].tabManager)
        restoredSecondManager.restoreSessionSnapshot(decoded.windows[1].tabManager)

        let restoredDrafts = Set(
            restoredFirstManager.tabs.flatMap(restoredTextBoxDraftSummaries(in:)) +
            restoredSecondManager.tabs.flatMap(restoredTextBoxDraftSummaries(in:))
        )

        XCTAssertEqual(restoredDrafts, Set([
            TextBoxSessionDraftSummary(isActive: true, parts: [.text("first window "), .attachment("first-window.png"), .text(" draft")]),
            TextBoxSessionDraftSummary(isActive: true, parts: [.text("second window "), .attachment("second-window.png"), .text(" draft")])
        ]))
    }

    func testTextBoxPendingAttachmentUploadIsStrippedWhenPreservedForRemount() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let terminalPanel = workspace.terminalPanel(for: panelId) else {
            XCTFail("Expected focused terminal surface")
            return
        }

        let originalTextView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        scrollView.documentView = originalTextView
        let textBoxWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 30),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        textBoxWindow.isReleasedWhenClosed = false
        textBoxWindow.contentView = scrollView
        textBoxWindow.makeFirstResponder(originalTextView)
        Self.retainedTextBoxUndoWindows.append(textBoxWindow)

        originalTextView.string = "hello world"
        originalTextView.setSelectedRange(NSRange(location: ("hello " as NSString).length, length: 0))

        let uploadID = UUID()
        originalTextView.insertPendingAttachmentUploadPlaceholder(id: uploadID)
        let uploadToken = originalTextView.pendingAttachmentUploadValidationToken()
        XCTAssertTrue(originalTextView.hasPendingAttachmentUploadPlaceholder())
        XCTAssertTrue(originalTextView.canAcceptPendingAttachmentUpload(validationToken: uploadToken))

        terminalPanel.preserveTextBoxContentForUnmount(from: originalTextView)

        XCTAssertFalse(originalTextView.canAcceptPendingAttachmentUpload(validationToken: uploadToken))

        let remountedTextView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        terminalPanel.registerTextBoxInputView(remountedTextView)

        XCTAssertFalse(remountedTextView.hasPendingAttachmentUploadPlaceholder())
        XCTAssertEqual(remountedTextView.submissionText(), "hello world")
    }

    func testTextBoxRepresentableDismantleDoesNotWriteSwiftUIBindings() {
        var text = "old"
        var attachments: [TextBoxAttachment] = []
        var height: CGFloat = 24
        var hasPendingAttachmentUpload = true
        var textWriteCount = 0
        var attachmentWriteCount = 0
        var heightWriteCount = 0
        var pendingWriteCount = 0
        var dismantledText: String?

        let inputView = TextBoxInputView(
            text: Binding(
                get: { text },
                set: { newValue in
                    textWriteCount += 1
                    text = newValue
                }
            ),
            attachments: Binding(
                get: { attachments },
                set: { newValue in
                    attachmentWriteCount += 1
                    attachments = newValue
                }
            ),
            textViewHeight: Binding(
                get: { height },
                set: { newValue in
                    heightWriteCount += 1
                    height = newValue
                }
            ),
            hasPendingAttachmentUpload: Binding(
                get: { hasPendingAttachmentUpload },
                set: { newValue in
                    pendingWriteCount += 1
                    hasPendingAttachmentUpload = newValue
                }
            ),
            font: NSFont.systemFont(ofSize: 14),
            backgroundColor: .textBackgroundColor,
            foregroundColor: .labelColor,
            terminalTitle: "codex",
            completionRootDirectory: nil,
            onSubmit: {},
            onEscape: {},
            onFocusTextBox: {},
            onToggleFocus: {},
            onForwardText: { _, _ in },
            onForwardKey: { _ in },
            onForwardControl: { _ in },
            onPaste: { _, _ in false },
            onInsertFileURLs: { _, _ in false },
            onChooseFiles: {},
            onContentChanged: {},
            onTextViewCreated: { _ in },
            onTextViewMovedToWindow: { _ in },
            onTextViewDismantled: { textView in
                dismantledText = textView.plainText()
            }
        )
        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.string = "preserve this"
        let scrollView = NSScrollView(frame: textView.frame)
        scrollView.documentView = textView

        TextBoxInputView.dismantleNSView(
            scrollView,
            coordinator: TextBoxInputView.Coordinator(parent: inputView)
        )

        XCTAssertEqual(dismantledText, "preserve this")
        XCTAssertEqual(textWriteCount, 0)
        XCTAssertEqual(attachmentWriteCount, 0)
        XCTAssertEqual(heightWriteCount, 0)
        XCTAssertEqual(pendingWriteCount, 0)
    }

    func testTextBoxPendingAttachmentUploadPreservesOriginalInsertionPoint() throws {
        let originalURL = try makeTemporaryPNGFile(named: "moon.png")
        let originalAttachment = TextBoxAttachment(
            localURL: originalURL,
            submissionText: TextBoxAttachment.submissionText(forPath: "/tmp/remote/moon.png"),
            submissionPath: "/tmp/remote/moon.png"
        )

        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.string = "hello world"
        textView.setSelectedRange(NSRange(location: ("hello " as NSString).length, length: 0))

        let uploadID = UUID()
        textView.insertPendingAttachmentUploadPlaceholder(id: uploadID)
        XCTAssertEqual(textView.plainText(), "hello world")

        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.insertText("say ", replacementRange: textView.selectedRange())

        XCTAssertTrue(textView.replacePendingAttachmentUploadPlaceholder(id: uploadID, with: [originalAttachment]))
        XCTAssertEqual(
            textView.submissionText(),
            "say hello /tmp/remote/moon.png world"
        )
    }

    func testTextBoxPendingAttachmentUploadQueuesDurableDraftCopyForOwnedTemporaryImage() throws {
        let temporaryURL = try makeTemporaryPNGFile(named: "moon.png")
        GhosttyPasteboardHelper.debugRegisterOwnedTemporaryImageFile(temporaryURL)
        let remotePath = "/tmp/remote/moon.png"
        let attachment = TextBoxAttachment(
            localURL: temporaryURL,
            submissionText: TextBoxAttachment.submissionText(forPath: remotePath),
            submissionPath: remotePath,
            cleanupLocalURLWhenDisposed: true
        )
        addTeardownBlock {
            GhosttyPasteboardHelper.cleanupTransferredTemporaryImageFiles([temporaryURL])
        }

        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = .labelColor
        let uploadID = UUID()
        textView.insertPendingAttachmentUploadPlaceholder(id: uploadID)

        XCTAssertTrue(textView.replacePendingAttachmentUploadPlaceholder(id: uploadID, with: [attachment]))
        GhosttyPasteboardHelper.cleanupTransferredTemporaryImageFiles([temporaryURL])

        let draft = try XCTUnwrap(textView.sessionDraftSnapshot(isActive: true))
        let snapshot = try XCTUnwrap(draft.parts.first?.attachment)
        let durablePath = try XCTUnwrap(snapshot.localPath)
        let durableURL = URL(fileURLWithPath: durablePath).standardizedFileURL
        addTeardownBlock {
            try? FileManager.default.removeItem(at: durableURL)
        }

        XCTAssertNotEqual(durableURL.path, temporaryURL.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: durableURL.path))
        XCTAssertEqual(snapshot.submissionPath, remotePath)
        XCTAssertEqual(snapshot.submissionText, TextBoxAttachment.submissionText(forPath: remotePath))
    }

    func testTextBoxPendingAttachmentUploadRemovalCleansPlaceholder() {
        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.string = "hello world"
        textView.setSelectedRange(NSRange(location: ("hello " as NSString).length, length: 0))

        let uploadID = UUID()
        textView.insertPendingAttachmentUploadPlaceholder(id: uploadID)
        XCTAssertTrue(textView.hasPendingAttachmentUploadPlaceholder())

        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.insertText("say ", replacementRange: textView.selectedRange())

        XCTAssertTrue(textView.removePendingAttachmentUploadPlaceholder(id: uploadID))
        XCTAssertFalse(textView.hasPendingAttachmentUploadPlaceholder())
        XCTAssertEqual(textView.plainText(), "say hello world")
        XCTAssertEqual(textView.submissionText(), "say hello world")
    }

    func testTextBoxAttachmentCloseIsUndoable() throws {
        let originalURL = try makeTemporaryPNGFile(named: "moon.png")
        let originalAttachment = TextBoxAttachment(
            localURL: originalURL,
            submissionText: TerminalImageTransferPlanner.escapeForShell(originalURL.path)
        )

        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.allowsUndo = true

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        scrollView.documentView = textView
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 30),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        window.makeFirstResponder(textView)
        Self.retainedTextBoxUndoWindows.append(window)

        textView.installDebugInlineFixture(originalAttachment, beforeText: "hello ", afterText: " world")
        XCTAssertEqual(textView.inlineAttachments().map(\.displayName), ["moon.png"])

        _ = textView.debugInteract(action: "close_first_attachment")
        XCTAssertTrue(textView.inlineAttachments().isEmpty)
        XCTAssertTrue(textView.undoManager?.canUndo == true)

        textView.undoManager?.undo()
        XCTAssertEqual(textView.inlineAttachments().map(\.displayName), ["moon.png"])
        XCTAssertEqual(
            textView.submissionText(),
            expectedImageSubmission(before: "hello ", url: originalURL, after: " world")
        )
    }

    func testTextBoxPendingAttachmentUploadInvalidatesOnClear() {
        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        scrollView.documentView = textView
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 30),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        window.makeFirstResponder(textView)
        Self.retainedTextBoxUndoWindows.append(window)

        let token = textView.pendingAttachmentUploadValidationToken()
        XCTAssertTrue(textView.canAcceptPendingAttachmentUpload(validationToken: token))

        textView.clearContent()

        XCTAssertFalse(textView.canAcceptPendingAttachmentUpload(validationToken: token))
    }

    func testTerminalFirstResponderGuardBlocksMoveFocusWhenRightSidebarOwnsKeyboardFocus() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let contentView = window.contentView,
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let terminalPanel = workspace.terminalPanel(for: panelId),
              let terminalView = surfaceView(in: terminalPanel.hostedView) else {
            XCTFail("Expected focused terminal surface")
            return
        }

        let strayView = FocusableTestView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        contentView.addSubview(strayView)
        defer { strayView.removeFromSuperview() }

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        terminalPanel.hostedView.setVisibleInUI(true)
        terminalPanel.hostedView.setActive(true)

        XCTAssertTrue(window.makeFirstResponder(strayView), "Expected a foreign responder before blocking terminal focus")
        appDelegate.noteRightSidebarKeyboardFocusIntent(mode: .feed, in: window)

        XCTAssertFalse(
            window.makeFirstResponder(terminalView),
            "Coordinator-owned sidebar focus should block direct terminal first-responder requests"
        )

        terminalPanel.hostedView.moveFocus()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertTrue(window.firstResponder === strayView, "Blocked terminal moveFocus should keep the existing responder intact")
        XCTAssertFalse(
            terminalPanel.hostedView.isSurfaceViewFirstResponder(),
            "Blocked terminal moveFocus must not leave the Ghostty surface as first responder"
        )
    }

    func testFindShortcutFromFileTreeOpensRightSidebarFind() {
        let controller = makeFindShortcutFocusController()
        controller.noteRightSidebarInteraction(mode: .files)

        XCTAssertEqual(
            controller.findShortcutTarget(currentResponder: nil),
            .rightSidebarFileSearch,
            "Cmd+F from the file tree should route to right-sidebar file search"
        )
    }

    func testFindShortcutFromTerminalOpensTerminalFind() {
        let controller = makeFindShortcutFocusController()
        controller.noteTerminalInteraction(workspaceId: UUID(), panelId: UUID())

        XCTAssertEqual(
            controller.findShortcutTarget(currentResponder: nil),
            .mainPanelFind,
            "Cmd+F from terminal focus should route to terminal find"
        )
    }

    func testFindShortcutFromOtherRightSidebarModeDoesNotStealFocus() {
        let workspaceId = UUID()
        let panelId = UUID()
        let controller = makeFindShortcutFocusController()
        controller.noteRightSidebarInteraction(mode: .feed)

        XCTAssertEqual(
            controller.findShortcutTarget(currentResponder: nil),
            .none,
            "Cmd+F from a non-file right sidebar mode should not steal focus"
        )
        XCTAssertFalse(
            controller.allowsTerminalFocus(workspaceId: workspaceId, panelId: panelId),
            "Right sidebar ownership should continue blocking direct terminal focus"
        )
    }

    func testPlainTypingRepairsFocusedTerminalWhenResponderDriftsFromPreferredFocus() {
        XCTAssertTrue(
            focusedTerminalKeyRepairNeeded(
                responderIsWindow: false,
                responderHasViableKeyRoutingOwner: true,
                responderMatchesPreferredKeyboardFocus: false
            ),
            "Typing should repair focus when the responder is live but no longer matches the focused terminal's preferred keyboard target"
        )
        XCTAssertFalse(
            focusedTerminalKeyRepairNeeded(
                responderIsWindow: false,
                responderHasViableKeyRoutingOwner: true,
                responderMatchesPreferredKeyboardFocus: true
            ),
            "Typing should leave focus alone when a live responder already owns the focused terminal's preferred keyboard target"
        )
    }

    private func makeRegisteredShortcutRoutingWindow(id: UUID) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(id.uuidString)")
        return window
    }

    private func closeRegisteredShortcutRoutingWindow(_ window: NSWindow, id: UUID) {
        AppDelegate.shared?.unregisterMainWindowContextForTesting(windowId: id, notifyObservers: false)
        closeTestWindow(window)
    }

    private func assertCloseShortcutsTargetFocusedWindowWhenEventWindowMetadataIsStale(
        _ shortcuts: [
            (
                actionName: String,
                modifiers: NSEvent.ModifierFlags,
                expectedAction: KeyboardShortcutSettings.Action
            )
        ],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for shortcut in shortcuts {
            guard shortcut.expectedAction == .closeTab || shortcut.expectedAction == .closeWorkspace else {
                XCTFail("Unexpected close shortcut action \(shortcut.expectedAction)", file: file, line: line)
                return
            }
        }

        let originalWindowId = UUID()
        let focusedWindowId = UUID()
        let staleEventWindowNumber = 901

        // Model the observed bug: the user-visible focused window is the new window,
        // but the key event still carries the original window number.
        for shortcut in shortcuts {
            guard let event = makeKeyDownEvent(
                key: "w",
                modifiers: shortcut.modifiers,
                keyCode: 13,
                windowNumber: staleEventWindowNumber
            ) else {
                XCTFail("Failed to construct \(shortcut.actionName) event", file: file, line: line)
                return
            }

            XCTAssertTrue(
                KeyboardShortcutSettings.shortcut(for: shortcut.expectedAction).matches(event: event),
                "\(shortcut.actionName) should match \(shortcut.expectedAction)",
                file: file,
                line: line
            )

            XCTAssertTrue(
                selectFocusedCloseShortcutTarget(
                    debugFocusedWindow: focusedWindowId,
                    keyWindow: nil,
                    mainWindow: nil,
                    orderedWindows: [],
                    eventWindow: originalWindowId
                ) == focusedWindowId,
                "\(shortcut.actionName) should resolve the focused window before stale event-window metadata",
                file: file,
                line: line
            )
        }
    }

    @discardableResult
    private func waitForCondition(
        timeout: TimeInterval = 1.0,
        interval: TimeInterval = 0.01,
        _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: interval))
        }
        return condition()
    }

    private func makeKeyDownEvent(
        key: String,
        modifiers: NSEvent.ModifierFlags,
        keyCode: UInt16,
        windowNumber: Int,
        isARepeat: Bool = false,
        timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> NSEvent? {
        makeKeyEvent(
            type: .keyDown,
            key: key,
            modifiers: modifiers,
            keyCode: keyCode,
            windowNumber: windowNumber,
            isARepeat: isARepeat,
            timestamp: timestamp
        )
    }

    private func makeKeyDownEvent(
        shortcut: StoredShortcut,
        windowNumber: Int
    ) -> NSEvent? {
        guard !shortcut.isUnbound,
              !shortcut.hasChord,
              let keyCode = shortcut.firstStroke.resolvedKeyCode() else {
            return nil
        }
        return makeKeyDownEvent(
            key: shortcut.menuItemKeyEquivalent ?? shortcut.key,
            modifiers: shortcut.modifierFlags,
            keyCode: keyCode,
            windowNumber: windowNumber
        )
    }

    private func makeKeyEvent(
        type: NSEvent.EventType,
        key: String,
        modifiers: NSEvent.ModifierFlags,
        keyCode: UInt16,
        windowNumber: Int,
        isARepeat: Bool = false,
        timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: timestamp,
            windowNumber: windowNumber,
            context: nil,
            characters: key,
            charactersIgnoringModifiers: key,
            isARepeat: isARepeat,
            keyCode: keyCode
        )
    }

    private struct PasteboardItemSnapshot {
        let representations: [(type: NSPasteboard.PasteboardType, data: Data)]
    }

    private func withPreservedGeneralPasteboard(_ body: () throws -> Void) throws {
        let pasteboard = NSPasteboard.general
        let snapshots = snapshotPasteboardItems(pasteboard)
        defer {
            restorePasteboardItems(snapshots, to: pasteboard)
        }
        try body()
    }

    private func snapshotPasteboardItems(_ pasteboard: NSPasteboard) -> [PasteboardItemSnapshot] {
        pasteboard.pasteboardItems?.map { item in
            PasteboardItemSnapshot(
                representations: item.types.compactMap { type in
                    item.data(forType: type).map { (type, $0) }
                }
            )
        } ?? []
    }

    private func restorePasteboardItems(
        _ snapshots: [PasteboardItemSnapshot],
        to pasteboard: NSPasteboard
    ) {
        pasteboard.clearContents()
        let items = snapshots.map { snapshot in
            let item = NSPasteboardItem()
            for representation in snapshot.representations {
                item.setData(representation.data, forType: representation.type)
            }
            return item
        }
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }

    private enum TextBoxSessionDraftPartSummary: Hashable {
        case text(String)
        case attachment(String)
    }

    private struct TextBoxSessionDraftSummary: Hashable {
        let isActive: Bool
        let parts: [TextBoxSessionDraftPartSummary]
    }

    private func installTextBoxSessionDraft(
        on terminalPanel: TerminalPanel,
        imageName: String,
        beforeText: String,
        afterText: String,
        isActive: Bool
    ) throws {
        let imageURL = try makeTemporaryPNGFile(named: imageName)
        let attachment = TextBoxAttachment(
            localURL: imageURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: imageURL)
        )
        let textView = makeRetainedTextBoxInputTextView()
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.installDebugInlineFixture(attachment, beforeText: beforeText, afterText: afterText)

        terminalPanel.preserveTextBoxContentForUnmount(from: textView)
        terminalPanel.isTextBoxActive = isActive
    }

    private func restoredTextBoxDraftSummaries(in workspace: Workspace) -> [TextBoxSessionDraftSummary] {
        workspace.panels.values
            .compactMap { $0 as? TerminalPanel }
            .compactMap { panel in
                guard let draft = panel.sessionTextBoxDraftSnapshot() else { return nil }
                return TextBoxSessionDraftSummary(
                    isActive: draft.isActive,
                    parts: textBoxSessionDraftPartSummaries(draft.parts)
                )
            }
    }

    private func textBoxSessionDraftPartSummaries(
        _ parts: [SessionTextBoxInputDraftPart]
    ) -> [TextBoxSessionDraftPartSummary] {
        parts.compactMap { part in
            switch part.kind {
            case .text:
                guard let text = part.text, !text.isEmpty else { return nil }
                return .text(text)
            case .attachment:
                guard let attachment = part.attachment else { return nil }
                return .attachment(attachment.displayName)
            }
        }
    }

    private func sessionWindowSnapshot(tabManager: TabManager, windowId: UUID? = nil) -> SessionWindowSnapshot {
        SessionWindowSnapshot(
            windowId: windowId,
            frame: nil,
            display: nil,
            tabManager: tabManager.sessionSnapshot(includeScrollback: false),
            sidebar: SessionSidebarSnapshot(
                isVisible: true,
                selection: .tabs,
                width: SessionPersistencePolicy.defaultSidebarWidth
            )
        )
    }

    private func makeRetainedTextBoxInputTextView() -> TextBoxInputTextView {
        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        Self.retainedTextBoxRestoreViews.append(textView)
        return textView
    }

    private func makeTemporaryPNGFile(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-textbox-attachment-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }

        let url = directory.appendingPathComponent(name)
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1, height: 1)).fill()
        image.unlockFocus()
        let tiffData = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiffData))
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: url)
        return url.standardizedFileURL
    }

    private func preparedSessionAttachmentSnapshot(
        _ attachment: TextBoxAttachment
    ) throws -> SessionTextBoxInputAttachmentSnapshot {
        _ = attachment.debugPrepareSessionDraftCopySynchronouslyForTesting()
        return SessionTextBoxInputAttachmentSnapshot(attachment)
    }

    private enum TextBoxSubmissionPartSummary: Equatable {
        case text(String)
        case attachment(String)
    }

    private func submissionPartSummaries(_ parts: [TextBoxSubmissionPart]) -> [TextBoxSubmissionPartSummary] {
        parts.map { part in
            switch part {
            case .text(let text):
                return .text(text)
            case .attachment(let attachment):
                return .attachment(attachment.submissionText)
            }
        }
    }

    private func expectedImageSubmission(before: String, url: URL, after: String) -> String {
        var result = "\(before)\(TextBoxAttachment.submissionText(forLocalFileURL: url))"
        if result.last?.isWhitespace != true,
           after.first?.isWhitespace != true {
            result += " "
        }
        result += after
        return result
    }

    private struct RenderedPixelBounds {
        let minX: Int
        let minY: Int
        let maxX: Int
        let maxY: Int
        let rasterHeight: Int

        var midY: CGFloat {
            CGFloat(minY + maxY) / 2
        }

        var topPadding: Int { minY }

        var bottomPadding: Int { max(0, rasterHeight - 1 - maxY) }

        var verticalPaddingDelta: Int {
            abs(topPadding - bottomPadding)
        }

        func debugDescription() -> String {
            "(minY:\(minY), maxY:\(maxY), midY:\(midY), top:\(topPadding), bottom:\(bottomPadding))"
        }
    }

    private func makeRenderableTextBoxInput(width: CGFloat, height: CGFloat) -> TextBoxInputTextView {
        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        textView.font = NSFont.systemFont(ofSize: 16)
        textView.textColor = .white
        textView.drawsBackground = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: 30)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainerInset = NSSize(width: 1, height: height > 30 ? 4 : 5)

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.documentView = textView
        Self.retainedTextBoxRenderScrollViews.append(scrollView)
        addTeardownBlock {
            Self.retainedTextBoxRenderScrollViews.removeAll { $0 === scrollView }
        }
        return textView
    }

    private func renderedTextScanRect(
        in textView: TextBoxInputTextView,
        characterRange: NSRange
    ) throws -> NSRect {
        let glyphFrame = try visibleGlyphFrame(in: textView, characterRange: characterRange)
        return NSRect(
            x: max(0, floor(glyphFrame.minX) - 2),
            y: max(0, floor(glyphFrame.minY) - 10),
            width: ceil(glyphFrame.width) + 4,
            height: ceil(glyphFrame.height) + 20
        )
    }

    private func renderedNonBackgroundPixelBounds(
        in textView: TextBoxInputTextView,
        scanRect: NSRect
    ) throws -> RenderedPixelBounds {
        let bitmap = try XCTUnwrap(textView.bitmapImageRepForCachingDisplay(in: textView.bounds))
        textView.cacheDisplay(in: textView.bounds, to: bitmap)

        let width = bitmap.pixelsWide
        let height = bitmap.pixelsHigh
        let scaleX = CGFloat(width) / max(1, textView.bounds.width)
        let scaleY = CGFloat(height) / max(1, textView.bounds.height)

        let minScanX = max(0, Int(floor(scanRect.minX * scaleX)))
        let minScanY = max(0, Int(floor(scanRect.minY * scaleY)))
        let maxScanX = min(width - 1, Int(ceil(scanRect.maxX * scaleX)))
        let maxScanY = min(height - 1, Int(ceil(scanRect.maxY * scaleY)))

        var minX = Int.max
        var minY = Int.max
        var maxX = Int.min
        var maxY = Int.min

        guard minScanX <= maxScanX, minScanY <= maxScanY else {
            XCTFail("Expected scan rect \(scanRect) inside text bounds \(textView.bounds)")
            return RenderedPixelBounds(minX: 0, minY: 0, maxX: 0, maxY: 0, rasterHeight: height)
        }

        for y in minScanY...maxScanY {
            for x in minScanX...maxScanX {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }
                let brightness = max(color.redComponent, color.greenComponent, color.blueComponent)
                guard brightness > 0.08 || color.alphaComponent > 0.08 else { continue }
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }

        guard minX != Int.max else {
            XCTFail("Expected rendered text pixels inside \(scanRect)")
            return RenderedPixelBounds(minX: 0, minY: 0, maxX: 0, maxY: 0, rasterHeight: height)
        }

        return RenderedPixelBounds(minX: minX, minY: minY, maxX: maxX, maxY: maxY, rasterHeight: height)
    }

    private func assertRenderedVerticalBoundsUnchanged(
        _ before: RenderedPixelBounds,
        _ after: RenderedPixelBounds,
        accuracy: CGFloat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(CGFloat(after.minY), CGFloat(before.minY), accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(CGFloat(after.maxY), CGFloat(before.maxY), accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(after.midY, before.midY, accuracy: accuracy, file: file, line: line)
    }

    private func visibleGlyphFrame(
        in textView: TextBoxInputTextView,
        characterRange: NSRange
    ) throws -> NSRect {
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let textContainer = try XCTUnwrap(textView.textContainer)
        layoutManager.ensureLayout(for: textContainer)
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: characterRange,
            actualCharacterRange: nil
        )
        let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        return rect.offsetBy(dx: textView.textContainerInset.width, dy: textView.textContainerInset.height)
    }

    private func visibleAttachmentCellFrame(in textView: TextBoxInputTextView) throws -> NSRect {
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let textContainer = try XCTUnwrap(textView.textContainer)
        let attributed = textView.attributedString()
        let fullRange = NSRange(location: 0, length: attributed.length)
        var attachmentRange: NSRange?
        var attachmentCell: NSTextAttachmentCellProtocol?
        attributed.enumerateAttribute(.attachment, in: fullRange, options: []) { value, range, stop in
            guard let attachment = value as? NSTextAttachment,
                  let cell = attachment.attachmentCell else { return }
            attachmentRange = range
            attachmentCell = cell
            stop.pointee = true
        }

        let range = try XCTUnwrap(attachmentRange)
        let cell = try XCTUnwrap(attachmentCell)
        layoutManager.ensureLayout(for: textContainer)
        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let lineFragment = layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
        let glyphPosition = layoutManager.location(forGlyphAt: glyphRange.location)
        return cell
            .cellFrame(
                for: textContainer,
                proposedLineFragment: lineFragment,
                glyphPosition: glyphPosition,
                characterIndex: range.location
            )
            .offsetBy(dx: textView.textContainerInset.width, dy: textView.textContainerInset.height)
    }

    private func baselineOffsetsForTextRuns(in textView: TextBoxInputTextView) -> [CGFloat] {
        let attributed = textView.attributedString()
        let fullRange = NSRange(location: 0, length: attributed.length)
        var offsets: [CGFloat] = []
        attributed.enumerateAttributes(in: fullRange, options: []) { attributes, _, _ in
            guard attributes[.attachment] == nil else { return }
            if let value = attributes[.baselineOffset] as? CGFloat {
                offsets.append(value)
            } else if let number = attributes[.baselineOffset] as? NSNumber {
                offsets.append(CGFloat(truncating: number))
            } else {
                offsets.append(0)
            }
        }
        return Array(Set(offsets)).sorted()
    }

    private func writeFileURLs(
        _ fileURLs: [URL],
        to pasteboard: NSPasteboard
    ) {
        pasteboard.clearContents()
        pasteboard.declareTypes(
            [.fileURL, PasteboardFileURLReader.legacyFilenamesPboardType, .string],
            owner: nil
        )
        if let firstURL = fileURLs.first {
            pasteboard.setString(firstURL.absoluteString, forType: .fileURL)
        }
        pasteboard.setPropertyList(
            fileURLs.map(\.path),
            forType: PasteboardFileURLReader.legacyFilenamesPboardType
        )
        pasteboard.setString(
            TerminalImageTransferPlanner.insertedText(forFileURLs: fileURLs),
            forType: .string
        )
    }

    private func withTemporaryShortcut(
        action: KeyboardShortcutSettings.Action,
        shortcut: StoredShortcut? = nil,
        _ body: () -> Void
    ) {
        let hadPersistedShortcut = UserDefaults.standard.object(forKey: action.defaultsKey) != nil
        let originalShortcut = KeyboardShortcutSettings.shortcut(for: action)
        defer {
            if hadPersistedShortcut {
                KeyboardShortcutSettings.setShortcut(originalShortcut, for: action)
            } else {
                KeyboardShortcutSettings.resetShortcut(for: action)
            }
            #if DEBUG
            AppDelegate.shared?.debugResetShortcutRoutingStateForTesting()
            #endif
        }
        KeyboardShortcutSettings.setShortcut(shortcut ?? action.defaultShortcut, for: action)
        #if DEBUG
        AppDelegate.shared?.debugResetShortcutRoutingStateForTesting()
        #endif
        body()
    }

#if DEBUG
    private func withCommandPaletteDismissRequestObserver(
        appDelegate: AppDelegate,
        _ body: (_ observedDismissWindow: () -> NSWindow?) -> Void
    ) {
        var observedDismissWindow: NSWindow?
        let previousObserver = appDelegate.debugCommandPaletteDismissRequestObserver
        appDelegate.debugCommandPaletteDismissRequestObserver = { window in
            observedDismissWindow = window
        }
        defer {
            appDelegate.debugCommandPaletteDismissRequestObserver = previousObserver
        }
        body({ observedDismissWindow })
    }
#endif

    private func makeCommandPaletteShortcutTestWindow() -> NSWindow {
        let windowId = UUID()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 160, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(windowId.uuidString)")
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 160, height: 120))
        return window
    }

    private func assertStaleCloseDefaultShortcutSuppressesMenuFallback(
        staleAction: KeyboardShortcutSettings.Action,
        replacementAction: KeyboardShortcutSettings.Action,
        replacementShortcut: StoredShortcut,
        remappedStaleShortcut: StoredShortcut,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared", file: file, line: line)
            return
        }
        guard let event = makeKeyDownEvent(shortcut: replacementShortcut, windowNumber: 0) else {
            XCTFail("Failed to construct reassigned close-default shortcut event", file: file, line: line)
            return
        }

        withTemporaryShortcut(action: staleAction, shortcut: remappedStaleShortcut) {
            withTemporaryShortcut(action: replacementAction, shortcut: replacementShortcut) {
                XCTAssertTrue(
                    appDelegate.shouldSuppressStaleCmuxMenuShortcut(event: event),
                    "\(staleAction.rawValue) should suppress its stale default menu fallback after that key is reassigned",
                    file: file,
                    line: line
                )
            }
        }
    }

    private func assertEscapeKeyUpIsConsumedAfterCommandPaletteOpenRequest(
        _ openRequest: (_ appDelegate: AppDelegate, _ window: NSWindow) -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared", file: file, line: line)
            return
        }

        let window = makeCommandPaletteShortcutTestWindow()
        defer { closeTestWindow(window) }

        openRequest(appDelegate, window)
        appDelegate.setCommandPaletteVisible(true, for: window)

        guard let escapeKeyDown = makeKeyEvent(
            type: .keyDown,
            key: "\u{1b}",
            modifiers: [],
            keyCode: 53,
            windowNumber: window.windowNumber
        ), let escapeKeyUp = makeKeyEvent(
            type: .keyUp,
            key: "\u{1b}",
            modifiers: [],
            keyCode: 53,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Escape key events", file: file, line: line)
            return
        }

#if DEBUG
        withCommandPaletteDismissRequestObserver(appDelegate: appDelegate) { observedDismissWindow in
            XCTAssertTrue(
                appDelegate.debugHandleShortcutMonitorEvent(event: escapeKeyDown, preferredWindow: window),
                file: file,
                line: line
            )
            XCTAssertEqual(observedDismissWindow()?.windowNumber, window.windowNumber, file: file, line: line)
        }
#else
        XCTFail("debugHandleShortcutMonitorEvent is only available in DEBUG", file: file, line: line)
#endif

        appDelegate.setCommandPaletteVisible(false, for: window)

#if DEBUG
        XCTAssertTrue(
            appDelegate.debugHandleShortcutMonitorEvent(event: escapeKeyUp, preferredWindow: window),
            "Escape keyUp should be consumed after dismiss for command palette open requests",
            file: file,
            line: line
        )
#else
        XCTFail("debugHandleShortcutMonitorEvent is only available in DEBUG", file: file, line: line)
#endif
    }

    func testBrowserFocusModeEscapeArmsDisarmsAndSecondEscapeExits() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }
        guard let harness = makeBrowserFocusModeHarness() else { return }
        defer { closeWindow(withId: harness.windowId) }

        let baseTimestamp = ProcessInfo.processInfo.systemUptime
        guard let inactiveEscape = makeKeyDownEvent(key: "\u{1b}", modifiers: [], keyCode: 53, windowNumber: harness.window.windowNumber, timestamp: baseTimestamp + 0.01),
              let inactiveRepeatEscape = makeKeyDownEvent(key: "\u{1b}", modifiers: [], keyCode: 53, windowNumber: harness.window.windowNumber, isARepeat: true, timestamp: baseTimestamp + 0.015),
              let activeFirstEscape = makeKeyDownEvent(key: "\u{1b}", modifiers: [], keyCode: 53, windowNumber: harness.window.windowNumber, timestamp: baseTimestamp + 0.04),
              let activeRepeatEscape = makeKeyDownEvent(key: "\u{1b}", modifiers: [], keyCode: 53, windowNumber: harness.window.windowNumber, isARepeat: true, timestamp: baseTimestamp + 0.045),
              let activeSecondEscape = makeKeyDownEvent(key: "\u{1b}", modifiers: [], keyCode: 53, windowNumber: harness.window.windowNumber, timestamp: baseTimestamp + 0.05),
              let capsExitFirstEscape = makeKeyDownEvent(key: "\u{1b}", modifiers: [.capsLock], keyCode: 53, windowNumber: harness.window.windowNumber, timestamp: baseTimestamp + 0.08),
              let capsExitSecondEscape = makeKeyDownEvent(key: "\u{1b}", modifiers: [.capsLock], keyCode: 53, windowNumber: harness.window.windowNumber, timestamp: baseTimestamp + 0.09),
              let commandS = makeKeyDownEvent(key: "s", modifiers: [.command], keyCode: 1, windowNumber: harness.window.windowNumber) else {
            XCTFail("Failed to construct browser focus mode key events")
            return
        }

        XCTAssertFalse(harness.panel.isBrowserFocusModeActive)
        XCTAssertEqual(
            appDelegate.handleBrowserFocusModeKeyEvent(inactiveEscape, webView: harness.webView, source: "unit.inactiveEscape"),
            .inactive
        )
        XCTAssertEqual(
            appDelegate.handleBrowserFocusModeKeyEvent(inactiveRepeatEscape, webView: harness.webView, source: "unit.inactiveRepeatEscape"),
            .inactive
        )
        XCTAssertFalse(harness.panel.isBrowserFocusModeActive)

        XCTAssertTrue(
            harness.panel.setBrowserFocusModeActive(true, reason: "unit.escape", focusWebView: false)
        )
        XCTAssertTrue(harness.panel.isBrowserFocusModeActive)
        XCTAssertFalse(harness.panel.isBrowserFocusModeExitArmed)

        XCTAssertEqual(
            appDelegate.handleBrowserFocusModeKeyEvent(commandS, webView: harness.webView, source: "unit.commandS"),
            .forwardToWebView
        )
        XCTAssertFalse(harness.panel.isBrowserFocusModeExitArmed)
        XCTAssertTrue(harness.panel.isBrowserFocusModeActive)

        XCTAssertEqual(
            appDelegate.handleBrowserFocusModeKeyEvent(activeFirstEscape, webView: harness.webView, source: "unit.firstEscapeAgain"),
            .forwardToWebView
        )
        XCTAssertTrue(harness.panel.isBrowserFocusModeExitArmed)
        XCTAssertEqual(
            appDelegate.handleBrowserFocusModeKeyEvent(activeRepeatEscape, webView: harness.webView, source: "unit.activeRepeatEscape"),
            .consume
        )
        XCTAssertTrue(harness.panel.isBrowserFocusModeActive)
        XCTAssertTrue(harness.panel.isBrowserFocusModeExitArmed)
        XCTAssertEqual(
            appDelegate.handleBrowserFocusModeKeyEvent(activeFirstEscape, webView: harness.webView, source: "unit.firstEscapeAgain.duplicate"),
            .consume
        )
        XCTAssertTrue(harness.panel.isBrowserFocusModeActive)
        XCTAssertTrue(harness.panel.isBrowserFocusModeExitArmed)

        XCTAssertEqual(
            appDelegate.handleBrowserFocusModeKeyEvent(activeSecondEscape, webView: harness.webView, source: "unit.secondEscape"),
            .consume
        )
        XCTAssertFalse(harness.panel.isBrowserFocusModeActive)
        XCTAssertFalse(harness.panel.isBrowserFocusModeExitArmed)

        XCTAssertTrue(
            harness.panel.setBrowserFocusModeActive(true, reason: "unit.capsEscape", focusWebView: false)
        )
        XCTAssertEqual(
            appDelegate.handleBrowserFocusModeKeyEvent(capsExitFirstEscape, webView: harness.webView, source: "unit.capsExitFirstEscape"),
            .forwardToWebView
        )
        XCTAssertTrue(harness.panel.isBrowserFocusModeExitArmed)
        XCTAssertEqual(
            appDelegate.handleBrowserFocusModeKeyEvent(capsExitSecondEscape, webView: harness.webView, source: "unit.capsExitSecondEscape"),
            .consume
        )
        XCTAssertFalse(harness.panel.isBrowserFocusModeActive)
        XCTAssertFalse(harness.panel.isBrowserFocusModeExitArmed)
    }

    func testBrowserFocusModeStaleExitArmRearmsOnNextEscape() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }
        guard let harness = makeBrowserFocusModeHarness() else { return }
        defer { closeWindow(withId: harness.windowId) }

        let baseTimestamp = ProcessInfo.processInfo.systemUptime
        guard let firstEscape = makeKeyDownEvent(key: "\u{1b}", modifiers: [], keyCode: 53, windowNumber: harness.window.windowNumber, timestamp: baseTimestamp + 0.01),
              let secondEscape = makeKeyDownEvent(key: "\u{1b}", modifiers: [], keyCode: 53, windowNumber: harness.window.windowNumber, timestamp: baseTimestamp + 2.0),
              let thirdEscape = makeKeyDownEvent(key: "\u{1b}", modifiers: [], keyCode: 53, windowNumber: harness.window.windowNumber, timestamp: baseTimestamp + 2.1) else {
            XCTFail("Failed to construct browser focus mode timeout Escape events")
            return
        }

        XCTAssertTrue(
            harness.panel.setBrowserFocusModeActive(true, reason: "unit.staleExitArm", focusWebView: false)
        )
        XCTAssertEqual(
            appDelegate.handleBrowserFocusModeKeyEvent(firstEscape, webView: harness.webView, source: "unit.staleExitArm.first"),
            .forwardToWebView
        )
        XCTAssertTrue(harness.panel.isBrowserFocusModeActive)
        XCTAssertTrue(harness.panel.isBrowserFocusModeExitArmed)

        XCTAssertEqual(
            appDelegate.handleBrowserFocusModeKeyEvent(secondEscape, webView: harness.webView, source: "unit.staleExitArm.rearm"),
            .forwardToWebView
        )
        XCTAssertTrue(harness.panel.isBrowserFocusModeActive)
        XCTAssertTrue(harness.panel.isBrowserFocusModeExitArmed)

        XCTAssertEqual(
            appDelegate.handleBrowserFocusModeKeyEvent(thirdEscape, webView: harness.webView, source: "unit.staleExitArm.exit"),
            .consume
        )
        XCTAssertFalse(harness.panel.isBrowserFocusModeActive)
        XCTAssertFalse(harness.panel.isBrowserFocusModeExitArmed)
    }

    func testBrowserFocusModeClearsWhenWebViewLeavesInteractiveHost() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }
        guard let harness = makeBrowserFocusModeHarness() else { return }
        defer { closeWindow(withId: harness.windowId) }

        XCTAssertTrue(
            harness.panel.setBrowserFocusModeActive(true, reason: "unit.staleHost", focusWebView: false)
        )
        XCTAssertTrue(harness.panel.isBrowserFocusModeActive)
        harness.webView.removeFromSuperview()

        guard let commandS = makeKeyDownEvent(key: "s", modifiers: [.command], keyCode: 1, windowNumber: harness.window.windowNumber) else {
            XCTFail("Failed to construct Cmd+S event")
            return
        }

        XCTAssertEqual(
            appDelegate.handleBrowserFocusModeKeyEvent(commandS, webView: harness.webView, source: "unit.staleHost"),
            .inactive
        )
        XCTAssertFalse(harness.panel.isBrowserFocusModeActive)
        XCTAssertFalse(harness.panel.isBrowserFocusModeExitArmed)
    }

    func testBrowserFocusModeCommandEquivalentSkipsAppMenuFallback() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }
        guard let harness = makeBrowserFocusModeHarness() else { return }
        defer { closeWindow(withId: harness.windowId) }

        XCTAssertTrue(
            harness.panel.setBrowserFocusModeActive(true, reason: "unit.commandEquivalent", focusWebView: false)
        )

        let originalMainMenu = NSApp.mainMenu
        let probe = MenuActionProbe()
        let menu = NSMenu()
        let item = NSMenuItem(title: "Find", action: #selector(MenuActionProbe.perform(_:)), keyEquivalent: "f")
        item.keyEquivalentModifierMask = [.command]
        item.target = probe
        menu.addItem(item)
        let returnItem = NSMenuItem(title: "Run", action: #selector(MenuActionProbe.perform(_:)), keyEquivalent: "\r")
        returnItem.keyEquivalentModifierMask = [.command]
        returnItem.target = probe
        menu.addItem(returnItem)
        NSApp.mainMenu = menu
        defer { NSApp.mainMenu = originalMainMenu }

        guard let commandF = makeKeyDownEvent(key: "f", modifiers: [.command], keyCode: 3, windowNumber: harness.window.windowNumber),
              let commandReturn = makeKeyDownEvent(key: "\r", modifiers: [.command], keyCode: 36, windowNumber: harness.window.windowNumber) else {
            XCTFail("Failed to construct browser focus mode command-equivalent events")
            return
        }

#if DEBUG
        XCTAssertFalse(appDelegate.debugHandleCustomShortcut(event: commandF))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
        XCTAssertTrue(harness.webView.performKeyEquivalent(with: commandF))
        XCTAssertEqual(probe.callCount, 0, "Focus mode must not replay unhandled page shortcuts into the app menu")
        XCTAssertTrue(harness.webView.performKeyEquivalent(with: commandReturn))
        XCTAssertEqual(probe.callCount, 0, "Focus mode must consume unhandled Cmd+Return instead of falling through to the app menu")
        XCTAssertTrue(harness.panel.isBrowserFocusModeActive)
    }

    private func makeBrowserFocusModeHarness(
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> (windowId: UUID, window: NSWindow, panel: BrowserPanel, webView: CmuxWebView)? {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared", file: file, line: line)
            return nil
        }

        let windowId = appDelegate.createMainWindow()
        guard let window = window(withId: windowId),
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace,
              let browserURL = URL(string: "data:text/html;base64,PGh0bWw+PGJvZHk+Zm9jdXM8L2JvZHk+PC9odG1sPg=="),
              let browserPanelId = manager.openBrowser(inWorkspace: workspace.id, url: browserURL, preferSplitRight: true),
              let browserPanel = manager.selectedWorkspace?.browserPanel(for: browserPanelId) ?? workspace.browserPanel(for: browserPanelId),
              let webView = browserPanel.webView as? CmuxWebView else {
            closeWindow(withId: windowId)
            XCTFail("Expected attached browser focus mode harness", file: file, line: line)
            return nil
        }

        workspace.focusPanel(browserPanel.id)
        if webView.superview == nil {
            webView.frame = window.contentView?.bounds ?? .zero
            window.contentView?.addSubview(webView)
        }
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.makeFirstResponder(webView), file: file, line: line)
        return (windowId: windowId, window: window, panel: browserPanel, webView: webView)
    }

    private func makeFindShortcutFocusController() -> MainWindowFocusController {
        MainWindowFocusController(
            windowId: UUID(),
            window: nil,
            tabManager: makeShortcutRoutingTabManager(),
            fileExplorerState: nil
        )
    }

#if DEBUG
    private func makeRegisteredLightweightMainWindowContext(
        appDelegate: AppDelegate,
        createInitialWorkspace: Bool = false
    ) -> (windowId: UUID, window: NSWindow, tabManager: TabManager) {
        let windowId = UUID()
        let window = makeRegisteredShortcutRoutingWindow(id: windowId)
        let tabManager = makeShortcutRoutingTabManager(
            autoWelcomeIfNeeded: false,
            createInitialWorkspace: createInitialWorkspace
        )
        let registeredWindowId = appDelegate.registerMainWindowContextForTesting(
            windowId: windowId,
            tabManager: tabManager,
            window: window,
            notifyObservers: false
        )
        return (registeredWindowId, window, tabManager)
    }

    private func makeVisibleRegisteredLightweightMainWindowContext(
        appDelegate: AppDelegate,
        createInitialWorkspace: Bool = false
    ) -> (windowId: UUID, window: NSWindow, tabManager: TabManager) {
        let context = makeRegisteredLightweightMainWindowContext(
            appDelegate: appDelegate,
            createInitialWorkspace: createInitialWorkspace
        )
        context.window.orderFrontRegardless()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        return context
    }
#endif

    private func window(withId windowId: UUID) -> NSWindow? {
        let identifier = "cmux.main.\(windowId.uuidString)"
        return NSApp.windows.first(where: { $0.identifier?.rawValue == identifier })
    }

    private func surfaceView(in hostedView: GhosttySurfaceScrollView) -> GhosttyNSView? {
        var stack: [NSView] = [hostedView]
        while let current = stack.popLast() {
            if let surfaceView = current as? GhosttyNSView {
                return surfaceView
            }
            stack.append(contentsOf: current.subviews)
        }
        return nil
    }

    private func findEditableTextField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable {
            return field
        }
        for subview in view.subviews {
            if let field = findEditableTextField(in: subview) {
                return field
            }
        }
        return nil
    }

    private func firstResponderOwnsTextField(_ firstResponder: NSResponder?, textField: NSTextField) -> Bool {
        if firstResponder === textField {
            return true
        }
        if let editor = firstResponder as? NSTextView,
           editor.isFieldEditor,
           editor.delegate as? NSTextField === textField {
            return true
        }
        return false
    }

    private func mainWindowIds() -> Set<UUID> {
        Set(NSApp.windows.compactMap { window in
            guard let raw = window.identifier?.rawValue,
                  raw.hasPrefix("cmux.main.") else {
                return nil
            }
            return UUID(uuidString: String(raw.dropFirst("cmux.main.".count)))
        })
    }

    private func closeWindow(withId windowId: UUID) {
        AppDelegate.shared?.closeMainWindowForXCTest(windowId: windowId)
    }

    private func closeTestWindow(_ window: NSWindow) {
        if let rawIdentifier = window.identifier?.rawValue,
           rawIdentifier.hasPrefix("cmux.main."),
           let windowId = UUID(uuidString: String(rawIdentifier.dropFirst("cmux.main.".count))) {
            AppDelegate.shared?.forgetRecoverableMainWindowRoute(windowId: windowId)
            window.identifier = nil
        }
        window.animationBehavior = .none
        window.orderOut(nil)
        window.close()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }

    private func waitFor(timeout: TimeInterval, until condition: () -> Bool) {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }
    }

    private func restoreDefaultsValue(_ value: Any?, forKey key: String, defaults: UserDefaults) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
