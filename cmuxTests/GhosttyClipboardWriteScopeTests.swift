import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class GhosttyClipboardWriteScopeTests: XCTestCase {
    func testAllowsSelectionClipboardWithoutFocusGate() {
        XCTAssertTrue(
            shouldAllowGhosttyClipboardWrite(
                location: GHOSTTY_CLIPBOARD_SELECTION,
                scope: nil
            )
        )
    }

    func testAllowsSystemClipboardForFrontmostFocusedSurface() {
        XCTAssertTrue(
            shouldAllowGhosttyClipboardWrite(
                location: GHOSTTY_CLIPBOARD_STANDARD,
                scope: GhosttySystemClipboardWriteScope(
                    appIsActive: true,
                    windowIsKey: true,
                    tabIsSelected: true,
                    surfaceIsFocused: true
                )
            )
        )
    }

    func testDeniesSystemClipboardForInactiveApp() {
        XCTAssertFalse(
            shouldAllowGhosttyClipboardWrite(
                location: GHOSTTY_CLIPBOARD_STANDARD,
                scope: GhosttySystemClipboardWriteScope(
                    appIsActive: false,
                    windowIsKey: true,
                    tabIsSelected: true,
                    surfaceIsFocused: true
                )
            )
        )
    }

    func testDeniesSystemClipboardForUnfocusedSurface() {
        XCTAssertFalse(
            shouldAllowGhosttyClipboardWrite(
                location: GHOSTTY_CLIPBOARD_STANDARD,
                scope: GhosttySystemClipboardWriteScope(
                    appIsActive: true,
                    windowIsKey: true,
                    tabIsSelected: true,
                    surfaceIsFocused: false
                )
            )
        )
    }
}
