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
final class WindowGlassEffectTests: XCTestCase {
    func testRemoveRestoresOriginalContentHierarchy() {
        _ = NSApplication.shared

        let originalContentView = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        let window = NSWindow(
            contentRect: originalContentView.bounds,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = originalContentView

        WindowGlassEffect.apply(to: window, tintColor: .systemBlue)

        if WindowGlassEffect.isAvailable {
            XCTAssertFalse(window.contentView === originalContentView)
            XCTAssertTrue(WindowGlassEffect.originalContentView(for: window) === originalContentView)
            XCTAssertTrue(originalContentView.superview === WindowGlassEffect.foregroundContainer(for: window))
            XCTAssertNotNil(WindowGlassEffect.portalInstallationTarget(for: window))
        } else {
            XCTAssertTrue(window.contentView === originalContentView)
            XCTAssertNil(WindowGlassEffect.originalContentView(for: window))
            XCTAssertNil(WindowGlassEffect.foregroundContainer(for: window))
            XCTAssertNil(WindowGlassEffect.portalInstallationTarget(for: window))
        }
        XCTAssertTrue(Self.windowContainsGlassBackground(window))

        WindowGlassEffect.remove(from: window)

        XCTAssertTrue(window.contentView === originalContentView)
        XCTAssertNil(WindowGlassEffect.foregroundContainer(for: window))
        XCTAssertNil(WindowGlassEffect.originalContentView(for: window))
        XCTAssertFalse(Self.windowContainsGlassBackground(window))
    }

    func testNativeGlassTintFollowsWindowKeyNotifications() throws {
        guard WindowGlassEffect.isAvailable else {
            throw XCTSkip("NSGlassEffectView is unavailable on this macOS version")
        }
        _ = NSApplication.shared

        let originalContentView = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        let window = NSWindow(
            contentRect: originalContentView.bounds,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = originalContentView

        WindowGlassEffect.apply(to: window, tintColor: .black, style: .clear)

        guard let backgroundView = Self.glassBackgroundView(in: window.contentView),
              let tintOverlay = backgroundView.subviews.last else {
            XCTFail("Expected glass background tint overlay")
            return
        }

        XCTAssertGreaterThan(tintOverlay.alphaValue, 0)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        XCTAssertEqual(tintOverlay.alphaValue, 0, accuracy: 0.001)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        XCTAssertGreaterThan(tintOverlay.alphaValue, 0)
    }

    private static func windowContainsGlassBackground(_ window: NSWindow) -> Bool {
        guard let contentView = window.contentView else { return false }
        let root = contentView.superview ?? contentView
        return glassBackgroundView(in: root) != nil
    }

    private static func glassBackgroundView(in view: NSView?) -> NSView? {
        guard let view else { return nil }
        if view.identifier == WindowGlassEffect.backgroundViewIdentifier {
            return view
        }
        return view.subviews.lazy.compactMap(glassBackgroundView(in:)).first
    }
}

