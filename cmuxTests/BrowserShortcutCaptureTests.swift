import AppKit
import Carbon.HIToolbox
import Testing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
private typealias BrowserCaptureStoredShortcut = cmux_DEV.StoredShortcut
#elseif canImport(cmux)
@testable import cmux
private typealias BrowserCaptureStoredShortcut = cmux.StoredShortcut
#endif

private final class BrowserCaptureMenuActionProbe: NSObject {
    var callCount = 0

    @objc func perform(_ sender: Any?) {
        _ = sender
        callCount += 1
    }
}

private final class BrowserCaptureUndoSpy {
    var undoCount = 0
}

private final class WKInspectorCaptureView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

private final class BrowserCaptureFocusableView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

private final class BrowserCaptureWindowTeardownState {
    var contextRemoved = false

    deinit {}
}

private struct BrowserCaptureHarness {
    let windowId: UUID
    let window: NSWindow
    let panel: BrowserPanel
    let webView: CmuxWebView
}

private enum BrowserCaptureFixtureError: Error {
    case appDelegateUnavailable
    case browserUnavailable
    case firstResponderUnavailable
}

@Suite(.serialized)
@MainActor
final class BrowserShortcutCaptureTests {
    @Test
    func configuredShortcutIsDeliveredToFocusedBrowserPage() throws {
        try withCaptureEnabled { harness in
            installCmuxUnitTestCmuxWebViewKeyDownOverride()
            var browserKeyDownCount = 0
            let targetWebView = harness.webView
            setCmuxUnitTestCmuxWebViewKeyDownHook({ [weak targetWebView] webView, _ in
                guard let targetWebView, webView === targetWebView else { return false }
                browserKeyDownCount += 1
                return false
            }, for: targetWebView)
            defer { setCmuxUnitTestCmuxWebViewKeyDownHook(nil, for: targetWebView) }

            let commandR = try #require(makeKeyDownEvent(
                key: "r",
                modifiers: [.command],
                keyCode: 15,
                windowNumber: harness.window.windowNumber
            ))

            NSApp.sendEvent(commandR)

