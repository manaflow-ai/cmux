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


// MARK: - Input event performance
private final class BrowserKeyboardHitTestCountingView: NSView {
    private(set) var hitTestCount = 0

    override func hitTest(_ point: NSPoint) -> NSView? {
        hitTestCount += 1
        return super.hitTest(point)
    }

    func resetHitTestCount() {
        hitTestCount = 0
    }
}


@MainActor
final class BrowserInputEventPerformanceTests: XCTestCase {
    func testBrowserKeyDownDispatchDoesNotHitTestPointerOnlyOverlays() {
        _ = NSApplication.shared
        AppDelegate.installWindowResponderSwizzlesForTesting()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let contentView = BrowserKeyboardHitTestCountingView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = contentView

        let slot = WindowBrowserSlotView(frame: contentView.bounds)
        slot.autoresizingMask = [.width, .height]
        contentView.addSubview(slot)

        let webView = CmuxWebView(frame: slot.bounds, configuration: WKWebViewConfiguration())
        webView.autoresizingMask = [.width, .height]
        slot.addSubview(webView)
        slot.pinHostedWebView(webView)
        slot.setPaneDropContext(BrowserPaneDropContext(
            workspaceId: UUID(),
            panelId: UUID(),
            paneId: PaneID(id: UUID())
        ))

        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        XCTAssertTrue(window.makeFirstResponder(webView))
        contentView.resetHitTestCount()

        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: NSPoint(x: 320, y: 210),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "a",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: 0
        ) else {
            XCTFail("Failed to construct browser keyDown event")
            return
        }

        window.sendEvent(event)

        XCTAssertEqual(
            contentView.hitTestCount,
            0,
            "Keyboard dispatch should not walk browser hit-test overlays; pointer routing owns hit-testing."
        )
    }
}


