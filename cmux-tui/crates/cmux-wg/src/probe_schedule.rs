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
//! [`PathWatch`] adds the quiet-path watch on top: the chosen path that
//! went silent is probed at once, and a probe it leaves unanswered for a
//! [`silence_window`](crate::multipath::silence_window) makes it suspect,
//! so the selector sprays around it. [`crate::Multipath`] keeps one per
//! path; an underlay with its own carriers (the iPhone link's) does too.

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

/// One path's probes and its quiet-path watch: when it was last silent,
/// and which probe already reported that.
#[derive(Debug, Default, Clone, Copy)]
pub struct PathWatch {
    probe: PathProbe,
    /// The first send on this path since it last delivered an
    /// authenticated datagram: how long it has been silent.
    unanswered_since: Option<Instant>,
    /// The outstanding probe that already made this path suspect.
    flagged_probe: Option<u64>,
}

/// What a [`PathWatch`] found at one step.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct WatchStep {
    /// Send a ping with this id on the path.
    pub ping: Option<u64>,
    /// The outstanding probe timed out: report [`ProbeOutcome::Lost`].
    ///
    /// [`ProbeOutcome::Lost`]: cmux_transport::ProbeOutcome::Lost
    pub lost: bool,
    /// The chosen path stayed silent through a probe's window: report
    /// [`Selector::on_silence`](cmux_transport::Selector::on_silence).
    pub silent: bool,
    /// When this path next needs a step.
    pub next: Option<Instant>,
}

impl PathWatch {
    /// A datagram went out on the path at `now`.
    pub fn sent(&mut self, now: Instant) {
        self.unanswered_since.get_or_insert(now);
    }

    /// An authenticated datagram arrived on the path: it is not silent.
    pub fn heard(&mut self) {
        self.unanswered_since = None;
    }

    /// Probe at the next step, whatever the interval says: something on
    /// the path says it may work again (a dead path's peer reached us on
    /// it), so it need not wait out the interval to prove it.
    pub fn probe_now(&mut self, now: Instant) {
        self.probe.due_now(now);
    }

    /// The round trip of probe `id`'s answer, if it is the one outstanding.
    pub fn answer(&mut self, config: &ProbeConfig, id: u64, now: Instant) -> Option<u64> {
        config.answer(&mut self.probe, id, now)
    }

    /// The path's step at `now`. `current` is whether the selector sends on
    /// it, `chosen` whether it holds it (suspect or not); `next_id` is the
    /// underlay's probe id counter. The chosen path that went quiet is
    /// probed at once, and its probe is judged one silence window after it
    /// left, not at the probe timeout.
    pub fn step(
        &mut self,
        config: &ProbeConfig,
        view: &PathView,
        (current, chosen): (bool, bool),
        next_id: &mut u64,
        now: Instant,
    ) -> WatchStep {
        let mut found = WatchStep::default();
        let mut silence_at = None;
        let window = crate::multipath::silence_window(view.rtt_us);
        if chosen {
            match self.probe.outstanding() {
                Some((probe, sent)) if self.flagged_probe != Some(probe) => {
                    if now >= sent + window {
                        self.flagged_probe = Some(probe);
                        found.silent = true;
                    } else {
                        silence_at = Some(sent + window);
                    }
                }
                Some(_) => {}
                None => match self.unanswered_since {
                    Some(since) if now >= since + window => self.probe.due_now(now),
                    Some(since) => silence_at = Some(since + window),
                    None => {}
                },
            }
        }
        let step = config.step(&mut self.probe, view, current, next_id, now);
        found.lost = step.lost;
        found.ping = step.ping;
        if step.ping.is_some() && chosen {
            let at = now + window;
            silence_at = Some(silence_at.map_or(at, |old: Instant| old.min(at)));
        }
        found.next = match (step.next, silence_at) {
            (Some(a), Some(b)) => Some(a.min(b)),
            (a, b) => a.or(b),
        };
        found
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
