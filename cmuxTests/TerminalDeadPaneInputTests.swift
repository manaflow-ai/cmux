import XCTest
import AppKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class TerminalDeadPaneInputTests: XCTestCase {
    private struct HostedTerminal {
        let surface: TerminalSurface
        let hostedView: GhosttySurfaceScrollView
        let surfaceView: GhosttyNSView
        let window: NSWindow
    }

    func testKeyDownAfterChildExitDoesNotRenderTypedBytes() throws {
#if DEBUG
        let hostedTerminal = try makeHostedTerminal(initialInput: "exec cat\r")
        defer {
            hostedTerminal.surface.teardownSurface()
            hostedTerminal.window.orderOut(nil)
        }

        let childExited = expectation(description: "child exited")
        let previousObserver = GhosttyApp.debugShowChildExitedActionObserver
        GhosttyApp.debugShowChildExitedActionObserver = { tabId, surfaceId in
            previousObserver?(tabId, surfaceId)
            guard surfaceId == hostedTerminal.surface.id else { return }
            childExited.fulfill()
        }
        defer { GhosttyApp.debugShowChildExitedActionObserver = previousObserver }

        XCTAssertTrue(hostedTerminal.window.makeFirstResponder(hostedTerminal.surfaceView))
        XCTAssertTrue(hostedTerminal.hostedView.sendSyntheticCtrlDForUITest())
        wait(for: [childExited], timeout: 2.0)

        let sentinel = "cmuxdeadpaneinput3998"
        XCTAssertFalse(try readSurfaceText(from: hostedTerminal.surface).contains(sentinel))

        var postExitGhosttyKeyEvents = 0
        let previousKeyObserver = GhosttyNSView.debugGhosttySurfaceKeyEventObserver
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = { keyEvent in
            previousKeyObserver?(keyEvent)
            postExitGhosttyKeyEvents += 1
        }
        defer { GhosttyNSView.debugGhosttySurfaceKeyEventObserver = previousKeyObserver }

        let directInsertSentinel = "cmuxdirectdeadpane3998"
        hostedTerminal.surfaceView.insertText(
            directInsertSentinel,
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        XCTAssertEqual(
            postExitGhosttyKeyEvents,
            0,
            "Direct committed text after child exit should not reach Ghostty input"
        )

        for scalar in sentinel.unicodeScalars {
            XCTAssertTrue(
                hostedTerminal.hostedView.debugSendSyntheticKeyPressAndReleaseForUITest(
                    characters: String(scalar),
                    charactersIgnoringModifiers: String(scalar),
                    keyCode: 0
                )
            )
        }

        let afterInput = try readSurfaceText(from: hostedTerminal.surface)
        XCTAssertEqual(
            postExitGhosttyKeyEvents,
            0,
            "Synthetic key events after child exit should not reach Ghostty input"
        )
        XCTAssertFalse(
            afterInput.contains(sentinel),
            "Terminal input after child exit should be dropped before Ghostty can render it into the cell grid"
        )
        XCTAssertFalse(
            afterInput.contains(directInsertSentinel),
            "Direct committed text after child exit should be dropped before Ghostty can render it into the cell grid"
        )
#else
        throw XCTSkip("Debug-only regression test")
#endif
    }

#if DEBUG
    private func makeHostedTerminal(initialInput: String) throws -> HostedTerminal {
        _ = NSApplication.shared
        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil,
            initialInput: initialInput
        )
        let hostedView = surface.hostedView
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let contentView = try XCTUnwrap(window.contentView)
        hostedView.frame = contentView.bounds
        hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostedView)
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        hostedView.setVisibleInUI(true)
        hostedView.setActive(true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        return HostedTerminal(
            surface: surface,
            hostedView: hostedView,
            surfaceView: try XCTUnwrap(findGhosttyNSView(in: hostedView)),
            window: window
        )
    }

    private func findGhosttyNSView(in view: NSView) -> GhosttyNSView? {
        if let ghosttyView = view as? GhosttyNSView {
            return ghosttyView
        }
        for subview in view.subviews {
            if let found = findGhosttyNSView(in: subview) {
                return found
            }
        }
        return nil
    }

    private func readSurfaceText(from terminalSurface: TerminalSurface) throws -> String {
        let surface = try XCTUnwrap(terminalSurface.surface)
        let topLeft = ghostty_point_s(
            tag: GHOSTTY_POINT_SCREEN,
            coord: GHOSTTY_POINT_COORD_TOP_LEFT,
            x: 0,
            y: 0
        )
        let bottomRight = ghostty_point_s(
            tag: GHOSTTY_POINT_SCREEN,
            coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
            x: 0,
            y: 0
        )
        let selection = ghostty_selection_s(
            top_left: topLeft,
            bottom_right: bottomRight,
            rectangle: false
        )

        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else {
            return ""
        }
        defer { ghostty_surface_free_text(surface, &text) }

        guard let ptr = text.text, text.text_len > 0 else {
            return ""
        }
        return String(decoding: Data(bytes: ptr, count: Int(text.text_len)), as: UTF8.self)
    }
#endif
}
