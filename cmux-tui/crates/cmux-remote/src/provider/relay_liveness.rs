//! Whether a daemon's relay registration is still alive, and how long to wait
//! before registering again (sans I/O: times are passed in).
//!
//! A Cloud machine that pauses and resumes keeps its relay control socket
//! open on its side, but the relay retired it long ago (a daemon control
//! that is silent for 45 s). Writing a ping into a dead TCP socket succeeds,
//! so a write never notices. The registration is dead when:
//!
//! - a ping got no answer (any control message) within [`PONG_TIMEOUT`]; or
//! - the wall clock moved more than the monotonic clock between two checks
//!   ([`ClockWatch`]). A paused VM's monotonic clock stands still while its
//!   wall clock is set forward on resume. A jump past [`CLOCK_JUMP`] sends a
//!   ping at once instead of at the next heartbeat; a jump past
//!   [`RELAY_RETIRES_SILENT`] is a resume the relay's control did not
//!   survive, so the registration is dead at once ([`Check::Resumed`]); or
//! - the monotonic clock itself moved past [`RELAY_RETIRES_SILENT`] between
//!   two checks ([`Look::outlived_relay`]). A VM provider that keeps every
//!   guest clock running through a pause (cmux-host's pause watch relies on
//!   the same) never steps the wall clock past the monotonic one, but the
//!   loop, which checks every [`CHECK_INTERVAL`], did not run for the whole
//!   pause: its control was silent past the relay's retirement, whatever
//!   froze it, so this is [`Check::Resumed`] too, with no ping into the dead
//!   socket and no [`PONG_TIMEOUT`].
//!
//! A registration's first [`YOUNG`] probes every [`CHECK_INTERVAL`], not
//! every heartbeat: a Cloud machine just restored and bound has a network
//! that is still settling, and a control socket that dies silently then
//! takes every Incoming with it (a dial waits for its lanes until the next
//! heartbeat, about 10 s, plus [`PONG_TIMEOUT`]). Probed this way a death in
//! those seconds is found within about `CHECK_INTERVAL + PONG_TIMEOUT`.
//!
//! The registration loop checks every [`CHECK_INTERVAL`], so a dead
//! registration after a resume is found within about `CHECK_INTERVAL`. It
//! then registers again with a fresh ticket ([`Retry`]): at once after a
//! resume, else after a jittered backoff ([`Backoff`]) that starts at
//! [`FIRST_BACKOFF`] and resets once a registration is ready. A resume while
//! the loop waits out a backoff (a credential source that failed before the
//! pause) also ends the wait, resets the backoff and registers at once.

use std::time::{Duration, SystemTime};

use tokio::time::Instant;

/// How often the loop checks the clocks and an outstanding ping.
pub(crate) const CHECK_INTERVAL: Duration = Duration::from_secs(1);
/// How long a ping may go unanswered.
pub(crate) const PONG_TIMEOUT: Duration = Duration::from_secs(3);
/// A wall-clock step beyond the monotonic clock that counts as a resume.
pub(crate) const CLOCK_JUMP: Duration = Duration::from_secs(2);
/// A pause longer than this outlived the registration: the relay retires a
/// daemon control that is silent for 45 s.
pub(crate) const RELAY_RETIRES_SILENT: Duration = Duration::from_secs(45);
/// How long a new registration probes every [`CHECK_INTERVAL`] instead of
/// every heartbeat.
pub(crate) const YOUNG: Duration = Duration::from_secs(20);
/// The first wait before registering again.
pub(crate) const FIRST_BACKOFF: Duration = Duration::from_millis(100);
/// The longest wait before registering again.
pub(crate) const MAX_BACKOFF: Duration = Duration::from_secs(5);
/// The first wait after a relay credential source (a ticket command) failed.
pub(crate) const FIRST_CREDENTIAL_BACKOFF: Duration = Duration::from_secs(1);
/// The longest wait after a relay credential source failed. Each attempt
/// asks the ticket issuer again, so a source that keeps failing is asked
/// at most about once a minute.
pub(crate) const MAX_CREDENTIAL_BACKOFF: Duration = Duration::from_secs(60);

/// What the loop does after a check.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Check {
    Idle,
    /// Send a ping now.
    Ping,
    /// The registration is dead: close it and register again.
    Dead,
    /// The machine resumed from a pause the registration did not survive:
    /// close it and register again at once.
    Resumed,
}

/// The wall clock against the monotonic clock: how far the wall clock moved
/// past the monotonic one since the last look (a paused VM's resume).
#[derive(Debug)]
pub(crate) struct ClockWatch {
    last: (Instant, SystemTime),
}

