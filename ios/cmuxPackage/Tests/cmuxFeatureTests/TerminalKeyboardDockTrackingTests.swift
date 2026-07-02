#if canImport(UIKit)
import CMUXMobileCore
import Foundation
import Testing
import UIKit

@testable import CmuxMobileTerminal

/// Behavioral tests for keyboard-synchronized terminal layout.
///
/// The terminal's bottom dock (toolbar + composer band) and render viewport must
/// sit EXACTLY on the keyboard's live animated edge every frame, not on a replay
/// of the notification's duration/curve. The surface samples an anchor pinned to
/// `keyboardLayoutGuide` each display-link tick and frame-sets the dock from that
/// sample; these tests script the sample (via `debugKeyboardGuideTopSamplerForTesting`)
/// and step ticks (via `debugAdvanceKeyboardDockTrackingForTesting`) so the whole
/// trajectory is deterministic — no real keyboard, no timing flake.
@MainActor
@Suite("Terminal keyboard dock tracking")
struct TerminalKeyboardDockTrackingTests {
    private final class StubDelegate: GhosttySurfaceViewDelegate {
        func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didProduceInput data: Data) {}
        func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didResize size: TerminalGridSize) {}
    }

    /// A scripted keyboard-guide sample the tests move frame by frame.
    private final class ScriptedGuide {
        var top: CGFloat

        init(top: CGFloat) {
            self.top = top
        }
    }

    private struct Harness {
        let window: UIWindow
        let view: GhosttySurfaceView
        let delegate: StubDelegate
        let guide: ScriptedGuide

        var boundsHeight: CGFloat { view.bounds.height }

        func setSample(_ top: CGFloat) {
            guide.top = top
        }

        func tick() {
            view.debugAdvanceKeyboardDockTrackingForTesting()
        }

        var state: GhosttySurfaceView.DebugKeyboardDockState {
            view.debugKeyboardDockStateForTesting()
        }

        /// Post a real `keyboardWillChangeFrame` through NotificationCenter so
        /// the production observer path runs, with `endFrame` in screen space.
        func postKeyboardFrameChange(overlap: CGFloat, duration: TimeInterval = 0.25) {
            let screenBounds = window.screen.bounds
            let endFrame = CGRect(
                x: 0,
                y: screenBounds.height - overlap,
                width: screenBounds.width,
                height: max(overlap, 336)
            )
            NotificationCenter.default.post(
                name: UIResponder.keyboardWillChangeFrameNotification,
                object: nil,
                userInfo: [
                    UIResponder.keyboardFrameEndUserInfoKey: endFrame,
                    UIResponder.keyboardAnimationDurationUserInfoKey: duration,
                    UIResponder.keyboardAnimationCurveUserInfoKey: 7,
                ]
            )
        }
    }

    private func makeHarness() throws -> Harness {
        let runtime = try GhosttyRuntime.shared()
        let delegate = StubDelegate()
        let view = GhosttySurfaceView(runtime: runtime, delegate: delegate, fontSize: 10)
        view.autoFocusOnWindowAttach = false
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.isHidden = false
        view.frame = window.bounds
        window.addSubview(view)
        window.layoutIfNeeded()
        view.layoutIfNeeded()
        // Rest state: guide top on the bottom occupancy edge, so the sample
        // matches the target exactly and no tracking is armed.
        let guide = ScriptedGuide(top: view.bounds.height)
        let harness = Harness(window: window, view: view, delegate: delegate, guide: guide)
        view.debugKeyboardGuideTopSamplerForTesting = { [guide] in guide.top }
        // Rest the scripted guide on the real resting occupancy (bottom safe
        // area, or the view bottom when the test window has no inset).
        let restingOccupancy = harness.state.keyboardHeight > 0
            ? harness.state.keyboardHeight
            : max(0, window.safeAreaInsets.bottom)
        guide.top = view.bounds.height - restingOccupancy
        return harness
    }

    @Test("keyboard show: dock and live viewport ride the sampled guide frame by frame")
    func showTracksScriptedGuide() throws {
        let h = try makeHarness()
        let height = h.boundsHeight
        let keyboard: CGFloat = 336
        let restingTop = h.guide.top

        h.postKeyboardFrameChange(overlap: keyboard)

        let afterNotification = h.state
        // The target (grid reservation) jumps to the final height immediately…
        #expect(abs(afterNotification.keyboardHeight - keyboard) <= 0.5)
        #expect(afterNotification.isTracking)
        // …but the dock has NOT snapped: it still sits at the pre-animation
        // sample (the resting guide position).
        if let toolbar = afterNotification.toolbarFrame {
            #expect(abs(toolbar.maxY - restingTop) <= 0.5)
        }

        let finalTop = height - keyboard
        let targetViewportDuringAnimation = afterNotification.targetViewportHeight
        // Walk the guide along an arbitrary trajectory (the real one is UIKit's
        // private spring — the contract is "wherever the guide is, the dock is").
        for top in [restingTop - 40, restingTop - 120, finalTop + 90, finalTop + 12] {
            h.setSample(top)
            h.tick()
            let state = h.state
            #expect(state.isTracking)
            let toolbar = try #require(state.toolbarFrame)
            // The dock bottom sits exactly on the sampled keyboard edge.
            #expect(abs(toolbar.maxY - top) <= 0.5)
            // The live render viewport bottom sits exactly on the dock top.
            #expect(abs(state.liveViewportHeight - toolbar.minY) <= 0.5)
            // The grid reservation does not thrash per frame.
            #expect(abs(state.targetViewportHeight - targetViewportDuringAnimation) <= 0.5)
        }

        // Converge: the sample reaches the target occupancy and tracking settles
        // on exact target math.
        h.setSample(finalTop)
        h.tick()
        let settled = h.state
        #expect(!settled.isTracking)
        let settledToolbar = try #require(settled.toolbarFrame)
        #expect(abs(settledToolbar.maxY - finalTop) <= 0.5)
    }

    @Test("keyboard hide: tracking walks the dock down and settles at the resting edge")
    func hideTracksScriptedGuide() throws {
        let h = try makeHarness()
        let height = h.boundsHeight
        let keyboard: CGFloat = 336
        let upTop = height - keyboard

        // Raise the keyboard and settle.
        h.postKeyboardFrameChange(overlap: keyboard)
        h.setSample(upTop)
        h.tick()
        #expect(!h.state.isTracking)

        // Hide. The dock must stay at the keyboard's current edge, then follow
        // the samples down.
        let restingOccupancy = max(0, h.window.safeAreaInsets.bottom)
        let restingTop = height - restingOccupancy
        h.postKeyboardFrameChange(overlap: 0)
        let afterHide = h.state
        #expect(afterHide.keyboardHeight == 0)
        #expect(afterHide.isTracking)
        if let toolbar = afterHide.toolbarFrame {
            #expect(abs(toolbar.maxY - upTop) <= 0.5)
        }

        for top in [upTop + 60, upTop + 180, restingTop - 20] {
            h.setSample(top)
            h.tick()
            let toolbar = try #require(h.state.toolbarFrame)
            #expect(abs(toolbar.maxY - top) <= 0.5)
            #expect(h.state.isTracking)
        }

        h.setSample(restingTop)
        h.tick()
        let settled = h.state
        #expect(!settled.isTracking)
        let settledToolbar = try #require(settled.toolbarFrame)
        #expect(abs(settledToolbar.maxY - restingTop) <= 0.5)
    }

    @Test("interactive dismissal: a moving guide with no notification self-arms tracking")
    func interactiveDismissSelfArms() throws {
        let h = try makeHarness()
        let height = h.boundsHeight
        let keyboard: CGFloat = 336
        let upTop = height - keyboard

        h.postKeyboardFrameChange(overlap: keyboard)
        h.setSample(upTop)
        h.tick()
        #expect(!h.state.isTracking)

        // The finger drags the keyboard down: the guide moves but UIKit posts
        // no willChangeFrame until the drag ends.
        h.setSample(upTop + 120)
        h.tick()
        let dragging = h.state
        #expect(dragging.isTracking)
        let draggingToolbar = try #require(dragging.toolbarFrame)
        #expect(abs(draggingToolbar.maxY - (upTop + 120)) <= 0.5)
        // The grid reservation still reflects the last committed keyboard state.
        #expect(abs(dragging.keyboardHeight - keyboard) <= 0.5)

        // Drag ends: UIKit posts the hide notification and the guide finishes
        // its run to the resting edge.
        let restingTop = height - max(0, h.window.safeAreaInsets.bottom)
        h.postKeyboardFrameChange(overlap: 0)
        h.setSample(restingTop)
        h.tick()
        let settled = h.state
        #expect(!settled.isTracking)
        #expect(settled.keyboardHeight == 0)
        let settledToolbar = try #require(settled.toolbarFrame)
        #expect(abs(settledToolbar.maxY - restingTop) <= 0.5)
    }

    @Test("real keyboard: the guide anchor is live and the dock converges onto it")
    func realKeyboardGuideAnchorDrivesDock() async throws {
        let h = try makeHarness()
        // Use the REAL guide (no scripted sampler) and a real first responder.
        h.view.debugKeyboardGuideTopSamplerForTesting = nil

        var sawKeyboard = false
        let token = NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillShowNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { sawKeyboard = true }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        h.view.focusInput()
        // Async-poll for the software keyboard; a simulator with a connected
        // hardware keyboard never shows one, in which case this test cannot
        // exercise the real guide and passes vacuously.
        for _ in 0..<60 {
            if sawKeyboard { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard sawKeyboard else { return }

        // Let the animation run; every observed frame with tracking active must
        // have the dock exactly on the sampled guide edge.
        for _ in 0..<40 {
            let state = h.state
            if state.isTracking,
               let toolbar = state.toolbarFrame,
               let guideTop = state.sampledGuideTop {
                #expect(abs(toolbar.maxY - guideTop) <= 1.5)
            }
            try await Task.sleep(nanoseconds: 16_000_000)
        }

        // After the animation the dock must have converged to the target math.
        let settled = h.state
        #expect(!settled.isTracking)
        #expect(settled.keyboardHeight > 0)
        if let toolbar = settled.toolbarFrame {
            #expect(abs(toolbar.maxY - (h.boundsHeight - settled.keyboardHeight)) <= 1.0)
        }
    }
}
#endif
