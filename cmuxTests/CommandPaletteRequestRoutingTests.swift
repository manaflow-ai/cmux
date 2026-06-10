import XCTest
import AppKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


@MainActor
final class CommandPaletteRequestRoutingTests: XCTestCase {
    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
    }

    func testRequestedWindowTargetsOnlyMatchingObservedWindow() {
        let windowA = makeWindow()
        let windowB = makeWindow()

        XCTAssertTrue(
            ContentView.shouldHandleCommandPaletteRequest(
                observedWindow: windowA,
                requestedWindow: windowA,
                keyWindow: windowA,
                mainWindow: windowA
            )
        )
        XCTAssertFalse(
            ContentView.shouldHandleCommandPaletteRequest(
                observedWindow: windowB,
                requestedWindow: windowA,
                keyWindow: windowA,
                mainWindow: windowA
            )
        )
    }

    func testNilRequestedWindowFallsBackToKeyWindow() {
        let key = makeWindow()
        let other = makeWindow()

        XCTAssertTrue(
            ContentView.shouldHandleCommandPaletteRequest(
                observedWindow: key,
                requestedWindow: nil,
                keyWindow: key,
                mainWindow: nil
            )
        )
        XCTAssertFalse(
            ContentView.shouldHandleCommandPaletteRequest(
                observedWindow: other,
                requestedWindow: nil,
                keyWindow: key,
                mainWindow: nil
            )
        )
    }

    func testNilRequestedAndKeyFallsBackToMainWindow() {
        let main = makeWindow()
        let other = makeWindow()

        XCTAssertTrue(
            ContentView.shouldHandleCommandPaletteRequest(
                observedWindow: main,
                requestedWindow: nil,
                keyWindow: nil,
                mainWindow: main
            )
        )
        XCTAssertFalse(
            ContentView.shouldHandleCommandPaletteRequest(
                observedWindow: other,
                requestedWindow: nil,
                keyWindow: nil,
                mainWindow: main
            )
        )
    }

    func testNoObservedWindowNeverHandlesRequest() {
        XCTAssertFalse(
            ContentView.shouldHandleCommandPaletteRequest(
                observedWindow: nil,
                requestedWindow: makeWindow(),
                keyWindow: makeWindow(),
                mainWindow: makeWindow()
            )
        )
    }
}

