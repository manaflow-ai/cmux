import XCTest
import AppKit
import ObjectiveC.runtime

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - External committed-text sanitization

final class ExternalCommittedTextSanitizationTests: XCTestCase {
    func testStripsLeadingCSISequenceFromExternalCommittedText() {
        XCTAssertEqual(
            GhosttyNSView.sanitizeExternalCommittedText("\u{1B}[Chello"),
            "hello"
        )
    }

    func testStripsLeadingC1CSISequenceFromExternalCommittedText() {
        XCTAssertEqual(
            GhosttyNSView.sanitizeExternalCommittedText("\u{009B}1;5Chello"),
            "hello"
        )
    }

    func testStripsMultipleLeadingControlAndEscapeSequences() {
        XCTAssertEqual(
            GhosttyNSView.sanitizeExternalCommittedText("\u{1B}[1;5C\u{1B}OChello"),
            "hello"
        )
    }

    func testLeavesLiteralBracketPrefixedTextUntouched() {
        XCTAssertEqual(
            GhosttyNSView.sanitizeExternalCommittedText("[Code] review"),
            "[Code] review"
        )
    }

    func testPreservesLeadingControlBytesUsedByAutomation() {
        XCTAssertEqual(
            GhosttyNSView.sanitizeExternalCommittedText("\n"),
            "\n"
        )
        XCTAssertEqual(
            GhosttyNSView.sanitizeExternalCommittedText("\tfoo"),
            "\tfoo"
        )
    }
}

