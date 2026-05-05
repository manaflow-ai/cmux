import CoreGraphics
import XCTest
@testable import cmux_ios

final class CmxTerminalLayoutTests: XCTestCase {
    func testKeyboardOverlapUsesActualKeyboardGuideIntersection() {
        let container = CGRect(x: 0, y: 0, width: 390, height: 844)

        XCTAssertEqual(
            CmxKeyboardOverlap.visibleHeight(
                containerBounds: container,
                keyboardFrame: CGRect(x: 0, y: 844, width: 390, height: 0)
            ),
            0
        )
        XCTAssertEqual(
            CmxKeyboardOverlap.visibleHeight(
                containerBounds: container,
                keyboardFrame: CGRect(x: 0, y: 544, width: 390, height: 300)
            ),
            300
        )
    }

    func testKeyboardOverlapIgnoresHiddenFullContainerGuideFrame() {
        XCTAssertEqual(
            CmxKeyboardOverlap.visibleHeight(
                containerBounds: CGRect(x: 0, y: 100, width: 390, height: 400),
                keyboardFrame: CGRect(x: 0, y: 0, width: 390, height: 900)
            ),
            0
        )
    }

    func testKeyboardOverlapIgnoresFloatingFramesForBottomPadding() {
        XCTAssertEqual(
            CmxKeyboardOverlap.visibleHeight(
                containerBounds: CGRect(x: 0, y: 0, width: 390, height: 844),
                keyboardFrame: CGRect(x: 80, y: 320, width: 240, height: 160)
            ),
            0
        )
    }

    func testKeyboardOverlapIgnoresHomeIndicatorGuideHeight() {
        XCTAssertEqual(
            CmxKeyboardOverlap.visibleHeight(
                containerBounds: CGRect(x: 0, y: 0, width: 390, height: 844),
                keyboardFrame: CGRect(x: 0, y: 810, width: 390, height: 34)
            ),
            0
        )
    }

    func testTerminalVisibleHeightShrinksByKeyboardOverlap() {
        XCTAssertEqual(
            CmxTerminalVisibleBounds.height(totalHeight: 1_290, keyboardOverlap: 0),
            1_290
        )
        XCTAssertEqual(
            CmxTerminalVisibleBounds.height(totalHeight: 1_290, keyboardOverlap: 441),
            849
        )
    }

    func testTerminalVisibleHeightClampsOutOfRangeKeyboardOverlap() {
        XCTAssertEqual(
            CmxTerminalVisibleBounds.height(totalHeight: 800, keyboardOverlap: -30),
            800
        )
        XCTAssertEqual(
            CmxTerminalVisibleBounds.height(totalHeight: 800, keyboardOverlap: 900),
            0
        )
    }
}
