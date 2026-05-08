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

    func testKeyboardOverlapAcceptsBottomKeyboardWithAccessoryGap() {
        XCTAssertEqual(
            CmxKeyboardOverlap.visibleHeight(
                containerBounds: CGRect(x: 0, y: 0, width: 390, height: 844),
                keyboardFrame: CGRect(x: 0, y: 544, width: 390, height: 256)
            ),
            300
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

    func testTerminalBoundsOverlayBorderUsesMinimalSolidLineOnMobile() {
        XCTAssertEqual(TerminalVisibleBoundsOverlayStyle.borderWidth, 1)
        XCTAssertTrue(
            TerminalVisibleBoundsOverlayStyle.showsBorder(
                pointSize: CGSize(width: 402, height: 774)
            )
        )
    }

    func testTerminalBoundsOverlayBorderMatchesForcedGridSize() {
        let size = TerminalVisibleBoundsOverlayStyle.borderSize(
            pointSize: CGSize(width: 768, height: 930),
            gridSize: TerminalGridSize(columns: 29, rows: 25, pixelWidth: 990, pixelHeight: 1_200),
            displayScale: 3
        )

        XCTAssertEqual(size.width, 330)
        XCTAssertEqual(size.height, 400)
    }

    func testTerminalBoundsOverlayDoesNotDrawFullSurfaceWhileGridIsPending() {
        let size = TerminalVisibleBoundsOverlayStyle.borderSize(
            pointSize: CGSize(width: 768, height: 930),
            gridSize: nil,
            renderSize: CmxTerminalSize(cols: 30, rows: 24),
            displayScale: 2
        )

        XCTAssertEqual(size, .zero)
    }

    func testTerminalBoundsOverlayBorderTracksRenderClampInsideLargerSurface() {
        let size = TerminalVisibleBoundsOverlayStyle.borderSize(
            pointSize: CGSize(width: 768, height: 930),
            gridSize: TerminalGridSize(columns: 53, rows: 52, pixelWidth: 1_986, pixelHeight: 2_600),
            renderSize: CmxTerminalSize(cols: 30, rows: 30),
            displayScale: 2
        )

        XCTAssertEqual(size.width, 563)
        XCTAssertEqual(size.height, 750)
    }

    func testTerminalBoundsOverlayLabelAvoidsCoveringRailsWhenThereIsNoSpareRoom() {
        XCTAssertNil(
            TerminalVisibleBoundsOverlayStyle.labelOrigin(
                pointSize: CGSize(width: 402, height: 774),
                borderSize: .zero
            )
        )
        XCTAssertNil(
            TerminalVisibleBoundsOverlayStyle.labelOrigin(
                pointSize: CGSize(width: 402, height: 774),
                borderSize: CGSize(width: 402, height: 774)
            )
        )
        XCTAssertEqual(
            TerminalVisibleBoundsOverlayStyle.labelOrigin(
                pointSize: CGSize(width: 768, height: 930),
                borderSize: CGSize(width: 330, height: 400)
            ),
            CGPoint(x: 334, y: 0)
        )
    }
}
