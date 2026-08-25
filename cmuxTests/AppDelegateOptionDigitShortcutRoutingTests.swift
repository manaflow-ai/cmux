import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

#if DEBUG
private final class OptionDigitFocusableTestView: NSView {
    var keyDownCallCount = 0
    var lastKeyDownCharactersIgnoringModifiers: String?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        keyDownCallCount += 1
        lastKeyDownCharactersIgnoringModifiers = event.charactersIgnoringModifiers
    }
}

private final class MarkedOptionTextView: NSTextView {
    var keyDownCallCount = 0

    override func keyDown(with event: NSEvent) {
        keyDownCallCount += 1
    }
}
#endif

@MainActor
@Suite(.serialized)
struct AppDelegateOptionDigitShortcutRoutingTests {
#if DEBUG
    @Test
    func fileConfiguredOptionOnlyArrowBindingsRouteBeforeTerminalFallback() throws {
        try withIsolatedShortcutRoutingState {
            let appDelegate = try #require(AppDelegate.shared)
            let windowId = appDelegate.createMainWindow()
            defer { closeWindow(withId: windowId) }

            let testWindow = try #require(self.window(withId: windowId))
            let manager = try #require(appDelegate.tabManagerFor(windowId: windowId))
            let firstWorkspace = try #require(manager.selectedWorkspace)
            let secondWorkspace = manager.addTab(select: false)
            manager.selectTab(at: 0)

            let terminalPanelId = try #require(firstWorkspace.focusedPanelId)
            let terminalPanel = try #require(firstWorkspace.terminalPanel(for: terminalPanelId))
            terminalPanel.hostedView.setVisibleInUI(true)
            terminalPanel.hostedView.setActive(true)
            terminalPanel.hostedView.moveFocus()
            testWindow.makeKeyAndOrderFront(nil)
            testWindow.displayIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            #expect(terminalPanel.hostedView.isSurfaceViewFirstResponder())

            let settingsFileURL = try writeShortcutSettingsFile(bindings: [
                "nextSidebarTab": "opt+↓",
                "prevSidebarTab": "opt+↑",
            ])
            defer { try? FileManager.default.removeItem(at: settingsFileURL) }
            KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
                primaryPath: settingsFileURL.path,
                fallbackPath: nil,
                additionalFallbackPaths: [],
                startWatching: false
            )
            appDelegate.debugResetShortcutRoutingStateForTesting()

            let nextEvent = try #require(makeKeyEvent(
                modifierFlags: [.option],
                characters: String(UnicodeScalar(NSDownArrowFunctionKey)!),
                charactersIgnoringModifiers: String(UnicodeScalar(NSDownArrowFunctionKey)!),
                keyCode: 125,
                windowNumber: testWindow.windowNumber
            ))
            let previousEvent = try #require(makeKeyEvent(
                modifierFlags: [.option],
                characters: String(UnicodeScalar(NSUpArrowFunctionKey)!),
                charactersIgnoringModifiers: String(UnicodeScalar(NSUpArrowFunctionKey)!),
                keyCode: 126,
                windowNumber: testWindow.windowNumber
            ))

            #expect(appDelegate.debugMatchesConfiguredShortcut(event: nextEvent, action: .nextSidebarTab))
            #expect(
                testWindow.performKeyEquivalent(with: nextEvent),
                "An explicit Option+Down binding should route before the terminal arrow fallback"
            )
            #expect(manager.selectedTabId == secondWorkspace.id)

            #expect(appDelegate.debugMatchesConfiguredShortcut(event: previousEvent, action: .prevSidebarTab))
            #expect(
                testWindow.performKeyEquivalent(with: previousEvent),
                "An explicit Option+Up binding should route before the terminal arrow fallback"
            )
            #expect(manager.selectedTabId == firstWorkspace.id)
        }
    }

    @Test
    func fileConfiguredOptionOnlyPrintableBindingWinsBeforeTextInput() throws {
        try withIsolatedShortcutRoutingState {
            let appDelegate = try #require(AppDelegate.shared)
            let windowId = appDelegate.createMainWindow()
            defer { closeWindow(withId: windowId) }

            let testWindow = try #require(self.window(withId: windowId))
            let manager = try #require(appDelegate.tabManagerFor(windowId: windowId))
            let initialWorkspaceCount = manager.tabs.count
            let settingsFileURL = try writeShortcutSettingsFile(bindings: [
                "newTab": "opt+q",
            ])
            defer { try? FileManager.default.removeItem(at: settingsFileURL) }
            KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
                primaryPath: settingsFileURL.path,
                fallbackPath: nil,
                additionalFallbackPaths: [],
                startWatching: false
            )
            appDelegate.debugResetShortcutRoutingStateForTesting()

            let event = try #require(makeKeyEvent(
                modifierFlags: [.option],
                characters: "@",
                charactersIgnoringModifiers: "q",
                keyCode: 12,
                windowNumber: testWindow.windowNumber
            ))

            #expect(shortcutRoutingShouldBypassForPrintableOptionText(event: event))
            #expect(
                appDelegate.debugHandleCustomShortcut(event: event),
                "An explicitly configured Option+Q binding should win over printable Option text"
            )
            #expect(manager.tabs.count == initialWorkspaceCount + 1)
        }
    }

    @Test
    func unboundOptionOnlyPrintableTextReachesFirstResponder() throws {
        try withIsolatedShortcutRoutingState {
            let appDelegate = try #require(AppDelegate.shared)
            let windowId = appDelegate.createMainWindow()
            defer { closeWindow(withId: windowId) }

            let testWindow = try #require(self.window(withId: windowId))
            let focusableView = OptionDigitFocusableTestView(
                frame: NSRect(x: 0, y: 0, width: 120, height: 24)
            )
            testWindow.contentView?.addSubview(focusableView)
            defer { focusableView.removeFromSuperview() }
            testWindow.makeKeyAndOrderFront(nil)
            #expect(testWindow.makeFirstResponder(focusableView))

            let event = try #require(makeKeyEvent(
                modifierFlags: [.option],
                characters: "@",
                charactersIgnoringModifiers: "q",
                keyCode: 12,
                windowNumber: testWindow.windowNumber
            ))

            #expect(shortcutRoutingShouldBypassForPrintableOptionText(event: event))
            #expect(
                testWindow.performKeyEquivalent(with: event),
                "An unbound Option+Q should be forwarded as text input"
            )
            #expect(focusableView.keyDownCallCount == 1)
            #expect(focusableView.lastKeyDownCharactersIgnoringModifiers == "q")
        }
    }

    @Test
    func optionDigitWorkspaceNumberShortcutBeatsPrintableOptionTextBypass() throws {
        try withIsolatedShortcutRoutingState {
            let appDelegate = try #require(AppDelegate.shared)
            let windowId = appDelegate.createMainWindow()
            defer { closeWindow(withId: windowId) }

            let testWindow = try #require(self.window(withId: windowId))
            let manager = try #require(appDelegate.tabManagerFor(windowId: windowId))

            let secondWorkspace = manager.addTab(select: false)
            manager.selectTab(at: 0)

            let optionWorkspaceNumber = optionDigitWorkspaceShortcut()

            try withTemporaryShortcut(action: .selectWorkspaceByNumber, shortcut: optionWorkspaceNumber) {
                let event = try #require(optionTwoEvent(windowNumber: testWindow.windowNumber))

                #expect(
                    appDelegate.debugHandleCustomShortcut(event: event),
                    "Explicit Option+digit workspace bindings should route before printable Option text bypass"
                )
                #expect(
                    manager.selectedTabId == secondWorkspace.id,
                    "Option+2 should select workspace 2 when selectWorkspaceByNumber is rebound to Option+1...9"
                )
            }
        }
    }

    @Test
    func focusHistoryRebindingRoutesNewShortcutsAndDropsDefaults() throws {
        try withIsolatedShortcutRoutingState {
            let appDelegate = try #require(AppDelegate.shared)
            let windowId = appDelegate.createMainWindow()
            defer { closeWindow(withId: windowId) }

            let testWindow = try #require(self.window(withId: windowId))
            let manager = try #require(appDelegate.tabManagerFor(windowId: windowId))
            let firstWorkspace = try #require(manager.selectedWorkspace)
            let secondWorkspace = manager.addTab(select: true)

            let reboundBack = StoredShortcut(
                key: "y",
                command: false,
                shift: false,
                option: true,
                control: false
            )
            let reboundForward = StoredShortcut(
                key: "u",
                command: false,
                shift: true,
                option: true,
                control: false
            )

            try withTemporaryShortcut(action: .focusHistoryBack, shortcut: reboundBack) {
                try withTemporaryShortcut(action: .focusHistoryForward, shortcut: reboundForward) {
                    let reboundBackEvent = try #require(makeKeyEvent(
                        modifierFlags: [.option],
                        characters: "¥",
                        charactersIgnoringModifiers: "y",
                        keyCode: 16,
                        windowNumber: testWindow.windowNumber
                    ))
                    let defaultBackEvent = try #require(makeKeyEvent(
                        modifierFlags: [.command],
                        characters: "[",
                        charactersIgnoringModifiers: "[",
                        keyCode: 33,
                        windowNumber: testWindow.windowNumber
                    ))

                    #expect(appDelegate.debugMatchesConfiguredShortcut(
                        event: reboundBackEvent,
                        action: .focusHistoryBack
                    ))
                    #expect(appDelegate.debugHandleCustomShortcut(event: reboundBackEvent))
                    #expect(manager.selectedTabId == firstWorkspace.id)
                    #expect(!appDelegate.debugMatchesConfiguredShortcut(
                        event: defaultBackEvent,
                        action: .focusHistoryBack
                    ))
                    _ = appDelegate.debugHandleCustomShortcut(event: defaultBackEvent)
                    #expect(
                        manager.selectedTabId == firstWorkspace.id,
                        "The retired Back binding must not keep navigating focus history"
                    )

                    let reboundForwardEvent = try #require(makeKeyEvent(
                        modifierFlags: [.option, .shift],
                        characters: "¨",
                        charactersIgnoringModifiers: "U",
                        keyCode: 32,
                        windowNumber: testWindow.windowNumber
                    ))
                    let defaultForwardEvent = try #require(makeKeyEvent(
                        modifierFlags: [.command],
                        characters: "]",
                        charactersIgnoringModifiers: "]",
                        keyCode: 30,
                        windowNumber: testWindow.windowNumber
                    ))

                    #expect(appDelegate.debugMatchesConfiguredShortcut(
                        event: reboundForwardEvent,
                        action: .focusHistoryForward
                    ))
                    #expect(appDelegate.debugHandleCustomShortcut(event: reboundForwardEvent))
                    #expect(manager.selectedTabId == secondWorkspace.id)
                    #expect(!appDelegate.debugMatchesConfiguredShortcut(
                        event: defaultForwardEvent,
                        action: .focusHistoryForward
                    ))
                    _ = appDelegate.debugHandleCustomShortcut(event: defaultForwardEvent)
                    #expect(
                        manager.selectedTabId == secondWorkspace.id,
                        "The retired Forward binding must not keep navigating focus history"
                    )
                }
            }
        }
    }

    @Test
    func configuredFocusHistoryShortcutsPrecedeCollidingGhosttySplitFallbacks() throws {
        try withIsolatedShortcutRoutingState {
            let appDelegate = try #require(AppDelegate.shared)
            let windowId = appDelegate.createMainWindow()
            defer { closeWindow(withId: windowId) }

            let testWindow = try #require(self.window(withId: windowId))
            let manager = try #require(appDelegate.tabManagerFor(windowId: windowId))
            let firstWorkspace = try #require(manager.selectedWorkspace)
            let secondWorkspace = manager.addTab(select: true)
            let terminalPanelId = try #require(secondWorkspace.focusedPanelId)
            let terminalPanel = try #require(secondWorkspace.terminalPanel(for: terminalPanelId))
            let back = KeyboardShortcutSettings.shortcut(for: .focusHistoryBack)
            let forward = KeyboardShortcutSettings.shortcut(for: .focusHistoryForward)
            let originalGhosttyPrevious = appDelegate.ghosttyGotoSplitPreviousShortcut
            let originalGhosttyNext = appDelegate.ghosttyGotoSplitNextShortcut
            defer {
                appDelegate.ghosttyGotoSplitPreviousShortcut = originalGhosttyPrevious
                appDelegate.ghosttyGotoSplitNextShortcut = originalGhosttyNext
            }
            appDelegate.ghosttyGotoSplitPreviousShortcut = back
            appDelegate.ghosttyGotoSplitNextShortcut = forward

            terminalPanel.hostedView.setVisibleInUI(true)
            terminalPanel.hostedView.setActive(true)
            terminalPanel.hostedView.moveFocus()
            testWindow.makeKeyAndOrderFront(nil)
            testWindow.displayIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

            #expect(Self.dispatch(back, in: testWindow, using: appDelegate))
            #expect(
                manager.selectedTabId == firstWorkspace.id,
                "The live configured Back action must win over an imported Ghostty fallback"
            )

            #expect(Self.dispatch(forward, in: testWindow, using: appDelegate))
            #expect(
                manager.selectedTabId == secondWorkspace.id,
                "The live configured Forward action must win over an imported Ghostty fallback"
            )

            let reboundBack = StoredShortcut(
                key: "y",
                command: false,
                shift: false,
                option: true,
                control: false
            )
            let reboundForward = StoredShortcut(
                key: "u",
                command: false,
                shift: true,
                option: true,
                control: false
            )
            try withTemporaryShortcut(action: .focusHistoryBack, shortcut: reboundBack) {
                try withTemporaryShortcut(action: .focusHistoryForward, shortcut: reboundForward) {
                    #expect(Self.dispatch(reboundBack, in: testWindow, using: appDelegate))
                    #expect(manager.selectedTabId == firstWorkspace.id)
                    #expect(Self.dispatch(reboundForward, in: testWindow, using: appDelegate))
                    #expect(manager.selectedTabId == secondWorkspace.id)

                    _ = Self.dispatch(back, in: testWindow, using: appDelegate)
                    #expect(
                        manager.selectedTabId == secondWorkspace.id,
                        "The retired Back binding must not keep stale ownership after a live rebind"
                    )
                }
            }
        }
    }

    @Test
    func focusHistoryDefaultsNavigateWithSidebarFocusDespiteGhosttyCollision() throws {
        try withIsolatedShortcutRoutingState {
            let appDelegate = try #require(AppDelegate.shared)
            let windowId = appDelegate.createMainWindow()
            defer { closeWindow(withId: windowId) }

            let testWindow = try #require(self.window(withId: windowId))
            let manager = try #require(appDelegate.tabManagerFor(windowId: windowId))
            let firstWorkspace = try #require(manager.selectedWorkspace)
            let secondWorkspace = manager.addTab(select: true)
            let back = KeyboardShortcutSettings.shortcut(for: .focusHistoryBack)
            let forward = KeyboardShortcutSettings.shortcut(for: .focusHistoryForward)
            let originalGhosttyPrevious = appDelegate.ghosttyGotoSplitPreviousShortcut
            let originalGhosttyNext = appDelegate.ghosttyGotoSplitNextShortcut
            let sidebarFocusView = OptionDigitFocusableTestView(
                frame: NSRect(x: 0, y: 0, width: 120, height: 24)
            )
            testWindow.contentView?.addSubview(sidebarFocusView)
            defer {
                sidebarFocusView.removeFromSuperview()
                appDelegate.ghosttyGotoSplitPreviousShortcut = originalGhosttyPrevious
                appDelegate.ghosttyGotoSplitNextShortcut = originalGhosttyNext
            }
            appDelegate.ghosttyGotoSplitPreviousShortcut = back
            appDelegate.ghosttyGotoSplitNextShortcut = forward
            appDelegate.noteRightSidebarKeyboardFocusIntent(mode: .sessions, in: testWindow)
            #expect(testWindow.makeFirstResponder(sidebarFocusView))

            #expect(Self.dispatch(back, in: testWindow, using: appDelegate))
            #expect(manager.selectedTabId == firstWorkspace.id)
            #expect(Self.dispatch(forward, in: testWindow, using: appDelegate))
            #expect(manager.selectedTabId == secondWorkspace.id)
        }
    }

    @Test
    func browserDefaultsNavigateBrowserHistoryWithoutChangingFocusHistory() throws {
        try withIsolatedShortcutRoutingState {
            let appDelegate = try #require(AppDelegate.shared)
            let windowId = appDelegate.createMainWindow()
            defer { closeWindow(withId: windowId) }

            let testWindow = try #require(self.window(withId: windowId))
            let manager = try #require(appDelegate.tabManagerFor(windowId: windowId))
            let secondWorkspace = manager.addTab(select: true)
            let browserPanelId = try #require(manager.openBrowser(inWorkspace: secondWorkspace.id))
            let browserPanel = try #require(secondWorkspace.browserPanel(for: browserPanelId))
            let back = KeyboardShortcutSettings.shortcut(for: .browserBack)
            let forward = KeyboardShortcutSettings.shortcut(for: .browserForward)
            let originalGhosttyPrevious = appDelegate.ghosttyGotoSplitPreviousShortcut
            let originalGhosttyNext = appDelegate.ghosttyGotoSplitNextShortcut
            defer {
                appDelegate.ghosttyGotoSplitPreviousShortcut = originalGhosttyPrevious
                appDelegate.ghosttyGotoSplitNextShortcut = originalGhosttyNext
            }
            appDelegate.ghosttyGotoSplitPreviousShortcut = back
            appDelegate.ghosttyGotoSplitNextShortcut = forward
            browserPanel.restoreSessionNavigationHistory(
                backHistoryURLStrings: [
                    "https://example.com/a",
                    "https://example.com/b",
                ],
                forwardHistoryURLStrings: [
                    "https://example.com/d",
                ],
                currentURLString: "https://example.com/c"
            )
            testWindow.makeKeyAndOrderFront(nil)
            #expect(testWindow.makeFirstResponder(browserPanel.webView))

            #expect(Self.dispatch(back, in: testWindow, using: appDelegate))
            let afterBack = browserPanel.sessionNavigationHistorySnapshot()
            #expect(afterBack.backHistoryURLStrings == ["https://example.com/a"])
            #expect(afterBack.forwardHistoryURLStrings == [
                "https://example.com/c",
                "https://example.com/d",
            ])
            #expect(manager.selectedTabId == secondWorkspace.id)

            #expect(Self.dispatch(forward, in: testWindow, using: appDelegate))
            let afterForward = browserPanel.sessionNavigationHistorySnapshot()
            #expect(afterForward.backHistoryURLStrings == [
                "https://example.com/a",
                "https://example.com/b",
            ])
            #expect(afterForward.forwardHistoryURLStrings == ["https://example.com/d"])
            #expect(manager.selectedTabId == secondWorkspace.id)
            #expect(secondWorkspace.focusedPanelId == browserPanelId)
        }
    }

    @Test
    func focusHistoryRebindingMatchesCommandShiftOptionAndControlVariants() throws {
        try withIsolatedShortcutRoutingState {
            let appDelegate = try #require(AppDelegate.shared)
            let windowId = appDelegate.createMainWindow()
            defer { closeWindow(withId: windowId) }

            let testWindow = try #require(self.window(withId: windowId))
            let candidates: [(KeyboardShortcutSettings.Action, StoredShortcut, NSEvent.ModifierFlags, String, String, UInt16)] = [
                (
                    .focusHistoryBack,
                    StoredShortcut(key: "y", command: true, shift: true, option: false, control: false),
                    [.command, .shift],
                    "Y",
                    "Y",
                    16
                ),
                (
                    .focusHistoryForward,
                    StoredShortcut(key: "u", command: false, shift: false, option: false, control: true),
                    [.control],
                    "\u{15}",
                    "u",
                    32
                ),
                (
                    .focusHistoryBack,
                    StoredShortcut(key: "y", command: false, shift: true, option: true, control: true),
                    [.shift, .option, .control],
                    "Y",
                    "Y",
                    16
                ),
            ]

            for (action, shortcut, modifiers, characters, charactersIgnoringModifiers, keyCode) in candidates {
                try withTemporaryShortcut(action: action, shortcut: shortcut) {
                    let event = try #require(makeKeyEvent(
                        modifierFlags: modifiers,
                        characters: characters,
                        charactersIgnoringModifiers: charactersIgnoringModifiers,
                        keyCode: keyCode,
                        windowNumber: testWindow.windowNumber
                    ))

                    #expect(appDelegate.debugMatchesConfiguredShortcut(event: event, action: action))
                    #expect(appDelegate.debugHandleCustomShortcut(event: event))
                }
            }
        }
    }

    @Test
    func markedTextWinsOverConfiguredPrintableOptionShortcut() throws {
        try withIsolatedShortcutRoutingState {
            let appDelegate = try #require(AppDelegate.shared)
            let windowId = appDelegate.createMainWindow()
            defer { closeWindow(withId: windowId) }

            let testWindow = try #require(self.window(withId: windowId))
            let manager = try #require(appDelegate.tabManagerFor(windowId: windowId))
            let selectedWorkspace = manager.addTab(select: true)
            let textView = MarkedOptionTextView(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
            testWindow.contentView?.addSubview(textView)
            testWindow.makeKeyAndOrderFront(nil)
            #expect(testWindow.makeFirstResponder(textView))
            textView.setMarkedText(
                "marked",
                selectedRange: NSRange(location: 6, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: 0)
            )
            #expect(textView.hasMarkedText())

            let whenURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: whenURL) }
            try #"{"shortcuts":{"when":{"switchRightSidebarToFiles":"true"}}}"#
                .write(to: whenURL, atomically: true, encoding: .utf8)
            KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
                primaryPath: whenURL.path, fallbackPath: nil, additionalFallbackPaths: [], startWatching: false
            )
            let reboundBack = StoredShortcut(
                key: "y",
                command: false,
                shift: false,
                option: true,
                control: false
            )
            let event = try #require(makeKeyEvent(
                modifierFlags: [.option],
                characters: "¥",
                charactersIgnoringModifiers: "y",
                keyCode: 16,
                windowNumber: testWindow.windowNumber
            ))
            try withTemporaryShortcut(action: .switchRightSidebarToFiles, shortcut: reboundBack) {
                #expect(appDelegate.rightSidebarModeShortcut(for: event) == nil)
                textView.unmarkText()
                #expect(appDelegate.rightSidebarModeShortcut(for: event) == .files)
                textView.setMarkedText(
                    "marked",
                    selectedRange: NSRange(location: 6, length: 0),
                    replacementRange: NSRange(location: NSNotFound, length: 0)
                )
            }
            try withTemporaryShortcut(action: .focusHistoryBack, shortcut: reboundBack) {
                #expect(!appDelegate.debugHandleCustomShortcut(event: event))
                #expect(manager.selectedTabId == selectedWorkspace.id)
                #expect(testWindow.performKeyEquivalent(with: event))
                #expect(textView.keyDownCallCount == 1)
                #expect(textView.hasMarkedText())
                #expect(manager.selectedTabId == selectedWorkspace.id)
            }
            textView.unmarkText()
        }
    }

    @Test
    func terminalKeyEquivalentRoutesActiveOptionDigitWorkspaceShortcut() throws {
        try withIsolatedShortcutRoutingState {
            let appDelegate = try #require(AppDelegate.shared)
            let windowId = appDelegate.createMainWindow()
            defer { closeWindow(withId: windowId) }

            let testWindow = try #require(self.window(withId: windowId))
            let manager = try #require(appDelegate.tabManagerFor(windowId: windowId))
            let workspace = try #require(manager.selectedWorkspace)
            let panelId = try #require(workspace.focusedPanelId)
            let terminalPanel = try #require(workspace.terminalPanel(for: panelId))

            let secondWorkspace = manager.addTab(select: false)
            manager.selectTab(at: 0)
            terminalPanel.hostedView.setVisibleInUI(true)
            terminalPanel.hostedView.setActive(true)
            terminalPanel.hostedView.moveFocus()
            testWindow.makeKeyAndOrderFront(nil)
            testWindow.displayIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

            #expect(
                terminalPanel.hostedView.isSurfaceViewFirstResponder(),
                "Expected terminal surface to own first responder before key-equivalent routing"
            )

            let optionWorkspaceNumber = optionDigitWorkspaceShortcut()

            try withTemporaryShortcut(action: .selectWorkspaceByNumber, shortcut: optionWorkspaceNumber) {
                let event = try #require(optionTwoEvent(windowNumber: testWindow.windowNumber))

                #expect(
                    testWindow.performKeyEquivalent(with: event),
                    "Terminal key-equivalent fallback should route active Option+digit workspace bindings"
                )
                #expect(
                    manager.selectedTabId == secondWorkspace.id,
                    "Option+2 should select workspace 2 before the terminal fast path receives printable Option text"
                )
            }
        }
    }

    @Test
    func inactiveOptionDigitWorkspaceWhenClauseStillForwardsPrintableOptionText() throws {
        try withIsolatedShortcutRoutingState {
            let appDelegate = try #require(AppDelegate.shared)
            let directoryURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directoryURL) }

            let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
            try """
            {
              "shortcuts": {
                "bindings": {
                  "selectWorkspaceByNumber": "opt+1"
                },
                "when": {
                  "selectWorkspaceByNumber": "browserFocus"
                }
              }
            }
            """.write(to: settingsFileURL, atomically: true, encoding: .utf8)

            KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
                primaryPath: settingsFileURL.path,
                fallbackPath: nil,
                additionalFallbackPaths: [],
                startWatching: false
            )
            appDelegate.debugResetShortcutRoutingStateForTesting()

            let windowId = appDelegate.createMainWindow()
            defer { closeWindow(withId: windowId) }

            let testWindow = try #require(self.window(withId: windowId))
            let contentView = try #require(testWindow.contentView)
            let focusableView = OptionDigitFocusableTestView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
            contentView.addSubview(focusableView)
            testWindow.makeKeyAndOrderFront(nil)
            testWindow.displayIfNeeded()

            #expect(testWindow.makeFirstResponder(focusableView), "Expected focusable view to own first responder")

            let event = try #require(makeKeyEvent(
                modifierFlags: [.option],
                characters: "™",
                charactersIgnoringModifiers: "2",
                keyCode: 19 // kVK_ANSI_2
            ))

            #expect(
                testWindow.performKeyEquivalent(with: event),
                "Inactive Option+digit workspace bindings should leave printable Option text forwarding intact"
            )
            #expect(focusableView.keyDownCallCount == 1, "Printable Option text should be forwarded to the text responder")
            #expect(focusableView.lastKeyDownCharactersIgnoringModifiers == "2")
        }
    }

    private func withIsolatedShortcutRoutingState(_ body: () throws -> Void) throws {
        let actionsWithPersistedShortcut = Set(
            KeyboardShortcutSettings.Action.allCases.filter {
                UserDefaults.standard.object(forKey: $0.defaultsKey) != nil
            }
        )
        let savedShortcutsByAction = Dictionary(
            uniqueKeysWithValues: actionsWithPersistedShortcut.map { action in
                (action, KeyboardShortcutSettings.shortcut(for: action))
            }
        )
        KeyboardShortcutRecorderActivity.resetForTesting()
        AppDelegate.shared?.debugResetShortcutRoutingStateForTesting()
        let originalSettingsFileStore = KeyboardShortcutSettings.installIsolatedTestFileStore(
            prefix: "cmux-option-digit-shortcut-routing"
        )
        KeyboardShortcutSettings.resetAll()
        AppDelegate.shared?.debugResetShortcutRoutingStateForTesting()

        defer {
            KeyboardShortcutRecorderActivity.resetForTesting()
            AppDelegate.shared?.debugResetShortcutRoutingStateForTesting()
            KeyboardShortcutSettings.settingsFileStore = originalSettingsFileStore
            for action in KeyboardShortcutSettings.Action.allCases {
                if actionsWithPersistedShortcut.contains(action),
                   let savedShortcut = savedShortcutsByAction[action] {
                    KeyboardShortcutSettings.setShortcut(savedShortcut, for: action)
                } else {
                    KeyboardShortcutSettings.resetShortcut(for: action)
                }
            }
            AppDelegate.shared?.debugResetShortcutRoutingStateForTesting()
        }

        try body()
    }

    private func withTemporaryShortcut(
        action: KeyboardShortcutSettings.Action,
        shortcut: StoredShortcut,
        _ body: () throws -> Void
    ) throws {
        let hadPersistedShortcut = UserDefaults.standard.object(forKey: action.defaultsKey) != nil
        let originalShortcut = KeyboardShortcutSettings.shortcut(for: action)
        defer {
            if hadPersistedShortcut {
                KeyboardShortcutSettings.setShortcut(originalShortcut, for: action)
            } else {
                KeyboardShortcutSettings.resetShortcut(for: action)
            }
            AppDelegate.shared?.debugResetShortcutRoutingStateForTesting()
        }
        KeyboardShortcutSettings.setShortcut(shortcut, for: action)
        AppDelegate.shared?.debugResetShortcutRoutingStateForTesting()
        try body()
    }

    private func optionDigitWorkspaceShortcut() -> StoredShortcut {
        StoredShortcut(
            key: "1",
            command: false,
            shift: false,
            option: true,
            control: false
        )
    }

    private func writeShortcutSettingsFile(bindings: [String: String]) throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        let bindingsObject = bindings
            .sorted { $0.key < $1.key }
            .map { "\"\($0.key)\": \"\($0.value)\"" }
            .joined(separator: ",\n        ")
        try """
        {
          "shortcuts": {
            "bindings": {
              \(bindingsObject)
            }
          }
        }
        """.write(to: settingsFileURL, atomically: true, encoding: .utf8)
        return settingsFileURL
    }

    private func optionTwoEvent(windowNumber: Int) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.option],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber,
            context: nil,
            characters: "™",
            charactersIgnoringModifiers: "2",
            isARepeat: false,
            keyCode: 19 // kVK_ANSI_2
        )
    }

    private static func dispatch(
        _ shortcut: StoredShortcut,
        in window: NSWindow,
        using appDelegate: AppDelegate
    ) -> Bool {
        guard !shortcut.isUnbound,
              !shortcut.hasChord,
              let keyCode = shortcut.firstStroke.resolvedKeyCode(),
              let event = NSEvent.keyEvent(
                  with: .keyDown,
                  location: .zero,
                  modifierFlags: shortcut.modifierFlags,
                  timestamp: ProcessInfo.processInfo.systemUptime,
                  windowNumber: window.windowNumber,
                  context: nil,
                  characters: shortcut.menuItemKeyEquivalent ?? shortcut.key,
                  charactersIgnoringModifiers: shortcut.menuItemKeyEquivalent ?? shortcut.key,
                  isARepeat: false,
                  keyCode: keyCode
              ) else {
            return false
        }
        return appDelegate.debugHandleCustomShortcut(event: event)
    }

    private func makeKeyEvent(
        modifierFlags: NSEvent.ModifierFlags,
        characters: String,
        charactersIgnoringModifiers: String,
        keyCode: UInt16,
        windowNumber: Int = 0
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            isARepeat: false,
            keyCode: keyCode
        )
    }

    private func window(withId windowId: UUID) -> NSWindow? {
        let identifier = "cmux.main.\(windowId.uuidString)"
        return NSApp.windows.first(where: { $0.identifier?.rawValue == identifier })
    }

    private func closeWindow(withId windowId: UUID) {
        guard let window = window(withId: windowId) else { return }
        let appDelegate = AppDelegate.shared
        let originalConfirmationHandler = appDelegate?.debugCloseMainWindowConfirmationHandler
        appDelegate?.debugCloseMainWindowConfirmationHandler = { _ in true }
        defer { appDelegate?.debugCloseMainWindowConfirmationHandler = originalConfirmationHandler }
        window.animationBehavior = .none
        window.orderOut(nil)
        window.close()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }
#endif
}
