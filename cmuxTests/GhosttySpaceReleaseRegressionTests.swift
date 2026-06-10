import XCTest
import AppKit
import ObjectiveC.runtime

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Space release regression (Codex hold-to-talk in cmux)

@MainActor
final class GhosttySpaceReleaseRegressionTests: XCTestCase {
    func testSyntheticSpaceReleaseCarriesUnshiftedCodepoint() {
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

        var releaseEvent: ghostty_input_key_s?
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = { keyEvent in
            if keyEvent.action == GHOSTTY_ACTION_RELEASE, keyEvent.keycode == 49 {
                releaseEvent = keyEvent
            }
        }

        let sent = hostedView.debugSendSyntheticKeyPressAndReleaseForUITest(
            characters: " ",
            charactersIgnoringModifiers: " ",
            keyCode: 49
        )
        XCTAssertTrue(sent, "Expected synthetic Space key press/release to be dispatched")

        guard let releaseEvent else {
            XCTFail("Expected to capture synthetic Space key release event")
            return
        }

        XCTAssertEqual(releaseEvent.action, GHOSTTY_ACTION_RELEASE)
        XCTAssertEqual(releaseEvent.keycode, 49)
        XCTAssertEqual(releaseEvent.unshifted_codepoint, " ".unicodeScalars.first!.value)
        XCTAssertEqual(releaseEvent.consumed_mods.rawValue, GHOSTTY_MODS_NONE.rawValue)
        XCTAssertFalse(releaseEvent.composing)
        XCTAssertNil(releaseEvent.text)
    }
}

