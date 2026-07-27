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
    func optionDigitWorkspaceNumberShortcutBeatsUnmatchedOptionRouting() throws {
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
                    "Explicit Option+digit workspace bindings should route before unmatched Option input"
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
                    #expect(!appDelegate.debugHandleCustomShortcut(event: defaultBackEvent))

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
                    #expect(!appDelegate.debugHandleCustomShortcut(event: defaultForwardEvent))
                }
            }
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
                    "Option+2 should select workspace 2 before unmatched Option input reaches the terminal"
                )
            }
        }
    }

    @Test
    func inactiveOptionDigitWorkspaceWhenClauseStillForwardsOptionInput() throws {
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
                "Inactive Option+digit workspace bindings should leave Option input forwarding intact"
            )
            #expect(focusableView.keyDownCallCount == 1, "Option input should be forwarded to the text responder")
            #expect(focusableView.lastKeyDownCharactersIgnoringModifiers == "2")
        }
    }

    @Test
    func configuredOptionTextShortcutBeatsUnmatchedOptionRouting() throws {
        try withIsolatedShortcutRoutingState {
            let appDelegate = try #require(AppDelegate.shared)
            let windowId = appDelegate.createMainWindow()
            defer { closeWindow(withId: windowId) }

            let testWindow = try #require(self.window(withId: windowId))
            let manager = try #require(appDelegate.tabManagerFor(windowId: windowId))
            let workspaceCountBefore = manager.tabs.count
            let optionQShortcut = StoredShortcut(
                key: "q",
                command: false,
                shift: false,
                option: true,
                control: false
            )

            try withTemporaryShortcut(action: .newTab, shortcut: optionQShortcut) {
                let keyDown = try #require(NSEvent.keyEvent(
                    with: .keyDown,
                    location: .zero,
                    modifierFlags: [.option],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: testWindow.windowNumber,
                    context: nil,
                    characters: "@",
                    charactersIgnoringModifiers: "q",
                    isARepeat: false,
                    keyCode: 12
                ))
                let keyUp = try #require(NSEvent.keyEvent(
                    with: .keyUp,
                    location: .zero,
                    modifierFlags: [.option],
                    timestamp: keyDown.timestamp + 0.01,
                    windowNumber: testWindow.windowNumber,
                    context: nil,
                    characters: "@",
                    charactersIgnoringModifiers: "q",
                    isARepeat: false,
                    keyCode: 12
                ))

                #expect(
                    appDelegate.debugHandleShortcutMonitorEvent(event: keyDown),
                    "An exact Option+Q binding must route before unmatched Option text reaches AppKit"
                )
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
                #expect(
                    manager.tabs.count == workspaceCountBefore + 1,
                    "The configured cmux shortcut must win even when the layout gives Option+Q printable text"
                )
                #expect(
                    appDelegate.debugHandleShortcutMonitorEvent(event: keyUp),
                    "A shortcut-owned key press must also own its matching physical key release"
                )
            }
        }
    }

    @Test
    func configuredKeyEquivalentOwnsMatchingRelease() throws {
        try withIsolatedShortcutRoutingState {
            let appDelegate = try #require(AppDelegate.shared)
            let windowId = appDelegate.createMainWindow()
            defer { closeWindow(withId: windowId) }

            let testWindow = try #require(self.window(withId: windowId))
            let optionQShortcut = StoredShortcut(
                key: "q",
                command: false,
                shift: false,
                option: true,
                control: false
            )

            try withTemporaryShortcut(action: .newTab, shortcut: optionQShortcut) {
                let timestamp = ProcessInfo.processInfo.systemUptime
                let keyDown = try #require(NSEvent.keyEvent(
                    with: .keyDown,
                    location: .zero,
                    modifierFlags: [.option],
                    timestamp: timestamp,
                    windowNumber: testWindow.windowNumber,
                    context: nil,
                    characters: "@",
                    charactersIgnoringModifiers: "q",
                    isARepeat: false,
                    keyCode: 12
                ))
                let keyUp = try #require(NSEvent.keyEvent(
                    with: .keyUp,
                    location: .zero,
                    modifierFlags: [.option],
                    timestamp: timestamp + 0.01,
                    windowNumber: testWindow.windowNumber,
                    context: nil,
                    characters: "@",
                    charactersIgnoringModifiers: "q",
                    isARepeat: false,
                    keyCode: 12
                ))

                #expect(appDelegate.handleConfiguredShortcutKeyEquivalent(keyDown))
                #expect(
                    appDelegate.debugHandleShortcutMonitorEvent(event: keyUp),
                    "A key-equivalent shortcut press must own the matching release"
                )
            }
        }
    }

    @Test
    func repeatCannotAcquireShortcutOwnershipAfterResponderOwnedPress() throws {
        try withIsolatedShortcutRoutingState {
            let appDelegate = try #require(AppDelegate.shared)
            let windowId = appDelegate.createMainWindow()
            defer { closeWindow(withId: windowId) }

            let testWindow = try #require(self.window(withId: windowId))
            let manager = try #require(appDelegate.tabManagerFor(windowId: windowId))
            let workspaceCountBefore = manager.tabs.count
            let textView = MarkedOptionTextView(
                frame: NSRect(x: 0, y: 0, width: 120, height: 24)
            )
            testWindow.contentView?.addSubview(textView)
            testWindow.makeKeyAndOrderFront(nil)
            #expect(testWindow.makeFirstResponder(textView))

            let optionQShortcut = StoredShortcut(
                key: "q",
                command: false,
                shift: false,
                option: true,
                control: false
            )

            try withTemporaryShortcut(action: .newTab, shortcut: optionQShortcut) {
                textView.setMarkedText(
                    "q",
                    selectedRange: NSRange(location: 0, length: 1),
                    replacementRange: NSRange(location: NSNotFound, length: 0)
                )

                let timestamp = ProcessInfo.processInfo.systemUptime
                let keyDown = try #require(NSEvent.keyEvent(
                    with: .keyDown,
                    location: .zero,
                    modifierFlags: [.option],
                    timestamp: timestamp,
                    windowNumber: testWindow.windowNumber,
                    context: nil,
                    characters: "@",
                    charactersIgnoringModifiers: "q",
                    isARepeat: false,
                    keyCode: 12
                ))
                let repeatKeyDown = try #require(NSEvent.keyEvent(
                    with: .keyDown,
                    location: .zero,
                    modifierFlags: [.option],
                    timestamp: timestamp + 0.1,
                    windowNumber: testWindow.windowNumber,
                    context: nil,
                    characters: "@",
                    charactersIgnoringModifiers: "q",
                    isARepeat: true,
                    keyCode: 12
                ))
                let keyUp = try #require(NSEvent.keyEvent(
                    with: .keyUp,
                    location: .zero,
                    modifierFlags: [.option],
                    timestamp: timestamp + 0.2,
                    windowNumber: testWindow.windowNumber,
                    context: nil,
                    characters: "@",
                    charactersIgnoringModifiers: "q",
                    isARepeat: false,
                    keyCode: 12
                ))

                #expect(!appDelegate.debugHandleShortcutMonitorEvent(event: keyDown))
                textView.unmarkText()

                #expect(
                    !appDelegate.debugHandleShortcutMonitorEvent(event: repeatKeyDown),
                    "A repeat must preserve the original responder owner"
                )
                #expect(
                    !appDelegate.debugHandleShortcutMonitorEvent(event: keyUp),
                    "The responder-owned release must remain unconsumed"
                )
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
                #expect(manager.tabs.count == workspaceCountBefore)
            }
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
