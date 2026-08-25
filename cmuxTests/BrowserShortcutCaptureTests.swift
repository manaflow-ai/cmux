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
            setCmuxUnitTestCmuxWebViewKeyDownHook { webView, _ in
                if webView === harness.webView {
                    browserKeyDownCount += 1
                }
                return false
            }
            defer { setCmuxUnitTestCmuxWebViewKeyDownHook(nil) }

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
            setCmuxUnitTestCmuxWebViewKeyDownHook { webView, _ in
                if webView === harness.webView {
                    browserKeyDownCount += 1
                }
                return false
            }
            defer { setCmuxUnitTestCmuxWebViewKeyDownHook(nil) }

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
            installCmuxUnitTestWKWebViewPerformKeyEquivalentOverride()
            cmuxUnitTestWKWebViewPerformKeyEquivalentHook = { currentWebView, _ in
                guard currentWebView === harness.webView else { return nil }
                return false
            }
            defer { cmuxUnitTestWKWebViewPerformKeyEquivalentHook = nil }

            let spy = BrowserCaptureUndoSpy()
            let undoManager = try #require(harness.webView.undoManager)
            undoManager.registerUndo(withTarget: spy) { $0.undoCount += 1 }

            let commandZ = try #require(makeKeyDownEvent(
                key: "z",
                modifiers: [.command],
                keyCode: UInt16(kVK_ANSI_Z),
                windowNumber: harness.window.windowNumber
            ))

            #expect(harness.window.performKeyEquivalent(with: commandZ))
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
        guard let window = window(withId: windowId),
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
        window.close()
        RunLoop.main.run(until: Date.now.addingTimeInterval(0.05))
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
            charactersIgnoringModifiers: key,
            isARepeat: false,
            keyCode: keyCode
        )
    }
}
