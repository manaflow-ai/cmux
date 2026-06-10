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


// MARK: - Titlebar double-click handling
extension WindowDragHandleHitTests {
    private final class RecordingTitlebarActionWindow: NSWindow {
        var zoomCallCount = 0
        var miniaturizeCallCount = 0

        override func zoom(_ sender: Any?) {
            zoomCallCount += 1
        }

        override func miniaturize(_ sender: Any?) {
            miniaturizeCallCount += 1
        }
    }

    private static func firstSubview(
        in view: NSView,
        matching predicate: (NSView) -> Bool
    ) -> NSView? {
        if predicate(view) {
            return view
        }

        for subview in view.subviews {
            if let match = firstSubview(in: subview, matching: predicate) {
                return match
            }
        }

        return nil
    }

    private static func firstCapturableTitlebarPoint(
        in dragHandle: NSView,
        window: NSWindow
    ) -> NSPoint? {
        let bounds = dragHandle.bounds.insetBy(dx: 4, dy: 4)
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        let yCandidates = [
            bounds.midY,
            bounds.minY + bounds.height * 0.25,
            bounds.minY + bounds.height * 0.75
        ]

        for y in yCandidates {
            var x = bounds.maxX
            while x >= bounds.minX {
                let point = NSPoint(x: x, y: y)
                if windowDragHandleShouldCaptureHit(
                    point,
                    in: dragHandle,
                    eventType: .leftMouseDown,
                    eventWindow: window
                ) {
                    return point
                }
                x -= 4
            }
        }

        return nil
    }

    func testSuppressedTitlebarDoubleClickConsumesWithoutWindowAction() {
        XCTAssertEqual(
            handleTitlebarDoubleClick(window: nil, behavior: .suppress),
            .suppressed
        )
        XCTAssertEqual(
            handleTitlebarDoubleClick(window: nil, behavior: .standardAction),
            .ignored
        )
        XCTAssertTrue(TitlebarDoubleClickHandlingResult.suppressed.consumesEvent)
        XCTAssertFalse(TitlebarDoubleClickHandlingResult.ignored.consumesEvent)
    }

    func testMinimalModeDoubleClickHandlerOnlyHandlesTopStripDoubleClicks() {
        let bounds = NSRect(x: 0, y: 0, width: 400, height: 300)

        XCTAssertTrue(
            shouldHandleMinimalModeTitlebarDoubleClick(
                isEnabled: true,
                clickCount: 2,
                point: NSPoint(x: 200, y: 292),
                bounds: bounds,
                topStripHeight: 30
            )
        )
        XCTAssertFalse(
            shouldHandleMinimalModeTitlebarDoubleClick(
                isEnabled: true,
                clickCount: 2,
                point: NSPoint(x: 200, y: 240),
                bounds: bounds,
                topStripHeight: 30
            )
        )
        XCTAssertFalse(
            shouldHandleMinimalModeTitlebarDoubleClick(
                isEnabled: false,
                clickCount: 2,
                point: NSPoint(x: 200, y: 292),
                bounds: bounds,
                topStripHeight: 30
            )
        )
        XCTAssertFalse(
            shouldHandleMinimalModeTitlebarDoubleClick(
                isEnabled: true,
                clickCount: 1,
                point: NSPoint(x: 200, y: 292),
                bounds: bounds,
                topStripHeight: 30
            )
        )
    }

    func testMinimalModeWindowDoubleClickRequiresMainTopStrip() {
        let bounds = NSRect(x: 0, y: 0, width: 400, height: 300)

        XCTAssertTrue(
            shouldHandleMinimalModeWindowTitlebarDoubleClick(
                isMinimalMode: true,
                isFullScreen: false,
                isMainWindow: true,
                clickCount: 2,
                locationInWindow: NSPoint(x: 200, y: 292),
                contentBounds: bounds,
                titlebarBandHeight: 30
            )
        )
        XCTAssertFalse(
            shouldHandleMinimalModeWindowTitlebarDoubleClick(
                isMinimalMode: false,
                isFullScreen: false,
                isMainWindow: true,
                clickCount: 2,
                locationInWindow: NSPoint(x: 200, y: 292),
                contentBounds: bounds,
                titlebarBandHeight: 30
            )
        )
        XCTAssertFalse(
            shouldHandleMinimalModeWindowTitlebarDoubleClick(
                isMinimalMode: true,
                isFullScreen: true,
                isMainWindow: true,
                clickCount: 2,
                locationInWindow: NSPoint(x: 200, y: 292),
                contentBounds: bounds,
                titlebarBandHeight: 30
            )
        )
        XCTAssertFalse(
            shouldHandleMinimalModeWindowTitlebarDoubleClick(
                isMinimalMode: true,
                isFullScreen: false,
                isMainWindow: false,
                clickCount: 2,
                locationInWindow: NSPoint(x: 200, y: 292),
                contentBounds: bounds,
                titlebarBandHeight: 30
            )
        )
        XCTAssertFalse(
            shouldHandleMinimalModeWindowTitlebarDoubleClick(
                isMinimalMode: true,
                isFullScreen: false,
                isMainWindow: true,
                clickCount: 2,
                locationInWindow: NSPoint(x: 200, y: 240),
                contentBounds: bounds,
                titlebarBandHeight: 30
            )
        )
    }

