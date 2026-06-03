import XCTest
@testable import cmux_DEV

@MainActor
final class TerminalHostedViewContainerTests: XCTestCase {
    func testSetHostedViewReplacesPreviousHostedView() {
        let container = TerminalHostedViewContainer()
        let firstView = UIView()
        let secondView = UIView()

        container.setHostedView(firstView)
        XCTAssertIdentical(container.hostedView, firstView)
        XCTAssertEqual(container.subviews, [firstView])

        container.setHostedView(secondView)

        XCTAssertIdentical(container.hostedView, secondView)
        XCTAssertEqual(container.subviews, [secondView])
        XCTAssertNil(firstView.superview)
        XCTAssertIdentical(secondView.superview, container)
    }

    func testSetHostedViewWithSameViewDoesNotDuplicateSubviews() {
        let container = TerminalHostedViewContainer()
        let hostedView = UIView()

        container.setHostedView(hostedView)
        container.setHostedView(hostedView)

        XCTAssertEqual(container.subviews, [hostedView])
    }
}