impl ClockWatch {
    pub(crate) fn new(mono: Instant, wall: SystemTime) -> Self {
        Self { last: (mono, wall) }
    }

    /// Both clocks' steps since the last look.
    pub(crate) fn look(&mut self, mono: Instant, wall: SystemTime) -> Look {
        let (last_mono, last_wall) = self.last;
        self.last = (mono, wall);
        let mono_step = mono.duration_since(last_mono);
        let wall_step = wall.duration_since(last_wall).unwrap_or_default();
        Look { wall_ahead: wall_step.saturating_sub(mono_step), mono_step }
    }
}

/// One [`ClockWatch::look`].
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Look {
    /// How far the wall clock stepped past the monotonic one: a resume where
    /// the monotonic clock stood still through the pause.
    pub(crate) wall_ahead: Duration,
    /// How far the monotonic clock moved: a resume where every guest clock
    /// kept running through the pause shows here, as a gap between two looks
    /// that are [`CHECK_INTERVAL`] apart while the process runs.
    pub(crate) mono_step: Duration,
}

impl Look {
    /// The looker did not run for longer than the relay keeps a silent
    /// daemon control, by either clock: the registration from before is gone.
    pub(crate) fn outlived_relay(self) -> bool {
        self.wall_ahead > RELAY_RETIRES_SILENT || self.mono_step > RELAY_RETIRES_SILENT
    }
}

/// The liveness of one registration.
#[derive(Debug)]
pub(crate) struct Liveness {
    heartbeat: Duration,
    ready_at: Instant,
    young: Duration,
    last_ping: Instant,
    awaiting_since: Option<Instant>,
    clocks: ClockWatch,
}

impl Liveness {
    /// A registration that became ready at `mono`/`wall`, pinging every
    /// `heartbeat` when nothing else happens.
    pub(crate) fn new(heartbeat: Duration, mono: Instant, wall: SystemTime) -> Self {
        Self::with_young(heartbeat, YOUNG, mono, wall)
    }

    /// As [`Liveness::new`], probing every [`CHECK_INTERVAL`] for its first
    /// `young`.
    pub(crate) fn with_young(
        heartbeat: Duration,
        young: Duration,
        mono: Instant,
        wall: SystemTime,
    ) -> Self {
        Self {
            heartbeat,
            ready_at: mono,
            young,
            last_ping: mono,
            awaiting_since: None,
            clocks: ClockWatch::new(mono, wall),
        }
    }

    /// The check at `mono`/`wall`.
    pub(crate) fn check(&mut self, mono: Instant, wall: SystemTime) -> Check {
        // First: a ping sent just before a pause is overdue after it, and a
        // resume (no backoff, circuits ended) is the truer ending.
        let look = self.clocks.look(mono, wall);
        if look.outlived_relay() {
            return Check::Resumed;
        }
        if self.awaiting_since.is_some_and(|since| mono.duration_since(since) >= PONG_TIMEOUT) {
            return Check::Dead;
        }
        let jumped = look.wall_ahead > CLOCK_JUMP;
        let young = mono.duration_since(self.ready_at) < self.young;
        let every = if young { CHECK_INTERVAL.min(self.heartbeat) } else { self.heartbeat };
        let due = mono.duration_since(self.last_ping) >= every;
        if self.awaiting_since.is_none() && (jumped || due) {
            self.last_ping = mono;
            self.awaiting_since = Some(mono);
            return Check::Ping;
        }
        Check::Idle
    }

    /// Any control message arrived: the registration is alive.
    pub(crate) fn on_inbound(&mut self) {
        self.awaiting_since = None;
    }
}

/// Full-jitter exponential backoff between registrations.
#[derive(Debug)]
pub(crate) struct Backoff {
    first: Duration,
    maximum: Duration,
    ceiling: Duration,
}

impl Backoff {
    pub(crate) fn new() -> Self {
        Self::with_bounds(FIRST_BACKOFF, MAX_BACKOFF)
    }

    /// The backoff after relay credential source failures.
    pub(crate) fn credential() -> Self {
        Self::with_bounds(FIRST_CREDENTIAL_BACKOFF, MAX_CREDENTIAL_BACKOFF)
    }

    fn with_bounds(first: Duration, maximum: Duration) -> Self {
        Self { first, maximum, ceiling: first }
    }

