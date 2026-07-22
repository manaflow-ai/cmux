import AppKit
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class AppDelegateWindowFrameReconcileTests: XCTestCase {
    // A window stranded above the only remaining display after disconnecting an
    // external monitor that sat above the built-in must be pulled back so its
    // titlebar is reachable. AppKit does not auto-constrain the non-movable main
    // window on a display change, so this reactive reconcile is the only defense.
    func testReconciledFrameAfterScreenChangePullsBackStrandedWindow() {
        // Built-in display only; the window's titlebar (top ~64pt near y~=1520)
        // is far above the built-in's visible top (944), with only its bottom
        // edge dipping into the display.
        let builtIn = AppDelegate.SessionDisplayGeometry(
            displayID: 1,
            frame: CGRect(x: 0, y: 0, width: 1_512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_512, height: 944)
        )
        let stranded = CGRect(x: 300, y: 884, width: 1_000, height: 700)

        let corrected = AppDelegate.reconciledFrameAfterScreenChange(
            frame: stranded,
            availableDisplays: [builtIn]
        )

        XCTAssertNotNil(corrected)
        guard let corrected else { return }
        // Titlebar is back within the visible area and size is preserved.
        XCTAssertLessThanOrEqual(corrected.maxY, builtIn.visibleFrame.maxY + 0.001)
        XCTAssertGreaterThanOrEqual(corrected.minY, builtIn.visibleFrame.minY - 0.001)
        XCTAssertEqual(corrected.width, 1_000, accuracy: 0.001)
        XCTAssertEqual(corrected.height, 700, accuracy: 0.001)
    }

    // A window already reachable on a connected display must not be disturbed by
    // an unrelated display reconfiguration.
    func testReconciledFrameAfterScreenChangeLeavesReachableWindowUntouched() {
        let builtIn = AppDelegate.SessionDisplayGeometry(
            displayID: 1,
            frame: CGRect(x: 0, y: 0, width: 1_512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_512, height: 944)
        )
        let onScreen = CGRect(x: 100, y: 100, width: 900, height: 600)

        XCTAssertNil(
            AppDelegate.reconciledFrameAfterScreenChange(
                frame: onScreen,
                availableDisplays: [builtIn]
            )
        )
    }

    func testReconciledFrameAfterScreenChangeReturnsNilWithoutDisplays() {
        XCTAssertNil(
            AppDelegate.reconciledFrameAfterScreenChange(
                frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                availableDisplays: []
            )
        )
    }
}
