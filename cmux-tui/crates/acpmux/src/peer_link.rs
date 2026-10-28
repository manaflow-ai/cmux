//! The state of one peer link (`peer.rs`): how long its connect, handshake
//! and keepalive may take, how long it waits between attempts, and what a
//! client is told while the link is down. A loaded peer (swap full, threads
//! stuck in the kernel) answers late; it is shown `degraded` or
//! `reconnecting` with its last-known sessions, never dropped.

use crate::rpc::RpcError;
use serde_json::{Value, json};
use std::time::Duration;

/// Deadlines of one link. `ACPMUX_PEER_TIMEOUT_SECS` sets the connect
/// deadline (the handshake gets three times it), `ACPMUX_PEER_PING_SECS`
/// the keepalive interval, for a host that is slow even when well, and
/// `ACPMUX_PEER_REQUEST_SECS` how long one request waits for its answer.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LinkTimings {
    /// ssh, the tunnel and the WebSocket upgrade; also the remote config read.
    pub connect: Duration,
    /// `initialize` and `_acpmux/watch` once the WebSocket is open.
    pub handshake: Duration,
    /// A ping goes out this often; any frame from the peer counts as an answer.
    pub ping_every: Duration,
    /// The link is dropped after this many intervals without a frame, and a
    /// send that cannot go out for as long.
    pub ping_misses: u32,
    /// A link that stayed ready this long starts its next backoff over.
    pub stable_after: Duration,
    /// How long one request waits for the peer's answer.
    pub request: Duration,
}

impl Default for LinkTimings {
    fn default() -> Self {
        Self {
            connect: Duration::from_secs(30),
            handshake: Duration::from_secs(90),
            ping_every: Duration::from_secs(20),
            ping_misses: 4,
            stable_after: Duration::from_secs(60),
            request: Duration::from_secs(600),
        }
    }
}

impl LinkTimings {
    pub fn from_env() -> Self {
        let secs = |key: &str| {
            std::env::var(key).ok().and_then(|v| v.trim().parse::<u64>().ok()).filter(|n| *n > 0)
        };
        let mut t = Self::default();
        if let Some(n) = secs("ACPMUX_PEER_TIMEOUT_SECS") {
            t.connect = Duration::from_secs(n);
            t.handshake = Duration::from_secs(n * 3);
        }
        if let Some(n) = secs("ACPMUX_PEER_PING_SECS") {
            t.ping_every = Duration::from_secs(n);
        }
        if let Some(n) = secs("ACPMUX_PEER_REQUEST_SECS") {
            t.request = Duration::from_secs(n);
        }
        t
    }

    /// How long the peer may stay silent (or refuse a send) before the link
    /// is dropped.
    pub fn silence_budget(&self) -> Duration {
        self.ping_every * self.ping_misses
    }
}

/// Reconnect delays: doubling from `BASE` to `CAP`, each drawn from the
/// upper half of its step (equal jitter), so peers that lost the same host
/// do not retry in step, and no attempt follows another at once. It never
/// gives up.
#[derive(Debug, Clone, Default)]
pub struct Backoff {
    failures: u32,
}

impl Backoff {
    pub const BASE: Duration = Duration::from_secs(2);
    pub const CAP: Duration = Duration::from_secs(60);

    /// The delay before the next attempt; `jitter` is in `0.0..1.0`.
    pub fn next(&mut self, jitter: f64) -> Duration {
        let step = Self::BASE.saturating_mul(1u32 << self.failures.min(16)).min(Self::CAP);
        self.failures = self.failures.saturating_add(1);
        step / 2 + step.mul_f64(jitter.clamp(0.0, 1.0) / 2.0)
    }

    pub fn reset(&mut self) {
        self.failures = 0;
    }
}

/// Notices that this computer slept (a closed lid, a sleeping Mac): the wall clock moved on further
/// than the monotonic one, which stops while the computer sleeps (macOS `mach_absolute_time`,
/// Linux `CLOCK_MONOTONIC`). A link's timers run on the monotonic clock, so after a wake a dead
/// link still looks fresh (its last frame "seconds" ago) and a backoff wait picks up where it was.
/// Each check is a few integer reads; a forward step of the wall clock (a time sync) reads as a
/// sleep too, which costs one early probe or attempt and nothing else.
#[derive(Debug, Clone, Copy)]
pub struct SleepWatch {
    wall_ms: u64,
    mono: std::time::Instant,
}

