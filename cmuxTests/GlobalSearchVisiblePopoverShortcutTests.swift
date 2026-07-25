import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
final class GlobalSearchVisiblePopoverShortcutTests {
    private let originalSettingsFileStore: KeyboardShortcutSettingsFileStore

    init() {
        originalSettingsFileStore = KeyboardShortcutSettings.settingsFileStore
        KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
            primaryPath: FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-global-search-visible-popover-\(UUID().uuidString).json")
                .path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            startWatching: false
        )
        KeyboardShortcutSettings.resetAll()
    }

    deinit {
        KeyboardShortcutSettings.settingsFileStore = originalSettingsFileStore
        KeyboardShortcutSettings.resetAll()
    }

    @Test func scopedVisibleGlobalSearchClosesFromAuxiliaryWindowShortcut() throws {
#if DEBUG
        let appDelegate = try #require(AppDelegate.shared)
        let harness = try makeHarness(appDelegate: appDelegate)
        defer { closeHarness(harness, appDelegate: appDelegate) }

        try scopeGlobalSearchToBrowserFocus()
        appDelegate.toggleGlobalSearchPalette()
        #expect(GlobalSearchCoordinator.shared.isPaletteVisible())

        let event = try makeKeyDownEvent(
            key: "f",
            modifiers: [.command, .option],
            keyCode: 3,
            windowNumber: harness.auxiliaryWindow.windowNumber
        )
        #expect(!appDelegate.shortcutWhenClauseAllows(action: .globalSearch, event: event))

        #expect(
            appDelegate.debugHandleCustomShortcut(event: event),
            "The visible Search popover must own its configured toggle shortcut"
        )
        #expect(waitUntilGlobalSearchCloses())
#else
        Issue.record("Global Search visible-popover routing requires a DEBUG build")
#endif
    }

    @Test func scopedVisibleGlobalSearchChordCompletesFromAuxiliaryWindow() throws {
#if DEBUG
        let appDelegate = try #require(AppDelegate.shared)
        let harness = try makeHarness(appDelegate: appDelegate)
        defer { closeHarness(harness, appDelegate: appDelegate) }

        KeyboardShortcutSettings.setShortcut(
            StoredShortcut(
                key: "k",
                command: true,
                shift: false,
                option: true,
                control: false,
                chordKey: "f"
            ),
            for: .globalSearch
        )
        try scopeGlobalSearchToBrowserFocus()
        appDelegate.toggleGlobalSearchPalette()
        #expect(GlobalSearchCoordinator.shared.isPaletteVisible())

        let prefixEvent = try makeKeyDownEvent(
            key: "k",
            modifiers: [.command, .option],
            keyCode: 40,
            windowNumber: harness.auxiliaryWindow.windowNumber
        )
        let suffixEvent = try makeKeyDownEvent(
            key: "f",
            modifiers: [],
            keyCode: 3,
            windowNumber: harness.auxiliaryWindow.windowNumber
        )
        #expect(!appDelegate.shortcutWhenClauseAllows(action: .globalSearch, event: prefixEvent))

        #expect(
            appDelegate.debugHandleCustomShortcut(event: prefixEvent),
            "The visible Search popover must arm its configured chord before auxiliary-window rejection"
        )
        #expect(GlobalSearchCoordinator.shared.isPaletteVisible())
        #expect(appDelegate.debugHandleCustomShortcut(event: suffixEvent))
        #expect(waitUntilGlobalSearchCloses())
#else
        Issue.record("Global Search visible-popover routing requires a DEBUG build")
