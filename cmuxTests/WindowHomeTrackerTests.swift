import Testing
import CoreGraphics

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite struct WindowHomeTrackerTests {
    private func makeSnapshot(
        displayID: UInt32,
        frame: CGRect = CGRect(x: 0, y: 0, width: 1_000, height: 800)
    ) -> SessionDisplaySnapshot {
        SessionDisplaySnapshot(
            displayID: displayID,
            frame: SessionRectSnapshot(frame),
            visibleFrame: SessionRectSnapshot(frame)
        )
    }

    @Test func recordsAndRetrievesHome() {
        let tracker = WindowHomeTracker()
        let id = UUID()
        let frame = CGRect(x: 1_200, y: 100, width: 600, height: 400)
        let display = makeSnapshot(displayID: 2)

        #expect(tracker.home(for: id) == nil)
        tracker.recordHome(windowId: id, frame: frame, display: display)

        let home = tracker.home(for: id)
        #expect(home?.frame == frame)
        #expect(home?.display == display)
    }

    @Test func recordHomeReplacesPreviousValue() {
        let tracker = WindowHomeTracker()
        let id = UUID()
        tracker.recordHome(
            windowId: id,
            frame: CGRect(x: 0, y: 0, width: 100, height: 100),
            display: makeSnapshot(displayID: 1)
        )
        let newFrame = CGRect(x: 1_300, y: 50, width: 700, height: 500)
        tracker.recordHome(windowId: id, frame: newFrame, display: makeSnapshot(displayID: 2))

        #expect(tracker.home(for: id)?.frame == newFrame)
        #expect(tracker.home(for: id)?.display.displayID == 2)
    }

    @Test func clearForgetsHome() {
        let tracker = WindowHomeTracker()
        let id = UUID()
        tracker.recordHome(
            windowId: id,
            frame: CGRect(x: 0, y: 0, width: 100, height: 100),
            display: makeSnapshot(displayID: 1)
        )
        tracker.clear(windowId: id)
        #expect(tracker.home(for: id) == nil)
    }

    @Test func tracksWindowsIndependently() {
        let tracker = WindowHomeTracker()
        let a = UUID()
        let b = UUID()
        tracker.recordHome(
            windowId: a,
            frame: CGRect(x: 0, y: 0, width: 100, height: 100),
            display: makeSnapshot(displayID: 1)
        )
        tracker.recordHome(
            windowId: b,
            frame: CGRect(x: 500, y: 500, width: 200, height: 200),
            display: makeSnapshot(displayID: 2)
        )
        tracker.clear(windowId: a)

        #expect(tracker.home(for: a) == nil)
        #expect(tracker.home(for: b)?.display.displayID == 2)
    }

    // MARK: shouldRecordHome decision

    @Test func recordsHomeForStableUserMove() {
        #expect(WindowHomeTracker.shouldRecordHome(
            isUserInitiated: true,
            isReconciling: false,
            isApplyingSessionRestore: false,
            isFullScreen: false,
            isZoomed: false,
            isMiniaturized: false,
            screenPresent: true
        ))
    }

    /// The crux of the fix: macOS rescues the window off a vanishing display
    /// onto the laptop, firing `windowDidMove` with NO preceding
    /// `windowWillMove`, so `isUserInitiated` is false even though the laptop is
    /// present and the window is in a normal state. This must NOT overwrite the
    /// remembered home, or the original placement is lost and nothing restores.
    @Test func doesNotRecordHomeForMacOSRescueMove() {
        #expect(!WindowHomeTracker.shouldRecordHome(
            isUserInitiated: false,
            isReconciling: false,
            isApplyingSessionRestore: false,
            isFullScreen: false,
            isZoomed: false,
            isMiniaturized: false,
            screenPresent: true
        ))
    }

    @Test(arguments: [
        // (userInitiated, reconciling, restoring, fullscreen, zoomed, mini, screenPresent)
        // Each tuple is a user-initiated move with exactly one suppressing condition.
        (true, true, false, false, false, false, true),   // reconciling (our own restore)
        (true, false, true, false, false, false, true),    // session restore
        (true, false, false, true, false, false, true),    // fullscreen
        (true, false, false, false, true, false, true),    // zoomed
        (true, false, false, false, false, true, true),    // miniaturized
        (true, false, false, false, false, false, false),  // window's screen absent
    ])
    func doesNotRecordHomeWhenSuppressed(
        _ args: (Bool, Bool, Bool, Bool, Bool, Bool, Bool)
    ) {
        #expect(!WindowHomeTracker.shouldRecordHome(
            isUserInitiated: args.0,
            isReconciling: args.1,
            isApplyingSessionRestore: args.2,
            isFullScreen: args.3,
            isZoomed: args.4,
            isMiniaturized: args.5,
            screenPresent: args.6
        ))
    }

    // MARK: restore resolver flow
    //
    // These exercise the exact pipeline `reconcileWindowHomeForDisplayChange`
    // depends on: resolve the persisted home against the live display list, then
    // restore only when the resolver reproduced the exact home frame (meaning the
    // home display is connected again).

    @Test func doesNotRestoreWhileHomeDisplayAbsent() throws {
        let homeFrame = SessionRectSnapshot(x: 1_200, y: 100, width: 600, height: 400)
        let homeDisplay = SessionDisplaySnapshot(
            displayID: 2,
            frame: SessionRectSnapshot(x: 1_000, y: 0, width: 1_000, height: 800),
            visibleFrame: SessionRectSnapshot(x: 1_000, y: 0, width: 1_000, height: 800)
        )
        // Only the laptop display is present; the external (id 2) is gone.
        let laptop = AppDelegate.SessionDisplayGeometry(
            displayID: 1,
            frame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900)
        )

        let resolved = AppDelegate.resolvedWindowFrame(
            from: homeFrame,
            display: homeDisplay,
            availableDisplays: [laptop],
            fallbackDisplay: laptop
        )

        let resolvedFrame = try #require(resolved)
        // Resolver clamps onto the laptop, so it is NOT the exact home frame.
        #expect(!rectApproximatelyEqual(resolvedFrame, homeFrame.cgRect))
    }

    @Test func restoresExactHomeWhenDisplayReturns() throws {
        let homeFrame = SessionRectSnapshot(x: 1_200, y: 100, width: 600, height: 400)
        let homeDisplay = SessionDisplaySnapshot(
            displayID: 2,
            frame: SessionRectSnapshot(x: 1_000, y: 0, width: 1_000, height: 800),
            visibleFrame: SessionRectSnapshot(x: 1_000, y: 0, width: 1_000, height: 800)
        )
        let laptop = AppDelegate.SessionDisplayGeometry(
            displayID: 1,
            frame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900)
        )
        // External display id 2 is back with identical geometry.
        let external = AppDelegate.SessionDisplayGeometry(
            displayID: 2,
            frame: CGRect(x: 1_000, y: 0, width: 1_000, height: 800),
            visibleFrame: CGRect(x: 1_000, y: 0, width: 1_000, height: 800)
        )

        let resolved = AppDelegate.resolvedWindowFrame(
            from: homeFrame,
            display: homeDisplay,
            availableDisplays: [laptop, external],
            fallbackDisplay: laptop
        )

        let resolvedFrame = try #require(resolved)
        // Resolver reproduces the exact home frame, so the reconcile would apply it.
        #expect(rectApproximatelyEqual(resolvedFrame, homeFrame.cgRect))
    }

    @Test func restoreIsIdempotentOnceApplied() throws {
        let homeFrame = SessionRectSnapshot(x: 1_200, y: 100, width: 600, height: 400)
        let homeDisplay = SessionDisplaySnapshot(
            displayID: 2,
            frame: SessionRectSnapshot(x: 1_000, y: 0, width: 1_000, height: 800),
            visibleFrame: SessionRectSnapshot(x: 1_000, y: 0, width: 1_000, height: 800)
        )
        let external = AppDelegate.SessionDisplayGeometry(
            displayID: 2,
            frame: CGRect(x: 1_000, y: 0, width: 1_000, height: 800),
            visibleFrame: CGRect(x: 1_000, y: 0, width: 1_000, height: 800)
        )

        let first = AppDelegate.resolvedWindowFrame(
            from: homeFrame,
            display: homeDisplay,
            availableDisplays: [external],
            fallbackDisplay: external
        )
        let second = AppDelegate.resolvedWindowFrame(
            from: homeFrame,
            display: homeDisplay,
            availableDisplays: [external],
            fallbackDisplay: external
        )

        let firstFrame = try #require(first)
        let secondFrame = try #require(second)
        // Re-running the resolver yields the same frame every time, so a burst of
        // didChangeScreenParameters notifications converges without a settle delay.
        #expect(firstFrame == secondFrame)
        #expect(rectApproximatelyEqual(firstFrame, homeFrame.cgRect))
    }

    /// Local mirror of `AppDelegate.rectApproximatelyEqual` (which is private to
    /// the app target) so the resolver-flow assertions match the reconcile's own
    /// comparison semantics.
    private func rectApproximatelyEqual(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat = 1) -> Bool {
        let l = lhs.standardized
        let r = rhs.standardized
        return abs(l.origin.x - r.origin.x) <= tolerance
            && abs(l.origin.y - r.origin.y) <= tolerance
            && abs(l.size.width - r.size.width) <= tolerance
            && abs(l.size.height - r.size.height) <= tolerance
    }
}
