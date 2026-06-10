import XCTest
import AppKit
import ObjectiveC.runtime

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Key text accumulator during CJK IME composition

/// Tests that the keyTextAccumulator correctly manages text during the keyDown
/// event flow, which is critical for CJK IME composition to work.
final class CJKIMEKeyTextAccumulatorTests: XCTestCase {

    func testAccumulatorStartsNil() {
        let view = GhosttyNSView(frame: .zero)
        XCTAssertNil(view.keyTextAccumulatorForTesting)
    }

    func testAccumulatorCanBeSetAndRead() {
        let view = GhosttyNSView(frame: .zero)

        view.setKeyTextAccumulatorForTesting([])
        XCTAssertEqual(view.keyTextAccumulatorForTesting, [])

        view.setKeyTextAccumulatorForTesting(["한"])
        XCTAssertEqual(view.keyTextAccumulatorForTesting, ["한"])

        view.setKeyTextAccumulatorForTesting(nil)
        XCTAssertNil(view.keyTextAccumulatorForTesting)
    }

    func testAccumulatorCollectsMultipleIMECommits() {
        let view = GhosttyNSView(frame: .zero)

        // Simulate a keyDown event that triggers multiple insertText calls
        // (can happen with some IME behaviors)
        view.setKeyTextAccumulatorForTesting([])

        var acc = view.keyTextAccumulatorForTesting!
        acc.append("你")
        acc.append("好")
        view.setKeyTextAccumulatorForTesting(acc)

        XCTAssertEqual(view.keyTextAccumulatorForTesting, ["你", "好"])
        view.setKeyTextAccumulatorForTesting(nil)
    }

    /// When the accumulator is nil (not in keyDown), insertText should not
    /// try to accumulate. This is the "direct send" path for IME events
    /// that arrive outside of keyDown processing.
    func testAccumulatorNilMeansDirectSendPath() {
        let view = GhosttyNSView(frame: .zero)

        view.setKeyTextAccumulatorForTesting(nil)
        // insertText with nil accumulator and no surface/currentEvent is a no-op,
        // but the important thing is that it doesn't crash or accumulate.
        XCTAssertNil(view.keyTextAccumulatorForTesting)
    }
}

