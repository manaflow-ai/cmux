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
final class WindowAccessorTests: XCTestCase {
    func testSameWindowDedupeAllowsRefreshIDChanges() {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let coordinator = WindowAccessor.Coordinator()

        XCTAssertTrue(coordinator.shouldInvoke(window: window, dedupeByWindow: true, refreshID: "glass-off"))
        XCTAssertFalse(coordinator.shouldInvoke(window: window, dedupeByWindow: true, refreshID: "glass-off"))
        XCTAssertTrue(coordinator.shouldInvoke(window: window, dedupeByWindow: true, refreshID: "glass-clear"))
        XCTAssertFalse(coordinator.shouldInvoke(window: window, dedupeByWindow: true, refreshID: "glass-clear"))
    }

    func testDedupeDisabledAlwaysInvokesForSameWindow() {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let coordinator = WindowAccessor.Coordinator()

        XCTAssertTrue(coordinator.shouldInvoke(window: window, dedupeByWindow: false, refreshID: "same"))
        XCTAssertTrue(coordinator.shouldInvoke(window: window, dedupeByWindow: false, refreshID: "same"))
    }
}

