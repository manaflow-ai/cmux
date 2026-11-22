//! When each path of a [`crate::Multipath`] is probed, and when an
//! unanswered probe counts as lost (transport.md section 4, step 6).
//!
//! One probe is outstanding per path at a time. A path that never answered
//! is probed every `dial_interval` (the dial and hole punching), the current
//! path every `current_interval`, and every other path every
//! `other_interval`. A probe without an answer after `timeout` is lost; the
//! selector declares the path dead after its configured number of losses.
//! The driver asks only while the session carries traffic, so an idle
//! session sends no probes.

use std::time::Duration;

use cmux_transport::{PathState, PathView};
use tokio::time::Instant;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ProbeConfig {
    pub current_interval: Duration,
    pub other_interval: Duration,
    pub dial_interval: Duration,
    pub timeout: Duration,
}

impl Default for ProbeConfig {
    /// transport.md: the current path every 5 s, the others every 30 s,
    /// candidates every 100 ms while punching, dead within about 3 s.
    fn default() -> Self {
        Self {
            current_interval: Duration::from_secs(5),
            other_interval: Duration::from_secs(30),
            dial_interval: Duration::from_millis(100),
            timeout: Duration::from_secs(1),
        }
    }
}

/// The probe state of one path.
#[derive(Debug, Default, Clone, Copy)]
pub(crate) struct PathProbe {
    next_at: Option<Instant>,
    outstanding: Option<(u64, Instant)>,
}

/// What one path needs now.
#[derive(Debug, Default, PartialEq, Eq)]
pub(crate) struct ProbeStep {
    /// The outstanding probe timed out.
    pub lost: bool,
    /// Send a ping with this id.
    pub ping: Option<u64>,
    /// When this path next needs attention.
    pub next: Option<Instant>,
}

impl ProbeConfig {
    fn interval(&self, view: &PathView, current: bool) -> Duration {
        match view.state {
            PathState::Probing => self.dial_interval,
            _ if current => self.current_interval,
            _ => self.other_interval,
        }
    }

    pub(crate) fn step(
        &self,
        probe: &mut PathProbe,
        view: &PathView,
        current: bool,
        next_id: &mut u64,
        now: Instant,
    ) -> ProbeStep {
        let mut step = ProbeStep::default();
        if let Some((_, sent)) = probe.outstanding
            && now >= sent + self.timeout
        {
            probe.outstanding = None;
            step.lost = true;
        }
        if probe.outstanding.is_none() && probe.next_at.is_none_or(|at| now >= at) {
            *next_id += 1;
            probe.outstanding = Some((*next_id, now));
            probe.next_at = Some(now + self.interval(view, current));
            step.ping = Some(*next_id);
        }
        // While a probe is outstanding the next one waits for its verdict.
        step.next = match probe.outstanding {
            Some((_, sent)) => Some(sent + self.timeout),
            None => probe.next_at,
        };
        step
    }

    /// The round trip of probe `id`, if it is the one outstanding.
    pub(crate) fn answer(&self, probe: &mut PathProbe, id: u64, now: Instant) -> Option<u64> {
        let (outstanding, sent) = probe.outstanding?;
        if outstanding != id {
            return None;
        }
        probe.outstanding = None;
        Some(u64::try_from((now - sent).as_micros()).unwrap_or(u64::MAX).max(1))
    }
}

#[cfg(test)]
mod tests {
    use cmux_transport::{PathId, PathKind};

    use super::*;

    fn view(state: PathState) -> PathView {
        PathView { id: PathId(0), kind: PathKind::DirectLan, state, rtt_us: None }
    }

    #[test]
    fn a_new_path_is_pinged_at_once_then_at_the_dial_interval() {
        let config = ProbeConfig::default();
        let (mut probe, mut ids, start) = (PathProbe::default(), 0, Instant::now());
        let step = config.step(&mut probe, &view(PathState::Probing), false, &mut ids, start);
        assert_eq!(step.ping, Some(1));
        assert_eq!(step.next, Some(start + config.timeout), "the verdict comes first");
        let answered = start + Duration::from_millis(7);
        assert_eq!(config.answer(&mut probe, 1, answered), Some(7_000));
        let step = config.step(&mut probe, &view(PathState::Alive), true, &mut ids, answered);
        assert_eq!(step.next, Some(start + config.dial_interval), "then the next ping");
        let later = start + config.dial_interval;
        let step = config.step(&mut probe, &view(PathState::Alive), true, &mut ids, later);
        assert_eq!(step.ping, Some(2));
        assert_eq!(step.next, Some(later + config.timeout), "the timeout comes first");
    }

    #[test]
    fn an_unanswered_probe_is_lost_after_the_timeout() {
        let config = ProbeConfig::default();
        let (mut probe, mut ids, start) = (PathProbe::default(), 0, Instant::now());
        config.step(&mut probe, &view(PathState::Probing), false, &mut ids, start);
        let early = start + config.dial_interval;
        let step = config.step(&mut probe, &view(PathState::Probing), false, &mut ids, early);
        assert_eq!(step, ProbeStep { lost: false, ping: None, next: Some(start + config.timeout) });
        let late = start + config.timeout;
        let step = config.step(&mut probe, &view(PathState::Probing), false, &mut ids, late);
        assert!(step.lost);
        assert_eq!(step.ping, Some(2), "the next probe goes out with the verdict");
        assert_eq!(config.answer(&mut probe, 1, late), None, "a late pong counts for nothing");
    }

    #[test]
    fn alive_paths_use_the_slow_intervals() {
        let config = ProbeConfig::default();
        let alive = view(PathState::Alive);
        assert_eq!(config.interval(&alive, true), config.current_interval);
        assert_eq!(config.interval(&alive, false), config.other_interval);
        assert_eq!(config.interval(&view(PathState::Dead), false), config.other_interval);
    }
}
