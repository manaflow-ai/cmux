//! How a retry loop spaces attempts after real failures
//! (plans/cmux-next/idle-wakeups.md).
//!
//! Attempts are spaced by a capped, jittered backoff that keeps growing
//! across consecutive failures; after `timed_retries` failures no timer is
//! armed and the loop waits for an event (the daemon socket changed, the
//! network returned, the app became active). A daemon that is relaunched and
//! dies on connect makes a new socket each time; after `socket_retries` such
//! failed attempts a socket change no longer wakes the loop. A loop that
//! starts its own peer (`keeps_trying`, the app's local daemon) keeps one
//! attempt per backoff cap instead, because nothing sends an event when the
//! cause of a failed start goes away (a full disk).
//!
//! The types are `#[repr(C)]` values, so the app keeps them inline (a Swift
//! struct copy is a copy of the pacer) and each step is one C call.

const NANOS_PER_SECOND: f64 = 1_000_000_000.0;
/// An `initial` that is not positive becomes this (the app's `Backoff` default).
const DEFAULT_INITIAL_NS: u64 = 100_000_000;
const MULTIPLIER: f64 = 2.0;
/// The share of each delay drawn at random (0.2: plus or minus 20 %).
const JITTER: f64 = 0.2;

/// The longest spacing after a busy refusal: the daemon is up and frees a
/// slot as soon as one of its connections ends.
pub const BUSY_RETRY_CAP_NS: u64 = 1_000_000_000;

/// The spacing and budget of one retry loop.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct CmuxRetryPolicy {
    /// The first spacing, nanoseconds (positive).
    pub initial_ns: u64,
    /// The cap of the spacing, nanoseconds (at least `initial_ns`).
    pub maximum_ns: u64,
    /// Failures after which retries wait for an event only.
    pub timed_retries: i64,
    /// Failed attempts woken by a socket change after which socket changes
    /// stop waking the loop (a crash loop).
    pub socket_retries: i64,
    /// Past `timed_retries`, keep one timed attempt per `maximum_ns`.
    pub keeps_trying: bool,
}

/// The named policies of the app (`RetryPolicy.reconnect` and the others).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Preset {
    /// Daemon reconnect: 50 ms growing to 30 s, 10 timed attempts.
    Reconnect,
    /// First connect to a daemon: 250 ms growing to 30 s, 10 timed attempts.
    FirstConnect,
    /// The app's own local daemon, which the reconnect starts: as `Reconnect`, then every 30 s.
    LocalReconnect,
    /// The app's first connect to its local daemon: as `FirstConnect`, then every 30 s.
    LocalFirstConnect,
    /// A failing store snapshot while connected: 100 ms growing to 10 s, 8 attempts.
    Resync,
}

impl Preset {
    pub const ALL: [Preset; 5] = [
        Self::Reconnect,
        Self::FirstConnect,
        Self::LocalReconnect,
        Self::LocalFirstConnect,
        Self::Resync,
    ];

    pub fn from_code(code: u32) -> Option<Self> {
        Self::ALL.get(usize::try_from(code).ok()?).copied()
    }

    pub fn name(self) -> &'static str {
        match self {
            Self::Reconnect => "reconnect",
            Self::FirstConnect => "first_connect",
            Self::LocalReconnect => "local_reconnect",
            Self::LocalFirstConnect => "local_first_connect",
            Self::Resync => "resync",
        }
    }

    pub fn policy(self) -> CmuxRetryPolicy {
        const MS: u64 = 1_000_000;
        const S: u64 = 1_000_000_000;
        match self {
            Self::Reconnect => CmuxRetryPolicy::new(50 * MS, 30 * S, 10, 3, false),
            Self::FirstConnect => CmuxRetryPolicy::new(250 * MS, 30 * S, 10, 3, false),
            Self::LocalReconnect => CmuxRetryPolicy::new(50 * MS, 30 * S, 10, 3, true),
            Self::LocalFirstConnect => CmuxRetryPolicy::new(250 * MS, 30 * S, 10, 3, true),
            Self::Resync => CmuxRetryPolicy::new(100 * MS, 10 * S, 8, 3, false),
        }
    }
}

