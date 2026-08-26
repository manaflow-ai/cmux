import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct GlobalSearchShortcutBehaviorTests {}

extension GlobalSearchShortcutBehaviorTests {
    @MainActor @Suite final class GlobalSearchLocalMonitorChainTests {
    private let originalSettingsFileStore: KeyboardShortcutSettingsFileStore

    init() {
        originalSettingsFileStore = KeyboardShortcutSettings.settingsFileStore
        KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
            primaryPath: FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-global-search-monitor-chain-\(UUID().uuidString).json")
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

    @Test func visibleSearchClosesForRemappedCommandShortcutThroughLocalMonitorChain() throws {
#if DEBUG
        let appDelegate = try #require(AppDelegate.shared)
        let window = try makeMainWindow(appDelegate: appDelegate)
        defer { closeWindow(window, appDelegate: appDelegate) }

        let shortcut = StoredShortcut(
            key: "j",
            command: true,
            shift: false,
            option: false,
            control: false
        )
        KeyboardShortcutSettings.setShortcut(shortcut, for: .globalSearch)
        #expect(
            KeyboardShortcutSettings.shortcut(for: .globalSearch) == shortcut,
            "The monitor-chain fixture must install a valid, unclaimed Command shortcut"
        )
        appDelegate.toggleGlobalSearchPalette()
        let popoverWindow = try #require(
            waitForSearchPopoverWindow(excluding: window),
            "The real Search popover and its local key monitor must be active"
        )

        NSApp.sendEvent(
            try makeKeyDownEvent(
                key: "j",
                modifiers: [.command],
                keyCode: 38,
                windowNumber: popoverWindow.windowNumber
            )
        )

        #expect(
            waitUntilGlobalSearchCloses(),
            "The popover monitor must route the configured toggle before consuming generic Command keys"
        )
#else
        Issue.record("Global Search local-monitor routing requires a DEBUG app-host build")
#endif
    }

    @Test func visibleSearchClosesForRemappedChordThroughLocalMonitorChain() throws {
#if DEBUG
        let appDelegate = try #require(AppDelegate.shared)
        let window = try makeMainWindow(appDelegate: appDelegate)
        defer { closeWindow(window, appDelegate: appDelegate) }

        KeyboardShortcutSettings.setShortcut(
            StoredShortcut(
                key: "k",
                command: true,
                shift: false,
                option: false,
                control: false,
                chordKey: "g"
            ),
            for: .globalSearch
        )
        appDelegate.toggleGlobalSearchPalette()
        let popoverWindow = try #require(
            waitForSearchPopoverWindow(excluding: window),
            "The real Search popover and its local key monitor must be active"
        )

        NSApp.sendEvent(
            try makeKeyDownEvent(
                key: "k",
                modifiers: [.command],
                keyCode: 40,
                windowNumber: popoverWindow.windowNumber
            )
        )
        #expect(GlobalSearchCoordinator.shared.isPaletteVisible())

        NSApp.sendEvent(
            try makeKeyDownEvent(
                key: "g",
                modifiers: [],
                keyCode: 5,
                windowNumber: popoverWindow.windowNumber
            )
        )

        #expect(
            waitUntilGlobalSearchCloses(),
            "The popover monitor must let the shared router arm and complete Global Search chords"
        )
#else
        Issue.record("Global Search local-monitor routing requires a DEBUG app-host build")
#endif
    }

    @Test func visibleSearchChordEditingSuffixCompletesThroughLocalMonitorChain() throws {
#if DEBUG
        let appDelegate = try #require(AppDelegate.shared)
        let window = try makeMainWindow(appDelegate: appDelegate)
        defer { closeWindow(window, appDelegate: appDelegate) }

        KeyboardShortcutSettings.setShortcut(
            StoredShortcut(
                key: "k",
                command: true,
                shift: false,
                option: false,
                control: false,
                chordKey: "c",
                chordCommand: true
            ),
            for: .globalSearch
        )
        appDelegate.toggleGlobalSearchPalette()
        let popoverWindow = try #require(
            waitForSearchPopoverWindow(excluding: window),
            "The real Search popover and its local key monitor must be active"
        )

        NSApp.sendEvent(
            try makeKeyDownEvent(
                key: "k",
                modifiers: [.command],
                keyCode: 40,
                windowNumber: popoverWindow.windowNumber
            )
        )
        #expect(GlobalSearchCoordinator.shared.isPaletteVisible())

        NSApp.sendEvent(
            try makeKeyDownEvent(
                key: "c",
                modifiers: [.command],
                keyCode: 8,
                windowNumber: popoverWindow.windowNumber
            )
        )

        #expect(
            waitUntilGlobalSearchCloses(),
            "An editing-key suffix must complete an already-active Global Search chord"
        )
#else
        Issue.record("Global Search local-monitor routing requires a DEBUG app-host build")
