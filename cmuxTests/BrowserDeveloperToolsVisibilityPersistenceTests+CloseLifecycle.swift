import XCTest
import Combine
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
import Bonsplit
import UserNotifications
import Network

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Inspector close lifecycle
extension BrowserDeveloperToolsVisibilityPersistenceTests {
    func testPaneCloseClosesVisibleInspectorSynchronouslyBeforeWebViewTeardown() {
        let (panel, inspector) = makePanelWithInspector()
        defer { closeBrowserPanel(panel) }

        XCTAssertTrue(panel.showDeveloperTools())
        XCTAssertTrue(panel.isDeveloperToolsVisible())
        XCTAssertEqual(inspector.closeCount, 0)

        panel.close()

        XCTAssertEqual(inspector.closeCount, 1)
        spinRunLoopOneTick()

        XCTAssertFalse(panel.isDeveloperToolsVisible())
    }

    func testWindowCloseClosesContainedBrowserInspectorBeforeWindowWillClose() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        guard let window = window(withId: windowId),
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace,
              let browserPanelId = manager.openBrowser(inWorkspace: workspace.id, preferSplitRight: true),
              let browserPanel = workspace.browserPanel(for: browserPanelId) else {
            XCTFail("Expected main window with browser panel")
            return
        }
        appDelegate.suppressClosedWindowHistoryForTesting(windowId: windowId)
        defer { tearDownMainWindow(window, manager: manager) }

        let inspector = FakeInspector()
        browserPanel.webView.cmuxSetUnitTestInspector(inspector)
        if browserPanel.webView.superview == nil {
            browserPanel.webView.frame = window.contentView?.bounds ?? .zero
            window.contentView?.addSubview(browserPanel.webView)
        }

        XCTAssertTrue(browserPanel.showDeveloperTools())
        XCTAssertTrue(browserPanel.isDeveloperToolsVisible())

