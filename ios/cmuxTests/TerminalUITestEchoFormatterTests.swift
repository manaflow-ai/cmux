import XCTest
@testable import cmux_DEV

final class TerminalUITestEchoFormatterTests: XCTestCase {
    func testPreviewUsesPrintableUTF8WhenAvailable() {
        XCTAssertEqual(
            TerminalUITestEchoFormatter.preview(for: Data("ls".utf8)),
            "ls"
        )
    }

    func testPreviewFormatsTabAndEscapeSequences() {
        XCTAssertEqual(
            TerminalUITestEchoFormatter.preview(for: Data([0x09])),
            "[TAB]"
        )
        XCTAssertEqual(
            TerminalUITestEchoFormatter.preview(for: Data([0x1B])),
            "[ESC]"
        )
    }
}