    /// The next wait for a random `unit` in `[0, 1)`: a uniform share of the
    /// ceiling, which then doubles up to the maximum ([`MAX_BACKOFF`]).
    pub(crate) fn next(&mut self, unit: f64) -> Duration {
        let wait = self.ceiling.mul_f64(unit.clamp(0.0, 1.0));
        self.ceiling = (self.ceiling * 2).min(self.maximum);
        wait
    }

    /// A registration became ready: start from the first wait again.
    pub(crate) fn reset(&mut self) {
        self.ceiling = self.first;
    }
}

/// How an attempt to register ended, for [`Retry::wait`].
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Ended {
    /// The relay refused or the socket failed.
    Relay,
    /// The credential source (the ticket command) failed.
    Credential,
    /// The machine resumed: the registration from before the pause is gone.
    Resumed,
}

/// The waits between registrations: one backoff after relay failures, one
/// after credential source failures, both reset by a ready registration or
/// a resume.
#[derive(Debug)]
pub(crate) struct Retry {
    relay: Backoff,
    credential: Backoff,
}

impl Retry {
    pub(crate) fn new() -> Self {
        Self { relay: Backoff::new(), credential: Backoff::credential() }
    }

    /// A registration got ready (and may have ended since).
    pub(crate) fn ready(&mut self) {
        self.relay.reset();
        self.credential.reset();
    }

    /// The wait before the next attempt, for a random `unit` in `[0, 1)`. A
    /// resume waits nothing and starts both backoffs over.
    pub(crate) fn wait(&mut self, ended: Ended, unit: f64) -> Duration {
        match ended {
            Ended::Relay => self.relay.next(unit),
            Ended::Credential => self.credential.next(unit),
            Ended::Resumed => {
                self.ready();
                Duration::ZERO
            }
        }
    }
}

/// A uniform random fraction in `[0, 1)`, or 1 when randomness fails.
pub(crate) fn random_unit() -> f64 {
    let mut bytes = [0_u8; 8];
    if getrandom::fill(&mut bytes).is_err() {
        return 1.0;
    }
    (u64::from_be_bytes(bytes) >> 11) as f64 / (1_u64 << 53) as f64
}

#[cfg(test)]
mod tests {
    use super::*;

    const HEARTBEAT: Duration = Duration::from_secs(15);

    fn start() -> (Instant, SystemTime) {
        (Instant::now(), SystemTime::UNIX_EPOCH + Duration::from_secs(1_800_000_000))
    }

    #[test]
    fn a_quiet_live_registration_pings_on_its_heartbeat() {
        let (mono, wall) = start();
        let mut live = Liveness::with_young(HEARTBEAT, Duration::ZERO, mono, wall);
        let at = |s: u64| (mono + Duration::from_secs(s), wall + Duration::from_secs(s));
        for s in 1..15 {
            let (m, w) = at(s);
            assert_eq!(live.check(m, w), Check::Idle, "{s}");
        }
        let (m, w) = at(15);
        assert_eq!(live.check(m, w), Check::Ping);
        live.on_inbound();
        let (m, w) = at(16);
        assert_eq!(live.check(m, w), Check::Idle);
    }

    #[test]
    fn an_unanswered_ping_is_a_dead_registration() {
        let (mono, wall) = start();
        let mut live = Liveness::with_young(HEARTBEAT, Duration::ZERO, mono, wall);
        let at = |s: u64| (mono + Duration::from_secs(s), wall + Duration::from_secs(s));
        let (m, w) = at(15);
        assert_eq!(live.check(m, w), Check::Ping);
        let (m, w) = at(17);
        assert_eq!(live.check(m, w), Check::Idle);
        let (m, w) = at(18);
        assert_eq!(live.check(m, w), Check::Dead);
    }

    /// A short pause (30 s, inside the relay's 45 s): the monotonic clock
    /// stands still while the wall clock moves. The next check pings at once,
    /// and a dead registration is found within PONG_TIMEOUT, long before the
    /// next heartbeat.
    #[test]
    fn a_short_pause_pings_at_once_and_finds_a_dead_registration_in_seconds() {
        let (mono, wall) = start();
        let mut live = Liveness::with_young(HEARTBEAT, Duration::ZERO, mono, wall);
        let (m, w) = (mono + Duration::from_secs(5), wall + Duration::from_secs(5));
        assert_eq!(live.check(m, w), Check::Idle);
        // Paused 30 s: monotonic +1 s (the next check), wall +31 s.
        let resumed = (m + CHECK_INTERVAL, w + Duration::from_secs(31));
        assert_eq!(live.check(resumed.0, resumed.1), Check::Ping);
        let later =
            |s: u64| (resumed.0 + Duration::from_secs(s), resumed.1 + Duration::from_secs(s));
        let (m, w) = later(2);
        assert_eq!(live.check(m, w), Check::Idle);
        let (m, w) = later(3);
        assert_eq!(live.check(m, w), Check::Dead);
    }