impl SleepWatch {
    /// How often a link or a backoff wait checks the clocks.
    pub const EVERY: Duration = Duration::from_secs(5);
    /// A gap between the clocks under this is scheduling noise, not a sleep.
    pub const SLACK: Duration = Duration::from_secs(10);

    pub fn new(wall_ms: u64, mono: std::time::Instant) -> Self {
        Self { wall_ms, mono }
    }

    /// From the clocks now.
    pub fn now() -> Self {
        Self::new(crate::store::now_ms(), std::time::Instant::now())
    }

    /// How long the computer slept since the last check, when it did; the watch then counts from
    /// now either way.
    pub fn check_at(&mut self, wall_ms: u64, mono: std::time::Instant) -> Option<Duration> {
        let wall = Duration::from_millis(wall_ms.saturating_sub(self.wall_ms));
        let awake = mono.saturating_duration_since(self.mono);
        *self = Self::new(wall_ms, mono);
        let slept = wall.saturating_sub(awake);
        (slept >= Self::SLACK).then_some(slept)
    }

    /// ``check_at`` with the clocks now.
    pub fn check(&mut self) -> Option<Duration> {
        self.check_at(crate::store::now_ms(), std::time::Instant::now())
    }
}

/// After a wake, how long an open link has to answer a ping before it is dropped and redialed
/// (its ssh tunnel and TCP connection often died while the computer slept).
pub const WAKE_PROBE: Duration = Duration::from_secs(10);

/// When a write that starts at `now` gives up: after the send `budget`, or at a running wake
/// probe's deadline when that comes first, so a write to a link that died while the computer
/// slept never holds the probe past it. Generic over the clock so a test can pass plain instants.
pub fn write_deadline<I>(now: I, budget: Duration, wake_probe: Option<I>) -> I
where
    I: Copy + Ord + std::ops::Add<Duration, Output = I>,
{
    let end = now + budget;
    wake_probe.map_or(end, |probe| probe.min(end))
}

/// A fresh jitter in `0.0..1.0` from the OS generator (0.5 if it fails).
pub fn jitter() -> f64 {
    let mut b = [0u8; 4];
    if getrandom::fill(&mut b).is_err() {
        return 0.5;
    }
    f64::from(u32::from_le_bytes(b)) / (f64::from(u32::MAX) + 1.0)
}

/// What `host ls` shows for a peer (`state` in `_acpmux/peers`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PeerState {
    /// The first attempt of a peer never reached (this run or a saved one).
    Connecting,
    /// Ready, and the peer answers.
    Connected,
    /// The WebSocket is open but the handshake has not finished, or a ping
    /// went unanswered: slow, not gone.
    Degraded,
    /// Down after it was reached; its last-known sessions stay listed.
    Reconnecting,
    /// Never reached, and attempts failed. Attempts go on.
    Offline,
}

impl PeerState {
    /// Its `_acpmux/peer_state_changed` form (`protocol/peer_state.rs`).
    pub fn wire(self) -> crate::protocol::peer_state::PeerLinkState {
        use crate::protocol::peer_state::PeerLinkState as W;
        match self {
            Self::Connecting => W::Connecting,
            Self::Connected => W::Connected,
            Self::Degraded => W::Degraded,
            Self::Reconnecting => W::Reconnecting,
            Self::Offline => W::Offline,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Connecting => "connecting",
            Self::Connected => "connected",
            Self::Degraded => "degraded",
            Self::Reconnecting => "reconnecting",
            Self::Offline => "offline",
        }
    }
}

/// The link's history, in wall-clock milliseconds (`store::now_ms`).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Link {
    open: bool,
    ready: bool,
    overdue: bool,
    /// Last frame from the peer (or the saved value from an earlier run).
    pub last_seen: Option<u64>,
    /// When the link last went down, while it is down.
    pub down_since: Option<u64>,
    /// Failed attempts since the link was last ready.
    pub attempts: u32,
    /// When the link last became ready.
    ready_at: Option<u64>,
    /// When the WebSocket last opened, while it is open.
    opened_at: Option<u64>,
}

