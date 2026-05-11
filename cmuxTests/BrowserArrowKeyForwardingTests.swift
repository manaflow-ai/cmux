import XCTest
import AppKit
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class BrowserArrowKeyForwardingTests: XCTestCase {
    func testRoutesAllPlainArrowKeysWhenBrowserFirstResponder() {
        for keyCode in [123, 124, 125, 126] as [UInt16] {
            XCTAssertTrue(
                shouldDispatchBrowserArrowViaFirstResponderKeyDown(
                    keyCode: keyCode,
                    firstResponderIsBrowser: true,
                    flags: []
                ),
                "Expected browser responder to own plain arrow keyCode \(keyCode)"
            )
        }
    }

    func testDoesNotForceForwardArrowsOutsidePlainBrowserResponderPath() {
        XCTAssertFalse(shouldDispatchBrowserArrowViaFirstResponderKeyDown(keyCode: 123, firstResponderIsBrowser: false, flags: []))
        XCTAssertFalse(shouldDispatchBrowserArrowViaFirstResponderKeyDown(keyCode: 124, firstResponderIsBrowser: true, firstResponderHasMarkedText: true, flags: []))
        XCTAssertFalse(shouldDispatchBrowserArrowViaFirstResponderKeyDown(keyCode: 125, firstResponderIsBrowser: true, flags: [.command]))
    }
}

@MainActor
final class BrowserReturnKeyForwardingTests: XCTestCase {
    private final class RecordingWebSubview: NSView {
        var keyDownCallCount = 0
        var lastKeyCode: UInt16?
        var reentrantPerformKeyEquivalentEvent: NSEvent?
        var reentrantPerformKeyEquivalentResult: Bool?

        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            keyDownCallCount += 1
            lastKeyCode = event.keyCode
            if let reentrantPerformKeyEquivalentEvent {
                reentrantPerformKeyEquivalentResult = window?.performKeyEquivalent(with: reentrantPerformKeyEquivalentEvent)
            }
        }
    }

    private func makeKeyEvent(
        windowNumber: Int,
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags = []
    ) -> NSEvent {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: keyCode
        ) else {
            fatalError("Failed to construct key event")
        }
        return event
    }

    func testRoutesPlainReturnFromEmbeddedWKWebViewResponderToKeyDownAndConsumesIt() {
        AppDelegate.installWindowResponderSwizzlesForTesting()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { window.close() }

        let webView = WKWebView(frame: window.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 320, height: 240))
        let webSubview = RecordingWebSubview(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        webView.addSubview(webSubview)
        window.contentView = webView

        XCTAssertTrue(window.makeFirstResponder(webSubview))

        let event = makeKeyEvent(windowNumber: window.windowNumber, keyCode: 36)
        XCTAssertTrue(window.performKeyEquivalent(with: event))
        XCTAssertEqual(webSubview.keyDownCallCount, 1)
        XCTAssertEqual(webSubview.lastKeyCode, 36)
    }

    func testConsumesReentrantReturnDuringForwardedBrowserKeyDown() {
        AppDelegate.installWindowResponderSwizzlesForTesting()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { window.close() }

        let webView = WKWebView(frame: window.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 320, height: 240))
        let webSubview = RecordingWebSubview(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        webView.addSubview(webSubview)
        window.contentView = webView

        XCTAssertTrue(window.makeFirstResponder(webSubview))

        let event = makeKeyEvent(windowNumber: window.windowNumber, keyCode: 36)
        webSubview.reentrantPerformKeyEquivalentEvent = event

        XCTAssertTrue(window.performKeyEquivalent(with: event))
        XCTAssertEqual(webSubview.keyDownCallCount, 1)
        XCTAssertEqual(webSubview.lastKeyCode, 36)
        XCTAssertEqual(webSubview.reentrantPerformKeyEquivalentResult, true)
    }

    func testReturnForwardingKeepsShortcutAndIMECasesOutOfTheForcedPath() {
        XCTAssertFalse(
            shouldDispatchBrowserReturnViaFirstResponderKeyDown(
                keyCode: 36,
                firstResponderIsBrowser: false,
                flags: []
            )
        )
        XCTAssertFalse(
            shouldDispatchBrowserReturnViaFirstResponderKeyDown(
                keyCode: 36,
                firstResponderIsBrowser: true,
                firstResponderHasMarkedText: true,
                flags: []
            )
        )
        XCTAssertFalse(
            shouldDispatchBrowserReturnViaFirstResponderKeyDown(
                keyCode: 36,
                firstResponderIsBrowser: true,
                flags: [.command]
            )
        )
        XCTAssertTrue(
            shouldDispatchBrowserReturnViaFirstResponderKeyDown(
                keyCode: 76,
                firstResponderIsBrowser: true,
                flags: [.shift]
            )
        )
    }
}