    /// A pause past the relay's 45 s: the registration is dead at once, with
    /// no ping and no pong timeout.
    #[test]
    fn a_resume_past_the_relays_retirement_is_a_dead_registration_at_once() {
        let (mono, wall) = start();
        let mut live = Liveness::with_young(HEARTBEAT, Duration::ZERO, mono, wall);
        let (m, w) = (mono + CHECK_INTERVAL, wall + CHECK_INTERVAL + Duration::from_secs(600));
        assert_eq!(live.check(m, w), Check::Resumed);
    }

    /// A pause past the relay's 45 s on a VM provider that keeps every guest
    /// clock running through it: the monotonic clock moves as far as the wall
    /// clock, so the wall clock never steps past it. The loop still did not
    /// look for ten minutes, so the registration is dead at once, with no
    /// ping into the dead socket and no 3 s pong timeout.
    #[test]
    fn a_resume_whose_clocks_all_kept_running_is_a_dead_registration_at_once() {
        let (mono, wall) = start();
        let mut live = Liveness::with_young(HEARTBEAT, Duration::ZERO, mono, wall);
        let (m, w) = (mono + CHECK_INTERVAL, wall + CHECK_INTERVAL);
        assert_eq!(live.check(m, w), Check::Idle);
        let paused = Duration::from_secs(600);
        assert_eq!(live.check(m + paused, w + paused), Check::Resumed);
    }

    /// A stall inside the relay's 45 s with both clocks moving together is no
    /// resume: the registration may have survived, so it is pinged as before.
    #[test]
    fn a_monotonic_gap_inside_the_relays_retirement_pings_instead() {
        let (mono, wall) = start();
        let mut live = Liveness::with_young(HEARTBEAT, Duration::ZERO, mono, wall);
        let gap = RELAY_RETIRES_SILENT - CHECK_INTERVAL;
        assert_eq!(live.check(mono + gap, wall + gap), Check::Ping);
    }

    /// A credential source failed three times before a pause (its backoff
    /// is up to 8 s); the resume registers at once and starts the backoff over.
    #[test]
    fn a_young_registration_probes_every_check_and_finds_a_silent_death_in_seconds() {
        let (mono, wall) = start();
        let mut live = Liveness::new(Duration::from_secs(10), mono, wall);
        let at = |s: u64| (mono + Duration::from_secs(s), wall + Duration::from_secs(s));
        // Answered probes every second while young.
        for s in 1..=3 {
            let (m, w) = at(s);
            assert_eq!(live.check(m, w), Check::Ping, "{s}");
            live.on_inbound();
        }
        // The socket dies silently: the probe at 4 s goes unanswered.
        let (m, w) = at(4);
        assert_eq!(live.check(m, w), Check::Ping);
        let (m, w) = at(5);
        assert_eq!(live.check(m, w), Check::Idle);
        let (m, w) = at(6);
        assert_eq!(live.check(m, w), Check::Idle);
        let (m, w) = at(7);
        assert_eq!(live.check(m, w), Check::Dead, "found 3 s after the death, not 13 s");
    }

    #[test]
    fn a_registration_past_young_falls_back_to_its_heartbeat() {
        let (mono, wall) = start();
        let mut live = Liveness::new(Duration::from_secs(10), mono, wall);
        let at = |s: u64| (mono + Duration::from_secs(s), wall + Duration::from_secs(s));
        let young = YOUNG.as_secs();
        for s in 1..young {
            let (m, w) = at(s);
            assert_eq!(live.check(m, w), Check::Ping, "{s}");
            live.on_inbound();
        }
        // The last young probe was at young - 1; the next is a heartbeat later.
        for s in young..young - 1 + 10 {
            let (m, w) = at(s);
            assert_eq!(live.check(m, w), Check::Idle, "{s}");
        }
        let (m, w) = at(young - 1 + 10);
        assert_eq!(live.check(m, w), Check::Ping);
    }

    #[test]
    fn a_resume_registers_with_no_backoff_and_starts_the_backoffs_over() {
        let mut retry = Retry::new();
        for _ in 0..3 {
            retry.wait(Ended::Credential, 1.0);
        }
        assert_eq!(retry.wait(Ended::Credential, 1.0), Duration::from_secs(8));
        assert_eq!(retry.wait(Ended::Resumed, 1.0), Duration::ZERO);
        assert_eq!(retry.wait(Ended::Credential, 1.0), FIRST_CREDENTIAL_BACKOFF);
        assert_eq!(retry.wait(Ended::Relay, 1.0), FIRST_BACKOFF);
    }

