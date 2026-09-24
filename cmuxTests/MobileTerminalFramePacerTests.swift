import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The mobile frame pacer must coalesce sustained TUI repaints to a bounded
/// per-surface rate (floor ~11fps) without ever delaying a keystroke echo,
/// and must widen its period when the transport sheds
/// (field context: an animating agent ships ~27fps / ~100KB/s over the relay,
/// and keystroke echoes queue behind that firehose).
@Suite("Mobile terminal frame pacer")
struct MobileTerminalFramePacerTests {
    private let t0 = ContinuousClock.now

    @Test func firstUpdateEmitsImmediately() {
        var pacer = MobileTerminalFramePacer()
        let decision = pacer.updateArrived(now: t0, acceptedInputSequence: nil)
        #expect(decision == .emit)
    }

    @Test func sustainedRepaintsCoalesceToTheFloorRate() {
        var pacer = MobileTerminalFramePacer()
        _ = pacer.updateArrived(now: t0, acceptedInputSequence: nil)
        var emits = 1
        var scheduled = 0
        // A 27fps burst: updates every 37ms for one second.
        for i in 1...27 {
            let now = t0 + .milliseconds(37 * i)
            switch pacer.updateArrived(now: now, acceptedInputSequence: nil) {
            case .emit: emits += 1
            case .coalesceAndSchedule: scheduled += 1
            case .coalesce: break
            }
        }
        // At a 90ms floor, one second of 27fps input yields at most ~12
        // immediate emits; the rest coalesce behind at most one scheduled
        // flush at a time.
        #expect(emits <= 12, "emitted \(emits)/28 updates: the firehose is not being paced")
        #expect(scheduled >= 1)
    }

    @Test func echoBearingUpdateBypassesThePeriod() {
        var pacer = MobileTerminalFramePacer()
        _ = pacer.updateArrived(now: t0, acceptedInputSequence: 41)
        // 10ms later — far inside the period — but the accepted-input marker
        // moved: this frame carries the user's keystroke echo.
        let decision = pacer.updateArrived(now: t0 + .milliseconds(10), acceptedInputSequence: 42)
        #expect(decision == .emit, "echo-bearing frame was paced: \(decision)")
    }

    @Test func unchangedInputSequenceDoesNotBypass() {
        var pacer = MobileTerminalFramePacer()
        _ = pacer.updateArrived(now: t0, acceptedInputSequence: 42)
        let decision = pacer.updateArrived(now: t0 + .milliseconds(10), acceptedInputSequence: 42)
        #expect(decision != .emit, "non-echo frame inside the period must coalesce")
    }

    @Test func scheduledFlushEmitsThePendingFrame() {
        var pacer = MobileTerminalFramePacer()
        _ = pacer.updateArrived(now: t0, acceptedInputSequence: nil)
        let d = pacer.updateArrived(now: t0 + .milliseconds(10), acceptedInputSequence: nil)
        guard case .coalesceAndSchedule(let deadline) = d else {
            Issue.record("expected a scheduled flush, got \(d)")
            return
        }
        #expect(deadline >= t0 + MobileTerminalFramePacer.floorPeriod)
        let flushed = pacer.flushFired(now: deadline)
        #expect(flushed, "the flush must emit the held frame")
    }

    @Test func flushAfterBypassEmitIsANoOp() {
        var pacer = MobileTerminalFramePacer()
        _ = pacer.updateArrived(now: t0, acceptedInputSequence: 1)
        _ = pacer.updateArrived(now: t0 + .milliseconds(10), acceptedInputSequence: 1)
        // An echo emit services the surface before the timer fires.
        _ = pacer.updateArrived(now: t0 + .milliseconds(20), acceptedInputSequence: 2)
        let flushed = pacer.flushFired(now: t0 + MobileTerminalFramePacer.floorPeriod)
        #expect(!flushed, "flush re-emitted a frame the bypass already serviced")
    }

    @Test func transportShedWidensThePeriodAndQuietRecoversIt() {
        var pacer = MobileTerminalFramePacer()
        _ = pacer.updateArrived(now: t0, acceptedInputSequence: nil)
        pacer.transportDidShed(now: t0 + .milliseconds(50))
        #expect(pacer.period > MobileTerminalFramePacer.floorPeriod, "shed must widen the period")
        var widened = pacer.period
        for i in 1...10 {
            pacer.transportDidShed(now: t0 + .milliseconds(50 + i))
        }
        #expect(pacer.period <= MobileTerminalFramePacer.ceilingPeriod, "period must stay capped at the ceiling")
        widened = pacer.period
        // Quiet recovery: an update long after the last shed decays the period.
        _ = pacer.updateArrived(
            now: t0 + MobileTerminalFramePacer.recoveryInterval + .seconds(1),
            acceptedInputSequence: nil
        )
        #expect(pacer.period < widened, "quiet interval must decay the period toward the floor")
    }

    @Test func telemetrySampleSummarizesActivityAtMostOncePerInterval() {
        var pacer = MobileTerminalFramePacer()
        _ = pacer.updateArrived(now: t0, acceptedInputSequence: nil)
        _ = pacer.updateArrived(now: t0 + .milliseconds(10), acceptedInputSequence: nil)
        _ = pacer.updateArrived(now: t0 + .milliseconds(20), acceptedInputSequence: nil)
        pacer.transportDidShed(now: t0 + .milliseconds(30))
        let first = pacer.takeSample(now: t0 + .milliseconds(40))
        #expect(first?.emitted == 1)
        #expect(first?.coalesced == 2)
        #expect(first?.sheds == 1)
        #expect((first?.periodMillis ?? 0) > 90)
        // Inside the sampling interval: nothing extra on the wire.
        _ = pacer.updateArrived(now: t0 + .milliseconds(500), acceptedInputSequence: nil)
        let second = pacer.takeSample(now: t0 + .milliseconds(600))
        #expect(second == nil)
        // After the interval the counters restarted from the previous sample.
        let third = pacer.takeSample(now: t0 + .milliseconds(40) + MobileTerminalFramePacer.sampleInterval)
        #expect(third?.coalesced == 0)
        #expect(third?.emitted == 1)
    }

    @Test func idlePacerProducesNoSample() {
        var pacer = MobileTerminalFramePacer()
        let sample = pacer.takeSample(now: t0)
        #expect(sample == nil)
    }
}
