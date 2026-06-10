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


// MARK: - Cmd-key main menu routing and copy preflight
extension CmuxWebViewKeyEquivalentTests {
    func testCmdNRoutesToMainMenuWhenWebViewIsFirstResponder() {
        let spy = ActionSpy()
        installMenu(spy: spy, key: "n", modifiers: [.command])

        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let event = makeKeyDownEvent(key: "n", modifiers: [.command], keyCode: 45) // kVK_ANSI_N
        XCTAssertNotNil(event)

        XCTAssertTrue(webView.performKeyEquivalent(with: event!))
        XCTAssertTrue(spy.invoked)
    }

    func testCmdWRoutesToMainMenuWhenWebViewIsFirstResponder() {
        let spy = ActionSpy()
        installMenu(spy: spy, key: "w", modifiers: [.command])

        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let event = makeKeyDownEvent(key: "w", modifiers: [.command], keyCode: 13) // kVK_ANSI_W
        XCTAssertNotNil(event)

        XCTAssertTrue(webView.performKeyEquivalent(with: event!))
        XCTAssertTrue(spy.invoked)
    }

    func testCmdRRoutesToMainMenuWhenWebViewIsFirstResponder() {
        let spy = ActionSpy()
        installMenu(spy: spy, key: "r", modifiers: [.command])

        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let event = makeKeyDownEvent(key: "r", modifiers: [.command], keyCode: 15) // kVK_ANSI_R
        XCTAssertNotNil(event)

        XCTAssertTrue(webView.performKeyEquivalent(with: event!))
        XCTAssertTrue(spy.invoked)
    }

    func testCmdCCopyPreflightsIntoWebContentBeforeMainMenu() {
        installCmuxUnitTestWKWebViewPerformKeyEquivalentOverride()

        let spy = ActionSpy()
        installMenu(spy: spy, key: "c", modifiers: [.command])

        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())
        var forwardedEvents: [NSEvent] = []
        cmuxUnitTestWKWebViewPerformKeyEquivalentHook = { currentWebView, event in
            guard currentWebView === webView else { return nil }
            forwardedEvents.append(event)
            return true
        }
        defer { cmuxUnitTestWKWebViewPerformKeyEquivalentHook = nil }

        let event = makeKeyDownEvent(key: "c", modifiers: [.command], keyCode: 8) // kVK_ANSI_C
        XCTAssertNotNil(event)

