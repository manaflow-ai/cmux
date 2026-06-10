import XCTest
import AppKit
import ObjectiveC.runtime

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - IME firstRect placement and sizing

/// Regression tests for IME candidate/preedit anchor rectangle reporting.
/// If width/height are discarded here, macOS can place preedit UI incorrectly.
final class CJKIMEFirstRectTests: XCTestCase {

    func testFirstRectUsesIMEProvidedWidthAndHeight() {
        let frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let view = GhosttyNSView(frame: frame)
        view.cellSize = CGSize(width: 10, height: 20)
        view.setIMEPointForTesting(x: 120, y: 240, width: 64, height: 26)

        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let content = NSView(frame: frame)
        window.contentView = content
        content.addSubview(view)
        view.frame = frame

        defer {
            view.clearIMEPointForTesting()
            window.orderOut(nil)
        }

        let rect = view.firstRect(forCharacterRange: NSRange(location: 0, length: 1), actualRange: nil)

        let expectedViewRect = NSRect(x: 120, y: frame.height - 240, width: 64, height: 26)
        let expectedScreenRect = window.convertToScreen(view.convert(expectedViewRect, to: nil))

        XCTAssertEqual(rect.origin.x, expectedScreenRect.origin.x, accuracy: 0.001)
        XCTAssertEqual(rect.origin.y, expectedScreenRect.origin.y, accuracy: 0.001)
        XCTAssertEqual(rect.width, 64, accuracy: 0.001)
        XCTAssertEqual(rect.height, 26, accuracy: 0.001)
    }

    func testFirstRectFallsBackToCellHeightWhenIMEHeightIsZero() {
        let frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        let view = GhosttyNSView(frame: frame)
        view.cellSize = CGSize(width: 9, height: 18)
        view.setIMEPointForTesting(x: 80, y: 120, width: 36, height: 0)

        let window = NSWindow(
            contentRect: NSRect(x: 40, y: 40, width: 640, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let content = NSView(frame: frame)
        window.contentView = content
        content.addSubview(view)
        view.frame = frame

        defer {
            view.clearIMEPointForTesting()
            window.orderOut(nil)
        }

        let rect = view.firstRect(forCharacterRange: NSRange(location: 0, length: 1), actualRange: nil)
        XCTAssertEqual(rect.width, 36, accuracy: 0.001)
        XCTAssertEqual(rect.height, 18, accuracy: 0.001)
    }

    func testFirstRectUsesZeroWidthForInsertionPointWithoutOffsettingCaretAnchor() {
        let frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        let view = GhosttyNSView(frame: frame)
        view.cellSize = CGSize(width: 9, height: 18)
        view.setIMEPointForTesting(x: 80, y: 120, width: 36, height: 24)

        let window = NSWindow(
            contentRect: NSRect(x: 40, y: 40, width: 640, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let content = NSView(frame: frame)
        window.contentView = content
        content.addSubview(view)
        view.frame = frame

        defer {
            view.clearIMEPointForTesting()
            window.orderOut(nil)
        }

        let rect = view.firstRect(forCharacterRange: NSRange(location: 5, length: 0), actualRange: nil)
        let expectedViewRect = NSRect(x: 80, y: frame.height - 120, width: 0, height: 24)
        let expectedScreenRect = window.convertToScreen(view.convert(expectedViewRect, to: nil))

        XCTAssertEqual(rect.origin.x, expectedScreenRect.origin.x, accuracy: 0.001)
        XCTAssertEqual(rect.origin.y, expectedScreenRect.origin.y, accuracy: 0.001)
        XCTAssertEqual(rect.width, 0, accuracy: 0.001)
        XCTAssertEqual(rect.height, 24, accuracy: 0.001)
    }

    func testDocumentVisibleRectUsesScreenCoordinates() {
        guard #available(macOS 14.0, *) else { return }

        let frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        let view = GhosttyNSView(frame: frame)

        let window = NSWindow(
            contentRect: NSRect(x: 40, y: 40, width: 640, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let content = NSView(frame: frame)
        window.contentView = content
        content.addSubview(view)
        view.frame = frame

        defer {
            window.orderOut(nil)
        }

        let expected = window.convertToScreen(view.convert(view.visibleRect, to: nil))
        let rect = view.documentVisibleRect

        XCTAssertEqual(rect.origin.x, expected.origin.x, accuracy: 0.001)
        XCTAssertEqual(rect.origin.y, expected.origin.y, accuracy: 0.001)
        XCTAssertEqual(rect.width, expected.width, accuracy: 0.001)
        XCTAssertEqual(rect.height, expected.height, accuracy: 0.001)
    }
}

