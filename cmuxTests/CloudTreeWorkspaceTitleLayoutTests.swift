import AppKit
import XCTest
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class CloudTreeWorkspaceTitleLayoutTests: XCTestCase {
    func testDisplayHostUsesVisibleCellWidth() {
        let cell = CloudTreeCellView(frame: NSRect(x: 0, y: 0, width: 700, height: 24))
        guard let host = cell.subviews.compactMap({ $0 as? CloudTreePassthroughHostingView }).first else {
            return XCTFail("Cloud tree cell should host a pass-through display view")
        }
        guard let trailingConstraint = cell.constraints.first(where: { constraint in
            (constraint.firstItem as? NSView) === host
                && constraint.firstAttribute == .trailing
                && (constraint.secondItem as? NSView) === cell
        }) else {
            return XCTFail("Cloud tree display host should have a trailing constraint")
        }

        XCTAssertEqual(trailingConstraint.relation, .equal)
        XCTAssertEqual(
            trailingConstraint.priority,
            NSLayoutConstraint.Priority(rawValue: NSLayoutConstraint.Priority.required.rawValue - 1)
        )
    }
}
