import AppKit
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class GhosttyTerminalViewVisibilityPolicyTests: XCTestCase {
    func testImmediateStateUpdateAllowedWhenDesiredStateIsHidden() {
        XCTAssertTrue(
            GhosttyTerminalView.shouldApplyImmediateHostedStateUpdate(
                desiredVisibleInUI: false,
                hostedViewHasSuperview: true,
                isBoundToCurrentHost: false
            )
        )
    }

    func testImmediateStateUpdateAllowedWhenBoundToCurrentHost() {
        XCTAssertTrue(
            GhosttyTerminalView.shouldApplyImmediateHostedStateUpdate(
                desiredVisibleInUI: true,
                hostedViewHasSuperview: true,
                isBoundToCurrentHost: true
            )
        )
    }

    func testImmediateStateUpdateSkippedForStaleHostBoundElsewhere() {
        XCTAssertFalse(
            GhosttyTerminalView.shouldApplyImmediateHostedStateUpdate(
                desiredVisibleInUI: true,
                hostedViewHasSuperview: true,
                isBoundToCurrentHost: false
            )
        )
    }

    func testImmediateStateUpdateAllowedWhenUnboundAndNotAttachedAnywhere() {
        XCTAssertTrue(
            GhosttyTerminalView.shouldApplyImmediateHostedStateUpdate(
                desiredVisibleInUI: true,
                hostedViewHasSuperview: false,
                isBoundToCurrentHost: false
            )
        )
    }

    func testInteractiveGeometryResizeUsesImmediatePortalSyncDecision() {
        XCTAssertTrue(
            GhosttyTerminalView.shouldSynchronizePortalGeometryImmediately(
                hostInLiveResize: false,
                windowInLiveResize: false,
                interactiveGeometryResizeActive: true
            ),
            "Interactive resize should use the immediate portal sync path"
        )
    }

    func testNonInteractiveGeometryResizeUsesCoalescedPortalSyncDecision() {
        XCTAssertFalse(
            GhosttyTerminalView.shouldSynchronizePortalGeometryImmediately(
                hostInLiveResize: false,
                windowInLiveResize: false,
                interactiveGeometryResizeActive: false
            ),
            "Keyboard sidebar toggles should use coalesced portal sync instead of consuming partial layout frames"
        )
    }

    func testPortalFrameUsesBonsplitPaneWidthWhenAnchorIsAnimatedNarrower() {
        let frame = TerminalPortalGeometryFramePolicy.portalFrameInWindow(
            anchorFrame: NSRect(x: 200, y: 0, width: 762.5, height: 644),
            paneContainerFrame: NSRect(x: 200, y: 0, width: 800, height: 672)
        )

        XCTAssertEqual(frame.origin.x, 200, accuracy: 0.001)
        XCTAssertEqual(frame.origin.y, 0, accuracy: 0.001)
        XCTAssertEqual(frame.width, 800, accuracy: 0.001)
        XCTAssertEqual(frame.height, 644, accuracy: 0.001)
    }

    func testPortalFrameUsesBonsplitPaneWidthWhenAnchorIsAnimatedWider() {
        let frame = TerminalPortalGeometryFramePolicy.portalFrameInWindow(
            anchorFrame: NSRect(x: 200, y: 0, width: 797, height: 644),
            paneContainerFrame: NSRect(x: 200, y: 0, width: 760, height: 672)
        )

        XCTAssertEqual(frame.origin.x, 200, accuracy: 0.001)
        XCTAssertEqual(frame.origin.y, 0, accuracy: 0.001)
        XCTAssertEqual(frame.width, 760, accuracy: 0.001)
        XCTAssertEqual(frame.height, 644, accuracy: 0.001)
    }

    func testPortalFrameIgnoresBonsplitPaneWhenVerticalBandDoesNotMatch() {
        let frame = TerminalPortalGeometryFramePolicy.portalFrameInWindow(
            anchorFrame: NSRect(x: 200, y: 720, width: 762.5, height: 300),
            paneContainerFrame: NSRect(x: 200, y: 0, width: 800, height: 300)
        )

        XCTAssertEqual(frame.origin.x, 200, accuracy: 0.001)
        XCTAssertEqual(frame.origin.y, 720, accuracy: 0.001)
        XCTAssertEqual(frame.width, 762.5, accuracy: 0.001)
        XCTAssertEqual(frame.height, 300, accuracy: 0.001)
    }
}
