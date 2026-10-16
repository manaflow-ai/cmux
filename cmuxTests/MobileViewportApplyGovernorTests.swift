@testable import CmuxMobileHost
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Mobile viewport reports may not resize the PTY on every landed request.
///
/// A field session over the relay logged 215 full replays in 5.2 minutes on
/// one surface because every flapping report (remount clear + re-apply,
/// alternating pre/post keyboard-inset geometry, stale in-flight piggybacks)
/// resized the surface, SIGWINCHing the TUI into a full repaint whose
/// render-grid replay kept the downlink saturated and the next report late
/// (https://github.com/manaflow-ai/cmux/issues/13474). The governor must
/// collapse those flaps: first cap immediate, equal targets dropped, changes
/// held for one stability window with newest-wins, and a clear followed by a
/// re-apply of the applied grid cancelling to zero resizes.
@Suite("Mobile viewport apply governor")
struct MobileViewportApplyGovernorTests {
    @Test func firstCapAppliesImmediately() {
        var governor = MobileViewportApplyGovernor()
        #expect(governor.request(.cap(columns: 72, rows: 60)) == .apply(.cap(columns: 72, rows: 60)))
        #expect(governor.applied == .cap(columns: 72, rows: 60))
    }

    @Test func uncapWithNothingAppliedDrops() {
        var governor = MobileViewportApplyGovernor()
        #expect(governor.request(.uncapped) == .drop)
        #expect(governor.flush() == nil)
    }

    @Test func repeatedEqualReportsNeverResize() {
        var governor = MobileViewportApplyGovernor()
        _ = governor.request(.cap(columns: 72, rows: 60))
        for _ in 0..<10 {
            #expect(governor.request(.cap(columns: 72, rows: 60)) == .drop)
        }
        #expect(governor.flush() == nil)
    }

    @Test func changeIsStagedNotAppliedAndNewestStagedWins() {
        var governor = MobileViewportApplyGovernor()
        _ = governor.request(.cap(columns: 72, rows: 60))
        #expect(
            governor.request(.cap(columns: 65, rows: 57))
                == .stage(.cap(columns: 65, rows: 57), scheduleFlush: true)
        )
        // The window is anchored at the first staged change: replacements ride
        // the same pending flush instead of pushing the deadline out.
        #expect(
            governor.request(.cap(columns: 83, rows: 64))
                == .stage(.cap(columns: 83, rows: 64), scheduleFlush: false)
        )
        #expect(governor.applied == .cap(columns: 72, rows: 60))
        #expect(governor.flush() == .cap(columns: 83, rows: 64))
        #expect(governor.applied == .cap(columns: 83, rows: 64))
    }

    @Test func remountClearThenReapplyCollapsesToZeroResizes() {
        // The exact field flap: the terminal view unmounts (viewport clear),
        // then remounts within the window and re-reports the same grid. The
        // PTY must never see either transition.
        var governor = MobileViewportApplyGovernor()
        _ = governor.request(.cap(columns: 72, rows: 60))
        #expect(governor.request(.uncapped) == .stage(.uncapped, scheduleFlush: true))
        #expect(governor.request(.cap(columns: 72, rows: 60)) == .drop)
        #expect(governor.flush() == nil)
        #expect(governor.applied == .cap(columns: 72, rows: 60))
    }

    @Test func alternatingGeometryFlapProducesNoImmediateApplies() {
        var governor = MobileViewportApplyGovernor()
        _ = governor.request(.cap(columns: 72, rows: 60))
        for _ in 0..<20 {
            #expect(governor.request(.cap(columns: 65, rows: 57)) != .apply(.cap(columns: 65, rows: 57)))
            #expect(governor.request(.cap(columns: 72, rows: 60)) != .apply(.cap(columns: 72, rows: 60)))
        }
        // The flap ended where it started, so the window elapses with nothing
        // to do.
        #expect(governor.flush() == nil)
        #expect(governor.applied == .cap(columns: 72, rows: 60))
    }

    @Test func uncapAfterDetachAppliesOnFlush() {
        var governor = MobileViewportApplyGovernor()
        _ = governor.request(.cap(columns: 72, rows: 60))
        #expect(governor.request(.uncapped) == .stage(.uncapped, scheduleFlush: true))
        #expect(governor.flush() == .uncapped)
        #expect(governor.applied == .uncapped)
    }

    @Test func reattachAfterUncapAppliesImmediately() {
        var governor = MobileViewportApplyGovernor()
        _ = governor.request(.cap(columns: 72, rows: 60))
        _ = governor.request(.uncapped)
        _ = governor.flush()
        // Cold attach after a real detach must not wait out the window: the
        // replay fence needs the phone's grid applied before capture.
        #expect(governor.request(.cap(columns: 46, rows: 37)) == .apply(.cap(columns: 46, rows: 37)))
    }

    @Test func stagedKindSwitchAsksForRescheduleSoUncapGetsItsOwnWindow() {
        // A cap change staged on the short window must not fast-track a clear
        // that lands right behind it: the uncap re-arms the timer so it waits
        // the uncap window from its own arrival (long enough for a remount's
        // re-apply to cancel it).
        var governor = MobileViewportApplyGovernor()
        _ = governor.request(.cap(columns: 72, rows: 60))
        #expect(
            governor.request(.cap(columns: 65, rows: 57))
                == .stage(.cap(columns: 65, rows: 57), scheduleFlush: true)
        )
        #expect(governor.request(.uncapped) == .stage(.uncapped, scheduleFlush: true))
        #expect(governor.request(.cap(columns: 72, rows: 60)) == .drop)
        #expect(governor.flush() == nil)
        #expect(governor.applied == .cap(columns: 72, rows: 60))
    }

    @Test func staleFlushAfterCancelledStageIsInert() {
        var governor = MobileViewportApplyGovernor()
        _ = governor.request(.cap(columns: 72, rows: 60))
        _ = governor.request(.uncapped)
        _ = governor.request(.cap(columns: 72, rows: 60))
        // The timer from the cancelled stage still fires; it must be a no-op
        // and must not clear state needed by the next real stage.
        #expect(governor.flush() == nil)
        #expect(
            governor.request(.cap(columns: 65, rows: 57))
                == .stage(.cap(columns: 65, rows: 57), scheduleFlush: true)
        )
        #expect(governor.flush() == .cap(columns: 65, rows: 57))
    }
}
