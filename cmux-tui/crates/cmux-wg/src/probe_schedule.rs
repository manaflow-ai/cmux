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
//!
//! [`PathWatch`] adds the quiet-path rule to one path's probes, with no
//! carrier attached, so a [`crate::Multipath`] (a carrier per path) and a
//! mesh peer (an address per path on one shared socket) run the same rule.

use std::time::Duration;

use cmux_transport::{PathId, PathState, PathView, Selector};
use tokio::time::Instant;

/// The shortest silence window: below it, scheduling jitter alone would
/// look like a dead path.
const SILENCE_FLOOR: Duration = Duration::from_millis(100);

/// How long the current path may stay silent, and then leave a probe
/// unanswered, before the underlay acts: four smoothed round trips, at
/// least [`SILENCE_FLOOR`].
pub fn silence_window(rtt_us: Option<u64>) -> Duration {
    let rtt = Duration::from_micros(rtt_us.unwrap_or(0));
    rtt.saturating_mul(4).max(SILENCE_FLOOR)
}

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

impl PathProbe {
    /// The probe waiting for its answer, and when it was sent.
    pub(crate) fn outstanding(&self) -> Option<(u64, Instant)> {
        self.outstanding
    }

    /// Probe at the next step, whatever the interval said (the path went
    /// quiet).
    pub(crate) fn due_now(&mut self, now: Instant) {
        if self.next_at.is_none_or(|at| at > now) {
            self.next_at = Some(now);
        }
    }
}

/// One path's probe and silence state, without its carrier.
#[derive(Debug, Default, Clone, Copy)]
pub(crate) struct PathWatch {
    pub(crate) probe: PathProbe,
    /// The first send on this path since it last delivered an
    /// authenticated datagram: how long it has been silent.
    unanswered_since: Option<Instant>,
    /// The outstanding probe that already made this path suspect.
    flagged_probe: Option<u64>,
}

impl PathWatch {
    /// A datagram left on this path.
    pub(crate) fn sent(&mut self, now: Instant) {
        self.unanswered_since.get_or_insert(now);
    }

    /// An authenticated datagram arrived on this path.
    pub(crate) fn heard(&mut self) {
        self.unanswered_since = None;
    }
}

/// What the paths of one peer need now: the pings to send, when they next
/// need anything, and the outcomes for the selector (probes lost, and
/// chosen paths gone quiet).
#[derive(Debug, Default, PartialEq, Eq)]
pub(crate) struct WatchDue {
    pub pings: Vec<(PathId, u64)>,
    pub next: Option<Instant>,
    pub lost: Vec<PathId>,
    pub silent: Vec<PathId>,
}

fn earliest(a: Option<Instant>, b: Option<Instant>) -> Option<Instant> {
    match (a, b) {
        (Some(a), Some(b)) => Some(a.min(b)),
        (a, b) => a.or(b),
    }
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
            // A suspect proves itself alive, or dead, as fast as a new path.
            PathState::Probing | PathState::Suspect => self.dial_interval,
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

    /// Step every path of one peer. The chosen path's silence counts too:
    /// it is probed at once when it went quiet, and reported silent when
    /// that probe is not answered within the window. The caller feeds
    /// `lost` to [`Selector::on_probe`] and `silent` to
    /// [`Selector::on_silence`].
    pub(crate) fn watch<'a>(
        &self,
        selector: &Selector,
        paths: impl Iterator<Item = (PathId, &'a mut PathWatch)>,
        next_id: &mut u64,
        now: Instant,
    ) -> WatchDue {
        let current = selector.current();
        let chosen = selector.chosen();
        let mut due = WatchDue::default();
        for (id, watch) in paths {
            let Some(view) = selector.path(id) else { continue };
            let mut silence_at = None;
            let window = silence_window(view.rtt_us);
            if chosen == Some(id) {
                match watch.probe.outstanding() {
                    Some((probe, sent)) if watch.flagged_probe != Some(probe) => {
                        if now >= sent + window {
                            watch.flagged_probe = Some(probe);
                            due.silent.push(id);
                        } else {
                            silence_at = Some(sent + window);
                        }
                    }
                    Some(_) => {}
                    None => match watch.unanswered_since {
                        Some(since) if now >= since + window => watch.probe.due_now(now),
                        Some(since) => silence_at = Some(since + window),
                        None => {}
                    },
                }
            }
            let step = self.step(&mut watch.probe, &view, current == Some(id), next_id, now);
            if step.lost {
                due.lost.push(id);
            }
            if let Some(probe) = step.ping {
                due.pings.push((id, probe));
                // A probe just sent on the chosen path (a silence probe
                // among them) is judged one window from now, not at its
                // 1 s timeout.
                if chosen == Some(id) {
                    silence_at = earliest(silence_at, Some(now + window));
                }
            }
            due.next = earliest(earliest(due.next, step.next), silence_at);
        }
        due
    }

    /// The round trip of probe `id`, if it is the one outstanding.
    pub(crate) fn answer(&self, probe: &mut PathProbe, id: u64, now: Instant) -> Option<u64> {
        let (outstanding, sent) = probe.outstanding?;
        if outstanding != id {
            return None;
        }
        probe.outstanding = None;
        Some(
            u64::try_from(now.saturating_duration_since(sent).as_micros())
                .unwrap_or(u64::MAX)
                .max(1),
        )
    }
}
