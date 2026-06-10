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


// MARK: - Web view context menu
@MainActor
final class CmuxWebViewContextMenuTests: XCTestCase {
    private func makeRightMouseDownEvent() -> NSEvent {
        guard let event = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        ) else {
            fatalError("Failed to create rightMouseDown event")
        }
        return event
    }

    func testWillOpenMenuAddsOpenLinkInDefaultBrowserAndRoutesSelectionToDefaultBrowserOpener() {
        _ = NSApplication.shared
        let webView = CmuxWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: WKWebViewConfiguration())
        let menu = NSMenu()
        let openLinkItem = NSMenuItem(title: "Open Link", action: nil, keyEquivalent: "")
        openLinkItem.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierOpenLink")
        menu.addItem(openLinkItem)
        menu.addItem(NSMenuItem(title: "Copy Link", action: nil, keyEquivalent: ""))

        var openedURL: URL?
        webView.contextMenuLinkURLProvider = { _, _, completion in
            completion(URL(string: "https://example.com/docs")!)
        }
        webView.contextMenuDefaultBrowserOpener = { url in
            openedURL = url
            return true
        }

        webView.willOpenMenu(menu, with: makeRightMouseDownEvent())

        guard let defaultBrowserItemIndex = menu.items.firstIndex(where: { $0.title == "Open Link in Default Browser" }) else {
            XCTFail("Expected Open Link in Default Browser item in context menu")
            return
        }
        guard let openLinkIndex = menu.items.firstIndex(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierOpenLink" }) else {
            XCTFail("Expected Open Link item in context menu")
            return
        }

        XCTAssertEqual(defaultBrowserItemIndex, openLinkIndex + 1)
        let defaultBrowserItem = menu.items[defaultBrowserItemIndex]
        XCTAssertTrue(defaultBrowserItem.target === webView)
        XCTAssertNotNil(defaultBrowserItem.action)

        let dispatched = NSApp.sendAction(
            defaultBrowserItem.action!,
            to: defaultBrowserItem.target,
            from: defaultBrowserItem
        )
        XCTAssertTrue(dispatched)
        XCTAssertEqual(openedURL?.absoluteString, "https://example.com/docs")
    }

    func testWillOpenMenuSkipsDefaultBrowserItemWhenContextHasNoOpenLinkEntry() {
        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Back", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Forward", action: nil, keyEquivalent: ""))

        webView.willOpenMenu(menu, with: makeRightMouseDownEvent())

        XCTAssertFalse(menu.items.contains { $0.title == "Open Link in Default Browser" })
    }

    func testWillOpenMenuHooksDownloadImageToDiskMenuVariant() {
        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let menu = NSMenu()
        let originalTarget = NSObject()
        let originalAction = NSSelectorFromString("downloadImageToDisk:")
        let downloadItem = NSMenuItem(title: "Download Image As...", action: originalAction, keyEquivalent: "")
        downloadItem.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierDownloadImageToDisk")
        downloadItem.target = originalTarget
        menu.addItem(downloadItem)

        webView.willOpenMenu(menu, with: makeRightMouseDownEvent())

        XCTAssertTrue(downloadItem.target === webView)
        XCTAssertNotNil(downloadItem.action)
        XCTAssertNotEqual(downloadItem.action, originalAction)
    }

    func testWillOpenMenuHooksDownloadLinkedFileToDiskMenuVariant() {
        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let menu = NSMenu()
        let originalTarget = NSObject()
        let originalAction = NSSelectorFromString("downloadLinkToDisk:")
        let downloadItem = NSMenuItem(title: "Download Linked File As...", action: originalAction, keyEquivalent: "")
        downloadItem.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierDownloadLinkToDisk")
        downloadItem.target = originalTarget
        menu.addItem(downloadItem)

        webView.willOpenMenu(menu, with: makeRightMouseDownEvent())

        XCTAssertTrue(downloadItem.target === webView)
        XCTAssertNotNil(downloadItem.action)
        XCTAssertNotEqual(downloadItem.action, originalAction)
    }
}


