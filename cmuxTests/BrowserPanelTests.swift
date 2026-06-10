import XCTest
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
import Bonsplit
import UserNotifications
import Darwin
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class BrowserPanelTestNavigationDelegate: NSObject, WKNavigationDelegate {
    let expectation: XCTestExpectation
    var error: Error?

    init(expectation: XCTestExpectation) {
        self.expectation = expectation
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        expectation.fulfill()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        self.error = error
        expectation.fulfill()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.error = error
        expectation.fulfill()
    }
}

@MainActor
final class BrowserWindowPortalLifecycleTests: XCTestCase {
    final class TrackingPortalWebView: WKWebView {
        private(set) var displayIfNeededCount = 0
        private(set) var reattachRenderingStateCount = 0

        override func displayIfNeeded() {
            displayIfNeededCount += 1
            super.displayIfNeeded()
        }

        @objc(_enterInWindow)
        func cmuxUnitTestEnterInWindow() {
            reattachRenderingStateCount += 1
        }

        @objc(_endDeferringViewInWindowChangesSync)
        func cmuxUnitTestEndDeferringViewInWindowChangesSync() {
            reattachRenderingStateCount += 1
        }
    }

    final class WKInspectorProbeView: NSView {}

    func realizeWindowLayout(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    func advanceAnimations() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    }

    func dropZoneOverlay(in slot: WindowBrowserSlotView, excluding webView: WKWebView) -> NSView? {
        let candidates = slot.subviews + (slot.superview?.subviews ?? [])
        return candidates.first(where: {
            $0 !== slot &&
            $0 !== webView &&
            String(describing: type(of: $0)).contains("BrowserDropZoneOverlayView")
        })
    }

}

