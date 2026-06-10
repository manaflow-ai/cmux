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


// MARK: - Arrow forwarding and window focus routing
extension CmuxWebViewKeyEquivalentTests {
    @MainActor
    func testWindowArrowForwardingRoutesFocusedOmnibarFieldEditorThroughKeyDown() {
        _ = NSApplication.shared
        AppDelegate.installWindowResponderSwizzlesForTesting()

        let panelId = UUID()
        let window = FieldEditorProbeWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = container

        let field = OmnibarNativeTextField(frame: NSRect(x: 12, y: 380, width: 360, height: 24))
        field.panelId = panelId
        field.stringValue = "abcdef"
        container.addSubview(field)

        window.makeKeyAndOrderFront(nil)
        defer {
            NotificationCenter.default.post(name: .browserDidBlurAddressBar, object: panelId)
            AppDelegate.clearWindowFirstResponderGuardTesting()
            field.removeFromSuperview()
            window.contentView = nil
            window.orderOut(nil)
        }

        XCTAssertTrue(window.makeFirstResponder(field))
        guard field.currentEditor() === window.testFieldEditor else {
            XCTFail("Expected the omnibar to use the probe field editor")
            return
        }

        NotificationCenter.default.post(name: .browserDidFocusAddressBar, object: panelId)
        window.testFieldEditor.resetKeyDownKeyCodes()

        guard let leftArrowEvent = makeKeyDownEvent(
            key: String(UnicodeScalar(NSLeftArrowFunctionKey)!),
            modifiers: [],
            keyCode: 123,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Left Arrow event")
            return
        }

        XCTAssertTrue(window.performKeyEquivalent(with: leftArrowEvent))
        XCTAssertEqual(
            window.testFieldEditor.keyDownKeyCodes,
            [123],
            "A live omnibar field editor must receive plain arrows through keyDown so NSTextView can move the caret"
        )
    }

    @MainActor
    func testWindowArrowForwardingRoutesFocusedMarkedTextOmnibarFieldEditorThroughKeyDown() {
        _ = NSApplication.shared
        AppDelegate.installWindowResponderSwizzlesForTesting()

        let panelId = UUID()
        let window = FieldEditorProbeWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = container

        let field = OmnibarNativeTextField(frame: NSRect(x: 12, y: 380, width: 360, height: 24))
        field.panelId = panelId
        field.stringValue = "ㄉㄚˋ"
        container.addSubview(field)

        window.makeKeyAndOrderFront(nil)
        defer {
            NotificationCenter.default.post(name: .browserDidBlurAddressBar, object: panelId)
            AppDelegate.clearWindowFirstResponderGuardTesting()
            field.removeFromSuperview()
            window.contentView = nil
            window.orderOut(nil)
        }

        XCTAssertTrue(window.makeFirstResponder(field))
        guard field.currentEditor() === window.testFieldEditor else {
            XCTFail("Expected the omnibar to use the probe field editor")
            return
        }

        NotificationCenter.default.post(name: .browserDidFocusAddressBar, object: panelId)
        window.testFieldEditor.resetKeyDownKeyCodes()
        window.testFieldEditor.reportsMarkedText = true

        guard let downArrowEvent = makeKeyDownEvent(
            key: String(UnicodeScalar(NSDownArrowFunctionKey)!),
            modifiers: [],
            keyCode: 125,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Down Arrow event")
            return
        }

        XCTAssertTrue(
            window.performKeyEquivalent(with: downArrowEvent),
            "Marked-text omnibar arrows must be delivered directly to the field editor instead of falling through to original key-equivalent handling"
        )
        XCTAssertEqual(window.testFieldEditor.keyDownKeyCodes, [125])
    }

