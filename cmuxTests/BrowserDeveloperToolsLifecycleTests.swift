import XCTest
import AppKit
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
extension BrowserDeveloperToolsVisibilityPersistenceTests {
    func testDetachedInspectorWillCloseDuringDockBackAdoptsAttachedInspector() {
        let (panel, inspector) = makePanelWithInspector()
        defer { closeBrowserPanel(panel) }
        let mainWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let inspectorWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        inspectorWindow.isReleasedWhenClosed = false
        defer {
            closeWindow(inspectorWindow)
            closeWindow(mainWindow)
        }
        guard let mainContentView = mainWindow.contentView,
              let inspectorContentView = inspectorWindow.contentView else {
            XCTFail("Expected test windows to have content views")
            return
        }
        let attachedHost = NSView(frame: mainContentView.bounds)
        mainContentView.addSubview(attachedHost)
        panel.webView.frame = NSRect(x: 0, y: 0, width: 260, height: attachedHost.bounds.height)
        attachedHost.addSubview(panel.webView)
        let attachedInspectorView = WKInspectorProbeView(
            frame: NSRect(x: 260, y: 0, width: 260, height: attachedHost.bounds.height)
        )
        attachedHost.addSubview(attachedInspectorView)
        inspectorWindow.title = "Web Inspector — example.com"
        let frontendWebView = WKInspectorProbeWebView(
            frame: inspectorContentView.bounds,
            configuration: WKWebViewConfiguration()
        )
        inspectorContentView.addSubview(frontendWebView)
        inspector.setFrontendWebView(frontendWebView)
        mainWindow.makeKeyAndOrderFront(nil)
        inspectorWindow.makeKeyAndOrderFront(nil)
        mainWindow.displayIfNeeded()
        inspectorWindow.displayIfNeeded()
        XCTAssertFalse(
            panel.ownsDetachedDeveloperToolsWindow(mainWindow),
            "A cmux/browser host window with an attached inspector frontend must not be treated as a detached inspector close target"
        )
        XCTAssertTrue(panel.showDeveloperTools())
        XCTAssertTrue(panel.isDeveloperToolsVisible())
        XCTAssertEqual(inspector.closeCount, 0)
        inspectorWindow.close()
        frontendWebView.removeFromSuperview()
        frontendWebView.frame = attachedInspectorView.bounds
        attachedInspectorView.addSubview(frontendWebView)
        XCTAssertEqual(
            inspector.closeCount,
            0,
            "Detached inspector willClose during redock must wait for WebKit's final layout before deciding whether to close _inspector"
        )
        XCTAssertTrue(panel.isDeveloperToolsVisible())
        waitForDeveloperToolsTransitions(panel: panel) {
            panel.isDeveloperToolsVisible() &&
                panel.preferredDeveloperToolsVisible &&
                inspector.closeCount == 0
        }
        XCTAssertEqual(
            inspector.closeCount,
            0,
            "Docking Web Inspector back into the page should adopt WebKit's attached layout instead of closing _inspector"
        )
        XCTAssertTrue(panel.isDeveloperToolsVisible())
        XCTAssertTrue(panel.preferredDeveloperToolsVisible)
        XCTAssertTrue(
            frontendWebView.evaluatedJavaScript.joined(separator: "\n").contains("const detachedFromHostWindow = false;"),
            "Adopting a WebKit-initiated redock must re-run dock-control normalization in attached mode"
        )
    }
    func testDetachedInspectorCloseButtonActionClosesWindowWithoutReenteringInspectorClose() {
        AppDelegate.installWindowResponderSwizzlesForTesting()
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }
        let windowId = appDelegate.createMainWindow()
        guard let mainWindow = window(withId: windowId),
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace,
              let browserPanelId = manager.openBrowser(inWorkspace: workspace.id, preferSplitRight: true),
              let browserPanel = workspace.browserPanel(for: browserPanelId) else {
            XCTFail("Expected main window with browser panel")
            return
        }
        appDelegate.suppressClosedWindowHistoryForTesting(windowId: windowId)
        defer { tearDownMainWindow(mainWindow, manager: manager) }
        let inspector = FakeInspector()
        browserPanel.webView.cmuxSetUnitTestInspector(inspector)
        if browserPanel.webView.superview == nil {
            browserPanel.webView.frame = mainWindow.contentView?.bounds ?? .zero
            mainWindow.contentView?.addSubview(browserPanel.webView)
        }
        let inspectorWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        inspectorWindow.title = "Web Inspector — example.com"
        let frontendWebView = WKInspectorProbeWebView(
            frame: inspectorWindow.contentView?.bounds ?? .zero,
            configuration: WKWebViewConfiguration()
        )
        inspectorWindow.contentView?.addSubview(frontendWebView)
        inspector.setFrontendWebView(frontendWebView)
        defer { closeWindow(inspectorWindow) }
        inspectorWindow.makeKeyAndOrderFront(nil)
        inspectorWindow.makeKey()
        XCTAssertTrue(browserPanel.showDeveloperTools())
        XCTAssertTrue(browserPanel.isDeveloperToolsVisible())
        XCTAssertEqual(inspector.closeCount, 0)
        var willCloseNotificationCount = 0
        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: inspectorWindow,
            queue: nil
        ) { _ in
            willCloseNotificationCount += 1
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let handled = NSApp.sendAction(
            NSSelectorFromString("__close"),
            to: inspectorWindow,
            from: inspectorWindow.standardWindowButton(.closeButton)
        )
        spinRunLoopOneTick()
        XCTAssertTrue(handled)
        XCTAssertEqual(
            inspector.closeCount,
            0,
            "The close-button action must close the inspector window without calling _inspector.close on the inspected page"
        )
        XCTAssertEqual(
            willCloseNotificationCount,
            1,
            "The intercepted close-button action should close the WebKit-owned inspector window exactly once"
        )
        XCTAssertFalse(inspectorWindow.isVisible)
        waitForDeveloperToolsTransitions(panel: browserPanel) {
            !inspectorWindow.isVisible &&
                browserPanel.debugDeveloperToolsStateSummary().contains("pref=0")
        }
        XCTAssertFalse(inspectorWindow.isVisible)
        XCTAssertTrue(browserPanel.debugDeveloperToolsStateSummary().contains("pref=0"))
    }
    func testDetachedInspectorNilTargetCloseActionUsesKeyWindow() {
        AppDelegate.installWindowResponderSwizzlesForTesting()
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }
        let windowId = appDelegate.createMainWindow()
        guard let mainWindow = window(withId: windowId),
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace,
              let browserPanelId = manager.openBrowser(inWorkspace: workspace.id, preferSplitRight: true),
              let browserPanel = workspace.browserPanel(for: browserPanelId) else {
            XCTFail("Expected main window with browser panel")
            return
        }
        appDelegate.suppressClosedWindowHistoryForTesting(windowId: windowId)
        defer { tearDownMainWindow(mainWindow, manager: manager) }
        let inspector = FakeInspector()
        browserPanel.webView.cmuxSetUnitTestInspector(inspector)
        if let contentView = mainWindow.contentView {
            attachPanelPresentationIfNeeded(browserPanel, to: contentView)
        }
        let inspectorWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        inspectorWindow.title = "Web Inspector — example.com"
        let frontendWebView = WKInspectorProbeWebView(
            frame: inspectorWindow.contentView?.bounds ?? .zero,
            configuration: WKWebViewConfiguration()
        )
        inspectorWindow.contentView?.addSubview(frontendWebView)
        inspector.setFrontendWebView(frontendWebView)
        defer { closeWindow(inspectorWindow) }
        inspectorWindow.makeKeyAndOrderFront(nil)
        inspectorWindow.makeKey()
        XCTAssertTrue(browserPanel.showDeveloperTools())
        XCTAssertEqual(inspector.closeCount, 0)
        XCTAssertTrue(inspectorWindow.isKeyWindow)
        let handled = NSApp.sendAction(NSSelectorFromString("__close"), to: nil, from: nil)
        spinRunLoopOneTick()
        XCTAssertTrue(handled)
        XCTAssertEqual(
            inspector.closeCount,
            0,
            "Menu and keyboard close actions without an explicit target must close the inspector window without reentering _inspector.close"
        )
        XCTAssertFalse(inspectorWindow.isVisible)
        XCTAssertTrue(browserPanel.debugDeveloperToolsStateSummary().contains("pref=0"))
    }
    func testDetachedInspectorNilTargetMenuItemCloseActionUsesKeyWindow() {
        AppDelegate.installWindowResponderSwizzlesForTesting()
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }
        let windowId = appDelegate.createMainWindow()
        guard let mainWindow = window(withId: windowId),
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace,
              let browserPanelId = manager.openBrowser(inWorkspace: workspace.id, preferSplitRight: true),
              let browserPanel = workspace.browserPanel(for: browserPanelId) else {
            XCTFail("Expected main window with browser panel")
            return
        }
        appDelegate.suppressClosedWindowHistoryForTesting(windowId: windowId)
        defer { tearDownMainWindow(mainWindow, manager: manager) }
        let inspector = FakeInspector()
        browserPanel.webView.cmuxSetUnitTestInspector(inspector)
        if let contentView = mainWindow.contentView {
            attachPanelPresentationIfNeeded(browserPanel, to: contentView)
        }
        let inspectorWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        inspectorWindow.title = "Inspector Localized — example.com"
        let frontendWebView = WKInspectorProbeWebView(
            frame: inspectorWindow.contentView?.bounds ?? .zero,
            configuration: WKWebViewConfiguration()
        )
        inspectorWindow.contentView?.addSubview(frontendWebView)
        inspector.setFrontendWebView(frontendWebView)
        defer { closeWindow(inspectorWindow) }
        inspectorWindow.makeKeyAndOrderFront(nil)
        inspectorWindow.makeKey()
        XCTAssertTrue(browserPanel.showDeveloperTools())
        XCTAssertEqual(inspector.closeCount, 0)
        XCTAssertTrue(inspectorWindow.isKeyWindow)
        let menuItem = NSMenuItem(
            title: "Close",
            action: NSSelectorFromString("close:"),
            keyEquivalent: "w"
        )
        let handled = NSApp.sendAction(NSSelectorFromString("close:"), to: nil, from: menuItem)
        spinRunLoopOneTick()
        XCTAssertTrue(handled)
        XCTAssertEqual(
            inspector.closeCount,
            0,
            "Nil-target menu Close actions must resolve and close the key detached inspector window without reentering _inspector.close"
        )
        XCTAssertFalse(inspectorWindow.isVisible)
        XCTAssertTrue(browserPanel.debugDeveloperToolsStateSummary().contains("pref=0"))
    }
    func testDetachedInspectorCommandWClosesInspectorWithoutClosingBrowserPanel() throws {
        AppDelegate.installWindowResponderSwizzlesForTesting()
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }
        let windowId = appDelegate.createMainWindow()
        guard let mainWindow = window(withId: windowId),
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace,
              let browserPanelId = manager.openBrowser(inWorkspace: workspace.id, preferSplitRight: true),
              let browserPanel = workspace.browserPanel(for: browserPanelId) else {
            XCTFail("Expected main window with browser panel")
            return
        }
        appDelegate.suppressClosedWindowHistoryForTesting(windowId: windowId)
        defer { tearDownMainWindow(mainWindow, manager: manager) }
        let inspector = FakeInspector()
        browserPanel.webView.cmuxSetUnitTestInspector(inspector)
        if let contentView = mainWindow.contentView {
            attachPanelPresentationIfNeeded(browserPanel, to: contentView)
        }
        let inspectorWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        inspectorWindow.title = "Web Inspector — example.com"
        let frontendWebView = WKInspectorProbeWebView(
            frame: inspectorWindow.contentView?.bounds ?? .zero,
            configuration: WKWebViewConfiguration()
        )
        inspectorWindow.contentView?.addSubview(frontendWebView)
        inspector.setFrontendWebView(frontendWebView)
        defer { closeWindow(inspectorWindow) }
        inspectorWindow.makeKeyAndOrderFront(nil)
        inspectorWindow.makeKey()
        XCTAssertTrue(browserPanel.showDeveloperTools())
        XCTAssertEqual(inspector.closeCount, 0)
        XCTAssertTrue(inspectorWindow.isKeyWindow)
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: inspectorWindow.windowNumber,
            context: nil,
            characters: "w",
            charactersIgnoringModifiers: "w",
            isARepeat: false,
            keyCode: 13
        ))
        withTemporaryShortcut(action: .closeTab, shortcut: commandWCloseTabShortcut) {
            NSApp.sendEvent(event)
            spinRunLoopOneTick()
        }
        waitForDeveloperToolsTransitions(panel: browserPanel) {
            !inspectorWindow.isVisible &&
                browserPanel.debugDeveloperToolsStateSummary().contains("pref=0")
        }
        XCTAssertEqual(
            inspector.closeCount,
            0,
            "Cmd-W in a detached Web Inspector must not call _inspector.close on the inspected page"
        )
        XCTAssertFalse(inspectorWindow.isVisible)
        XCTAssertNotNil(
            workspace.browserPanel(for: browserPanelId),
            "Cmd-W in a detached Web Inspector must not fall through to cmux close-tab routing"
        )
        XCTAssertTrue(browserPanel.debugDeveloperToolsStateSummary().contains("pref=0"))
    }
    func testDetachedInspectorCommandWIgnoresStaleMainEventWindow() throws {
        AppDelegate.installWindowResponderSwizzlesForTesting()
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }
        let windowId = appDelegate.createMainWindow()
        guard let mainWindow = window(withId: windowId),
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace,
              let browserPanelId = manager.openBrowser(inWorkspace: workspace.id, preferSplitRight: true),
              let browserPanel = workspace.browserPanel(for: browserPanelId) else {
            XCTFail("Expected main window with browser panel")
            return
        }
        appDelegate.suppressClosedWindowHistoryForTesting(windowId: windowId)
        defer { tearDownMainWindow(mainWindow, manager: manager) }
        let inspector = FakeInspector()
        browserPanel.webView.cmuxSetUnitTestInspector(inspector)
        if let contentView = mainWindow.contentView {
            attachPanelPresentationIfNeeded(browserPanel, to: contentView)
        }
        let inspectorWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        inspectorWindow.title = "Inspector Localized — example.com"
        let frontendWebView = WKInspectorProbeWebView(
            frame: inspectorWindow.contentView?.bounds ?? .zero,
            configuration: WKWebViewConfiguration()
        )
        inspectorWindow.contentView?.addSubview(frontendWebView)
        inspector.setFrontendWebView(frontendWebView)
        defer { closeWindow(inspectorWindow) }
        inspectorWindow.makeKeyAndOrderFront(nil)
        inspectorWindow.makeKey()
        XCTAssertTrue(browserPanel.showDeveloperTools())
        XCTAssertEqual(inspector.closeCount, 0)
        XCTAssertTrue(inspectorWindow.isKeyWindow)
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: mainWindow.windowNumber,
            context: nil,
            characters: "w",
            charactersIgnoringModifiers: "w",
            isARepeat: false,
            keyCode: 13
        ))
        withTemporaryShortcut(action: .closeTab, shortcut: commandWCloseTabShortcut) {
            NSApp.sendEvent(event)
            spinRunLoopOneTick()
        }
        waitForDeveloperToolsTransitions(panel: browserPanel) {
            !inspectorWindow.isVisible &&
                browserPanel.debugDeveloperToolsStateSummary().contains("pref=0")
        }
        XCTAssertEqual(
            inspector.closeCount,
            0,
            "Cmd-W with stale main-window event metadata must not call _inspector.close on the inspected page"
        )
        XCTAssertFalse(inspectorWindow.isVisible)
        XCTAssertNotNil(
            workspace.browserPanel(for: browserPanelId),
            "Cmd-W with stale main-window event metadata must not fall through to cmux close-tab routing"
        )
        XCTAssertTrue(browserPanel.debugDeveloperToolsStateSummary().contains("pref=0"))
    }
    func testDirectAttachedOpenAdoptsAttachedPresentation() {
        let (panel, _) = makePanelWithInspector()
        defer { closeBrowserPanel(panel) }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { closeWindow(window) }
        guard let contentView = window.contentView else {
            XCTFail("Expected window content view")
            return
        }
        let attachedHost = NSView(frame: contentView.bounds)
        contentView.addSubview(attachedHost)
        panel.webView.frame = NSRect(x: 0, y: 0, width: 260, height: attachedHost.bounds.height)
        attachedHost.addSubview(panel.webView)
        let attachedInspectorView = WKInspectorProbeView(
            frame: NSRect(x: 260, y: 0, width: 260, height: attachedHost.bounds.height)
        )
        attachedHost.addSubview(attachedInspectorView)
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        XCTAssertTrue(panel.debugDeveloperToolsStateSummary().contains("presentation=detached"))
        // WebKit can open DevTools directly in its saved attached/bottom dock
        // configuration: no detached inspector window ever exists, so the
        // detached-window close resolver never runs. The UI sync must adopt
        // the attached classification or attached manual-close detection
        // stays disabled and preserved visible intent can resurrect an
        // inspector the user explicitly closed.
        XCTAssertTrue(panel.showDeveloperTools())
        XCTAssertTrue(
            panel.debugDeveloperToolsStateSummary().contains("presentation=attached"),
            "Direct attached open must adopt the attached presentation classification"
        )
    }
}
