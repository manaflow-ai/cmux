import XCTest
import AppKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


final class CommandPaletteBackNavigationTests: XCTestCase {
    func testBackspaceOnEmptyRenameInputReturnsToCommandList() {
        XCTAssertTrue(
            ContentView.commandPaletteShouldPopRenameInputOnDelete(
                renameDraft: "",
                modifiers: []
            )
        )
    }

    func testBackspaceWithRenameTextDoesNotReturnToCommandList() {
        XCTAssertFalse(
            ContentView.commandPaletteShouldPopRenameInputOnDelete(
                renameDraft: "Terminal 1",
                modifiers: []
            )
        )
    }

    func testModifiedBackspaceDoesNotReturnToCommandList() {
        XCTAssertFalse(
            ContentView.commandPaletteShouldPopRenameInputOnDelete(
                renameDraft: "",
                modifiers: [.control]
            )
        )
        XCTAssertFalse(
            ContentView.commandPaletteShouldPopRenameInputOnDelete(
                renameDraft: "",
                modifiers: [.command]
            )
        )
    }
}
