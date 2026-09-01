#if canImport(UIKit)
import CMUXMobileCore
import CmuxMobileSupport
import CmuxMobileTerminalKit
import CoreGraphics
import Foundation
import Testing
import UIKit

@testable import CmuxMobileTerminal

/// The full-height keyboard-pin contract: the terminal grid never resizes for
/// the keyboard. `TerminalViewportCoordinator` produces a keyboard-invariant
/// container/render placement, and `GhosttySurfaceHostView` keeps the
/// full-height render's bottom edge glued to the dock (composer bar) purely
/// through its constraint system while the dock seat rides a keyboard.
@MainActor
private final class FullHeightPinDelegate: NSObject, GhosttySurfaceViewDelegate {
    private(set) var reports: [TerminalGridSize] = []

    func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didProduceInput data: Data) {}

    func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didResize size: TerminalGridSize, reportID: UInt64) {
        reports.append(size)
        // Steady-state daemon behavior: grant everything the phone asks for,
        // so the negotiation settles by itself and `effectiveGrid` never pins
        // the render below its natural size.
        surfaceView.markViewportReportConfirmed()
        surfaceView.applyConfirmedViewSize(cols: size.columns, rows: size.rows, reportID: reportID)
    }
}

@MainActor
@Suite("Terminal full-height keyboard pin", .serialized)
struct TerminalKeyboardFullHeightPinTests {
    @Test("viewport coordinator is keyboard-invariant except for the dock seat")
    func coordinatorKeyboardInvariance() {
        let coordinator = TerminalViewportCoordinator()
        func snap(_ keyboard: CGFloat, chromeHidden: Bool = false) -> TerminalViewportSnapshot {
            coordinator.snapshot(inputs: TerminalViewportInputs(
                bounds: CGSize(width: 402, height: 874),
                keyboardHeight: keyboard,
                composerBandHeight: 44,
                reservedToolbarHeight: 34,
                toolbarFrameHeight: 34,
                bottomSafeAreaInset: 34,
                chromeHidden: chromeHidden
            ))
        }
        let down = snap(0)
        let up = snap(336)
        #expect(down.containerSize == up.containerSize)
        #expect(down.layoutViewportRect == up.layoutViewportRect)
        let renderSize = CGSize(width: 402, height: down.layoutViewportRect.height)
        #expect(down.renderRect(forRenderSize: renderSize) == up.renderRect(forRenderSize: renderSize))
        // The render is bottom-pinned to the viewport in both states.
        #expect(down.renderRect(forRenderSize: renderSize).maxY == down.layoutViewportRect.maxY)

        // The dock seat is the ONLY keyboard consumer.
        #expect(up.keyboardOccupancy == 336)
        #expect(down.keyboardOccupancy == 34)

        // Dock frames stack directly under the viewport in surface
        // coordinates, in BOTH keyboard states: keyboard motion moves the
        // surface (host wrapper), never these frames.
        #expect(down.toolbarFrame.minY == down.layoutViewportRect.maxY)
        #expect(up.toolbarFrame == down.toolbarFrame)
        #expect(up.composerFrame.minY == up.toolbarFrame.maxY)
        #expect(up.composerFrame == down.composerFrame)

        // Chrome hidden reclaims the whole height; the (invisible) dock seats
        // by the keyboard alone.
        let hiddenUp = snap(336, chromeHidden: true)
        #expect(hiddenUp.layoutViewportRect.height == 874)
        #expect(hiddenUp.keyboardOccupancy == 336)
        #expect(snap(0, chromeHidden: true).keyboardOccupancy == 0)
    }