        var closeCountObservedAtWillClose: Int?
        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: nil
        ) { _ in
            closeCountObservedAtWillClose = inspector.closeCount
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        window.performClose(nil)
        spinRunLoopOneTick()

        XCTAssertEqual(closeCountObservedAtWillClose, 1)
        XCTAssertEqual(inspector.closeCount, 1)
        XCTAssertFalse(browserPanel.isDeveloperToolsVisible())
    }

    func testDetachedInspectorWindowUserCloseSynchronouslyClosesOwningInspector() {
        let (panel, inspector) = makePanelWithInspector()
        defer { closeBrowserPanel(panel) }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Web Inspector — example.com"
        let frontendWebView = WKWebView(frame: window.contentView?.bounds ?? .zero)
        window.contentView?.addSubview(frontendWebView)
        window.contentView?.addSubview(WKInspectorProbeView(frame: window.contentView?.bounds ?? .zero))
        inspector.setFrontendWebView(frontendWebView)
        defer { closeWindow(window) }

        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(panel.showDeveloperTools())
        XCTAssertTrue(panel.isDeveloperToolsVisible())
        XCTAssertEqual(inspector.closeCount, 0)

        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)

        XCTAssertEqual(
            inspector.closeCount,
            1,
            "User-closing a detached Web Inspector window must synchronously close the owning _inspector before AppKit/WebKit teardown continues"
        )
        XCTAssertFalse(panel.isDeveloperToolsVisible())
    }

    func testDetachedInspectorWillCloseDuringDockBackClosesInspectorBeforeWebKitAttachContinues() {
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

        XCTAssertTrue(panel.showDeveloperTools())
        XCTAssertTrue(panel.isDeveloperToolsVisible())
        XCTAssertEqual(inspector.closeCount, 0)

        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: inspectorWindow)

        XCTAssertEqual(
            inspector.closeCount,
            1,
            "Detached inspector willClose must close the owning inspector instead of letting WebKit continue an unstable in-window attach"
        )
        XCTAssertFalse(panel.isDeveloperToolsVisible())
    }

    func testDetachedInspectorCloseButtonActionClosesBeforeWindowWillCloseNotification() {
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

        XCTAssertTrue(handled)
        XCTAssertEqual(
            inspector.closeCount,
            1,
            "The close-button action must close the owning inspector before WebKit's NSWindowWillClose observer can run"
        )
        XCTAssertEqual(
            willCloseNotificationCount,
            0,
            "The intercepted close-button action should not fall through to AppKit's window close path"
        )
        XCTAssertFalse(browserPanel.isDeveloperToolsVisible())
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
        XCTAssertEqual(inspector.closeCount, 0)
        XCTAssertTrue(inspectorWindow.isKeyWindow)

        let handled = NSApp.sendAction(NSSelectorFromString("__close"), to: nil, from: nil)

        XCTAssertTrue(handled)
        XCTAssertEqual(
            inspector.closeCount,
            1,
            "Menu and keyboard close actions without an explicit target must still route through inspector teardown"
        )
        XCTAssertFalse(browserPanel.isDeveloperToolsVisible())
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
        XCTAssertEqual(inspector.closeCount, 0)
        XCTAssertTrue(inspectorWindow.isKeyWindow)

        let menuItem = NSMenuItem(
            title: "Close",
            action: NSSelectorFromString("close:"),
            keyEquivalent: "w"
        )
        let handled = NSApp.sendAction(NSSelectorFromString("close:"), to: nil, from: menuItem)

        XCTAssertTrue(handled)
        XCTAssertEqual(
            inspector.closeCount,
            1,
            "Nil-target menu Close actions must resolve the key detached inspector window before AppKit posts willClose"
        )
        XCTAssertFalse(browserPanel.isDeveloperToolsVisible())
    }

    func testNilTargetMainWindowCloseActionDoesNotCloseAttachedInspector() {
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
              let browserPanel = workspace.browserPanel(for: browserPanelId),
              let contentView = mainWindow.contentView else {
            XCTFail("Expected main window with browser panel")
            return
        }
        appDelegate.suppressClosedWindowHistoryForTesting(windowId: windowId)
        defer { tearDownMainWindow(mainWindow, manager: manager) }

        let inspector = FakeInspector()
        browserPanel.webView.cmuxSetUnitTestInspector(inspector)
        if browserPanel.webView.superview == nil {
            browserPanel.webView.frame = contentView.bounds
            contentView.addSubview(browserPanel.webView)
        }

        let frontendWebView = WKInspectorProbeWebView(
            frame: NSRect(
                x: contentView.bounds.midX,
                y: 0,
                width: contentView.bounds.midX,
                height: contentView.bounds.height
            ),
            configuration: WKWebViewConfiguration()
        )
        contentView.addSubview(frontendWebView)
        inspector.setFrontendWebView(frontendWebView)

        mainWindow.makeKeyAndOrderFront(nil)
        mainWindow.makeKey()
        XCTAssertTrue(browserPanel.showDeveloperTools())
        XCTAssertTrue(browserPanel.isDeveloperToolsVisible())
        XCTAssertEqual(inspector.closeCount, 0)

        _ = NSApp.sendAction(NSSelectorFromString("__close"), to: nil, from: nil)

        XCTAssertEqual(
            inspector.closeCount,
            0,
            "Nil-target main-window Close actions must not be mistaken for detached inspector window closes"
        )
        XCTAssertTrue(browserPanel.isDeveloperToolsVisible())
    }

    func testNilTargetControllerCloseActionDoesNotCloseDetachedInspector() {
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
        XCTAssertEqual(inspector.closeCount, 0)

        _ = NSApp.sendAction(NSSelectorFromString("close:"), to: nil, from: nil)

        XCTAssertEqual(
            inspector.closeCount,
            0,
            "Nil-target controller close: actions must not be treated as detached inspector window closes"
        )
        XCTAssertTrue(browserPanel.isDeveloperToolsVisible())
    }

}
