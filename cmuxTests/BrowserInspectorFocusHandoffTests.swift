import AppKit
import WebKit
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class BrowserInspectorFocusHandoffTests: XCTestCase {
    private final class FakeWKInspectorResponderView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    func testWindowFirstResponderGuardPostsBrowserClickIntentForInspectorFocus() {
        _ = NSApplication.shared
        AppDelegate.installWindowResponderSwizzlesForTesting()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = contentView

        let anchor = NSView(frame: NSRect(x: 80, y: 60, width: 480, height: 260))
        contentView.addSubview(anchor)

        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())
        window.makeKeyAndOrderFront(nil)
        contentView.layoutSubtreeIfNeeded()
        BrowserWindowPortalRegistry.bind(webView: webView, to: anchor, visibleInUI: true, zPriority: 1)
        BrowserWindowPortalRegistry.synchronizeForAnchor(anchor)

        defer {
            BrowserWindowPortalRegistry.detach(webView: webView)
            AppDelegate.clearWindowFirstResponderGuardTesting()
            window.orderOut(nil)
        }

        guard let slot = webView.superview as? WindowBrowserSlotView else {
            XCTFail("Expected bound portal slot")
            return
        }

        let inspector = FakeWKInspectorResponderView(frame: NSRect(x: 320, y: 0, width: 160, height: slot.bounds.height))
        slot.addSubview(inspector)

        var clickIntentCount = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .webViewDidReceiveClick,
            object: nil,
            queue: nil
        ) { notification in
            if notification.object as? CmuxWebView === webView {
                clickIntentCount += 1
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let pointInWindow = inspector.convert(NSPoint(x: inspector.bounds.midX, y: inspector.bounds.midY), to: nil)
        let pointerDownEvent = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: pointInWindow,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1.0
        )
        XCTAssertNotNil(pointerDownEvent)

        AppDelegate.setWindowFirstResponderGuardTesting(currentEvent: pointerDownEvent, hitView: nil)
        _ = window.makeFirstResponder(nil)
        XCTAssertTrue(window.makeFirstResponder(inspector))
        XCTAssertEqual(clickIntentCount, 1)
    }
}