impl CmuxRetryPolicy {
    /// A policy with its values corrected, never refused: an `initial_ns` of
    /// 0 becomes 100 ms and `maximum_ns` is at least `initial_ns`.
    pub fn new(
        initial_ns: u64,
        maximum_ns: u64,
        timed_retries: i64,
        socket_retries: i64,
        keeps_trying: bool,
    ) -> Self {
        let initial_ns = if initial_ns > 0 { initial_ns } else { DEFAULT_INITIAL_NS };
        Self {
            initial_ns,
            maximum_ns: maximum_ns.max(initial_ns),
            timed_retries,
            socket_retries,
            keeps_trying,
        }
    }

    /// The spacing of attempt `attempt` (0-based) with the draw `random` in
    /// 0..<1: `initial * 2^attempt` capped at `maximum`, plus or minus 20 %,
    /// never below 80 % of `initial` nor above `maximum`.
    pub fn spacing_ns(&self, attempt: u32, random: f64) -> u64 {
        let initial = seconds(self.initial_ns);
        let maximum = seconds(self.maximum_ns);
        let exponent = i32::try_from(attempt.min(62)).unwrap_or(62);
        let base = (initial * MULTIPLIER.powi(exponent)).min(maximum);
        let random = if random.is_nan() { 0.0 } else { random.clamp(0.0, 1.0) };
        let spread = base * JITTER * (random * 2.0 - 1.0);
        let delay = (base + spread).max(initial * (1.0 - JITTER)).min(maximum);
        nanos(delay)
    }
}

fn seconds(ns: u64) -> f64 {
    #[allow(clippy::cast_precision_loss, reason = "durations far below 2^53 ns (104 days)")]
    let ns = ns as f64;
    ns / NANOS_PER_SECOND
}

fn nanos(seconds: f64) -> u64 {
    let ns = (seconds * NANOS_PER_SECOND).round();
    if ns.is_nan() || ns <= 0.0 {
        return 0;
    }
    #[allow(
        clippy::cast_possible_truncation,
        clippy::cast_sign_loss,
        reason = "positive and saturating: `as` clamps a float above u64::MAX"
    )]
    let ns = ns as u64;
    ns
}

/// What woke a retry loop's wait.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WakeCause {
    /// An explicit event (app activation, network, a reconnect action).
    Event,
    /// The watched socket changed.
    Socket,
    Timer,
    Cancelled,
}

impl WakeCause {
    pub fn from_code(code: u32) -> Option<Self> {
        match code {
            0 => Some(Self::Event),
            1 => Some(Self::Socket),
            2 => Some(Self::Timer),
            3 => Some(Self::Cancelled),
            _ => None,
        }
    }
}

/// One retry loop's pacing state: one backoff across consecutive failures,
/// reset only after a success that stayed healthy.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct CmuxRetryPacer {
    pub policy: CmuxRetryPolicy,
    /// The backoff's next attempt (its exponent).
    pub attempt: u32,
    /// Failures since the last reset.
    pub failures: i64,
    /// Failed attempts since the last reset that a socket change woke.
    pub socket_failures: i64,
    pub woke_by_socket: bool,
    /// A socket's refusals spent the timed retries (`budget_device`, `budget_inode`).
    pub has_budget_socket: bool,
    pub budget_device: u64,
    pub budget_inode: u64,
    /// The last attempt was refused at the daemon's connection limit.
    pub busy_refusal: bool,
}

impl CmuxRetryPacer {
    pub fn new(policy: CmuxRetryPolicy) -> Self {
        Self {
            policy,
            attempt: 0,
            failures: 0,
            socket_failures: 0,
            woke_by_socket: false,
            has_budget_socket: false,
            budget_device: 0,
            budget_inode: 0,
            busy_refusal: false,
        }
    }

    /// The timed-retry budget is spent: wait for an event only (never for a
    /// `keeps_trying` loop).
    pub fn is_exhausted(&self) -> bool {
        self.failures >= self.policy.timed_retries && !self.policy.keeps_trying
    }

    /// The next wait arms no timer: the budget is spent and the last attempt
    /// was not a busy refusal, whose daemon is alive and keeps a timed retry.
    pub fn waits_for_event_only(&self) -> bool {
        self.is_exhausted() && !self.busy_refusal
    }

    /// A socket change may wake the next wait: false in a crash loop.
    pub fn wakes_on_socket(&self) -> bool {
        self.socket_failures < self.policy.socket_retries
    }

