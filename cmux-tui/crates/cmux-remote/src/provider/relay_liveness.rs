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
//! A loop that did not run for longer than [`STALL`] (but less than
//! [`RELAY_RETIRES_SILENT`]) with a ping out has not been listening: the
//! answer may be sitting in the socket, and a just-restored machine faults
//! its memory back in and stalls for seconds while the daemon starts. Its
//! next check is [`Check::Stalled`], and the ping gets a fresh
//! [`PONG_TIMEOUT`] of awake time before it counts as unanswered, so a stall
//! never reads as a dead registration (a dead one costs the dial attached
//! to it 4 s or more, and a new ticket).
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
/// A gap between two checks past this is the loop stalling, not listening.
pub(crate) const STALL: Duration = Duration::from_secs(2);
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
    /// The loop did not run for this long with a ping out: the ping waits a
    /// fresh [`PONG_TIMEOUT`] (the answer may be in the socket unread).
    Stalled(Duration),
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
        if self.awaiting_since.is_some() && look.mono_step > STALL {
            self.awaiting_since = Some(mono);
            return Check::Stalled(look.mono_step);
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
#[path = "relay_liveness_tests.rs"]
mod tests;