impl Link {
    pub fn state(&self) -> PeerState {
        match (self.open, self.ready && !self.overdue) {
            (true, true) => PeerState::Connected,
            (true, false) => PeerState::Degraded,
            (false, _) if self.last_seen.is_some() => PeerState::Reconnecting,
            (false, _) if self.attempts == 0 => PeerState::Connecting,
            (false, _) => PeerState::Offline,
        }
    }

    pub fn is_ready(&self) -> bool {
        self.open && self.ready
    }

    /// Whether an unforced reconnect leaves this link alone (`Hub::reconnect_peer_with`): it is
    /// ready (connected, or slow to answer a ping), or its handshake began less than `young` ago.
    /// A handshake older than that may never finish, so a reconnect replaces it.
    pub fn keeps_on_reconnect(&self, now: u64, young: Duration) -> bool {
        if !self.open {
            return false;
        }
        self.ready
            || self.opened_at.is_some_and(|at| now.saturating_sub(at) < young.as_millis() as u64)
    }

    /// A saved `lastSeen` from an earlier run of this daemon.
    pub fn seed(&mut self, last_seen: Option<u64>) {
        if self.last_seen.is_none() {
            self.last_seen = last_seen;
        }
    }

    /// The WebSocket opened; the handshake runs.
    pub fn opened(&mut self, now: u64) {
        self.opened_at = Some(now);
        self.open = true;
        self.ready = false;
        self.overdue = false;
        self.last_seen = Some(now);
    }

    /// The handshake finished: sessions are listed.
    pub fn ready(&mut self, now: u64) {
        self.ready = true;
        self.overdue = false;
        self.last_seen = Some(now);
        self.down_since = None;
        self.attempts = 0;
        self.ready_at = Some(now);
    }

    /// A frame arrived.
    pub fn heard(&mut self, now: u64) {
        self.overdue = false;
        self.last_seen = Some(now);
    }

    /// A ping interval passed without a frame.
    pub fn overdue(&mut self) {
        self.overdue = true;
    }

    /// The attempt failed or the link dropped. Returns whether the link had
    /// stayed ready for `stable_after` (so the backoff starts over).
    pub fn down(&mut self, now: u64, stable_after: Duration) -> bool {
        let stable = self.is_ready()
            && self
                .ready_at
                .is_some_and(|at| now.saturating_sub(at) >= stable_after.as_millis() as u64);
        self.open = false;
        self.ready = false;
        self.overdue = false;
        self.ready_at = None;
        self.opened_at = None;
        self.attempts = self.attempts.saturating_add(1);
        self.down_since.get_or_insert(now);
        stable
    }
}

/// `40s`, `3m`, `2h`, `5d`.
pub fn ago(ms: u64) -> String {
    let s = ms / 1000;
    match s {
        0..=119 => format!("{s}s"),
        120..=7199 => format!("{}m", s / 60),
        7200..=172_799 => format!("{}h", s / 3600),
        _ => format!("{}d", s / 86_400),
    }
}

/// `huge-blue (reconnecting, last seen 40s ago: connect timed out)`.
pub fn describe(name: &str, link: &Link, error: Option<&str>, now: u64) -> String {
    let seen = match link.last_seen {
        Some(at) => format!(", last seen {} ago", ago(now.saturating_sub(at))),
        None => ", never reached".to_owned(),
    };
    let error = error.map(|e| format!(": {e}")).unwrap_or_default();
    format!("{name} ({}{seen}{error})", link.state().as_str())
}

