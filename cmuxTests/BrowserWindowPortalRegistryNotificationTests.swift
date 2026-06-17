import XCTest
import AppKit
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class BrowserWindowPortalRegistryNotificationTests: XCTestCase {
    private func realizeWindowLayout(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    private func advanceAnimations() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }

    func testRegistryDoesNotNotifyForUnchangedPortalVisibility() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let anchor = NSView(frame: NSRect(x: 20, y: 20, width: 180, height: 120))
        contentView.addSubview(anchor)
        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())

        var notificationCount = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .browserPortalRegistryDidChange,
            object: webView,
            queue: nil
        ) { _ in
            notificationCount += 1
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
            BrowserWindowPortalRegistry.detach(webView: webView)
        }

        BrowserWindowPortalRegistry.bind(webView: webView, to: anchor, visibleInUI: true)
        BrowserWindowPortalRegistry.synchronizeForAnchor(anchor)
        advanceAnimations()
        XCTAssertEqual(notificationCount, 1)

        BrowserWindowPortalRegistry.updateEntryVisibility(for: webView, visibleInUI: true, zPriority: 0)
        XCTAssertEqual(
            notificationCount,
            1,
            "Reapplying an unchanged portal visibility snapshot should not wake Workspace layout follow-up"
        )

        BrowserWindowPortalRegistry.updateEntryVisibility(for: webView, visibleInUI: false, zPriority: 0)
        XCTAssertEqual(notificationCount, 2)

        BrowserWindowPortalRegistry.updateEntryVisibility(for: webView, visibleInUI: false, zPriority: 0)
        XCTAssertEqual(
            notificationCount,
            2,
            "Repeated hidden-state updates should not post duplicate registry-change notifications"
        )

        guard let slot = webView.superview as? WindowBrowserSlotView else {
            XCTFail("Expected browser slot")
            return
        }
        XCTAssertFalse(slot.isHidden)

        BrowserWindowPortalRegistry.hide(webView: webView, source: "unitTest")
        advanceAnimations()
        XCTAssertTrue(slot.isHidden)
        XCTAssertEqual(
            notificationCount,
            3,
            "A hidden visibility state whose slot still needs presentation sync should notify exactly once"
        )

        BrowserWindowPortalRegistry.hide(webView: webView, source: "unitTest")
        advanceAnimations()
        XCTAssertEqual(
            notificationCount,
            3,
            "A repeated hide after state and presentation are already hidden should not notify"
        )
    }
}