    pub fn reset(&mut self) {
        *self = Self::new(self.policy);
    }

    fn next_spacing(&mut self, random: f64) -> u64 {
        let spacing = self.policy.spacing_ns(self.attempt, random);
        self.attempt = self.attempt.saturating_add(1);
        spacing
    }

    /// Notes one failure; the spacing before the next attempt, or `None` when
    /// the budget is spent (wait for an event only).
    pub fn failed(&mut self, random: f64) -> Option<u64> {
        if self.busy_refusal {
            self.busy_refusal = false;
            self.woke_by_socket = false;
            return Some(self.next_spacing(random).min(BUSY_RETRY_CAP_NS));
        }
        self.failures = self.failures.saturating_add(1);
        if self.woke_by_socket {
            self.socket_failures = self.socket_failures.saturating_add(1);
        }
        self.woke_by_socket = false;
        // Past the budget a loop that keeps trying stays at the backoff's cap.
        if self.failures > self.policy.timed_retries && !self.policy.keeps_trying {
            None
        } else {
            Some(self.next_spacing(random))
        }
    }

    /// A failure while the socket is missing: it spends no timed retry, but a
    /// socket a socket change brought and that is gone again counts toward
    /// the crash-loop limit.
    pub fn failed_while_missing(&mut self) {
        if self.woke_by_socket {
            self.socket_failures = self.socket_failures.saturating_add(1);
        }
        self.woke_by_socket = false;
    }

    /// A failure while the socket `(device, inode)` exists. The timed retries
    /// belong to one socket: a socket other than the one that spent them gets
    /// timed retries of its own (its change can come while an attempt runs,
    /// and then wakes nothing); each renewal counts as a failure a socket
    /// change brought, so a daemon that keeps replacing its socket gets at
    /// most `socket_retries` renewals until a success resets the pacer.
    pub fn failed_at(&mut self, device: u64, inode: u64, random: f64) -> Option<u64> {
        if !self.has_budget_socket {
            self.has_budget_socket = true;
            self.budget_device = device;
            self.budget_inode = inode;
        } else if (self.budget_device, self.budget_inode) != (device, inode)
            && self.wakes_on_socket()
        {
            self.budget_device = device;
            self.budget_inode = inode;
            self.failures = 0;
            self.attempt = 0;
            self.woke_by_socket = true;
        }
        self.failed(random)
    }

    /// The attempt was refused at the daemon's connection limit
    /// (`server.busy`): the next failure spends no timed retry and is spaced
    /// at most [`BUSY_RETRY_CAP_NS`].
    pub fn refused_busy(&mut self) {
        self.busy_refusal = true;
    }

    /// What woke the wait before the next attempt. An explicit event starts a
    /// `keeps_trying` loop's spacing over; the crash-loop count stays.
    pub fn woke(&mut self, cause: WakeCause) {
        self.woke_by_socket = cause == WakeCause::Socket;
        if cause == WakeCause::Event && self.policy.keeps_trying {
            self.failures = 0;
            self.attempt = 0;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn policy(timed: i64, socket: i64) -> CmuxRetryPolicy {
        CmuxRetryPolicy::new(250_000_000, 30_000_000_000, timed, socket, false)
    }

    #[test]
    fn spacing_doubles_to_the_cap_with_no_jitter_at_the_middle_draw() {
        let p = policy(10, 3);
        let spaced: Vec<u64> = (0..10).map(|a| p.spacing_ns(a, 0.5)).collect();
        assert_eq!(
            spaced,
            vec![
                250_000_000,
                500_000_000,
                1_000_000_000,
                2_000_000_000,
                4_000_000_000,
                8_000_000_000,
                16_000_000_000,
                30_000_000_000,
                30_000_000_000,
                30_000_000_000
            ]
        );
        // The floor: 80 % of initial; the ceiling: the cap.
        assert_eq!(p.spacing_ns(0, 0.0), 200_000_000);
        assert_eq!(p.spacing_ns(20, 1.0), 30_000_000_000);
    }

    #[test]
    fn a_zero_initial_is_corrected() {
        let p = CmuxRetryPolicy::new(0, 0, 1, 3, false);
        assert_eq!((p.initial_ns, p.maximum_ns), (100_000_000, 100_000_000));
    }
}
