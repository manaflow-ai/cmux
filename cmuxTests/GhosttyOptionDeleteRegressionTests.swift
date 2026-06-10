import XCTest
import AppKit
import ObjectiveC.runtime

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


@MainActor
final class GhosttyOptionDeleteRegressionTests: XCTestCase {
    func testOptionDeletePreservesAltAsModifierForWordDelete() {
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

        var pressEvent: ghostty_input_key_s?
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = { keyEvent in
            guard keyEvent.action == GHOSTTY_ACTION_PRESS, keyEvent.keycode == 51 else { return }
            pressEvent = keyEvent
        }

        let sent = hostedView.debugSendSyntheticKeyPressAndReleaseForUITest(
            characters: "\u{7F}",
            charactersIgnoringModifiers: "\u{7F}",
            keyCode: 51,
            modifierFlags: [.option]
        )
        XCTAssertTrue(sent, "Expected synthetic Option+Delete event to be dispatched")

        guard let pressEvent else {
            XCTFail("Expected to capture Option+Delete key event")
            return
        }

        XCTAssertEqual(pressEvent.action, GHOSTTY_ACTION_PRESS)
        XCTAssertEqual(pressEvent.keycode, 51)
        XCTAssertEqual(
            pressEvent.mods.rawValue & GHOSTTY_MODS_ALT.rawValue,
            GHOSTTY_MODS_ALT.rawValue,
            "Option+Delete should preserve Alt on the raw key event"
        )
        XCTAssertEqual(
            pressEvent.consumed_mods.rawValue,
            GHOSTTY_MODS_NONE.rawValue,
            "Non-printing delete should not consume Option as text input"
        )
        XCTAssertNil(pressEvent.text, "Delete should be encoded as a key event, not forwarded as DEL text")
    }
}