            #expect(browserKeyDownCount == 1)
        }
    }

    @Test
    func remappedDefaultReachesFocusedBrowserWithoutStaleMenuDispatch() throws {
        try withCaptureEnabled { harness in
            installCmuxUnitTestCmuxWebViewKeyDownOverride()
            var browserKeyDownCount = 0
            let targetWebView = harness.webView
            setCmuxUnitTestCmuxWebViewKeyDownHook({ [weak targetWebView] webView, _ in
                guard let targetWebView, webView === targetWebView else { return false }
                browserKeyDownCount += 1
                return false
            }, for: targetWebView)
            defer { setCmuxUnitTestCmuxWebViewKeyDownHook(nil, for: targetWebView) }

            let previousMainMenu = NSApp.mainMenu
            let menuProbe = BrowserCaptureMenuActionProbe()
            defer { NSApp.mainMenu = previousMainMenu }
            let staleMenu = NSMenu(title: "Test")
            let staleItem = NSMenuItem(
                title: "Go to Workspace",
                action: #selector(BrowserCaptureMenuActionProbe.perform(_:)),
                keyEquivalent: "p"
            )
            staleItem.keyEquivalentModifierMask = [.command]
            staleItem.target = menuProbe
            staleMenu.addItem(staleItem)
            NSApp.mainMenu = staleMenu

            let commandP = try #require(makeKeyDownEvent(
                key: "p",
                modifiers: [.command],
                keyCode: 35,
                windowNumber: harness.window.windowNumber
            ))
            let remappedShortcut = BrowserCaptureStoredShortcut(
                key: "p",
                command: true,
                shift: true,
                option: false,
                control: false
            )

            withTemporaryShortcut(action: .goToWorkspace, shortcut: remappedShortcut) {
                NSApp.sendEvent(commandP)
            }

            #expect(menuProbe.callCount == 0)
            #expect(browserKeyDownCount == 1)
        }
    }

    @Test
    func captureLeavesUnrelatedNativeMenuShortcutToAppKit() throws {
        let appDelegate = try #require(AppDelegate.shared)
        try withCaptureEnabled { harness in
            let previousMainMenu = NSApp.mainMenu
            let menuProbe = BrowserCaptureMenuActionProbe()
            defer { NSApp.mainMenu = previousMainMenu }

            let nativeMenu = NSMenu(title: "Native")
            let nativeItem = NSMenuItem(
                title: "Native Hide Probe",
                action: #selector(BrowserCaptureMenuActionProbe.perform(_:)),
                keyEquivalent: "h"
            )
            nativeItem.keyEquivalentModifierMask = [.command]
            nativeItem.target = menuProbe
            nativeMenu.addItem(nativeItem)
            NSApp.mainMenu = nativeMenu

            let commandH = try #require(makeKeyDownEvent(
                key: "h",
                modifiers: [.command],
                keyCode: 4,
                windowNumber: harness.window.windowNumber
            ))

            #expect(!appDelegate.shouldCaptureBrowserKeyboardShortcuts(for: commandH))
            NSApp.sendEvent(commandH)

            #expect(
                menuProbe.callCount == 1,
                "Capture must yield unrelated native menu equivalents back to AppKit"
            )
        }
    }

    @Test
    func captureLeavesProtectedApplicationShortcutToAppKit() throws {
        let appDelegate = try #require(AppDelegate.shared)
        try withCaptureEnabled { harness in
            let commandQ = try #require(makeKeyDownEvent(
                key: "q",
                modifiers: [.command],
                keyCode: 12,
                windowNumber: harness.window.windowNumber
            ))

            #expect(KeyboardShortcutSettings.Action.quit.isProtectedFromBrowserCapture)
            #expect(
                !appDelegate.shouldCaptureBrowserKeyboardShortcuts(for: commandQ),
                "Browser capture must never swallow the app Quit shortcut"
            )
        }
    }

    @Test
    func capturePreservesBrowserFocusModeEscapeExit() throws {
        try withCaptureEnabled { harness in
            #expect(
                harness.panel.setBrowserFocusModeActive(
                    true,
                    reason: "unit.captureEscape",
                    focusWebView: false
                )
            )

            let baseTimestamp = ProcessInfo.processInfo.systemUptime
            let firstEscape = try #require(makeKeyDownEvent(
                key: "\u{1b}",
                modifiers: [],
                keyCode: 53,
                windowNumber: harness.window.windowNumber,
                timestamp: baseTimestamp + 0.01
            ))
            let secondEscape = try #require(makeKeyDownEvent(
                key: "\u{1b}",
                modifiers: [],
                keyCode: 53,
                windowNumber: harness.window.windowNumber,
                timestamp: baseTimestamp + 0.02
            ))

            #expect(harness.webView.performKeyEquivalent(with: firstEscape))
            #expect(harness.panel.isBrowserFocusModeActive)
            #expect(harness.panel.isBrowserFocusModeExitArmed)
            #expect(harness.webView.performKeyEquivalent(with: secondEscape))
            #expect(!harness.panel.isBrowserFocusModeActive)
            #expect(!harness.panel.isBrowserFocusModeExitArmed)
        }
    }

    @Test
    func capturePreservesWebContentUndoWhenPageDeclines() throws {
        try withCaptureEnabled { harness in
            let spy = BrowserCaptureUndoSpy()
            let undoManager = try #require(harness.webView.undoManager)
            undoManager.registerUndo(withTarget: spy) { $0.undoCount += 1 }

            let commandZ = try #require(makeKeyDownEvent(
                key: "z",
                modifiers: [.command],
                keyCode: UInt16(kVK_ANSI_Z),
                windowNumber: harness.window.windowNumber
            ))

            // Exercise the keyDown fallback directly. The regular WebKit
            // decline/replay path is covered by CmuxWebViewWebContentUndoTests;
            // this assertion keeps capture's precedence from bypassing it.
            harness.webView.keyDown(with: commandZ)
            #expect(spy.undoCount == 1)
        }
    }

    @Test
    func captureExcludesWebInspectorResponders() throws {
        let appDelegate = try #require(AppDelegate.shared)
        try withCaptureEnabled { harness in
            let inspectorContainer = WKInspectorCaptureView(
                frame: NSRect(x: 0, y: 0, width: 160, height: 80)
            )
            let inspectorChild = BrowserCaptureFocusableView(frame: inspectorContainer.bounds)
            inspectorContainer.addSubview(inspectorChild)
            harness.webView.addSubview(inspectorContainer)
            defer { inspectorContainer.removeFromSuperview() }
            #expect(harness.window.makeFirstResponder(inspectorChild))

            let commandP = try #require(makeKeyDownEvent(
                key: "p",
                modifiers: [.command],
                keyCode: 35,
                windowNumber: harness.window.windowNumber
            ))

            #expect(!appDelegate.shouldCaptureBrowserKeyboardShortcuts(for: commandP))
            #expect(!appDelegate.forwardStaleShortcutToFocusedBrowser(commandP))
        }
    }

    @Test
    func captureFailsClosedForPortalBrowserChrome() throws {
        let appDelegate = try #require(AppDelegate.shared)
        try withCaptureEnabled { harness in
            guard let slot = ancestorSlot(for: harness.webView) else {
                throw BrowserCaptureFixtureError.browserUnavailable
            }

            let chromeView = BrowserCaptureFocusableView(
                frame: NSRect(x: 0, y: 0, width: 120, height: 40)
            )
            slot.addSubview(chromeView, positioned: .above, relativeTo: nil)
            defer { chromeView.removeFromSuperview() }
            #expect(harness.window.makeFirstResponder(chromeView))

            let commandR = try #require(makeKeyDownEvent(
                key: "r",
                modifiers: [.command],
                keyCode: 15,
                windowNumber: harness.window.windowNumber
            ))

            #expect(
                !appDelegate.shouldCaptureBrowserKeyboardShortcuts(for: commandR),
                "A focusable portal sibling must remain browser chrome, not page focus"
            )

            let nestedChromeView = BrowserCaptureFocusableView(
                frame: NSRect(x: 0, y: 0, width: 120, height: 40)
            )
            harness.webView.addSubview(nestedChromeView, positioned: .above, relativeTo: nil)
            defer { nestedChromeView.removeFromSuperview() }
            #expect(harness.window.makeFirstResponder(nestedChromeView))
            let nestedCommandR = try #require(makeKeyDownEvent(
                key: "r",
                modifiers: [.command],
                keyCode: 15,
                windowNumber: harness.window.windowNumber
            ))
            #expect(
                !appDelegate.shouldCaptureBrowserKeyboardShortcuts(for: nestedCommandR),
                "An unknown WebKit sibling must remain chrome, not page focus"
            )
        }
    }

    @Test
    func captureRecognizesFocusedPageContentDescendant() throws {
        let appDelegate = try #require(AppDelegate.shared)
        try withCaptureEnabled { harness in
            guard let pageRoot = harness.webView.cmuxBrowserPageContentRoot() else {
                throw BrowserCaptureFixtureError.browserUnavailable
            }

            let pageChild = BrowserCaptureFocusableView(
                frame: pageRoot.bounds.insetBy(dx: 4, dy: 4)
            )
            pageRoot.addSubview(pageChild)
            defer { pageChild.removeFromSuperview() }
            let overlappingUnknownSibling = BrowserCaptureFocusableView(
                frame: harness.webView.bounds
            )
            harness.webView.addSubview(overlappingUnknownSibling, positioned: .above, relativeTo: nil)
            defer { overlappingUnknownSibling.removeFromSuperview() }
            #expect(harness.window.makeFirstResponder(pageChild))

            let commandR = try #require(makeKeyDownEvent(
                key: "r",
                modifiers: [.command],
                keyCode: 15,
                windowNumber: harness.window.windowNumber
            ))

            #expect(
                appDelegate.shortcutEventBrowserWebView(commandR) === harness.webView,
                "A responder below the real page-content root must resolve to its browser web view"
            )
            #expect(appDelegate.shouldCaptureBrowserKeyboardShortcuts(for: commandR))

            #expect(harness.window.makeFirstResponder(overlappingUnknownSibling))
            let unknownSiblingCommandR = try #require(makeKeyDownEvent(
                key: "r",
                modifiers: [.command],
                keyCode: 15,
                windowNumber: harness.window.windowNumber
            ))
            #expect(
                appDelegate.shortcutEventBrowserWebView(unknownSiblingCommandR) == nil,
                "A full-size unknown WebKit sibling must remain browser chrome"
            )
            #expect(
                !appDelegate.shouldCaptureBrowserKeyboardShortcuts(for: unknownSiblingCommandR),
                "Capture must fail closed when an unknown sibling owns focus"
            )
        }
    }

    @Test
    func configuredShortcutIsDeliveredToFocusedPopupPageBeforeCloseHandling() throws {
        let opener = BrowserPanel(workspaceId: UUID(), isRemoteWorkspace: false)
        defer { opener.close() }

        let popupWebView = try #require(
            opener.createFloatingPopup(
                configuration: WKWebViewConfiguration(),
                windowFeatures: WKWindowFeatures()
            ) as? CmuxWebView
        )
        let popupWindow = try #require(popupWebView.window as? BrowserPopupPanel)
        defer {
            popupWindow.orderOut(nil)
            popupWindow.close()
        }

        popupWindow.makeKeyAndOrderFront(nil)
        #expect(popupWindow.makeFirstResponder(popupWebView))
        #expect(popupWebView.isOwnedByBrowserPopupPanel)

        let settingKey = KeyboardShortcutSettings.browserKeyboardShortcutCaptureSetting.userDefaultsKey
        let previousSetting = UserDefaults.standard.object(forKey: settingKey)
        defer {
            if let previousSetting {
                UserDefaults.standard.set(previousSetting, forKey: settingKey)
            } else {
                UserDefaults.standard.removeObject(forKey: settingKey)
            }
        }
        UserDefaults.standard.set(true, forKey: settingKey)

        installCmuxUnitTestCmuxWebViewKeyDownOverride()
        var browserKeyDownCount = 0
        setCmuxUnitTestCmuxWebViewKeyDownHook({ [weak popupWebView] webView, _ in
            guard let popupWebView, webView === popupWebView else { return false }
            browserKeyDownCount += 1
            return false
        }, for: popupWebView)
        defer { setCmuxUnitTestCmuxWebViewKeyDownHook(nil, for: popupWebView) }

        let commandR = try #require(makeKeyDownEvent(
            key: "r",
            modifiers: [.command],
            keyCode: 15,
            windowNumber: popupWindow.windowNumber
        ))

        #expect(popupWindow.performKeyEquivalent(with: commandR))
        #expect(browserKeyDownCount == 1)
        #expect(popupWindow.isVisible, "Page capture must run before popup Close Tab handling")
    }

    @Test
    func printableShiftAndOptionBindingsRemainCaptureCandidates() throws {
        let appDelegate = try #require(AppDelegate.shared)
        try withCaptureEnabled { harness in
            installCmuxUnitTestCmuxWebViewKeyDownOverride()
            var browserKeyDownCount = 0
            let targetWebView = harness.webView
            setCmuxUnitTestCmuxWebViewKeyDownHook({ [weak targetWebView] webView, _ in
                guard let targetWebView, webView === targetWebView else { return false }
                browserKeyDownCount += 1
                return false
            }, for: targetWebView)
            defer { setCmuxUnitTestCmuxWebViewKeyDownHook(nil, for: targetWebView) }

            let cases: [(
                shortcut: BrowserCaptureStoredShortcut,
                characters: String,
                charactersIgnoringModifiers: String,
                keyCode: UInt16
            )] = [
                (
                    BrowserCaptureStoredShortcut(
                        key: "s",
                        command: false,
                        shift: true,
                        option: false,
                        control: false
                    ),
                    "S",
                    "s",
                    1
                ),
                (
                    BrowserCaptureStoredShortcut(
                        key: "p",
                        command: false,
                        shift: false,
                        option: true,
                        control: false
                    ),
                    "π",
                    "p",
                    35
                ),
                (
                    BrowserCaptureStoredShortcut(
                        key: "space",
                        command: false,
                        shift: false,
                        option: false,
                        control: false
                    ),
                    " ",
                    " ",
                    49
                ),
            ]

            for (shortcut, characters, charactersIgnoringModifiers, keyCode) in cases {
                let event = try #require(makeKeyDownEvent(
                    key: characters,
                    charactersIgnoringModifiers: charactersIgnoringModifiers,
                    modifiers: shortcut.modifierFlags,
                    keyCode: keyCode,
                    windowNumber: harness.window.windowNumber
                ))
                withTemporaryShortcut(action: .toggleBrowserDeveloperTools, shortcut: shortcut) {
                    #expect(
                        appDelegate.shouldCaptureBrowserKeyboardShortcuts(for: event),
                        "Printable \(shortcut.displayString) must remain a browser-capture candidate"
                    )
                    NSApp.sendEvent(event)
                }
            }

            #expect(browserKeyDownCount == cases.count)
        }
    }

    @Test
    func numberedShortcutFamilyCapturesEveryDigit() throws {
        let appDelegate = try #require(AppDelegate.shared)
        try withCaptureEnabled { harness in
            installCmuxUnitTestCmuxWebViewKeyDownOverride()
            var browserKeyDownCount = 0
            let targetWebView = harness.webView
            setCmuxUnitTestCmuxWebViewKeyDownHook({ [weak targetWebView] webView, _ in
                guard let targetWebView, webView === targetWebView else { return false }
                browserKeyDownCount += 1
                return false
            }, for: targetWebView)
            defer { setCmuxUnitTestCmuxWebViewKeyDownHook(nil, for: targetWebView) }

            let numberedShortcut = BrowserCaptureStoredShortcut(
                key: "1",
                command: false,
                shift: false,
                option: false,
                control: true
            )
            let ctrl1 = try #require(makeKeyDownEvent(
                key: "1",
                modifiers: [.control],
                keyCode: 18,
                windowNumber: harness.window.windowNumber
            ))
            let ctrl3 = try #require(makeKeyDownEvent(
                key: "3",
                modifiers: [.control],
                keyCode: 20,
                windowNumber: harness.window.windowNumber
            ))

            withTemporaryShortcut(action: .selectSurfaceByNumber, shortcut: numberedShortcut) {
                #expect(appDelegate.shouldCaptureBrowserKeyboardShortcuts(for: ctrl1))
                #expect(appDelegate.shouldCaptureBrowserKeyboardShortcuts(for: ctrl3))
                NSApp.sendEvent(ctrl1)
                NSApp.sendEvent(ctrl3)
            }

            #expect(browserKeyDownCount == 2)
        }
    }

    @Test
    func numberedShortcutDoesNotCaptureWhileAnotherChordIsArmed() throws {
        let appDelegate = try #require(AppDelegate.shared)
        try withCaptureEnabled { harness in
            let numberedShortcut = BrowserCaptureStoredShortcut(
                key: "1",
                command: false,
                shift: false,
                option: false,
                control: true
            )
            let ctrl3 = try #require(makeKeyDownEvent(
                key: "3",
                modifiers: [.control],
                keyCode: 20,
                windowNumber: harness.window.windowNumber
            ))
            let previousPrefix = appDelegate.activeConfiguredShortcutChordPrefixForCurrentEvent
            defer {
                appDelegate.activeConfiguredShortcutChordPrefixForCurrentEvent = previousPrefix
                appDelegate.shortcutEventFocusContextCache = nil
            }

            withTemporaryShortcut(action: .selectSurfaceByNumber, shortcut: numberedShortcut) {
                appDelegate.activeConfiguredShortcutChordPrefixForCurrentEvent = BrowserCaptureStoredShortcut(
                    key: "b",
                    command: false,
                    shift: false,
                    option: false,
                    control: true
                ).firstStroke
                #expect(
                    !appDelegate.shouldCaptureBrowserKeyboardShortcuts(for: ctrl3),
                    "A numbered family must not consume a suffix while another chord is armed"
                )
            }
        }
    }

    @Test
    func standalonePopupBrowserScopedShortcutsYieldToWebKitWhenCaptureDisabled() throws {
        let appDelegate = try #require(AppDelegate.shared)
        let opener = BrowserPanel(workspaceId: UUID(), isRemoteWorkspace: false)
        defer { opener.close() }

        let popupWebView = try #require(
            opener.createFloatingPopup(
                configuration: WKWebViewConfiguration(),
                windowFeatures: WKWindowFeatures()
            ) as? CmuxWebView
        )
        let popupWindow = try #require(popupWebView.window as? BrowserPopupPanel)
        defer {
            popupWindow.orderOut(nil)
            popupWindow.close()
        }

        popupWindow.makeKeyAndOrderFront(nil)
        #expect(popupWindow.makeFirstResponder(popupWebView))

        let settingKey = KeyboardShortcutSettings.browserKeyboardShortcutCaptureSetting.userDefaultsKey
        let previousSetting = UserDefaults.standard.object(forKey: settingKey)
        defer {
            if let previousSetting {
                UserDefaults.standard.set(previousSetting, forKey: settingKey)
            } else {
                UserDefaults.standard.removeObject(forKey: settingKey)
            }
        }
        UserDefaults.standard.set(false, forKey: settingKey)

        installCmuxUnitTestWKWebViewPerformKeyEquivalentOverride()
        let previousHook = cmuxUnitTestWKWebViewPerformKeyEquivalentHook
        var webKitEvents: [NSEvent] = []
        cmuxUnitTestWKWebViewPerformKeyEquivalentHook = { webView, event in
            guard webView === popupWebView else { return nil }
            webKitEvents.append(event)
            return true
        }
        defer { cmuxUnitTestWKWebViewPerformKeyEquivalentHook = previousHook }

        let events = [
            try #require(makeKeyDownEvent(
                key: "i",
                modifiers: [.command, .option],
                keyCode: 34,
                windowNumber: popupWindow.windowNumber
            )),
            try #require(makeKeyDownEvent(
                key: "c",
                modifiers: [.command, .option],
                keyCode: 8,
                windowNumber: popupWindow.windowNumber
            )),
        ]

        for event in events {
            #expect(
                !appDelegate.handleBrowserSurfaceKeyEquivalent(event),
                "A standalone popup cannot execute BrowserPanel-scoped actions"
            )
            #expect(popupWebView.performKeyEquivalent(with: event))
        }

        #expect(webKitEvents.count == events.count)
    }

    private func withCaptureEnabled(
        _ body: (BrowserCaptureHarness) throws -> Void
    ) throws {
        let harness = try makeHarness()
        defer { closeWindow(withId: harness.windowId) }

        let settingKey = KeyboardShortcutSettings.browserKeyboardShortcutCaptureSetting.userDefaultsKey
        let previousSetting = UserDefaults.standard.object(forKey: settingKey)
        defer {
            if let previousSetting {
                UserDefaults.standard.set(previousSetting, forKey: settingKey)
            } else {
                UserDefaults.standard.removeObject(forKey: settingKey)
            }
        }
        UserDefaults.standard.set(true, forKey: settingKey)
        try body(harness)
    }

    private func makeHarness() throws -> BrowserCaptureHarness {
        guard let appDelegate = AppDelegate.shared else {
            throw BrowserCaptureFixtureError.appDelegateUnavailable
        }

        AppDelegate.installWindowResponderSwizzlesForTesting()
        let windowId = appDelegate.createMainWindow()
        guard let window = waitForWindow(withId: windowId),
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace,
              let browserURL = URL(string: "data:text/html;base64,PGh0bWw+PGJvZHk+Zm9jdXM8L2JvZHk+PC9odG1sPg=="),
              let browserPanelId = manager.openBrowser(
                  inWorkspace: workspace.id,
                  url: browserURL,
                  preferSplitRight: true
              ),
              let browserPanel = manager.selectedWorkspace?.browserPanel(for: browserPanelId)
                  ?? workspace.browserPanel(for: browserPanelId),
              let webView = browserPanel.webView as? CmuxWebView else {
            closeWindow(withId: windowId)
            throw BrowserCaptureFixtureError.browserUnavailable
        }

        workspace.focusPanel(browserPanel.id)
        if webView.cmuxBrowserViewportAttachmentSuperview == nil,
           let contentView = window.contentView {
            let presentationView = webView.cmuxBrowserViewportPresentationView
            contentView.addSubview(presentationView)
            webView.cmuxApplyBrowserViewportLayout(in: contentView.bounds)
        }
        window.makeKeyAndOrderFront(nil)
        guard window.makeFirstResponder(webView) else {
            closeWindow(withId: windowId)
            throw BrowserCaptureFixtureError.firstResponderUnavailable
        }
        return BrowserCaptureHarness(
            windowId: windowId,
            window: window,
            panel: browserPanel,
            webView: webView
        )
    }

    private func waitForWindow(withId windowId: UUID) -> NSWindow? {
        let deadline = Date().addingTimeInterval(3.0)
        repeat {
            // `createMainWindow()` installs the SwiftUI-hosted window on a
            // later run-loop turn. Prefer the AppDelegate context once it is
            // available, then fall back to the identifier used by the shared
            // test helpers.
            if let window = AppDelegate.shared?.mainWindow(for: windowId) {
                return window
            }
            if let window = window(withId: windowId) {
                return window
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        } while Date() < deadline
        return nil
    }

    private func ancestorSlot(for webView: NSView) -> WindowBrowserSlotView? {
        var current: NSView? = webView
        while let view = current {
            if let slot = view as? WindowBrowserSlotView {
                return slot
            }
            current = view.superview
        }
        return nil
    }

    private func window(withId windowId: UUID) -> NSWindow? {
        let identifier = "cmux.main.\(windowId.uuidString)"
        return NSApp.windows.first { $0.identifier?.rawValue == identifier }
    }

    private func closeWindow(withId windowId: UUID) {
        guard let window = window(withId: windowId),
              let appDelegate = AppDelegate.shared else {
            return
        }
        let originalConfirmationHandler = appDelegate.debugCloseMainWindowConfirmationHandler
        appDelegate.debugCloseMainWindowConfirmationHandler = { _ in true }
        defer { appDelegate.debugCloseMainWindowConfirmationHandler = originalConfirmationHandler }
        window.animationBehavior = .none
        window.orderOut(nil)

        let teardownState = BrowserCaptureWindowTeardownState()
        let removalObserver = NotificationCenter.default.addObserver(
            forName: .mainWindowContextsDidChange,
            object: appDelegate,
            queue: .main
        ) { _ in
            teardownState.contextRemoved = !appDelegate.mainWindowContexts.values.contains {
                $0.windowId == windowId
            }
        }
        defer { NotificationCenter.default.removeObserver(removalObserver) }

        window.close()

        // `window.close()` can return before the AppDelegate unregisters its
        // context. Keep the teardown event-driven and bounded: the lifecycle
        // notification is the completion signal, while the deadline prevents
        // a broken test fixture from hanging the test host indefinitely.
        let deadline = Date.now.addingTimeInterval(3)
        while !teardownState.contextRemoved,
              appDelegate.mainWindowContexts.values.contains(where: { $0.windowId == windowId }),
              Date.now < deadline {
            _ = RunLoop.main.run(mode: .default, before: Date.now.addingTimeInterval(0.1))
        }
    }

    private func withTemporaryShortcut(
        action: KeyboardShortcutSettings.Action,
        shortcut: BrowserCaptureStoredShortcut,
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
            AppDelegate.shared?.debugResetShortcutRoutingStateForTesting(clearFocusedWindowOverride: false)
#endif
        }
        KeyboardShortcutSettings.setShortcut(shortcut, for: action)
#if DEBUG
        AppDelegate.shared?.debugResetShortcutRoutingStateForTesting(clearFocusedWindowOverride: false)
#endif
        body()
    }

    private func makeKeyDownEvent(
        key: String,
        charactersIgnoringModifiers: String? = nil,
        modifiers: NSEvent.ModifierFlags,
        keyCode: UInt16,
        windowNumber: Int,
        timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: timestamp,
            windowNumber: windowNumber,
            context: nil,
            characters: key,
            charactersIgnoringModifiers: charactersIgnoringModifiers ?? key,
            isARepeat: false,
            keyCode: keyCode
        )
    }
}
