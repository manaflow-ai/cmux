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
final class FolderWindowMoveSuppressionTests: XCTestCase {
    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
    }

    func testSuppressionTracksMovableWindowWithoutChangingMovability() {
        let window = makeWindow()
        window.isMovable = true

        let depth = beginWindowDragSuppression(window: window)

        XCTAssertEqual(depth, 1)
        XCTAssertTrue(isWindowDragSuppressed(window: window))
        XCTAssertTrue(window.isMovable)
    }

    func testSuppressionTracksImmovableWindowWithoutChangingMovability() {
        let window = makeWindow()
        window.isMovable = false

        let depth = beginWindowDragSuppression(window: window)

        XCTAssertEqual(depth, 1)
        XCTAssertTrue(isWindowDragSuppressed(window: window))
        XCTAssertFalse(window.isMovable)
    }

    func testEndingSuppressionDoesNotRestoreStaleMovability() {
        let window = makeWindow()
        window.isMovable = false

        XCTAssertEqual(beginWindowDragSuppression(window: window), 1)
        XCTAssertFalse(window.isMovable)

        window.isMovable = true

        XCTAssertEqual(endWindowDragSuppression(window: window), 0)
        XCTAssertFalse(isWindowDragSuppressed(window: window))
        XCTAssertTrue(window.isMovable)
    }

    func testClearWindowDragSuppressionRemovesAllDepth() {
        let window = makeWindow()
        window.isMovable = false

        XCTAssertEqual(beginWindowDragSuppression(window: window), 1)
        XCTAssertEqual(beginWindowDragSuppression(window: window), 2)
        XCTAssertEqual(windowDragSuppressionDepth(window: window), 2)

        XCTAssertEqual(clearWindowDragSuppression(window: window), 0)
        XCTAssertEqual(windowDragSuppressionDepth(window: window), 0)
        XCTAssertFalse(window.isMovable)
    }

    func testClearWindowDragSuppressionFinishesActiveMoveSequence() {
        let window = makeWindow()
        window.isMovable = true

        XCTAssertEqual(
            beginWindowMoveSuppressionSequence(window: window, reason: .bonsplitPaneTabDrag),
            .bonsplitPaneTabDrag
        )
        XCTAssertFalse(window.isMovable)
        XCTAssertEqual(activeWindowMoveSuppressionSequenceReason(window: window), .bonsplitPaneTabDrag)

        XCTAssertEqual(clearWindowDragSuppression(window: window), 0)

        XCTAssertNil(activeWindowMoveSuppressionSequenceReason(window: window))
        XCTAssertEqual(windowDragSuppressionDepth(window: window), 0)
        XCTAssertFalse(isWindowDragSuppressed(window: window))
        XCTAssertTrue(window.isMovable)
    }

    func testWindowDragSuppressionDepthLifecycle() {
        let window = makeWindow()
        XCTAssertEqual(windowDragSuppressionDepth(window: window), 0)
        XCTAssertFalse(isWindowDragSuppressed(window: window))

        XCTAssertEqual(beginWindowDragSuppression(window: window), 1)
        XCTAssertEqual(windowDragSuppressionDepth(window: window), 1)
        XCTAssertTrue(isWindowDragSuppressed(window: window))

        XCTAssertEqual(endWindowDragSuppression(window: window), 0)
        XCTAssertEqual(windowDragSuppressionDepth(window: window), 0)
        XCTAssertFalse(isWindowDragSuppressed(window: window))
    }

    func testWindowDragSuppressionIsReferenceCounted() {
        let window = makeWindow()
        XCTAssertEqual(beginWindowDragSuppression(window: window), 1)
        XCTAssertEqual(beginWindowDragSuppression(window: window), 2)
        XCTAssertEqual(windowDragSuppressionDepth(window: window), 2)
        XCTAssertTrue(isWindowDragSuppressed(window: window))

        XCTAssertEqual(endWindowDragSuppression(window: window), 1)
        XCTAssertEqual(windowDragSuppressionDepth(window: window), 1)
        XCTAssertTrue(isWindowDragSuppressed(window: window))

        XCTAssertEqual(endWindowDragSuppression(window: window), 0)
        XCTAssertEqual(windowDragSuppressionDepth(window: window), 0)
        XCTAssertFalse(isWindowDragSuppressed(window: window))
    }

    func testTemporaryWindowMovableEnableRestoresImmovableWindow() {
        let window = makeWindow()
        window.isMovable = false

        let previous = withTemporaryWindowMovableEnabled(window: window) {
            XCTAssertTrue(window.isMovable)
        }

        XCTAssertEqual(previous, false)
        XCTAssertFalse(window.isMovable)
    }

    func testTemporaryWindowMovableEnablePreservesMovableWindow() {
        let window = makeWindow()
        window.isMovable = true

        let previous = withTemporaryWindowMovableEnabled(window: window) {
            XCTAssertTrue(window.isMovable)
        }

        XCTAssertEqual(previous, true)
        XCTAssertTrue(window.isMovable)
    }
}


#endif