    /// End-to-end host contract on a real surface: the dock seat rides a
    /// keyboard height and the full-height render's bottom edge stays glued
    /// to the dock top with no grid renegotiation. The chrome-hidden mode
    /// hands the seat to the host's plain bottom constraint (the system
    /// keyboard guide cannot be driven on a simulator), which is the same
    /// constraint the iOS 27 notification fallback rides.
    @Test("host keeps the render bottom glued to a riding dock seat")
    func hostRenderBottomRidesDockSeat() async throws {
        let runtime = try GhosttyRuntime.shared()
        let delegate = FullHeightPinDelegate()
        let view = GhosttySurfaceView(runtime: runtime, delegate: delegate, fontSize: 10)
        view.autoFocusOnWindowAttach = false
        view.isRenderDispatchSuppressed = true
        let host = GhosttySurfaceHostView(
            surfaceView: view,
            keyboardFrameTracker: MobileKeyboardFrameTracker()
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        host.frame = window.bounds
        window.addSubview(host)
        window.isHidden = false
        defer {
            view.prepareForDismantle()
            host.removeFromSuperview()
            window.isHidden = true
        }
        host.setNeedsLayout()
        host.layoutIfNeeded()

        func gap() -> CGFloat {
            guard let renderBottom = view.hostedTerminalPresentationBottom(in: host),
                  let dockTop = view.hostedBottomDockPresentationTop(in: host) else {
                return .infinity
            }
            return abs(renderBottom - dockTop)
        }
        func pump(timeout: TimeInterval = 8, until condition: () -> Bool) async -> Bool {
            let deadline = Date(timeIntervalSinceNow: timeout)
            while Date() < deadline {
                if condition() { return true }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            return condition()
        }
        func settle(_ interval: TimeInterval = 0.8) async {
            let deadline = Date(timeIntervalSinceNow: interval)
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }

        // Initial handshake: a real render exists and its bottom edge sits at
        // the designed seat — `dockSeamPadding` above the dock top while the
        // chrome is visible, so content never presses into the toolbar.
        #expect(await pump { !delegate.reports.isEmpty }, "no natural-grid report after attach")
        #expect(
            await pump { abs(gap() - view.hostedDockSeamPadding) <= 1 },
            "render bottom never attached to its padded dock seat; gap=\(gap())"
        )

        // Hand the seat to the plain bottom constraint and ride a keyboard.
        view.setChromeHidden(true)
        host.setNeedsLayout()
        host.layoutIfNeeded()
        await settle()
        let reportsBefore = delegate.reports.count

        view.setKeyboardHeightForTesting(336)
        host.setNeedsLayout()
        host.layoutIfNeeded()
        await settle()
        let dockTopUp = try #require(view.hostedBottomDockPresentationTop(in: host))
        #expect(abs(dockTopUp - (874 - 336)) <= 1, "dock seat did not ride the keyboard: dockTop=\(dockTopUp)")
        // Blank rows below the content absorb the keyboard before the render
        // slides: the seam equals min(blank, intrusion). On this idle screen
        // (cursor at the top) that is the FULL intrusion — the terminal stays
        // top-pinned and the keyboard covers only blank rows. If the cursor
        // is unreadable in this harness the absorption reports nil and the
        // render is fully bottom-pinned instead; both satisfy gap == slack.
        let expectedSlack = TerminalLetterboxGeometry.keyboardAbsorptionSlack(
            blankBelowContent: view.hostedBlankBelowContent,
            intrusion: 336
        )
        #expect(
            abs(gap() - expectedSlack) <= 1,
            "render seam must equal the blank-space slack; gap=\(gap()) slack=\(expectedSlack)"
        )
        #expect(
            delegate.reports.count == reportsBefore,
            "the keyboard seat must not renegotiate the grid. reports=\(delegate.reports)"
        )

        // Seat returns to the bottom; the render follows in the same
        // constraint system — no resize, no report, no detachment.
        view.setKeyboardHeightForTesting(0)
        host.setNeedsLayout()
        host.layoutIfNeeded()
        await settle()
        let dockTopDown = try #require(view.hostedBottomDockPresentationTop(in: host))
        #expect(abs(dockTopDown - 874) <= 1, "dock seat did not return to the screen bottom: dockTop=\(dockTopDown)")
        #expect(gap() <= 1, "render bottom detached from the dock after the keyboard seat dropped; gap=\(gap())")
        #expect(delegate.reports.count == reportsBefore)
    }
}
#endif
