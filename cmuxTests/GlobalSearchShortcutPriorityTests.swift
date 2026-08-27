import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension GlobalSearchShortcutBehaviorTests {
    @MainActor @Suite final class GlobalSearchShortcutPriorityTests {
    private let originalSettingsFileStore: KeyboardShortcutSettingsFileStore

    init() {
        originalSettingsFileStore = KeyboardShortcutSettings.settingsFileStore
        KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
            primaryPath: FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-global-search-priority-\(UUID().uuidString).json")
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

    @Test func rightSidebarModeOwnsOverlappingGlobalSearchShortcut() throws {
#if DEBUG
        let appDelegate = try #require(AppDelegate.shared)
        let windowId = appDelegate.createMainWindow()
        let window = try #require(findWindow(withId: windowId))
        let fileExplorerState = try #require(appDelegate.fileExplorerState)
        defer {
            GlobalSearchCoordinator.shared.dismissPalette()
            appDelegate.debugResetShortcutRoutingStateForTesting()
            closeWindow(window, appDelegate: appDelegate)
        }

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        fileExplorerState.mode = .sessions
        appDelegate.noteRightSidebarKeyboardFocusIntent(mode: .sessions, in: window)
        _ = window.makeFirstResponder(nil)

        KeyboardShortcutSettings.setShortcut(
            StoredShortcut(
                key: "1",
                command: false,
                shift: false,
                option: false,
                control: true
            ),
            for: .globalSearch
        )
        appDelegate.debugResetShortcutRoutingStateForTesting(clearFocusedWindowOverride: false)

        let event = try makeKeyEvent(
            type: .keyDown,
            key: "1",
            modifiers: [.control],
            keyCode: 18,
            windowNumber: window.windowNumber
        )

        #expect(appDelegate.debugHandleCustomShortcut(event: event))
        #expect(
            fileExplorerState.mode == .files,
            "A focused right-sidebar mode shortcut must run before overlapping app shortcuts"
        )
        #expect(
            !GlobalSearchCoordinator.shared.isPaletteVisible(),
            "Global Search must not steal a stroke owned by the focused right sidebar"
        )
#else
        Issue.record("Global Search shortcut-priority routing requires a DEBUG build")
#endif
    }

    @Test func omnibarControlNOwnsOverlappingGlobalSearchChordPrefix() throws {
        try assertOmnibarOwnsGlobalSearchChordPrefix(
            key: "n",
            keyCode: 45,
            expectedDelta: 1
        )
    }

    @Test func omnibarControlPOwnsOverlappingGlobalSearchChordPrefix() throws {
        try assertOmnibarOwnsGlobalSearchChordPrefix(
            key: "p",
            keyCode: 35,
            expectedDelta: -1
        )
    }

    @Test func activeGlobalSearchChordOwnsControlNSuffixOverOmnibar() throws {
#if DEBUG
        let appDelegate = try #require(AppDelegate.shared)
        let harness = try makeOmnibarHarness(appDelegate: appDelegate)
        defer {
            GlobalSearchCoordinator.shared.dismissPalette()
            appDelegate.debugResetShortcutRoutingStateForTesting()
            closeWindow(harness.window, appDelegate: appDelegate)
        }

        KeyboardShortcutSettings.setShortcut(
            StoredShortcut(
                key: "k",
                command: true,
                shift: false,
                option: true,
                control: false,
                chordKey: "n",
                chordCommand: false,
                chordShift: false,
                chordOption: false,
                chordControl: true
            ),
            for: .globalSearch
        )
        appDelegate.debugResetShortcutRoutingStateForTesting(clearFocusedWindowOverride: false)

        let prefixEvent = try makeKeyEvent(
            type: .keyDown,
            key: "k",
            modifiers: [.command, .option],
            keyCode: 40,
            windowNumber: harness.window.windowNumber
        )
        let suffixEvent = try makeKeyEvent(
            type: .keyDown,
            key: "n",
            modifiers: [.control],
            keyCode: 45,
            windowNumber: harness.window.windowNumber
        )

        #expect(appDelegate.debugHandleCustomShortcut(event: prefixEvent))
        #expect(!GlobalSearchCoordinator.shared.isPaletteVisible())
        #expect(
            appDelegate.debugHandleCustomShortcut(event: suffixEvent),
            "Focused-input navigation must not steal the suffix of an already-active chord"
        )
        #expect(GlobalSearchCoordinator.shared.isPaletteVisible())
#else
        Issue.record("Global Search shortcut-priority routing requires a DEBUG build")
#endif
    }

    @Test func browserEditingOwnsUnarmedGlobalSearchChordPrefix() throws {
#if DEBUG
        let appDelegate = try #require(AppDelegate.shared)
        let harness = try makeOmnibarHarness(appDelegate: appDelegate)
        let webView = try #require(harness.panel.webView as? CmuxWebView)
        defer {
            GlobalSearchCoordinator.shared.dismissPalette()
            appDelegate.debugResetShortcutRoutingStateForTesting()
            closeWindow(harness.window, appDelegate: appDelegate)
        }

        if webView.cmuxBrowserViewportAttachmentSuperview == nil,
           let contentView = harness.window.contentView {
            let presentationView = webView.cmuxBrowserViewportPresentationView
            contentView.addSubview(presentationView)
            webView.cmuxApplyBrowserViewportLayout(in: contentView.bounds)
        }
        BrowserOmnibarNativeFieldRegistry.shared.unregister(harness.field, panelId: harness.panel.id)
        harness.field.removeFromSuperview()
        webView.allowsFirstResponderAcquisition = true
        #expect(harness.window.makeFirstResponder(webView))
        #expect(harness.window.firstResponder === webView)

        KeyboardShortcutSettings.setShortcut(
            StoredShortcut(
                key: "c",
                command: true,
                shift: false,
                option: false,
                control: false,
                chordKey: "g",
                chordCommand: true
            ),
            for: .globalSearch
        )
        appDelegate.debugResetShortcutRoutingStateForTesting(clearFocusedWindowOverride: false)

        let prefixEvent = try makeKeyEvent(
            type: .keyDown,
            key: "c",
            modifiers: [.command],
            keyCode: 8,
            windowNumber: harness.window.windowNumber
        )
        let suffixEvent = try makeKeyEvent(
            type: .keyDown,
            key: "g",
            modifiers: [.command],
            keyCode: 5,
            windowNumber: harness.window.windowNumber
        )

        #expect(
            !appDelegate.debugHandleCustomShortcut(event: prefixEvent),
            "Focused browser editing must own Cmd-C before an unarmed Global Search chord"
        )
        _ = appDelegate.debugHandleCustomShortcut(event: suffixEvent)
        #expect(
            !GlobalSearchCoordinator.shared.isPaletteVisible(),
            "A browser-owned editing command must not leave a Global Search chord armed"
        )
