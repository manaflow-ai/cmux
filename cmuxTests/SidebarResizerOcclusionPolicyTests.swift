import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class SidebarResizerOcclusionPolicyTests: XCTestCase {
    func testDraggingBypassesPointerWindowGate() {
        XCTAssertTrue(
            SidebarResizerOcclusionPolicy.bandMayActivate(
                isDragging: true,
                isInDividerBand: false,
                pointerWindowNumber: nil,
                observedWindowNumber: 10
            )
        )
    }

    func testInBandSameWindowActivates() {
        XCTAssertTrue(
            SidebarResizerOcclusionPolicy.bandMayActivate(
                isDragging: false,
                isInDividerBand: true,
                pointerWindowNumber: 10,
                observedWindowNumber: 10
            )
        )
    }

    func testInBandDifferentWindowDoesNotActivate() {
        XCTAssertFalse(
            SidebarResizerOcclusionPolicy.bandMayActivate(
                isDragging: false,
                isInDividerBand: true,
                pointerWindowNumber: 11,
                observedWindowNumber: 10
            )
        )
    }

    func testInBandNilPointerWindowDoesNotActivate() {
        XCTAssertFalse(
            SidebarResizerOcclusionPolicy.bandMayActivate(
                isDragging: false,
                isInDividerBand: true,
                pointerWindowNumber: nil,
                observedWindowNumber: 10
            )
        )
    }

    func testOutOfBandDoesNotActivate() {
        XCTAssertFalse(
            SidebarResizerOcclusionPolicy.bandMayActivate(
                isDragging: false,
                isInDividerBand: false,
                pointerWindowNumber: 10,
                observedWindowNumber: 10
            )
        )
    }
}