#endif
    }

    @Test func markedTextOwnsInputWhileGlobalSearchIsVisible() throws {
#if DEBUG
        let appDelegate = try #require(AppDelegate.shared)
        let harness = try makeHarness(appDelegate: appDelegate)
        defer { closeHarness(harness, appDelegate: appDelegate) }

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        harness.auxiliaryWindow.contentView?.addSubview(textView)
        #expect(harness.auxiliaryWindow.makeFirstResponder(textView))
        textView.setMarkedText(
            "かな",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        #expect(textView.hasMarkedText())

        KeyboardShortcutSettings.setShortcut(
            StoredShortcut(
                key: "q",
                command: false,
                shift: false,
                option: true,
                control: false
            ),
            for: .globalSearch
        )
        appDelegate.toggleGlobalSearchPalette()
        #expect(GlobalSearchCoordinator.shared.isPaletteVisible())

        let event = try makeKeyDownEvent(
            key: "q",
            characters: "@",
            modifiers: [.option],
            keyCode: 12,
            windowNumber: harness.auxiliaryWindow.windowNumber
        )

        #expect(
            !appDelegate.debugHandleCustomShortcut(event: event),
            "IME marked text must keep ownership before visible Search shortcut routing"
        )
        #expect(GlobalSearchCoordinator.shared.isPaletteVisible())
#else
        Issue.record("Global Search visible-popover routing requires a DEBUG build")
#endif
    }

    private func scopeGlobalSearchToBrowserFocus() throws {
        try """
        {
          "shortcuts": {
            "when": {
              "globalSearch": "browserFocus"
            }
          }
        }
        """.write(
            to: KeyboardShortcutSettings.settingsFileStore.settingsFileURLForEditing(),
            atomically: true,
            encoding: .utf8
        )
        KeyboardShortcutSettings.settingsFileStore.reload()
    }

    private func makeHarness(
        appDelegate: AppDelegate
    ) throws -> (mainWindow: NSWindow, auxiliaryWindow: NSPanel) {
        let windowId = appDelegate.createMainWindow()
        let mainWindow = try #require(findWindow(withId: windowId))
        let auxiliaryWindow = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        auxiliaryWindow.identifier = NSUserInterfaceItemIdentifier(
            "cmux.test.globalSearchAuxiliaryWindow"
        )
        auxiliaryWindow.makeKeyAndOrderFront(nil)
        return (mainWindow, auxiliaryWindow)
    }

    private func makeKeyDownEvent(
        key: String,
        characters: String? = nil,
        modifiers: NSEvent.ModifierFlags,
        keyCode: UInt16,
        windowNumber: Int
    ) throws -> NSEvent {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber,
            context: nil,
            characters: characters ?? key,
            charactersIgnoringModifiers: key,
            isARepeat: false,
            keyCode: keyCode
        ) else {
            throw TestHarnessError.eventUnavailable
        }
        return event
    }

    private func findWindow(withId windowId: UUID) -> NSWindow? {
        let identifier = "cmux.main.\(windowId.uuidString)"
        return NSApp.windows.first(where: { $0.identifier?.rawValue == identifier })
    }

    private func waitUntilGlobalSearchCloses(timeout: TimeInterval = 2) -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        repeat {
            if !GlobalSearchCoordinator.shared.isPaletteVisible() {
                return true
            }
            _ = RunLoop.main.run(
                mode: .default,
                before: min(deadline, Date.now.addingTimeInterval(0.01))
            )
        } while Date.now < deadline
        return !GlobalSearchCoordinator.shared.isPaletteVisible()
    }

    private func closeHarness(
        _ harness: (mainWindow: NSWindow, auxiliaryWindow: NSPanel),
        appDelegate: AppDelegate
    ) {
        GlobalSearchCoordinator.shared.dismissPalette()
        appDelegate.debugResetShortcutRoutingStateForTesting()
        harness.auxiliaryWindow.orderOut(nil)
        harness.auxiliaryWindow.close()
#if DEBUG
        let originalConfirmationHandler = appDelegate.debugCloseMainWindowConfirmationHandler
        appDelegate.debugCloseMainWindowConfirmationHandler = { _ in true }
        defer { appDelegate.debugCloseMainWindowConfirmationHandler = originalConfirmationHandler }
#endif
        harness.mainWindow.animationBehavior = .none
        harness.mainWindow.orderOut(nil)
        harness.mainWindow.close()
        RunLoop.main.run(until: Date.now.addingTimeInterval(0.05))
    }

    private enum TestHarnessError: Error {
        case eventUnavailable
    }
}
