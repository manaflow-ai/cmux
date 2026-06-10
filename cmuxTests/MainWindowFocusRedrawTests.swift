import XCTest
import AppKit
import Carbon.HIToolbox
import Darwin
import PDFKit
import Testing
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
@testable import Bonsplit
import UserNotifications

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


@MainActor
final class MainWindowFocusRedrawTests: XCTestCase {
    func testKeyRegainInvalidatesRootContentView() {
        _ = NSApplication.shared

        let appDelegate = AppDelegate()
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: tabManager)
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
        }

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 420))
        let splitView = NSSplitView(frame: contentView.bounds)
        splitView.isVertical = true
        splitView.autoresizingMask = [.width, .height]
        splitView.dividerStyle = .thin

        let sidebar = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 420))
        let main = NSView(frame: NSRect(x: 221, y: 0, width: 419, height: 420))
        splitView.addArrangedSubview(sidebar)
        splitView.addArrangedSubview(main)
        contentView.addSubview(splitView)
        splitView.setPosition(220, ofDividerAt: 0)

        let window = CmuxMainWindow(
            contentRect: contentView.bounds,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(windowId.uuidString)")
        window.contentView = contentView
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }

        contentView.layoutSubtreeIfNeeded()
        splitView.adjustSubviews()

        contentView.needsDisplay = false

        appDelegate.handleCmuxWindowResignedKey(
            Notification(name: NSWindow.didResignKeyNotification, object: window)
        )
        appDelegate.handleCmuxWindowBecameKey(
            Notification(name: NSWindow.didBecomeKeyNotification, object: window)
        )

        XCTAssertTrue(
            contentView.needsDisplay,
            "Regaining key focus must invalidate the root content view."
        )
    }
}

