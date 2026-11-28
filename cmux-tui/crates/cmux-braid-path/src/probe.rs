//! When each path is probed, and when an unanswered probe counts as lost (transport.md
//! section 4, step 6). Moved here from cmux-wg (RFD 0164 slice B4) so every path manager
//! shares one schedule; cmux-wg re-exports it.
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
//! [`silence_window`] makes it suspect, so the selector sprays around it.
//! [`crate::PathSet`] keeps one per path; an underlay with its own carriers
//! (cmux-wg's `Multipath`, the iPhone link's) does too.

use std::time::Duration;

use cmux_transport::{PathId, PathState, PathView};
use tokio::time::Instant;

/// The shortest silence window: below it, scheduling jitter alone would
/// look like a dead path.
const SILENCE_FLOOR: Duration = Duration::from_millis(100);

/// How long the current path may stay silent, and then leave a probe
/// unanswered, before the path manager acts: four smoothed round trips, at
/// least [`SILENCE_FLOOR`].
#[must_use]
pub fn silence_window(rtt_us: Option<u64>) -> Duration {
    let rtt = Duration::from_micros(rtt_us.unwrap_or(0));
    rtt.saturating_mul(4).max(SILENCE_FLOOR)
}

/// Pings a probing underlay wants sent now (path, probe id), and when it
/// next wants anything: a ping, or the deadline of an unanswered one.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct DueProbes {
    pub pings: Vec<(PathId, u64)>,
    pub next: Option<Instant>,
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
    /// When the last ping left, answered or not.
    last_ping: Option<Instant>,
    /// Something asked for a probe now (`due_now`): it goes out whatever
    /// traffic says.
    urgent: bool,
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
        self.urgent = true;
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
    /// An authenticated datagram arrived on the path since its last ping.
    heard_since_ping: bool,
    /// Routine pings wait until then (`hold_routine`).
    routine_floor: Option<Instant>,
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
        self.heard_since_ping = true;
    }

    /// Probe at the next step, whatever the interval says: something on
    /// the path says it may work again (a dead path's peer reached us on
    /// it), so it need not wait out the interval to prove it.
    pub fn probe_now(&mut self, now: Instant) {
        self.probe.due_now(now);
    }

    /// [`Self::probe_now`], also when a probe is outstanding: one sent at
    /// least `min_age` ago is given up (reported neither answered nor lost;
    /// a late answer to it is ignored), so the new one goes at the next step
    /// instead of after the old one's timeout. For a path the peer just
    /// reached us on while it was dead or never answered: the outstanding
    /// probe went out while the path was black-holed, and waiting out its
    /// 1 s timeout is what kept a session on the relay after the direct path
    /// opened (RFD 0142 R1). `min_age` bounds it to one probe per that long
    /// however many datagrams arrive.
    pub fn probe_now_fresh(&mut self, now: Instant, min_age: Duration) {
        if let Some((_, sent)) = self.probe.outstanding
            && now.saturating_duration_since(sent) >= min_age
        {
            self.probe.outstanding = None;
            self.flagged_probe = None;
        }
        self.probe.due_now(now);
    }

    /// Hold this path's routine pings until `floor` (the link's idle air
    /// gap: the radio stays asleep between the tunnel's own sends), or lift
    /// the hold with `None`. A ping something asked for (`probe_now`, a
    /// path gone quiet) and a new or suspect path's pings never wait.
    pub fn hold_routine(&mut self, floor: Option<Instant>) {
        self.routine_floor = floor;
    }

    /// The round trip of probe `id`'s answer, if it is the one outstanding.
    /// The answer also says the path is not silent. It is the path's own
    /// probe coming back, not other traffic, so it does not stand in for the
    /// next routine ping (`skip_proven_ping`).
    pub fn answer(&mut self, config: &ProbeConfig, id: u64, now: Instant) -> Option<u64> {
        let rtt_us = config.answer(&mut self.probe, id, now)?;
        self.unanswered_since = None;
        self.heard_since_ping = false;
        Some(rtt_us)
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
        let window = silence_window(view.rtt_us);
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
        if current {
            self.skip_proven_ping(config, view, now);
        }
        self.wait_for_floor(view, now);
        let step = config.step(&mut self.probe, view, current, next_id, now);
        if step.ping.is_some() {
            self.heard_since_ping = false;
        }
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

impl PathWatch {
    /// The current path's routine ping is due, but the path delivered an
    /// authenticated datagram since its last one: traffic (the link's own
    /// keepalive and its answer, a key, a frame) already proved it, so the
    /// ping would only spend a radio wake. It waits another interval, up to
    /// `other_interval` after the last ping, when one goes anyway to keep
    /// the round trip current. A ping something asked for (`due_now`: the
    /// path went quiet, a network change) and a suspect or new path are
    /// never skipped.
    fn skip_proven_ping(&mut self, config: &ProbeConfig, view: &PathView, now: Instant) {
        let probe = &mut self.probe;
        let routine_due = probe.outstanding.is_none() && probe.next_at.is_some_and(|at| now >= at);
        if !routine_due || probe.urgent || !self.heard_since_ping || view.state != PathState::Alive
        {
            return;
        }
        let Some(last) = probe.last_ping else { return };
        let refresh = last + config.other_interval;
        if now >= refresh {
            return;
        }
        // A path that later goes quiet under a send is caught by the
        // silence watch (`unanswered_since`), not by this ping.
        probe.next_at = Some((now + config.current_interval).min(refresh));
    }
}

impl PathWatch {
    /// A routine ping due before the hold's floor waits for it.
    fn wait_for_floor(&mut self, view: &PathView, now: Instant) {
        let Some(floor) = self.routine_floor.filter(|floor| *floor > now) else { return };
        let probe = &mut self.probe;
        let routine_due = probe.outstanding.is_none() && probe.next_at.is_some_and(|at| now >= at);
        if routine_due && !probe.urgent && matches!(view.state, PathState::Alive | PathState::Dead)
        {
            probe.next_at = Some(floor);
        }
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
            probe.last_ping = Some(now);
            probe.urgent = false;
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

#[cfg(test)]
mod tests {
    use super::*;
    use cmux_transport::{Medium, PathId, PathKind};

    fn alive() -> PathView {
        PathView {
            id: PathId(0),
            kind: PathKind::DirectLan,
            medium: Medium::Lan,
            state: PathState::Alive,
            rtt_us: Some(10_000),
        }
    }

    /// One step of the current, chosen path: the ping it sent, if any.
    fn step(watch: &mut PathWatch, id: &mut u64, now: Instant) -> Option<u64> {
        watch.step(&ProbeConfig::default(), &alive(), (true, true), id, now).ping
    }

    /// The first ping at `start`, answered at once.
    fn proven(start: Instant) -> (PathWatch, u64) {
        let mut watch = PathWatch::default();
        let mut id = 0;
        let ping = step(&mut watch, &mut id, start).expect("the first ping");
        watch.answer(&ProbeConfig::default(), ping, start).expect("answered");
        (watch, id)
    }

    #[test]
    fn traffic_on_the_current_path_stands_in_for_its_ping_up_to_the_refresh() {
        let start = Instant::now();
        let secs = |n| start + Duration::from_secs(n);
        let (mut watch, mut id) = proven(start);
        watch.heard();
        for at in [5, 10, 15, 20, 25] {
            assert_eq!(step(&mut watch, &mut id, secs(at)), None, "skipped at {at} s");
        }
        assert!(step(&mut watch, &mut id, secs(30)).is_some(), "the round trip refresh");
    }

    #[test]
    fn the_answer_to_its_own_ping_does_not_stand_in_for_the_next() {
        let start = Instant::now();
        let mut watch = PathWatch::default();
        let mut id = 0;
        let ping = step(&mut watch, &mut id, start).expect("the first ping");
        watch.heard(); // the pong's datagram is heard before it is matched
        watch.answer(&ProbeConfig::default(), ping, start).expect("answered");
        assert!(step(&mut watch, &mut id, start + Duration::from_secs(5)).is_some());
    }

    #[test]
    fn a_silent_current_path_is_pinged_on_schedule() {
        let start = Instant::now();
        let (mut watch, mut id) = proven(start);
        assert!(step(&mut watch, &mut id, start + Duration::from_secs(5)).is_some());
    }

    #[test]
    fn the_air_gap_holds_routine_pings_but_not_one_asked_for() {
        let start = Instant::now();
        let secs = |n| start + Duration::from_secs(n);
        let (mut watch, mut id) = proven(start);
        watch.hold_routine(Some(secs(20)));
        assert_eq!(step(&mut watch, &mut id, secs(5)), None, "held to the floor");
        watch.probe_now(secs(6));
        let urgent = step(&mut watch, &mut id, secs(6)).expect("asked for: goes now");
        watch.answer(&ProbeConfig::default(), urgent, secs(6));
        assert_eq!(step(&mut watch, &mut id, secs(11)), None);
        assert!(step(&mut watch, &mut id, secs(20)).is_some(), "the floor passed");
    }
}
