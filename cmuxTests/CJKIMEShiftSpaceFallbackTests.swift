import XCTest
import AppKit
import ObjectiveC.runtime

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Shift+Space fallback suppression (IME source-switch shortcut)

final class CJKIMEShiftSpaceFallbackTests: XCTestCase {
    func testSuppressesShiftSpaceFallbackWhenNoMarkedTextAndNoIMECommit() {
        let view = GhosttyNSView(frame: .zero)
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.shift],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: " ",
            charactersIgnoringModifiers: " ",
            isARepeat: false,
            keyCode: 49
        ) else {
            XCTFail("Failed to create Shift+Space event")
            return
        }

        XCTAssertTrue(
            view.shouldSuppressShiftSpaceFallbackTextForTesting(event: event, markedTextBefore: false),
            "Shift+Space should suppress synthesized space fallback when IME did not commit text"
        )
    }

    func testDoesNotSuppressRegularSpaceFallback() {
        let view = GhosttyNSView(frame: .zero)
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: " ",
            charactersIgnoringModifiers: " ",
            isARepeat: false,
            keyCode: 49
        ) else {
            XCTFail("Failed to create Space event")
            return
        }

        XCTAssertFalse(
            view.shouldSuppressShiftSpaceFallbackTextForTesting(event: event, markedTextBefore: false),
            "Only Shift+Space should be suppressed"
        )
    }
}