    @MainActor
    func testWindowArrowForwardingRestoresFocusedOmnibarBeforeBrowserFirstResponder() {
        _ = NSApplication.shared
        AppDelegate.installWindowResponderSwizzlesForTesting()

        let panelId = UUID()
        let window = FieldEditorProbeWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = container

        let field = OmnibarNativeTextField(frame: NSRect(x: 12, y: 380, width: 360, height: 24))
        field.panelId = panelId
        field.stringValue = "abcdef"
        container.addSubview(field)

        let webView = CmuxWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 360), configuration: WKWebViewConfiguration())
        webView.allowsFirstResponderAcquisition = true
        container.addSubview(webView)

        window.makeKeyAndOrderFront(nil)
        defer {
            NotificationCenter.default.post(name: .browserDidBlurAddressBar, object: panelId)
            AppDelegate.clearWindowFirstResponderGuardTesting()
            field.removeFromSuperview()
            webView.removeFromSuperview()
            window.contentView = nil
            window.orderOut(nil)
        }

        XCTAssertTrue(window.makeFirstResponder(field))
        guard field.currentEditor() === window.testFieldEditor else {
            XCTFail("Expected the omnibar to use the probe field editor")
            return
        }

        NotificationCenter.default.post(name: .browserDidFocusAddressBar, object: panelId)
        window.testFieldEditor.resetKeyDownKeyCodes()

        XCTAssertTrue(window.makeFirstResponder(webView))
        XCTAssertTrue(window.firstResponder === webView)

        guard let leftArrowEvent = makeKeyDownEvent(
            key: String(UnicodeScalar(NSLeftArrowFunctionKey)!),
            modifiers: [],
            keyCode: 123,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Left Arrow event")
            return
        }

        XCTAssertTrue(window.performKeyEquivalent(with: leftArrowEvent))
        XCTAssertEqual(
            window.testFieldEditor.keyDownKeyCodes,
            [123],
            "When the omnibar is still logically focused, transient WebView first-responder state must not steal plain arrows from the omnibar field editor"
        )
    }

    @MainActor
    func testWindowArrowForwardingConsumesMarkedTextOmnibarRestore() {
        _ = NSApplication.shared
        AppDelegate.installWindowResponderSwizzlesForTesting()

        let panelId = UUID()
        let window = FieldEditorProbeWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = container

        let field = OmnibarNativeTextField(frame: NSRect(x: 12, y: 380, width: 360, height: 24))
        field.panelId = panelId
        field.stringValue = "abcdef"
        container.addSubview(field)

        let webView = CmuxWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 360), configuration: WKWebViewConfiguration())
        webView.allowsFirstResponderAcquisition = true
        container.addSubview(webView)

        window.makeKeyAndOrderFront(nil)
        defer {
            NotificationCenter.default.post(name: .browserDidBlurAddressBar, object: panelId)
            AppDelegate.clearWindowFirstResponderGuardTesting()
            field.removeFromSuperview()
            webView.removeFromSuperview()
            window.contentView = nil
            window.orderOut(nil)
        }

        XCTAssertTrue(window.makeFirstResponder(field))
        guard field.currentEditor() === window.testFieldEditor else {
            XCTFail("Expected the omnibar to use the probe field editor")
            return
        }

        NotificationCenter.default.post(name: .browserDidFocusAddressBar, object: panelId)
        window.testFieldEditor.resetKeyDownKeyCodes()
        window.testFieldEditor.reportsMarkedText = true

        XCTAssertTrue(window.makeFirstResponder(webView))
        XCTAssertTrue(window.firstResponder === webView)

        guard let leftArrowEvent = makeKeyDownEvent(
            key: String(UnicodeScalar(NSLeftArrowFunctionKey)!),
            modifiers: [],
            keyCode: 123,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Left Arrow event")
            return
        }

        XCTAssertTrue(
            window.performKeyEquivalent(with: leftArrowEvent),
            "After restoring the omnibar, the arrow must be delivered once instead of returning unhandled after mutating first responder"
        )
        XCTAssertEqual(window.testFieldEditor.keyDownKeyCodes, [123])
    }

    @MainActor
    func testWindowFirstResponderBypassBlocksSwizzledMakeFirstResponder() {
        _ = NSApplication.shared
        AppDelegate.installWindowResponderSwizzlesForTesting()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = container

        let responder = FirstResponderView(frame: NSRect(x: 0, y: 0, width: 80, height: 40))
        container.addSubview(responder)

        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        _ = window.makeFirstResponder(nil)
        cmuxWithWindowFirstResponderBypass {
            XCTAssertFalse(
                window.makeFirstResponder(responder),
                "Bypass scope should block transient first-responder changes during devtools auto-restore"
            )
        }
        XCTAssertTrue(window.makeFirstResponder(responder))
    }

    @MainActor
    func testCmdBacktickMenuActionThatChangesKeyWindowOnlyRunsOnceWhenTerminalIsFirstResponder() {
        _ = NSApplication.shared
        AppDelegate.installWindowResponderSwizzlesForTesting()

        let firstWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let secondWindow = NSWindow(
            contentRect: NSRect(x: 40, y: 40, width: 640, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        let firstContainer = NSView(frame: firstWindow.contentRect(forFrameRect: firstWindow.frame))
        let secondContainer = NSView(frame: secondWindow.contentRect(forFrameRect: secondWindow.frame))
        firstWindow.contentView = firstContainer
        secondWindow.contentView = secondContainer

        let firstTerminal = GhosttyNSView(frame: firstContainer.bounds)
        firstTerminal.autoresizingMask = [.width, .height]
        firstContainer.addSubview(firstTerminal)

        let secondTerminal = GhosttyNSView(frame: secondContainer.bounds)
        secondTerminal.autoresizingMask = [.width, .height]
        secondContainer.addSubview(secondTerminal)

        let spy = WindowCyclingActionSpy()
        spy.firstWindow = firstWindow
        spy.secondWindow = secondWindow
        installMenu(
            target: spy,
            action: #selector(WindowCyclingActionSpy.cycleWindow(_:)),
            key: "`",
            modifiers: [.command]
        )

        secondWindow.orderFront(nil)
        firstWindow.makeKeyAndOrderFront(nil)
        defer {
            secondWindow.orderOut(nil)
            firstWindow.orderOut(nil)
        }

        XCTAssertTrue(firstWindow.makeFirstResponder(firstTerminal))
        guard let event = makeKeyDownEvent(
            key: "`",
            modifiers: [.command],
            keyCode: 50,
            windowNumber: firstWindow.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+` event")
            return
        }

        NSApp.sendEvent(event)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertEqual(spy.invocationCount, 1, "Cmd+` should only trigger one window-cycle action")
    }

    @MainActor
    func testCmdBacktickDoesNotRouteDirectlyToMainMenuWhenWebViewIsFirstResponder() {
        _ = NSApplication.shared

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

        let spy = ActionSpy()
        installMenu(
            target: spy,
            action: #selector(ActionSpy.didInvoke(_:)),
            key: "`",
            modifiers: [.command]
        )

        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
        }

        XCTAssertTrue(window.makeFirstResponder(webView))
        guard let event = makeKeyDownEvent(
            key: "`",
            modifiers: [.command],
            keyCode: 50,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+` event")
            return
        }

        XCTAssertFalse(shouldRouteCommandEquivalentDirectlyToMainMenu(event))
        _ = webView.performKeyEquivalent(with: event)
        XCTAssertFalse(
            spy.invoked,
            "CmuxWebView should not route Cmd+` directly to the menu when WebKit is first responder"
        )
    }

    @MainActor
    func testCmdFDoesNotPreflightIntoPageWhenWebInspectorResponderIsFocused() {
        _ = NSApplication.shared
        installCmuxUnitTestWKWebViewPerformKeyEquivalentOverride()

        let spy = ActionSpy()
        installMenu(spy: spy, key: "f", modifiers: [.command])

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

        let inspectorView = FakeWKInspectorResponderView(frame: NSRect(x: 0, y: 0, width: 32, height: 20))
        webView.addSubview(inspectorView)

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

        XCTAssertTrue(window.makeFirstResponder(inspectorView))
        guard let event = makeKeyDownEvent(
            key: "f",
            modifiers: [.command],
            keyCode: 3,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+F event")
            return
        }

        let consumed = webView.performKeyEquivalent(with: event)

        XCTAssertTrue(consumed, "Expected the menu/inspector path to keep consuming Cmd+F")
        XCTAssertTrue(spy.invoked, "Expected Cmd+F to stay on the menu/inspector path while Web Inspector is focused")
        XCTAssertEqual(
            forwardedEvents.count,
            0,
            "Did not expect CmuxWebView to preflight Cmd+F into page content while Web Inspector is focused"
        )
    }

}