    func testMinimalModeTitlebarConsecutiveClicksCanFormDoubleClick() {
        let previous = MinimalModeTitlebarClickRecord(
            windowNumber: 42,
            timestamp: 10,
            locationInWindow: NSPoint(x: 200, y: 292)
        )

        XCTAssertTrue(
            minimalModeTitlebarClickFormsDoubleClick(
                clickCount: 1,
                timestamp: 10.2,
                locationInWindow: NSPoint(x: 201, y: 291),
                windowNumber: 42,
                previous: previous,
                doubleClickInterval: 0.5
            )
        )
        XCTAssertFalse(
            minimalModeTitlebarClickFormsDoubleClick(
                clickCount: 1,
                timestamp: 10.65,
                locationInWindow: NSPoint(x: 201, y: 291),
                windowNumber: 42,
                previous: previous,
                doubleClickInterval: 0.5
            )
        )
        XCTAssertTrue(
            minimalModeTitlebarClickFormsDoubleClick(
                clickCount: 1,
                timestamp: 10.62,
                locationInWindow: NSPoint(x: 201, y: 291),
                windowNumber: 42,
                previous: previous,
                doubleClickInterval: 0.5,
                doubleClickIntervalTolerance: 0.15
            )
        )
        XCTAssertTrue(
            minimalModeTitlebarClickFormsDoubleClick(
                clickCount: 2,
                timestamp: 20,
                locationInWindow: NSPoint(x: 20, y: 20),
                windowNumber: 99,
                previous: nil,
                doubleClickInterval: 0.5
            )
        )
        XCTAssertFalse(
            minimalModeTitlebarClickFormsDoubleClick(
                clickCount: 1,
                timestamp: 10.8,
                locationInWindow: NSPoint(x: 201, y: 291),
                windowNumber: 42,
                previous: previous,
                doubleClickInterval: 0.5
            )
        )
        XCTAssertFalse(
            minimalModeTitlebarClickFormsDoubleClick(
                clickCount: 1,
                timestamp: 10.2,
                locationInWindow: NSPoint(x: 240, y: 292),
                windowNumber: 42,
                previous: previous,
                doubleClickInterval: 0.5
            )
        )
        XCTAssertFalse(
            minimalModeTitlebarClickFormsDoubleClick(
                clickCount: 1,
                timestamp: 10.2,
                locationInWindow: NSPoint(x: 201, y: 291),
                windowNumber: 43,
                previous: previous,
                doubleClickInterval: 0.5
            )
        )
    }

    func testRightSidebarModeBarEmptySpaceDoubleClickPerformsTitlebarAction() {
        _ = NSApplication.shared

        let previousGlobalDefaults = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)
        var testGlobalDefaults = previousGlobalDefaults ?? [:]
        testGlobalDefaults["AppleActionOnDoubleClick"] = "Fill"
        testGlobalDefaults["AppleMiniaturizeOnDoubleClick"] = false
        UserDefaults.standard.setPersistentDomain(testGlobalDefaults, forName: UserDefaults.globalDomain)
        defer {
            if let previousGlobalDefaults {
                UserDefaults.standard.setPersistentDomain(previousGlobalDefaults, forName: UserDefaults.globalDomain)
            } else {
                UserDefaults.standard.removePersistentDomain(forName: UserDefaults.globalDomain)
            }
        }

        let window = RecordingTitlebarActionWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 260),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }

        let rootView = RightSidebarPanelView(
            tabManager: TabManager(),
            fileExplorerStore: FileExplorerStore(),
            fileExplorerState: FileExplorerState(),
            sessionIndexStore: SessionIndexStore(),
            titlebarHeight: 36,
            workspaceId: nil,
            onResumeSession: nil,
            onOpenFilePreview: { _ in },
            onOpenAsPane: { _ in },
            onClose: {}
        )
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = window.contentRect(forFrameRect: window.frame)
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        hostingView.layoutSubtreeIfNeeded()

        guard let dragHandle = Self.firstSubview(
            in: hostingView,
            matching: { $0.identifier == WindowDragHandleView.viewIdentifier }
        ) else {
            XCTFail("Expected right-sidebar mode bar to install a titlebar drag handle")
            return
        }

        guard let emptyModeBarLocalPoint = Self.firstCapturableTitlebarPoint(
            in: dragHandle,
            window: window
        ) else {
            XCTFail("Expected right-sidebar mode bar to expose at least one empty titlebar point")
            return
        }

        let emptyModeBarPoint = dragHandle.convert(emptyModeBarLocalPoint, to: nil as NSView?)
        guard let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: emptyModeBarPoint,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 2,
            pressure: 1.0
        ) else {
            XCTFail("Expected to create right-sidebar mode-bar double-click event")
            return
        }

        NSApp.sendEvent(event)

        XCTAssertEqual(window.zoomCallCount, 1)
        XCTAssertEqual(window.miniaturizeCallCount, 0)
    }
}
