import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// cmux's main window hosts SwiftUI directly, so its content view is flipped
/// while the window frame is not. `NSView.hitTest(_:)` takes a point in the
/// receiver's superview space; a window point converted into the flipped
/// content view and handed to `hitTest` is mirrored vertically (issue 12152:
/// the file editor at the bottom answered for presses on the tab strip at
/// the top). Every window-space hit-test goes through `cmuxHitTest`.
@MainActor
@Suite("Window-point hit testing")
struct WindowPointHitTestTests {
    private final class FlippedContentView: NSView {
        override var isFlipped: Bool { true }
    }

    @Test("A flipped content view answers the view under the window point, not its mirror image")
    func flippedContentViewAnswersTheViewUnderThePoint() throws {
        let window = try Self.makeWindow()
        defer { window.orderOut(nil) }
        let contentView = try #require(window.contentView)
        // Flipped coordinates: y grows downward, so `top` is at the top of the window.
        let top = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 40))
        let bottom = NSView(frame: NSRect(x: 0, y: 40, width: 240, height: 160))
        contentView.addSubview(top)
        contentView.addSubview(bottom)
        window.makeKeyAndOrderFront(nil)

        let topPoint = top.convert(NSPoint(x: 120, y: 20), to: nil)
        let bottomPoint = bottom.convert(NSPoint(x: 120, y: 80), to: nil)
        #expect(contentView.cmuxHitTest(windowPoint: topPoint) === top)
        #expect(contentView.cmuxHitTest(windowPoint: bottomPoint) === bottom)
    }

    @Test("Folder-drag window-move suppression sees the folder icon under the press, not its mirror image")
    func folderDragSuppressionUsesTheViewUnderThePress() throws {
        let window = try Self.makeWindow()
        defer { window.orderOut(nil) }
        let contentView = try #require(window.contentView)
        let folder = DraggableFolderNSView(directory: NSTemporaryDirectory())
        folder.frame = NSRect(x: 20, y: 0, width: 40, height: 40)
        let filler = NSView(frame: NSRect(x: 0, y: 40, width: 240, height: 160))
        contentView.addSubview(folder)
        contentView.addSubview(filler)
        window.isMovable = true
        window.makeKeyAndOrderFront(nil)

        // Press in the icon's right half: its frame starts at x = 20, so a
        // superview-space point there lies outside the icon's own bounds and
        // exposes a hit test that compares the wrong coordinate space.
        let folderPress = try Self.mouseDown(window: window, at: folder.convert(NSPoint(x: 30, y: 20), to: nil))
        let fillerPress = try Self.mouseDown(window: window, at: filler.convert(NSPoint(x: 40, y: 80), to: nil))
        #expect(shouldSuppressWindowMoveForFolderDrag(window: window, event: folderPress))
        #expect(!shouldSuppressWindowMoveForFolderDrag(window: window, event: fillerPress))
    }

    private static func makeWindow() throws -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = FlippedContentView(frame: NSRect(x: 0, y: 0, width: 240, height: 200))
        return window
    }

    private static func mouseDown(window: NSWindow, at windowPoint: NSPoint) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: windowPoint,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
    }
}
