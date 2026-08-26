#if canImport(UIKit)
import CMUXMobileCore
import CmuxMobileSupport
import CmuxMobileTerminalKit
import CoreGraphics
import Foundation
import Testing
import UIKit

@testable import CmuxMobileTerminal

/// The files-chip keyboard contract: the chip anchors to the top of the
/// terminal's VISIBLE region. While the keyboard is up the host slides the
/// full-height render wrapper — and the surface with it — so the render
/// bottom rides the composer bar (#10594); the chip must counter that slide
/// and stay inside the clipped-visible area instead of riding the surface's
/// top edge off screen.
@MainActor
private final class ArtifactChipKeyboardDelegate: NSObject, GhosttySurfaceViewDelegate {
    func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didProduceInput data: Data) {}

    func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didResize size: TerminalGridSize, reportID: UInt64) {
        // Steady-state daemon behavior: grant everything the phone asks for.
        surfaceView.markViewportReportConfirmed()
        surfaceView.applyConfirmedViewSize(cols: size.columns, rows: size.rows, reportID: reportID)
    }
}

@MainActor
@Suite("Terminal files chip keyboard visibility", .serialized)
struct TerminalArtifactChipKeyboardTests {
    private func makeSurface() throws -> (GhosttySurfaceView, ArtifactChipKeyboardDelegate) {
        let runtime = try GhosttyRuntime.shared()
        let delegate = ArtifactChipKeyboardDelegate()
        let view = GhosttySurfaceView(runtime: runtime, delegate: delegate, fontSize: 10)
        view.autoFocusOnWindowAttach = false
        view.isRenderDispatchSuppressed = true
        return (view, delegate)
    }

    @Test("chip keeps its resting top anchor while nothing above clips the surface")
    func chipRestsAtSurfaceTop() async throws {
        let (view, delegate) = try makeSurface()
        _ = delegate
        let bounds = CGRect(x: 0, y: 0, width: 402, height: 874)
        let window = UIWindow(frame: bounds)
        let clipView = UIView(frame: bounds)
        clipView.clipsToBounds = true
        window.addSubview(clipView)
        window.isHidden = false
        defer {
            view.prepareForDismantle()
            clipView.removeFromSuperview()
            window.isHidden = true
        }
        view.frame = bounds
        clipView.addSubview(view)
        view.layoutIfNeeded()

        let chipContent = UIView()
        view.mountArtifactChipView(chipContent, animated: false)
        let container = try #require(chipContent.superview)
        let restingY = max(8, view.safeAreaInsets.top + 8)
        #expect(
            abs(container.frame.minY - restingY) <= 1,
            "resting chip must keep its top anchor; minY=\(container.frame.minY) expected=\(restingY)"
        )
    }

    @Test("chip stays inside the visible region while the surface is slid for the keyboard")
    func chipPinsToVisibleTopWhileSlid() async throws {
        let (view, delegate) = try makeSurface()
        _ = delegate
        let bounds = CGRect(x: 0, y: 0, width: 402, height: 874)
        let window = UIWindow(frame: bounds)
        let clipView = UIView(frame: bounds)
        clipView.clipsToBounds = true
        window.addSubview(clipView)
        window.isHidden = false
        defer {
            view.prepareForDismantle()
            clipView.removeFromSuperview()
            window.isHidden = true
        }
        // The keyboard-up placement the host produces: the full-height surface
        // slid up inside a clipping wrapper so its bottom rides the composer
        // bar and its top sits above the visible area.
        let slide: CGFloat = 300
        view.frame = bounds.offsetBy(dx: 0, dy: -slide)
        clipView.addSubview(view)
        view.layoutIfNeeded()

        let chipContent = UIView()
        view.mountArtifactChipView(chipContent, animated: false)
        let container = try #require(chipContent.superview)
        #expect(
            container.frame.minY >= slide,
            "chip must stay inside the clipped-visible region; minY=\(container.frame.minY) visibleTop=\(slide)"
        )
    }

    /// End-to-end through the real host: ride a keyboard seat and require the
    /// chip to sit at or below the host's visible top edge in surface
    /// coordinates, in both keyboard states. The slide magnitude depends on
    /// how much blank render absorbs the intrusion (harness-dependent), so
    /// the assertion is the visibility contract rather than a fixed offset.
    @Test("host keeps the chip visible across keyboard toggles")
    func hostKeepsChipVisibleAcrossKeyboardToggles() async throws {
        let (view, delegate) = try makeSurface()
        _ = delegate
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

        func settle(_ interval: TimeInterval = 0.8) async {
            let deadline = Date(timeIntervalSinceNow: interval)
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        func visibleTop() -> CGFloat {
            view.convert(CGPoint.zero, from: host).y
        }

        let chipContent = UIView()
        view.mountArtifactChipView(chipContent, animated: false)
        let container = try #require(chipContent.superview)
        await settle()
        #expect(
            container.frame.minY + 1 >= visibleTop(),
            "chip below visible top before keyboard; minY=\(container.frame.minY) visibleTop=\(visibleTop())"
        )

        // Hand the dock seat to the plain bottom constraint (the system
        // keyboard guide cannot be driven on a simulator) and ride a keyboard.
        view.setChromeHidden(true)
        host.setNeedsLayout()
        host.layoutIfNeeded()
        await settle()

        view.setKeyboardHeightForTesting(336)
        host.setNeedsLayout()
        host.layoutIfNeeded()
        await settle()
        // The live app re-pins the chip from the surface's display link as the
        // wrapper animates; the harness forces one settled layout pass instead
        // of depending on display-link timing inside xctest.
        view.setNeedsLayout()
        view.layoutIfNeeded()
        #expect(
            container.frame.minY + 1 >= visibleTop(),
            "chip slid off the visible region with the keyboard up; minY=\(container.frame.minY) visibleTop=\(visibleTop())"
        )

        view.setKeyboardHeightForTesting(0)
        host.setNeedsLayout()
        host.layoutIfNeeded()
        await settle()
        view.setNeedsLayout()
        view.layoutIfNeeded()
        #expect(
            container.frame.minY + 1 >= visibleTop(),
            "chip stuck offset after the keyboard dropped; minY=\(container.frame.minY) visibleTop=\(visibleTop())"
        )
        #expect(
            abs(container.frame.minY - max(8, view.safeAreaInsets.top + 8)) <= 1,
            "chip must return to its resting anchor after the keyboard drops; minY=\(container.frame.minY)"
        )
    }
}
#endif