        XCTAssertTrue(webView.performKeyEquivalent(with: event!))
        XCTAssertEqual(forwardedEvents.count, 1)
        XCTAssertEqual(forwardedEvents.first?.keyCode, 8)
        XCTAssertFalse(spy.invoked)
    }

    func testCmdCCopyFallsBackToMainMenuWhenWebContentDoesNotHandleIt() {
        installCmuxUnitTestWKWebViewPerformKeyEquivalentOverride()

        let spy = ActionSpy()
        installMenu(spy: spy, key: "c", modifiers: [.command])

        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())
        var forwardedEvents: [NSEvent] = []
        cmuxUnitTestWKWebViewPerformKeyEquivalentHook = { currentWebView, event in
            guard currentWebView === webView else { return nil }
            forwardedEvents.append(event)
            return false
        }
        defer { cmuxUnitTestWKWebViewPerformKeyEquivalentHook = nil }

        let event = makeKeyDownEvent(key: "c", modifiers: [.command], keyCode: 8) // kVK_ANSI_C
        XCTAssertNotNil(event)

        XCTAssertTrue(webView.performKeyEquivalent(with: event!))
        XCTAssertEqual(forwardedEvents.count, 1)
        XCTAssertEqual(forwardedEvents.first?.keyCode, 8)
        XCTAssertTrue(spy.invoked)
    }

    @MainActor
    func testWindowCmdCCopyPreflightsFocusedBrowserChildIntoWebContentBeforeMainMenu() {
        _ = NSApplication.shared
        AppDelegate.installWindowResponderSwizzlesForTesting()
        installCmuxUnitTestWKWebViewPerformKeyEquivalentOverride()

        let spy = ActionSpy()
        installMenu(spy: spy, key: "c", modifiers: [.command])

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = container

        let webView = CmuxWebView(frame: container.bounds, configuration: WKWebViewConfiguration())
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)

        let responder = FirstResponderView(frame: NSRect(x: 0, y: 0, width: 32, height: 20))
        webView.addSubview(responder)

        var forwardedEvents: [NSEvent] = []
        cmuxUnitTestWKWebViewPerformKeyEquivalentHook = { currentWebView, event in
            guard currentWebView === webView else { return nil }
            forwardedEvents.append(event)
            return true
        }

        window.makeKeyAndOrderFront(nil)
        defer {
            cmuxUnitTestWKWebViewPerformKeyEquivalentHook = nil
            window.orderOut(nil)
        }

        XCTAssertTrue(window.makeFirstResponder(responder))
        guard let event = makeKeyDownEvent(
            key: "c",
            modifiers: [.command],
            keyCode: 8,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+C event")
            return
        }

        XCTAssertTrue(window.performKeyEquivalent(with: event))
        XCTAssertEqual(forwardedEvents.count, 1)
        XCTAssertEqual(forwardedEvents.first?.keyCode, 8)
        XCTAssertFalse(spy.invoked)
    }

    @MainActor
    func testWindowCmdCCopyFallsBackToMainMenuWhenFocusedBrowserChildDoesNotHandleIt() {
        _ = NSApplication.shared
        AppDelegate.installWindowResponderSwizzlesForTesting()
        installCmuxUnitTestWKWebViewPerformKeyEquivalentOverride()

        let spy = ActionSpy()
        installMenu(spy: spy, key: "c", modifiers: [.command])

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = container

        let webView = CmuxWebView(frame: container.bounds, configuration: WKWebViewConfiguration())
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)

        let responder = FirstResponderView(frame: NSRect(x: 0, y: 0, width: 32, height: 20))
        webView.addSubview(responder)

        var forwardedEvents: [NSEvent] = []
        cmuxUnitTestWKWebViewPerformKeyEquivalentHook = { currentWebView, event in
            guard currentWebView === webView else { return nil }
            forwardedEvents.append(event)
            return false
        }

        window.makeKeyAndOrderFront(nil)
        defer {
            cmuxUnitTestWKWebViewPerformKeyEquivalentHook = nil
            window.orderOut(nil)
        }

        XCTAssertTrue(window.makeFirstResponder(responder))
        guard let event = makeKeyDownEvent(
            key: "c",
            modifiers: [.command],
            keyCode: 8,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+C event")
            return
        }

        XCTAssertTrue(window.performKeyEquivalent(with: event))
        XCTAssertEqual(forwardedEvents.count, 1)
        XCTAssertEqual(forwardedEvents.first?.keyCode, 8)
        XCTAssertTrue(spy.invoked)
    }

    @MainActor
    func testWindowCmdCCopySuppressesSecondWebContentReplayWhenFocusedBrowserChildAndMenuDecline() {
        _ = NSApplication.shared
        AppDelegate.installWindowResponderSwizzlesForTesting()
        installCmuxUnitTestWKWebViewPerformKeyEquivalentOverride()

        NSApp.mainMenu = NSMenu(title: "Main")

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = container

        let webView = CmuxWebView(frame: container.bounds, configuration: WKWebViewConfiguration())
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)

        let responder = FirstResponderView(frame: NSRect(x: 0, y: 0, width: 32, height: 20))
        webView.addSubview(responder)

        var forwardedEvents: [NSEvent] = []
        cmuxUnitTestWKWebViewPerformKeyEquivalentHook = { currentWebView, event in
            guard currentWebView === webView else { return nil }
            forwardedEvents.append(event)
            return false
        }

        window.makeKeyAndOrderFront(nil)
        defer {
            cmuxUnitTestWKWebViewPerformKeyEquivalentHook = nil
            window.orderOut(nil)
        }

        XCTAssertTrue(window.makeFirstResponder(responder))
        guard let event = makeKeyDownEvent(
            key: "c",
            modifiers: [.command],
            keyCode: 8,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+C event")
            return
        }

        XCTAssertTrue(window.performKeyEquivalent(with: event))
        XCTAssertEqual(forwardedEvents.count, 1)
        XCTAssertEqual(forwardedEvents.first?.keyCode, 8)
    }

    func testReturnDoesNotRouteToMainMenuWhenWebViewIsFirstResponder() {
        let spy = ActionSpy()
        installMenu(spy: spy, key: "\r", modifiers: [])

        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let event = makeKeyDownEvent(key: "\r", modifiers: [], keyCode: 36) // kVK_Return
        XCTAssertNotNil(event)

        XCTAssertFalse(webView.performKeyEquivalent(with: event!))
        XCTAssertFalse(spy.invoked)
    }

    func testCmdReturnDoesNotRouteToMainMenuWhenWebViewIsFirstResponder() {
        let spy = ActionSpy()
        installMenu(spy: spy, key: "\r", modifiers: [.command])

        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let event = makeKeyDownEvent(key: "\r", modifiers: [.command], keyCode: 36) // kVK_Return
        XCTAssertNotNil(event)

        XCTAssertFalse(webView.performKeyEquivalent(with: event!))
        XCTAssertFalse(spy.invoked)
    }

    func testKeypadEnterDoesNotRouteToMainMenuWhenWebViewIsFirstResponder() {
        let spy = ActionSpy()
        installMenu(spy: spy, key: "\r", modifiers: [])

        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let event = makeKeyDownEvent(key: "\r", modifiers: [], keyCode: 76) // kVK_ANSI_KeypadEnter
        XCTAssertNotNil(event)

        XCTAssertFalse(webView.performKeyEquivalent(with: event!))
        XCTAssertFalse(spy.invoked)
    }

}
