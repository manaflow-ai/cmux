import AppKit
import CmuxAppKitSupportUI
import CmuxFoundation
import Carbon.HIToolbox
import Darwin
import PDFKit
import Testing
import XCTest
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
@testable import Bonsplit
import UserNotifications
// Selective imports: the app target also defines AppIconMode/StoredShortcut/etc.,
// so a blanket `import CmuxSettings` here makes those names ambiguous. Import only
// the settings symbols this file needs.
import struct CmuxSettings.AccountCatalogSection
import struct CmuxSettings.AppCatalogSection
import struct CmuxSettings.FileRouteSettingsStore

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
final class WindowMoveSuppressionHitPathTests {
    private func makeWindowWithContentView() -> (NSWindow, NSView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = contentView
        return (window, contentView)
    }

    private func makeMouseEvent(type: NSEvent.EventType, location: NSPoint, window: NSWindow) -> NSEvent {
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        ) else {
            fatalError("Failed to create \(type) mouse event")
        }
        return event
    }

    @Test func testSuppressionHitPathRecognizesFolderView() {
        let folderView = DraggableFolderNSView(directory: "/tmp")
        XCTAssertTrue(shouldSuppressWindowMoveForFolderDrag(hitView: folderView))
    }

    @Test func testSuppressionHitPathRecognizesDescendantOfFolderView() {
        let folderView = DraggableFolderNSView(directory: "/tmp")
        let child = NSView(frame: .zero)
        folderView.addSubview(child)
        XCTAssertTrue(shouldSuppressWindowMoveForFolderDrag(hitView: child))
    }

    @Test func testSuppressionHitPathIgnoresUnrelatedViews() {
        XCTAssertFalse(shouldSuppressWindowMoveForFolderDrag(hitView: NSView(frame: .zero)))
        XCTAssertFalse(shouldSuppressWindowMoveForFolderDrag(hitView: nil))
    }

    @Test func testSuppressionEventPathRecognizesFolderHitInsideWindow() {
        let (window, contentView) = makeWindowWithContentView()
        window.isMovable = true
        let folderView = DraggableFolderNSView(directory: "/tmp")
        folderView.frame = NSRect(x: 10, y: 10, width: 16, height: 16)
        contentView.addSubview(folderView)

        let event = makeMouseEvent(type: .leftMouseDown, location: NSPoint(x: 14, y: 14), window: window)

        XCTAssertTrue(shouldSuppressWindowMoveForFolderDrag(window: window, event: event))
    }

    @Test func testSuppressionEventPathRejectsNonFolderAndNonMouseDownEvents() {
        let (window, contentView) = makeWindowWithContentView()
        window.isMovable = true
        let plainView = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        contentView.addSubview(plainView)

        let down = makeMouseEvent(type: .leftMouseDown, location: NSPoint(x: 20, y: 20), window: window)
        XCTAssertFalse(shouldSuppressWindowMoveForFolderDrag(window: window, event: down))

        let dragged = makeMouseEvent(type: .leftMouseDragged, location: NSPoint(x: 20, y: 20), window: window)
        XCTAssertFalse(shouldSuppressWindowMoveForFolderDrag(window: window, event: dragged))
    }

    @Test func testBonsplitPaneTabMouseDownSuppressesWindowMove() {
        let (window, contentView) = makeWindowWithContentView()
        window.isMovable = true
        let tabRegion = FakeBonsplitTabItemRegionView(frame: NSRect(x: 20, y: 132, width: 240, height: 30))
        tabRegion.tabFrames = [CGRect(x: 8, y: 0, width: 96, height: 30)]
        contentView.addSubview(tabRegion)
        BonsplitTabItemHitRegionRegistry.register(tabRegion)
        defer { BonsplitTabItemHitRegionRegistry.unregister(tabRegion) }

        let tabPoint = tabRegion.convert(NSPoint(x: 28, y: 15), to: nil)
        let event = makeMouseEvent(type: .leftMouseDown, location: tabPoint, window: window)

        XCTAssertTrue(shouldSuppressWindowMoveForBonsplitPaneTabDrag(window: window, event: event))
        XCTAssertEqual(windowMoveSuppressionReason(window: window, event: event), .bonsplitPaneTabDrag)
    }

    @Test func testBonsplitPaneTabDragSequenceKeepsWindowImmovableUntilMouseUp() {
        let (window, contentView) = makeWindowWithContentView()
        window.isMovable = true
        let tabRegion = FakeBonsplitTabItemRegionView(frame: NSRect(x: 20, y: 132, width: 240, height: 30))
        tabRegion.tabFrames = [CGRect(x: 8, y: 0, width: 96, height: 30)]
        contentView.addSubview(tabRegion)
        BonsplitTabItemHitRegionRegistry.register(tabRegion)
        defer {
            _ = finishWindowMoveSuppressionSequence(window: window)
            BonsplitTabItemHitRegionRegistry.unregister(tabRegion)
        }

        let tabPoint = tabRegion.convert(NSPoint(x: 28, y: 15), to: nil)
        let down = makeMouseEvent(type: .leftMouseDown, location: tabPoint, window: window)

        XCTAssertEqual(beginOrContinueWindowMoveSuppressionSequenceForEvent(window: window, event: down), .bonsplitPaneTabDrag)
        XCTAssertFalse(window.isMovable)
        XCTAssertTrue(isWindowDragSuppressed(window: window))
        XCTAssertEqual(activeWindowMoveSuppressionSequenceReason(window: window), .bonsplitPaneTabDrag)

        let draggedOutsideTab = makeMouseEvent(
            type: .leftMouseDragged,
            location: NSPoint(x: contentView.bounds.midX, y: contentView.bounds.midY),
            window: window
        )
        XCTAssertEqual(
            beginOrContinueWindowMoveSuppressionSequenceForEvent(window: window, event: draggedOutsideTab),
            .bonsplitPaneTabDrag
        )
        XCTAssertFalse(window.isMovable, "Window must remain immovable for the whole tab-drag mouse sequence")
        XCTAssertFalse(shouldFinishWindowMoveSuppressionSequenceAfterDispatch(window: window, event: draggedOutsideTab))

        let up = makeMouseEvent(type: .leftMouseUp, location: tabPoint, window: window)
        XCTAssertEqual(beginOrContinueWindowMoveSuppressionSequenceForEvent(window: window, event: up), .bonsplitPaneTabDrag)
        XCTAssertTrue(shouldFinishWindowMoveSuppressionSequenceAfterDispatch(window: window, event: up))
        XCTAssertEqual(finishWindowMoveSuppressionSequence(window: window), .bonsplitPaneTabDrag)
        XCTAssertTrue(window.isMovable)
        XCTAssertFalse(isWindowDragSuppressed(window: window))
        XCTAssertNil(activeWindowMoveSuppressionSequenceReason(window: window))
    }

    @Test func testBonsplitPaneTabSuppressionRestoresImmovableMainWindow() {
        let (window, contentView) = makeWindowWithContentView()
        window.isMovable = false
        let tabRegion = FakeBonsplitTabItemRegionView(frame: NSRect(x: 20, y: 132, width: 240, height: 30))
        tabRegion.tabFrames = [CGRect(x: 8, y: 0, width: 96, height: 30)]
        contentView.addSubview(tabRegion)
        BonsplitTabItemHitRegionRegistry.register(tabRegion)
        defer {
            _ = finishWindowMoveSuppressionSequence(window: window)
            BonsplitTabItemHitRegionRegistry.unregister(tabRegion)
        }

        let tabPoint = tabRegion.convert(NSPoint(x: 28, y: 15), to: nil)
        let down = makeMouseEvent(type: .leftMouseDown, location: tabPoint, window: window)

        XCTAssertEqual(beginOrContinueWindowMoveSuppressionSequenceForEvent(window: window, event: down), .bonsplitPaneTabDrag)
        XCTAssertFalse(window.isMovable)
        XCTAssertEqual(finishWindowMoveSuppressionSequence(window: window), .bonsplitPaneTabDrag)
        XCTAssertFalse(
            window.isMovable,
            "Tab-drag suppression must not restore native AppKit window dragging when the main window baseline is immovable"
        )
    }

    @Test func testNewMouseDownReevaluatesAfterStaleBonsplitPaneTabSuppression() {
        let (window, contentView) = makeWindowWithContentView()
        window.isMovable = true
        let tabRegion = FakeBonsplitTabItemRegionView(frame: NSRect(x: 20, y: 132, width: 240, height: 30))
        tabRegion.tabFrames = [CGRect(x: 8, y: 0, width: 96, height: 30)]
        contentView.addSubview(tabRegion)
        BonsplitTabItemHitRegionRegistry.register(tabRegion)
        defer {
            _ = finishWindowMoveSuppressionSequence(window: window)
            BonsplitTabItemHitRegionRegistry.unregister(tabRegion)
        }

        let tabPoint = tabRegion.convert(NSPoint(x: 28, y: 15), to: nil)
        let down = makeMouseEvent(type: .leftMouseDown, location: tabPoint, window: window)
        XCTAssertEqual(beginOrContinueWindowMoveSuppressionSequenceForEvent(window: window, event: down), .bonsplitPaneTabDrag)
        XCTAssertFalse(window.isMovable)

        let emptyChromePoint = tabRegion.convert(NSPoint(x: 180, y: 15), to: nil)
        let nextDown = makeMouseEvent(type: .leftMouseDown, location: emptyChromePoint, window: window)
        XCTAssertNil(
            beginOrContinueWindowMoveSuppressionSequenceForEvent(
                window: window,
                event: nextDown,
                pressedMouseButtons: 1
            ),
            "A fresh mouse-down must end stale tab suppression and re-check the actual hit target"
        )
        XCTAssertTrue(window.isMovable)
        XCTAssertFalse(isWindowDragSuppressed(window: window))
        XCTAssertNil(activeWindowMoveSuppressionSequenceReason(window: window))
    }

    @Test func testBonsplitPaneTabSuppressionLeavesEmptyTabChromeDraggable() {
        let (window, contentView) = makeWindowWithContentView()
        window.isMovable = true
        let tabRegion = FakeBonsplitTabItemRegionView(frame: NSRect(x: 20, y: 132, width: 240, height: 30))
        tabRegion.tabFrames = [CGRect(x: 8, y: 0, width: 96, height: 30)]
        contentView.addSubview(tabRegion)
        BonsplitTabItemHitRegionRegistry.register(tabRegion)
        defer { BonsplitTabItemHitRegionRegistry.unregister(tabRegion) }

        let emptyChromePoint = tabRegion.convert(NSPoint(x: 180, y: 15), to: nil)
        let event = makeMouseEvent(type: .leftMouseDown, location: emptyChromePoint, window: window)

        XCTAssertFalse(shouldSuppressWindowMoveForBonsplitPaneTabDrag(window: window, event: event))
        XCTAssertNil(windowMoveSuppressionReason(window: window, event: event))
    }
}
