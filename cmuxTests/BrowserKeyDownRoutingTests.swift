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


// MARK: - IME and Return keyDown routing
private final class BrowserMarkedTextProbeTextView: NSTextView {
    var hasMarkedTextForTesting = false
    private(set) var keyDownEvents: [NSEvent] = []

    override var acceptsFirstResponder: Bool { true }

    override func hasMarkedText() -> Bool {
        hasMarkedTextForTesting
    }

    override func keyDown(with event: NSEvent) {
        keyDownEvents.append(event)
    }
}

final class BrowserIMEKeyDownRoutingTests: XCTestCase {
    @MainActor
    func testWindowPerformKeyEquivalentDoesNotForwardReturnDuringMarkedTextComposition() {
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

        let webView = CmuxWebView(frame: container.bounds, configuration: WKWebViewConfiguration())
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)

        let responder = BrowserMarkedTextProbeTextView(frame: NSRect(x: 0, y: 0, width: 32, height: 20))
        responder.hasMarkedTextForTesting = true
        webView.addSubview(responder)

        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        XCTAssertTrue(window.makeFirstResponder(responder))
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36
        ) else {
            XCTFail("Failed to construct Return event")
            return
        }

        let consumed = window.performKeyEquivalent(with: event)

        XCTAssertFalse(consumed, "Return should stay in the IME path while marked text is active")
        XCTAssertTrue(responder.hasMarkedText(), "Marked text should still be active until the input method commits it")
        XCTAssertEqual(responder.keyDownEvents.count, 0, "Return should not be force-forwarded to the browser responder during IME composition")
    }

    @MainActor
    func testWindowPerformKeyEquivalentDoesNotForwardKeypadEnterDuringMarkedTextComposition() {
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

        let webView = CmuxWebView(frame: container.bounds, configuration: WKWebViewConfiguration())
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)

        let responder = BrowserMarkedTextProbeTextView(frame: NSRect(x: 0, y: 0, width: 32, height: 20))
        responder.hasMarkedTextForTesting = true
        webView.addSubview(responder)

        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        XCTAssertTrue(window.makeFirstResponder(responder))
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 76
        ) else {
            XCTFail("Failed to construct keypad Enter event")
            return
        }

        let consumed = window.performKeyEquivalent(with: event)

        XCTAssertFalse(consumed, "Keypad Enter should stay in the IME path while marked text is active")
        XCTAssertTrue(responder.hasMarkedText(), "Marked text should still be active until the input method commits it")
        XCTAssertEqual(responder.keyDownEvents.count, 0, "Keypad Enter should not be force-forwarded to the browser responder during IME composition")
    }
}


final class BrowserReturnKeyDownRoutingTests: XCTestCase {
    func testRoutesForReturnWhenBrowserFirstResponder() {
        XCTAssertTrue(
            shouldDispatchBrowserReturnViaFirstResponderKeyDown(
                keyCode: 36,
                firstResponderIsBrowser: true,
                flags: []
            )
        )
    }

    func testRoutesForKeypadEnterWhenBrowserFirstResponder() {
        XCTAssertTrue(
            shouldDispatchBrowserReturnViaFirstResponderKeyDown(
                keyCode: 76,
                firstResponderIsBrowser: true,
                flags: []
            )
        )
    }

    func testDoesNotRouteForNonEnterKey() {
        XCTAssertFalse(
            shouldDispatchBrowserReturnViaFirstResponderKeyDown(
                keyCode: 13,
                firstResponderIsBrowser: true,
                flags: []
            )
        )
    }

    func testDoesNotRouteWhenFirstResponderIsNotBrowser() {
        XCTAssertFalse(
            shouldDispatchBrowserReturnViaFirstResponderKeyDown(
                keyCode: 36,
                firstResponderIsBrowser: false,
                flags: []
            )
        )
    }

    func testDoesNotRouteReturnWhenBrowserFirstResponderHasMarkedText() {
        XCTAssertFalse(
            shouldDispatchBrowserReturnViaFirstResponderKeyDown(
                keyCode: 36,
                firstResponderIsBrowser: true,
                firstResponderHasMarkedText: true,
                flags: []
            )
        )
    }

    func testDoesNotRouteKeypadEnterWhenBrowserFirstResponderHasMarkedText() {
        XCTAssertFalse(
            shouldDispatchBrowserReturnViaFirstResponderKeyDown(
                keyCode: 76,
                firstResponderIsBrowser: true,
                firstResponderHasMarkedText: true,
                flags: []
            )
        )
    }

    func testRoutesForShiftReturnWhenBrowserFirstResponder() {
        XCTAssertTrue(
            shouldDispatchBrowserReturnViaFirstResponderKeyDown(
                keyCode: 36,
                firstResponderIsBrowser: true,
                flags: [.shift]
            )
        )
    }

    func testDoesNotRouteForCommandShiftReturnWhenBrowserFirstResponder() {
        XCTAssertFalse(
            shouldDispatchBrowserReturnViaFirstResponderKeyDown(
                keyCode: 36,
                firstResponderIsBrowser: true,
                flags: [.command, .shift]
            )
        )
    }

    func testDoesNotRouteForCommandReturnWhenBrowserFirstResponder() {
        XCTAssertFalse(
            shouldDispatchBrowserReturnViaFirstResponderKeyDown(
                keyCode: 36,
                firstResponderIsBrowser: true,
                flags: [.command]
            )
        )
    }

    func testDoesNotRouteForOptionReturnWhenBrowserFirstResponder() {
        XCTAssertFalse(
            shouldDispatchBrowserReturnViaFirstResponderKeyDown(
                keyCode: 36,
                firstResponderIsBrowser: true,
                flags: [.option]
            )
        )
    }

    func testDoesNotRouteForControlReturnWhenBrowserFirstResponder() {
        XCTAssertFalse(
            shouldDispatchBrowserReturnViaFirstResponderKeyDown(
                keyCode: 36,
                firstResponderIsBrowser: true,
                flags: [.control]
            )
        )
    }
}