#else
        Issue.record("Global Search shortcut-priority routing requires a DEBUG build")
#endif
    }

    @Test func commandPaletteEditingOwnsOverlappingGlobalSearchShortcut() throws {
        try assertCommandPaletteEditingOwnsUnarmedGlobalSearchBinding(
            StoredShortcut(
                key: "c",
                command: true,
                shift: false,
                option: false,
                control: false
            )
        )
    }

    @Test func commandPaletteEditingOwnsOverlappingGlobalSearchChordPrefix() throws {
        try assertCommandPaletteEditingOwnsUnarmedGlobalSearchBinding(
            StoredShortcut(
                key: "c",
                command: true,
                shift: false,
                option: false,
                control: false,
                chordKey: "g",
                chordCommand: true
            )
        )
    }

    private func assertCommandPaletteEditingOwnsUnarmedGlobalSearchBinding(
        _ shortcut: StoredShortcut
    ) throws {
#if DEBUG
        let appDelegate = try #require(AppDelegate.shared)
        let windowId = appDelegate.createMainWindow()
        let window = try #require(findWindow(withId: windowId))
        defer {
            GlobalSearchCoordinator.shared.dismissPalette()
            appDelegate.setCommandPaletteVisible(false, for: window)
            appDelegate.debugResetShortcutRoutingStateForTesting()
            closeWindow(window, appDelegate: appDelegate)
        }

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        appDelegate.setCommandPaletteVisible(true, for: window)
        #expect(appDelegate.isCommandPaletteEffectivelyVisible(for: window))

        KeyboardShortcutSettings.setShortcut(shortcut, for: .globalSearch)
        appDelegate.debugResetShortcutRoutingStateForTesting(clearFocusedWindowOverride: false)

        let prefixEvent = try makeKeyEvent(
            type: .keyDown,
            key: "c",
            modifiers: [.command],
            keyCode: 8,
            windowNumber: window.windowNumber
        )
        #expect(
            !appDelegate.debugHandleCustomShortcut(event: prefixEvent),
            "Command-palette editing must own Cmd-C before an unarmed Global Search binding"
        )

        if shortcut.hasChord {
            let suffixEvent = try makeKeyEvent(
                type: .keyDown,
                key: "g",
                modifiers: [.command],
                keyCode: 5,
                windowNumber: window.windowNumber
            )
            _ = appDelegate.debugHandleCustomShortcut(event: suffixEvent)
        }
        #expect(
            !GlobalSearchCoordinator.shared.isPaletteVisible(),
            "A command-palette editing command must not toggle or arm Global Search"
        )
#else
        Issue.record("Global Search shortcut-priority routing requires a DEBUG build")