    #[test]
    fn the_clock_watch_sees_a_pause_and_not_a_steady_clock() {
        let (mono, wall) = start();
        let mut clocks = ClockWatch::new(mono, wall);
        let steady = clocks.look(mono + CHECK_INTERVAL, wall + CHECK_INTERVAL);
        assert_eq!(steady, Look { wall_ahead: Duration::ZERO, mono_step: CHECK_INTERVAL });
        assert!(!steady.outlived_relay());
        let (m, w) = (mono + CHECK_INTERVAL * 2, wall + CHECK_INTERVAL * 2 + RELAY_RETIRES_SILENT);
        let at_retirement = clocks.look(m, w);
        assert_eq!(at_retirement.wall_ahead, RELAY_RETIRES_SILENT);
        assert!(!at_retirement.outlived_relay(), "the relay retires past 45 s, not at it");
        let (m, w) = (m + CHECK_INTERVAL, w + CHECK_INTERVAL + Duration::from_secs(46));
        let past = clocks.look(m, w);
        assert_eq!(past.wall_ahead, Duration::from_secs(46));
        assert!(past.outlived_relay());
        let back = clocks.look(m + CHECK_INTERVAL, w - Duration::from_secs(600));
        assert_eq!(back.wall_ahead, Duration::ZERO, "a clock set back is no resume");
        assert!(!back.outlived_relay());
        // Every guest clock kept running through a 46 s pause: no wall step,
        // but a monotonic gap past the relay's retirement.
        let gap = Duration::from_secs(46);
        let (m, w) = (m + CHECK_INTERVAL + gap, w - Duration::from_secs(600) + gap);
        let running = clocks.look(m, w);
        assert_eq!(running, Look { wall_ahead: Duration::ZERO, mono_step: gap });
        assert!(running.outlived_relay());
    }

    /// A ping sent just before a pause is overdue after it: the resume wins,
    /// so the registration goes again with no backoff.
    #[test]
    fn a_ping_outstanding_across_a_pause_ends_as_a_resume() {
        let (mono, wall) = start();
        let mut live = Liveness::with_young(HEARTBEAT, Duration::ZERO, mono, wall);
        let (m, w) = (mono + HEARTBEAT, wall + HEARTBEAT);
        assert_eq!(live.check(m, w), Check::Ping);
        let paused = Duration::from_secs(600);
        assert_eq!(live.check(m + paused, w + paused), Check::Resumed);
    }

    #[test]
    fn a_wall_clock_set_backwards_or_a_small_step_is_no_resume() {
        let (mono, wall) = start();
        let mut live = Liveness::with_young(HEARTBEAT, Duration::ZERO, mono, wall);
        let m = mono + CHECK_INTERVAL;
        assert_eq!(live.check(m, wall - Duration::from_secs(60)), Check::Idle);
        let m2 = m + CHECK_INTERVAL;
        assert_eq!(
            live.check(m2, wall - Duration::from_secs(60) + CHECK_INTERVAL + CLOCK_JUMP),
            Check::Idle
        );
    }

    #[test]
    fn backoff_is_jittered_from_100ms_doubles_to_5s_and_resets() {
        let mut backoff = Backoff::new();
        assert_eq!(backoff.next(0.5), Duration::from_millis(50));
        assert_eq!(backoff.next(1.0), Duration::from_millis(200));
        assert_eq!(backoff.next(0.0), Duration::ZERO);
        for _ in 0..10 {
            backoff.next(0.5);
        }
        assert_eq!(backoff.next(1.0), MAX_BACKOFF);
        backoff.reset();
        assert_eq!(backoff.next(1.0), FIRST_BACKOFF);
        let unit = random_unit();
        assert!((0.0..1.0).contains(&unit) || unit == 1.0);
    }

    #[test]
    fn credential_backoff_doubles_from_1s_to_a_60s_cap() {
        let mut backoff = Backoff::credential();
        assert_eq!(backoff.next(1.0), FIRST_CREDENTIAL_BACKOFF);
        assert_eq!(backoff.next(1.0), Duration::from_secs(2));
        for _ in 0..20 {
            backoff.next(0.5);
        }
        assert_eq!(backoff.next(1.0), MAX_CREDENTIAL_BACKOFF);
        backoff.reset();
        assert_eq!(backoff.next(1.0), FIRST_CREDENTIAL_BACKOFF);
    }
}
