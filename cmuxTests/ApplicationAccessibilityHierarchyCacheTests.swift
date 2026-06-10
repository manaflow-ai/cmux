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

#if DEBUG


@MainActor
final class ApplicationAccessibilityHierarchyCacheTests: XCTestCase {
    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        return window
    }

    private func assertWindowsEqual(_ actual: Any?, _ expected: [NSWindow], file: StaticString = #filePath, line: UInt = #line) {
        guard let actualWindows = actual as? [NSWindow] else {
            XCTFail("Expected NSWindow array", file: file, line: line)
            return
        }
        guard actualWindows.count == expected.count else {
            XCTFail("Expected \(expected.count) windows, got \(actualWindows.count)", file: file, line: line)
            return
        }
        for (lhs, rhs) in zip(actualWindows, expected) {
            XCTAssertTrue(lhs === rhs, file: file, line: line)
        }
    }

    func testRepeatedWindowsQueriesReuseSingleHierarchyBuildUntilStateChanges() {
        let firstWindow = makeWindow()
        let secondWindow = makeWindow()
        defer {
            firstWindow.orderOut(nil)
            secondWindow.orderOut(nil)
        }

        let cache = CmuxApplicationAccessibilityHierarchyCache()
        let state = CmuxApplicationAccessibilityHierarchyCache.StateToken(windows: [firstWindow, secondWindow])
        var buildCount = 0

        let firstValue = cache.value(for: .windows, stateToken: state) {
            buildCount += 1
            return .init(windows: [firstWindow, secondWindow])
        }
        let secondValue = cache.value(for: .windows, stateToken: state) {
            XCTFail("Expected cached snapshot for repeated state")
            return .init(windows: [])
        }

        assertWindowsEqual(firstValue, [firstWindow, secondWindow])
        assertWindowsEqual(secondValue, [firstWindow, secondWindow])
        XCTAssertEqual(buildCount, 1, "Expected a single hierarchy build for repeated AX queries with no invalidation")
    }

    func testChangedStateTokenInvalidatesCachedHierarchySnapshot() {
        let window = makeWindow()
        let otherWindow = makeWindow()
        defer {
            window.orderOut(nil)
            otherWindow.orderOut(nil)
        }

        let cache = CmuxApplicationAccessibilityHierarchyCache()
        let initialState = CmuxApplicationAccessibilityHierarchyCache.StateToken(windows: [window])
        let updatedState = CmuxApplicationAccessibilityHierarchyCache.StateToken(windows: [window, otherWindow])
        var buildCount = 0

        _ = cache.value(for: .windows, stateToken: initialState) {
            buildCount += 1
            return .init(windows: [window])
        }
        let updatedWindowsValue = cache.value(for: .windows, stateToken: updatedState) {
            buildCount += 1
            return .init(windows: [window, otherWindow])
        }

        assertWindowsEqual(updatedWindowsValue, [window, otherWindow])
        XCTAssertEqual(buildCount, 2, "Expected the cache to rebuild once after the hierarchy token changes")
    }

    func testNonWindowsAttributesStayPassthrough() {
        let cache = CmuxApplicationAccessibilityHierarchyCache()

        for attribute: NSAccessibility.Attribute in [.children, .visibleChildren, .mainWindow, .focusedWindow] {
            switch cache.resolve(attribute: attribute, application: NSApp) {
            case .passthrough:
                break
            case .handled:
                XCTFail("Expected \(attribute.rawValue) to fall back to AppKit")
            }
        }
    }

    func testWindowCloseNotificationInvalidatesCache() {
        let window = makeWindow()
        defer { window.orderOut(nil) }

        let center = NotificationCenter()
        let cache = CmuxApplicationAccessibilityHierarchyCache(notificationCenter: center)
        let state = CmuxApplicationAccessibilityHierarchyCache.StateToken(windows: [window])
        var buildCount = 0

        _ = cache.value(for: .windows, stateToken: state) {
            buildCount += 1
            return .init(windows: [window])
        }
        center.post(name: NSWindow.willCloseNotification, object: window)
        _ = cache.value(for: .windows, stateToken: state) {
            buildCount += 1
            return .init(windows: [window])
        }

        XCTAssertEqual(buildCount, 2, "Expected NSWindow.willCloseNotification to invalidate the cache")
    }
}
#endif
