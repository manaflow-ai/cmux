//! One terminal size change in flight toward the child at a time.
//!
//! A PTY is a byte stream with no record of the width each byte was written
//! for. After SIGWINCH a shell redraws its prompt for the size it read, with
//! relative cursor motion computed at that width. If the terminal is resized
//! again before those bytes are parsed, they land on a grid of another width
//! and leave fragments of the prompt behind. Coalescing a burst of resizes
//! only narrows that window; a shell that takes longer to answer than the
//! coalescing delay still races it.
//!
//! The gate removes the race instead: after a size reaches the child, the
//! next one waits until the child has answered and gone quiet. At a shell
//! prompt (known from OSC 133) a redraw is expected, so the gate waits for
//! it to start rather than mistaking a slow shell (bash with ble.sh takes
//! about 55 ms to write its first byte) for a silent one. Elsewhere, a short
//! quiet period releases it. Caps bound the wait for programs that never
//! answer or never go quiet. The latest requested size always wins.

use std::time::{Duration, Instant};

/// Output gap that ends a child's answer to a resize.
pub(crate) const ANSWER_QUIET: Duration = Duration::from_millis(30);
/// Longest wait for a prompt redraw that has not started or not finished.
pub(crate) const PROMPT_ANSWER_CAP: Duration = Duration::from_millis(300);
/// Longest wait while a running program keeps writing.
pub(crate) const PROGRAM_ANSWER_CAP: Duration = Duration::from_millis(250);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum GateDecision {
    /// No size change is waiting on the child; apply now.
    Open,
    /// Check again at this instant (output may open the gate sooner).
    WaitUntil(Instant),
}

#[derive(Debug, Default)]
pub(crate) struct ResizeGate {
    in_flight: Option<InFlight>,
}

#[derive(Debug, Clone, Copy)]
struct InFlight {
    since: Instant,
    expects_redraw: bool,
}

impl ResizeGate {
    /// Whether a new size may be applied at `now`, given the time of the most
    /// recent child output.
    pub(crate) fn decide(&self, now: Instant, last_output: Option<Instant>) -> GateDecision {
        let Some(in_flight) = self.in_flight else { return GateDecision::Open };
        let cap = in_flight.since
            + if in_flight.expects_redraw { PROMPT_ANSWER_CAP } else { PROGRAM_ANSWER_CAP };
        if now >= cap {
            return GateDecision::Open;
        }
        let answered_at = last_output.filter(|at| *at >= in_flight.since);
        let quiet_from = match answered_at {
            Some(at) => at,
            // A shell at its prompt answers with a redraw; wait for it.
            None if in_flight.expects_redraw => return GateDecision::WaitUntil(cap),
            None => in_flight.since,
        };
        let due = quiet_from + ANSWER_QUIET;
        if now >= due { GateDecision::Open } else { GateDecision::WaitUntil(due.min(cap)) }
    }

    /// Record that a size reached the child at `now`.
    pub(crate) fn applied(&mut self, now: Instant, expects_redraw: bool) {
        self.in_flight = Some(InFlight { since: now, expects_redraw });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn at(base: Instant, ms: u64) -> Instant {
        base + Duration::from_millis(ms)
    }

    #[test]
    fn opens_when_nothing_is_in_flight() {
        let gate = ResizeGate::default();
        assert_eq!(gate.decide(Instant::now(), None), GateDecision::Open);
    }

    #[test]
    fn a_prompt_waits_for_a_slow_redraw_to_start_and_finish() {
        let t0 = Instant::now();
        let mut gate = ResizeGate::default();
        gate.applied(t0, true);
        // Output from before the resize is not an answer.
        assert_eq!(
            gate.decide(at(t0, 40), Some(at(t0, 0) - Duration::from_millis(5))),
            GateDecision::WaitUntil(at(t0, 300))
        );
        // Silent for 54 ms: still waiting (a quiet gap alone is not enough).
        assert_eq!(gate.decide(at(t0, 54), None), GateDecision::WaitUntil(at(t0, 300)));
        // The redraw starts at 55 ms and ends at 64 ms.
        assert_eq!(gate.decide(at(t0, 70), Some(at(t0, 64))), GateDecision::WaitUntil(at(t0, 94)));
        assert_eq!(gate.decide(at(t0, 94), Some(at(t0, 64))), GateDecision::Open);
    }

    #[test]
    fn a_prompt_that_never_redraws_opens_at_its_cap() {
        let t0 = Instant::now();
        let mut gate = ResizeGate::default();
        gate.applied(t0, true);
        assert_eq!(gate.decide(at(t0, 299), None), GateDecision::WaitUntil(at(t0, 300)));
        assert_eq!(gate.decide(at(t0, 300), None), GateDecision::Open);
    }

    #[test]
    fn a_running_program_opens_after_a_short_quiet_period() {
        let t0 = Instant::now();
        let mut gate = ResizeGate::default();
        gate.applied(t0, false);
        assert_eq!(gate.decide(at(t0, 10), None), GateDecision::WaitUntil(at(t0, 30)));
        assert_eq!(gate.decide(at(t0, 30), None), GateDecision::Open);
    }

    #[test]
    fn continuous_output_opens_at_the_program_cap() {
        let t0 = Instant::now();
        let mut gate = ResizeGate::default();
        gate.applied(t0, false);
        assert_eq!(gate.decide(at(t0, 240), Some(at(t0, 239))), GateDecision::WaitUntil(at(t0, 250)));
        assert_eq!(gate.decide(at(t0, 250), Some(at(t0, 249))), GateDecision::Open);
    }
}