#endif
    }

    private func assertOmnibarOwnsGlobalSearchChordPrefix(
        key: String,
        keyCode: UInt16,
        expectedDelta: Int
    ) throws {
#if DEBUG
        let appDelegate = try #require(AppDelegate.shared)
        let harness = try makeOmnibarHarness(appDelegate: appDelegate)
        defer {
            GlobalSearchCoordinator.shared.dismissPalette()
            appDelegate.debugResetShortcutRoutingStateForTesting()
            closeWindow(harness.window, appDelegate: appDelegate)
        }

        KeyboardShortcutSettings.setShortcut(
            StoredShortcut(
                key: key,
                command: false,
                shift: false,
                option: false,
                control: true,
                chordKey: "g",
                chordCommand: true,
                chordShift: false,
                chordOption: false,
                chordControl: false
            ),
            for: .globalSearch
        )
        appDelegate.debugResetShortcutRoutingStateForTesting(clearFocusedWindowOverride: false)

        let panelId = harness.panel.id
        var observedDeltas: [Int] = []
        let token = NotificationCenter.default.addObserver(
            forName: .browserMoveOmnibarSelection,
            object: nil,
            queue: nil
        ) { notification in
            guard notification.object as? UUID == panelId,
                  let delta = notification.userInfo?["delta"] as? Int else {
                return
            }
            observedDeltas.append(delta)
        }
        defer { NotificationCenter.default.removeObserver(token) }

        let prefixEvent = try makeKeyEvent(
            type: .keyDown,
            key: key,
            modifiers: [.control],
            keyCode: keyCode,
            windowNumber: harness.window.windowNumber
        )
        let keyUpEvent = try makeKeyEvent(
            type: .keyUp,
            key: key,
            modifiers: [.control],
            keyCode: keyCode,
            windowNumber: harness.window.windowNumber
        )
        let suffixEvent = try makeKeyEvent(
            type: .keyDown,
            key: "g",
            modifiers: [.command],
            keyCode: 5,
            windowNumber: harness.window.windowNumber
        )

        #expect(appDelegate.debugHandleCustomShortcut(event: prefixEvent))
        #expect(
            observedDeltas == [expectedDelta],
            "Ctrl-\(key.uppercased()) must navigate the focused omnibar instead of arming Global Search"
        )
        _ = appDelegate.debugHandleShortcutMonitorEvent(event: keyUpEvent)
        _ = appDelegate.debugHandleCustomShortcut(event: suffixEvent)
        #expect(
            !GlobalSearchCoordinator.shared.isPaletteVisible(),
            "An omnibar-owned prefix must not leave a Global Search chord armed"
        )
#else
        Issue.record("Global Search shortcut-priority routing requires a DEBUG build")
#endif
    }

    private func makeOmnibarHarness(
        appDelegate: AppDelegate
    ) throws -> (window: NSWindow, panel: BrowserPanel, field: OmnibarNativeTextField) {
        let windowId = appDelegate.createMainWindow()
        guard let window = findWindow(withId: windowId),
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace,
              let browserPanelId = manager.openBrowser(
                  inWorkspace: workspace.id,
                  url: URL(string: "about:blank"),
                  preferSplitRight: true
              ),
              let panel = manager.selectedWorkspace?.browserPanel(for: browserPanelId)
                  ?? workspace.browserPanel(for: browserPanelId) else {
            if let window = findWindow(withId: windowId) {
                closeWindow(window, appDelegate: appDelegate)
            }
            throw TestHarnessError.browserHarnessUnavailable
        }

        let field = OmnibarNativeTextField(frame: NSRect(x: 8, y: 8, width: 240, height: 24))
        field.identifier = browserOmnibarTextFieldIdentifier
        field.panelId = panel.id
        field.stringValue = "example"
        window.contentView?.addSubview(field)
        BrowserOmnibarNativeFieldRegistry.shared.register(field, panelId: panel.id)

        workspace.focusPanel(panel.id)
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        guard window.makeFirstResponder(field) else {
            BrowserOmnibarNativeFieldRegistry.shared.unregister(field, panelId: panel.id)
            field.removeFromSuperview()
            closeWindow(window, appDelegate: appDelegate)
            throw TestHarnessError.omnibarFocusUnavailable
        }
        NotificationCenter.default.post(name: .browserDidFocusAddressBar, object: panel.id)
        return (window, panel, field)
    }

    private func makeKeyEvent(
        type: NSEvent.EventType,
        key: String,
        modifiers: NSEvent.ModifierFlags,
        keyCode: UInt16,
        windowNumber: Int
    ) throws -> NSEvent {
        guard let event = NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber,
            context: nil,
            characters: key,
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

    private func closeWindow(_ window: NSWindow, appDelegate: AppDelegate) {
#if DEBUG
        let originalConfirmationHandler = appDelegate.debugCloseMainWindowConfirmationHandler
        appDelegate.debugCloseMainWindowConfirmationHandler = { _ in true }
        defer { appDelegate.debugCloseMainWindowConfirmationHandler = originalConfirmationHandler }
#endif
        window.contentView?.subviews
            .compactMap { $0 as? OmnibarNativeTextField }
            .forEach { field in
                if let panelId = field.panelId {
                    BrowserOmnibarNativeFieldRegistry.shared.unregister(field, panelId: panelId)
                }
                field.removeFromSuperview()
            }
        window.animationBehavior = .none
        window.orderOut(nil)
        window.close()
        RunLoop.main.run(until: Date.now.addingTimeInterval(0.05))
    }

    private enum TestHarnessError: Error {
        case browserHarnessUnavailable
        case omnibarFocusUnavailable
        case eventUnavailable
    }
    }
}
