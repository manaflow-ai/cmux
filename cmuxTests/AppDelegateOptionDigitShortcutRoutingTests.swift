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
#endif

@MainActor
@Suite(.serialized)
struct AppDelegateOptionDigitShortcutRoutingTests {
#if DEBUG
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
        keyCode: UInt16
    ) -> NSEvent? {
        NSEvent.keyEvent(
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
