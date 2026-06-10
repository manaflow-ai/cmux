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
final class TitlebarLeadingInsetPassthroughViewTests: XCTestCase {
    func testLeadingInsetViewDoesNotParticipateInHitTesting() {
        let view = TitlebarLeadingInsetPassthroughView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        XCTAssertNil(view.hitTest(NSPoint(x: 20, y: 10)))
    }

    func testLeadingInsetViewCannotMoveWindowViaMouseDown() {
        let view = TitlebarLeadingInsetPassthroughView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        XCTAssertFalse(view.mouseDownCanMoveWindow)
    }

    func testMainWindowHostingViewCannotMoveWindowViaMouseDown() {
        let view = MainWindowHostingView(rootView: Color.clear)
        XCTAssertFalse(
            view.mouseDownCanMoveWindow,
            "Main content must never become an implicit AppKit window-drag region; explicit titlebar chrome owns app-window dragging"
        )
    }

    func testMainWindowDragBehaviorRequiresExplicitDragZones() {
        let window = CmuxMainWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        window.isMovable = true
        window.isMovableByWindowBackground = true

        configureCmuxMainWindowDragBehavior(window)

        XCTAssertFalse(
            window.isMovable,
            "Main windows must not use native AppKit titlebar dragging because pane tabs live in the titlebar band"
        )
        XCTAssertFalse(window.isMovableByWindowBackground)

        let previous = withTemporaryWindowMovableEnabled(window: window) {
            XCTAssertTrue(window.isMovable)
        }

        XCTAssertEqual(previous, false)
        XCTAssertFalse(
            window.isMovable,
            "Explicit chrome drag zones may temporarily enable movement, but the main window must return to pane-tab-safe immovable state"
        )
    }
}


#endif
