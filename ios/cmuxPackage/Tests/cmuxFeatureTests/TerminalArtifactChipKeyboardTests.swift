#if canImport(UIKit)
import CMUXMobileCore
import CmuxMobileSupport
import CmuxMobileTerminalKit
import CoreGraphics
import Foundation
import Testing
import UIKit

@testable import CmuxMobileTerminal

/// The files-chip keyboard contract: the chip is chrome, not render. The host
/// slides the full-height render wrapper so the render bottom rides the
/// composer bar while the keyboard is up (#10594); the chip is adopted into
/// the host's keyboard-invariant chrome space (like the dock), so its frame
/// in host coordinates must not move at all across keyboard toggles — before
/// this contract it rode the surface's top edge off screen whenever the
/// keyboard was shown.
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

    @Test("chip keeps its resting top anchor on a hostless surface")
    func chipRestsAtSurfaceTop() async throws {
        let (view, delegate) = try makeSurface()
        _ = delegate
        let bounds = CGRect(x: 0, y: 0, width: 402, height: 874)
        let window = UIWindow(frame: bounds)
        window.addSubview(view)
        window.isHidden = false
        defer {
            view.prepareForDismantle()
            view.removeFromSuperview()
            window.isHidden = true
        }
        view.frame = bounds
        view.layoutIfNeeded()

        let chipContent = UIView()
        view.mountArtifactChipView(chipContent, animated: false)
        view.layoutIfNeeded()
        let container = try #require(chipContent.superview)
        let restingY = view.safeAreaInsets.top + 8
        #expect(
            abs(container.frame.minY - restingY) <= 1,
            "resting chip must keep its top anchor; minY=\(container.frame.minY) expected=\(restingY)"
        )
        #expect(container.frame.height >= 44)
        #expect(container.frame.width >= 88)
    }

    /// End-to-end through the real host: the chip's frame in HOST coordinates
    /// is identical before, during, and after a keyboard seat ride, because
    /// the chip is constraint-anchored in the host's chrome space and the
    /// keyboard moves only the render wrapper. The pre-contract failure mode
    /// (chip riding the slid wrapper above the visible region) shows up here
    /// as a keyboard-up frame shifted by the slide.
    @Test("host keeps the chip frame keyboard-invariant")
    func hostKeepsChipFrameKeyboardInvariant() async throws {
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

        let chipContent = UIView()
        view.mountArtifactChipView(chipContent, animated: false)
        host.layoutIfNeeded()
        let container = try #require(chipContent.superview)
        func chipFrameInHost() -> CGRect {
            container.convert(container.bounds, to: host)
        }
        await settle()
        let restingFrame = chipFrameInHost()
        #expect(
            abs(restingFrame.minY - (host.safeAreaInsets.top + 8)) <= 1,
            "chip must rest 8pt below the host's safe top; frame=\(restingFrame)"
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
        host.layoutIfNeeded()
        let keyboardUpFrame = chipFrameInHost()
        #expect(
            abs(keyboardUpFrame.minY - restingFrame.minY) <= 1
                && abs(keyboardUpFrame.height - restingFrame.height) <= 1,
            "chip frame must not move with the keyboard; resting=\(restingFrame) up=\(keyboardUpFrame)"
        )

        view.setKeyboardHeightForTesting(0)
        host.setNeedsLayout()
        host.layoutIfNeeded()
        await settle()
        host.layoutIfNeeded()
        let keyboardDownFrame = chipFrameInHost()
        #expect(
            abs(keyboardDownFrame.minY - restingFrame.minY) <= 1,
            "chip frame must return unchanged after the keyboard drops; resting=\(restingFrame) down=\(keyboardDownFrame)"
        )
    }
}
#endif
