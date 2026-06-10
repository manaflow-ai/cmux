import XCTest
import AppKit
import ObjectiveC.runtime

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


@MainActor
final class GhosttyBackquoteRegressionTests: XCTestCase {
    func testShiftBackquoteEscFallbackSendsLiteralTilde() {
        _ = NSApplication.shared

        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        let hostedView = surface.hostedView

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer {
            GhosttyNSView.debugGhosttySurfaceKeyEventObserver = nil
            window.orderOut(nil)
        }

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }
        hostedView.frame = contentView.bounds
        hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostedView)

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        hostedView.setVisibleInUI(true)
        hostedView.setActive(true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        var pressText: String?
        var pressUnshiftedCodepoint: UInt32?
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = { keyEvent in
            guard keyEvent.action == GHOSTTY_ACTION_PRESS, keyEvent.keycode == 50 else { return }
            pressUnshiftedCodepoint = keyEvent.unshifted_codepoint
            if let text = keyEvent.text {
                pressText = String(cString: text)
            } else {
                pressText = nil
            }
        }

        let sent = hostedView.debugSendSyntheticKeyPressAndReleaseForUITest(
            characters: "\u{1B}",
            charactersIgnoringModifiers: "`",
            keyCode: 50,
            modifierFlags: [.shift]
        )
        XCTAssertTrue(sent, "Expected synthetic Shift+backquote event to be dispatched")
        XCTAssertEqual(pressText, "~")
        XCTAssertEqual(pressUnshiftedCodepoint, "`".unicodeScalars.first?.value)
    }
}