/// The refusal of a request for a session on a peer that is down: the
/// reason is `peer_unreachable` (the CLI's error detail), retryable. The
/// request was not sent, so retrying it never runs it twice.
pub fn unreachable_error(name: &str, link: &Link, error: Option<&str>, now: u64) -> RpcError {
    RpcError::internal(format!(
        "peer_unreachable: {}; the request was not sent; run `acpmux host ls` and retry after the peer reconnects",
        describe(name, link, error, now)
    )).with_data(
        json!({
            "reason": "peer_unreachable",
            "retryable": true,
            "try": "acpmux host ls",
            "detail": "the request was not sent",
            "peer": name,
            "peerState": link.state().as_str(),
            "lastSeen": link.last_seen,
            "error": error,
        }),
    )
}

/// The `host ls` state column: `state` from a daemon that sends it, else
/// `connected`/`offline` from `connected`; a peer that is down adds when it
/// was last seen.
pub fn state_label(peer: &Value, now: u64) -> String {
    let connected = peer.get("connected").and_then(Value::as_bool).unwrap_or(false);
    let state = peer.get("state").and_then(Value::as_str).unwrap_or(if connected {
        "connected"
    } else {
        "offline"
    });
    match peer.get("lastSeen").and_then(Value::as_u64) {
        Some(at) if !connected => format!("{state} (seen {} ago)", ago(now.saturating_sub(at))),
        _ => state.to_owned(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_sleep_is_the_wall_clock_running_ahead_of_the_monotonic_one() {
        let start = std::time::Instant::now();
        let mut watch = SleepWatch::new(1_000_000, start);
        // Awake: both clocks moved 5 s.
        assert_eq!(watch.check_at(1_005_000, start + Duration::from_secs(5)), None);
        // Scheduling noise under the slack is no sleep.
        assert_eq!(watch.check_at(1_015_000, start + Duration::from_secs(9)), None);
        // Asleep for 10 minutes: the wall clock moved 10 min 5 s, the monotonic one 5 s.
        let slept = watch.check_at(1_620_000, start + Duration::from_secs(14));
        assert_eq!(slept, Some(Duration::from_secs(600)));
        // The watch counts from the wake on.
        assert_eq!(watch.check_at(1_625_000, start + Duration::from_secs(19)), None);
    }

    #[test]
    fn an_unforced_reconnect_keeps_a_ready_link_and_a_young_handshake() {
        let young = Duration::from_secs(30);
        let mut link = Link::default();
        assert!(!link.keeps_on_reconnect(1_000, young), "a link that never opened is replaced");
        link.opened(1_000);
        assert!(link.keeps_on_reconnect(20_000, young), "a handshake 19 s old is left to finish");
        assert!(!link.keeps_on_reconnect(40_000, young), "a handshake 39 s old may never finish");
        link.ready(40_000);
        link.overdue();
        assert!(link.keeps_on_reconnect(500_000, young), "a ready link slow to answer is kept");
        link.down(600_000, STABLE);
        assert!(!link.keeps_on_reconnect(600_001, young), "a link that is down is replaced");
    }

    #[test]
    fn a_wall_clock_set_back_is_no_sleep() {
        let start = std::time::Instant::now();
        let mut watch = SleepWatch::new(2_000_000, start);
        assert_eq!(watch.check_at(1_000_000, start + Duration::from_secs(5)), None);
        assert_eq!(watch.check_at(1_005_000, start + Duration::from_secs(10)), None);
    }

    #[test]
    fn a_write_during_a_wake_probe_gives_up_at_the_probes_deadline() {
        let now = std::time::Instant::now();
        let budget = Duration::from_secs(80);
        assert_eq!(write_deadline(now, budget, None), now + budget);
        let probe = now + WAKE_PROBE;
        assert_eq!(write_deadline(now, budget, Some(probe)), probe);
        // A probe further off than the budget leaves the budget.
        assert_eq!(
            write_deadline(now, Duration::from_secs(5), Some(probe)),
            now + Duration::from_secs(5)
        );
    }

    const STABLE: Duration = Duration::from_secs(60);

    #[test]
    fn a_link_goes_connected_then_reconnecting_then_connected() {
        let mut link = Link::default();
        assert_eq!(link.state(), PeerState::Connecting);
        link.opened(1_000);
        assert_eq!(link.state(), PeerState::Degraded, "handshaking");
        link.ready(2_000);
        assert_eq!(link.state(), PeerState::Connected);
        link.overdue();
        assert_eq!(link.state(), PeerState::Degraded, "a ping went unanswered");
        link.heard(3_000);
        assert_eq!(link.state(), PeerState::Connected);
        assert!(!link.down(10_000, STABLE), "ready 8s: not stable");
        assert_eq!(link.state(), PeerState::Reconnecting);
        assert_eq!(
            (link.last_seen, link.down_since, link.attempts),
            (Some(3_000), Some(10_000), 1)
        );
        link.down(40_000, STABLE);
        assert_eq!(link.state(), PeerState::Reconnecting, "attempts go on");
        assert_eq!((link.down_since, link.attempts), (Some(10_000), 2), "down since the first");
        link.opened(50_000);
        link.ready(51_000);
        assert_eq!(link.state(), PeerState::Connected);
        assert_eq!((link.down_since, link.attempts), (None, 0));
        assert!(link.down(51_000 + 61_000, STABLE), "ready 61s: stable");
    }

    #[test]
    fn a_peer_never_reached_is_offline_and_a_saved_one_is_reconnecting() {
        let mut link = Link::default();
        link.down(1_000, STABLE);
        assert_eq!(link.state(), PeerState::Offline);
        let mut saved = Link::default();
        saved.seed(Some(500));
        assert_eq!(saved.state(), PeerState::Reconnecting);
        saved.down(1_000, STABLE);
        assert_eq!(saved.state(), PeerState::Reconnecting);
        saved.seed(Some(1));
        assert_eq!(saved.last_seen, Some(500), "a seed never overrides what this run saw");
    }

    #[test]
    fn backoff_doubles_within_jittered_bounds_up_to_the_cap() {
        let mut low = Backoff::default();
        let mut high = Backoff::default();
        let mut step = Backoff::BASE;
        for _ in 0..12 {
            let (lo, hi) = (low.next(0.0), high.next(0.999_999));
            assert_eq!(lo, step / 2);
            assert!(hi <= step && hi > step.mul_f64(0.99), "{hi:?} for {step:?}");
            step = (step * 2).min(Backoff::CAP);
        }
        assert_eq!(low.next(0.0), Backoff::CAP / 2, "capped, never zero");
        assert!(high.next(1.0) <= Backoff::CAP);
        low.reset();
        assert_eq!(low.next(0.0), Backoff::BASE / 2);
        let j = jitter();
        assert!((0.0..1.0).contains(&j));
    }

    #[test]
    fn the_unreachable_error_names_the_state_age_and_last_error() {
        let mut link = Link::default();
        link.opened(0);
        link.ready(0);
        link.down(1_000, STABLE);
        let e = unreachable_error("huge-blue", &link, Some("connect timed out"), 40_000);
        assert!(
            e.message.contains("huge-blue (reconnecting, last seen 40s ago: connect timed out)")
        );
        assert!(e.message.contains("acpmux host ls"));
        let data = e.data.unwrap();
        assert_eq!(data["reason"], "peer_unreachable");
        assert_eq!(data["retryable"], true);
        assert_eq!(data["try"], "acpmux host ls");
        assert_eq!(data["peerState"], "reconnecting");
        assert_eq!(data["lastSeen"], 0);
        let never = describe("gone", &Link::default(), None, 5);
        assert_eq!(never, "gone (connecting, never reached)");
    }

    #[test]
    fn host_ls_labels_old_and_new_daemons() {
        assert_eq!(state_label(&json!({"connected": true}), 0), "connected");
        assert_eq!(state_label(&json!({"connected": false}), 0), "offline");
        let down = json!({"connected": false, "state": "reconnecting", "lastSeen": 1_000});
        assert_eq!(state_label(&down, 181_000), "reconnecting (seen 3m ago)");
        assert_eq!(ago(59_000), "59s");
        assert_eq!(ago(3 * 3_600_000), "3h");
    }

    #[test]
    fn env_sets_the_connect_handshake_and_ping_deadlines() {
        let t = LinkTimings::default();
        assert_eq!(t.silence_budget(), Duration::from_secs(80));
        assert!(t.connect >= Duration::from_secs(30) && t.handshake >= t.connect);
    }
}
