import AppKit
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Cloud tree workspace title layout")
struct CloudTreeWorkspaceTitleLayoutTests {
    @Test("the hosted row content reaches the cell trailing edge")
    func displayHostUsesVisibleCellWidth() throws {
        let cell = CloudTreeCellView(frame: NSRect(x: 0, y: 0, width: 700, height: 24))
        let host = try #require(cell.subviews.compactMap { $0 as? CloudTreePassthroughHostingView }.first)
        let trailingConstraint = try #require(cell.constraints.first { constraint in
            (constraint.firstItem as? NSView) === host
                && constraint.firstAttribute == .trailing
                && (constraint.secondItem as? NSView) === cell
        })

        #expect(trailingConstraint.relation == .equal)
    }
}