#endif
    }

    @Test func visibleSearchCompletesEditingSuffixFromPromotedChordState() throws {
#if DEBUG
        let appDelegate = try #require(AppDelegate.shared)
        let window = try makeMainWindow(appDelegate: appDelegate)
        defer { closeWindow(window, appDelegate: appDelegate) }

        let shortcut = StoredShortcut(
            key: "k",
            command: true,
            shift: false,
            option: false,
            control: false,
            chordKey: "c",
            chordCommand: true
        )
        KeyboardShortcutSettings.setShortcut(shortcut, for: .globalSearch)
        appDelegate.toggleGlobalSearchPalette()
        let popoverWindow = try #require(
            waitForSearchPopoverWindow(excluding: window),
            "The real Search popover and its local key monitor must be active"
        )
        appDelegate.activeConfiguredShortcutChordPrefixForCurrentEvent =
            shortcut.firstStroke

        let route = appDelegate.routeVisibleGlobalSearchShortcutFromLocalMonitor(
            try makeKeyDownEvent(
                key: "c",
                modifiers: [.command],
                keyCode: 8,
                windowNumber: popoverWindow.windowNumber
            )
        )

        guard case .handled = route else {
            Issue.record(
                "An editing-key suffix must complete a promoted Global Search chord"
            )
            return
        }
        #expect(waitUntilGlobalSearchCloses())
#else
        Issue.record("Global Search local-monitor routing requires a DEBUG app-host build")
#endif
    }

    @Test func unrelatedChordSuffixPreservesPendingPrefixForDownstreamMonitor() throws {
#if DEBUG
        let appDelegate = try #require(AppDelegate.shared)
        let window = try makeMainWindow(appDelegate: appDelegate)
        defer { closeWindow(window, appDelegate: appDelegate) }

        let shortcut = StoredShortcut(
            key: "k",
            command: true,
            shift: false,
            option: false,
            control: false,
            chordKey: "g"
        )
        KeyboardShortcutSettings.setShortcut(shortcut, for: .globalSearch)
        appDelegate.toggleGlobalSearchPalette()
        let popoverWindow = try #require(
            waitForSearchPopoverWindow(excluding: window),
            "The real Search popover and its local key monitor must be active"
        )
        let unrelatedSuffixEvent = try makeKeyDownEvent(
            key: "s",
            modifiers: [],
            keyCode: 1,
            windowNumber: popoverWindow.windowNumber
        )
        let chordWindowNumber = appDelegate.configuredShortcutChordWindowNumber(
            for: unrelatedSuffixEvent
        )
        appDelegate.pendingConfiguredShortcutChord = AppDelegate.PendingConfiguredShortcutChord(
            firstStroke: shortcut.firstStroke,
            windowNumber: chordWindowNumber
        )

        let route = appDelegate.routeVisibleGlobalSearchShortcutFromLocalMonitor(
            unrelatedSuffixEvent
        )

        guard case .notApplicable = route else {
            Issue.record("An unrelated suffix must continue to the downstream shortcut monitor")
            return
        }
        #expect(
            appDelegate.pendingConfiguredShortcutChord?.firstStroke == shortcut.firstStroke,
            "The Search popover monitor must not destroy another chord sharing the prefix"
        )
        #expect(
            appDelegate.pendingConfiguredShortcutChord?.windowNumber == chordWindowNumber
        )
        #expect(GlobalSearchCoordinator.shared.isPaletteVisible())
#else
        Issue.record("Global Search local-monitor routing requires a DEBUG app-host build")
#endif
    }

    private func makeMainWindow(appDelegate: AppDelegate) throws -> NSWindow {
        let windowId = appDelegate.createMainWindow()
        let identifier = "cmux.main.\(windowId.uuidString)"
        let window = try #require(
            NSApp.windows.first(where: { $0.identifier?.rawValue == identifier })
        )
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        return window
    }

    private func waitForSearchPopoverWindow(
        excluding mainWindow: NSWindow,
        timeout: TimeInterval = 2
    ) -> NSWindow? {
        let deadline = Date.now.addingTimeInterval(timeout)
        repeat {
            if let window = NSApp.windows.first(where: {
                $0 !== mainWindow
                    && $0.isVisible
                    && $0.firstResponder is NSTextView
            }) {
                return window
            }
            _ = RunLoop.main.run(
                mode: .default,
                before: min(deadline, Date.now.addingTimeInterval(0.01))
            )
        } while Date.now < deadline
        return nil
    }

    private func makeKeyDownEvent(
        key: String,
        modifiers: NSEvent.ModifierFlags,
        keyCode: UInt16,
        windowNumber: Int
    ) throws -> NSEvent {
        try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: windowNumber,
                context: nil,
                characters: key,
                charactersIgnoringModifiers: key,
                isARepeat: false,
                keyCode: keyCode
            )
        )
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

    private func closeWindow(_ window: NSWindow, appDelegate: AppDelegate) {
        GlobalSearchCoordinator.shared.dismissPalette()
#if DEBUG
        appDelegate.debugResetShortcutRoutingStateForTesting()
        let originalConfirmationHandler = appDelegate.debugCloseMainWindowConfirmationHandler
        appDelegate.debugCloseMainWindowConfirmationHandler = { _ in true }
        defer { appDelegate.debugCloseMainWindowConfirmationHandler = originalConfirmationHandler }
#endif
        window.animationBehavior = .none
        window.orderOut(nil)
        window.close()
    }
    }
}
