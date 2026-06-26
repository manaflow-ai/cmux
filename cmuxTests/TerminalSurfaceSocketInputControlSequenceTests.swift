@preconcurrency import XCTest
import Foundation

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class TerminalSurfaceSocketInputControlSequenceTests: XCTestCase {
    /// Verifies CPR/DSR CSI sequences are queued as terminal output bytes instead of literal shell input.
    func testColdSocketInputQueuesCSIReportsAsRawTerminalBytes() {
        for sequence in ["\u{1B}[6n", "\u{1B}[50;36R"] {
            let panel = TerminalPanel(workspaceId: UUID())

            panel.surface.releaseSurfaceForTesting()
            XCTAssertTrue(panel.surface.sendInput(sequence))

            let pending = panel.surface.debugPendingSocketInputForTesting()
            XCTAssertEqual(
                pending.keyEvents,
                0,
                "CSI reports must not be split into Escape key events plus literal text."
            )
            XCTAssertEqual(
                pending.inputTextItems,
                0,
                "CSI reports must bypass committed text input so Ghostty consumes them as terminal control sequences."
            )
            XCTAssertEqual(
                pending.pasteTextItems,
                0,
                "CSI reports must bypass paste input so they are not echoed by the shell."
            )
            XCTAssertEqual(
                pending.processOutputItems,
                1,
                "CSI reports must be queued as one terminal output payload."
            )
            XCTAssertEqual(pending.bytes, sequence.utf8.count)
        }
    }
}
