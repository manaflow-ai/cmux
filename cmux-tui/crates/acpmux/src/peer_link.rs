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
/// `ACPMUX_PEER_REQUEST_SECS` how long one request waits for its answer, and
/// `ACPMUX_PEER_START_SECS` how long a forwarded `session/new` waits.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LinkTimings {
    /// ssh, the tunnel and the WebSocket upgrade; also the remote config read.
    // timeout: a dead route must fail connection setup so the reconnect loop can choose a new
    // route; once connected, peer traffic uses the link's liveness path.
    pub connect: Duration,
    /// `initialize` and `_acpmux/watch` once the WebSocket is open.
    // timeout: a peer that never completes its handshake is not usable; the link retries while
    // the socket remains open and this is the long hazard bound for a wedged handshake.
    pub handshake: Duration,
    /// A ping goes out this often; any byte from the peer counts as an answer.
    pub ping_every: Duration,
    /// The link is dropped after this many intervals without a byte from the peer, at first:
    /// a link to a peer that answers late gets more (`SilenceBudget`).
    pub ping_misses: u32,
    /// `ACPMUX_PEER_PING_SECS` was set: the silence budget stays `silence_budget()`.
    pub fixed_silence: bool,
    /// The link is dropped when one send cannot go out for this long (a peer that stops
    /// reading). Longer than the silence budget: a large frame on a slow uplink takes a while.
    // timeout: a peer that never reads would hold every queued write; a dead transport is
    // detected sooner by the silence budget.
    pub send: Duration,
    /// A link that stayed ready this long starts its next backoff over.
    pub stable_after: Duration,
    /// How long one request waits for the peer's answer.
    // timeout: a connected peer that never answers and never closes needs a finite diagnostic
    // bound; keepalive detects a dead transport earlier.
    pub request: Duration,
    /// How long a forwarded `session/new` waits for the peer's answer: past the peer's own
    /// start envelope. `Peer::send_request` takes the larger of this and `request`, so a slow
    /// live start is not cut off by the old pooled-start budget.
    // timeout: a remote handler that stays connected but never answers needs a finite forwarding
    // hazard bound; a dead peer is detected by the transport keepalive.
    pub start: Duration,
}

/// The peer's whole `session/new` budget (`hub::SESSION_NEW_BUDGET`), plus room for the link.
pub const START_DEFAULT: Duration =
    Duration::from_secs(crate::hub::SESSION_NEW_BUDGET.as_secs() + 15);

impl Default for LinkTimings {
    fn default() -> Self {
        Self {
            connect: Duration::from_secs(30),
            handshake: Duration::from_secs(90),
            // A dead link (a dropped network, a computer that slept) is found within 6 to 8 s,
            // not 80, so its redial starts while the person still waits. A ping is a few bytes
            // over the tunnel each 2 s, answered by the peer's connection reader.
            ping_every: Duration::from_secs(2),
            ping_misses: 3,
            fixed_silence: false,
            send: Duration::from_secs(80),
            stable_after: Duration::from_secs(60),
            request: Duration::from_secs(600),
            start: START_DEFAULT,
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
            t.fixed_silence = true;
        }
        if let Some(n) = secs("ACPMUX_PEER_REQUEST_SECS") {
            t.request = Duration::from_secs(n);
        }
        if let Some(n) = secs("ACPMUX_PEER_START_SECS") {
            t.start = Duration::from_secs(n);
        }
        t
    }

    /// How long the peer may stay silent before the link is dropped, until it answers late
    /// (`SilenceBudget`).
    pub fn silence_budget(&self) -> Duration {
        self.ping_every * self.ping_misses
    }
}

/// How long one peer's links may stay silent before they are dropped. It starts at
/// `LinkTimings::silence_budget` (6 s), so a dead link is found in seconds, and grows for a peer
/// that answers late but answers (a loaded host): an answer that came after more than half the
/// budget raises it to twice that gap, and a link dropped for silence that opens again within a
/// connect deadline (the peer was slow, not gone) doubles it. Never past `CAP`, the 80 s of
/// before #38015. After `stable_after` with no answer that late, it halves, not under twice the
/// longest gap meanwhile, back down to the start. A fixed `ACPMUX_PEER_PING_SECS` keeps it at
/// the start. Kept per peer across its links, so a redial does not forget what it learned.
#[derive(Debug, Clone)]
pub struct SilenceBudget {
    floor: Duration,
    cap: Duration,
    fixed: bool,
    current: Duration,
    /// When the budget last grew or shrank, while it is over the floor.
    moved_at: Option<tokio::time::Instant>,
    /// The longest gap between answers since `moved_at`.
    longest: Duration,
    /// When a link was dropped for silence: one that opens within `reopen` of it doubles it.
    dropped_at: Option<tokio::time::Instant>,
    reopen: Duration,
    stable_after: Duration,
}

impl SilenceBudget {
    /// The old fixed budget: 4 pings 20 s apart.
    pub const CAP: Duration = Duration::from_secs(80);

    pub fn new(timings: &LinkTimings) -> Self {
        let floor = timings.silence_budget();
        Self {
            floor,
            cap: Self::CAP.max(floor),
            fixed: timings.fixed_silence,
            current: floor,
            moved_at: None,
            longest: Duration::ZERO,
            dropped_at: None,
            reopen: timings.connect,
            stable_after: timings.stable_after,
        }
    }

    pub fn current(&self) -> Duration {
        self.current
    }

    fn raise(&mut self, to: Duration, now: tokio::time::Instant) {
        if self.fixed || to <= self.current {
            return;
        }
        self.current = to.min(self.cap);
        self.moved_at = Some(now);
        self.longest = Duration::ZERO;
    }

    /// The peer answered after `gap` without a byte.
    pub fn answered_after(&mut self, gap: Duration, now: tokio::time::Instant) {
        self.longest = self.longest.max(gap);
        if gap * 2 > self.current {
            self.raise(gap * 2, now);
        }
    }

    /// The link is dropped for silence.
    pub fn dropped(&mut self, now: tokio::time::Instant) {
        self.dropped_at = Some(now);
    }

    /// A new link's WebSocket opened: the peer's daemon answers.
    pub fn opened(&mut self, now: tokio::time::Instant) {
        if let Some(at) = self.dropped_at.take()
            && now.saturating_duration_since(at) <= self.reopen
        {
            self.raise(self.current * 2, now);
        }
    }

    /// A ping interval passed on a link that is up: after `stable_after` with no late answer,
    /// the budget comes down a step.
    pub fn settle(&mut self, now: tokio::time::Instant) {
        let Some(at) = self.moved_at else { return };
        if now.saturating_duration_since(at) < self.stable_after {
            return;
        }
        self.current = (self.current / 2).max(self.longest * 2).max(self.floor);
        self.moved_at = (self.current > self.floor).then_some(now);
        self.longest = Duration::ZERO;
    }
}

/// Reconnect delays: doubling from `BASE` to `CAP`, each drawn from the
/// upper half of its step (equal jitter), so peers that lost the same host
/// do not retry in step, and no attempt follows another at once. It never
/// gives up. While a client waits on the peer, no step is longer than
/// `WANTED_CAP` (`Backoff::wanted`, `Peer::want`).
#[derive(Debug, Clone, Default)]
pub struct Backoff {
    failures: u32,
}

impl Backoff {
    pub const BASE: Duration = Duration::from_millis(500);
    pub const CAP: Duration = Duration::from_secs(60);
    /// The longest step while a client waits on the peer: a daemon that restarts or a
    /// handshake that fails once costs an open chat a second, not the doubled minute.
    pub const WANTED_CAP: Duration = Duration::from_secs(1);

    /// `delay` for a peer a client waits on: unchanged when it is within `WANTED_CAP`, else
    /// drawn again from that cap's upper half with `jitter` (in `0.0..1.0`).
    pub fn wanted(delay: Duration, jitter: f64) -> Duration {
        if delay <= Self::WANTED_CAP {
            return delay;
        }
        let half = Self::WANTED_CAP.mul_f64(0.5);
        half.saturating_add(Self::WANTED_CAP.mul_f64(jitter.clamp(0.0, 1.0) / 2.0))
    }

    /// The delay before the next attempt; `jitter` is in `0.0..1.0`.
    pub fn next(&mut self, jitter: f64) -> Duration {
        let step = Self::BASE.saturating_mul(1u32 << self.failures.min(16)).min(Self::CAP);
        self.failures = self.failures.saturating_add(1);
        step / 2 + step.mul_f64(jitter.clamp(0.0, 1.0) / 2.0)
    }

    pub fn reset(&mut self) {
        self.failures = 0;
    }

    /// Steps drawn since the last `reset`.
    pub fn failures(&self) -> u32 {
        self.failures
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
    /// Tokio's monotonic clock: the OS one at run time, and the paused one in a test, so a
    /// test that moves time does not read as a sleep.
    mono: tokio::time::Instant,
}

impl SleepWatch {
    /// How often a link or a backoff wait checks the clocks.
    pub const EVERY: Duration = Duration::from_secs(5);
    /// A gap between the clocks under this is scheduling noise, not a sleep.
    pub const SLACK: Duration = Duration::from_secs(10);

    pub fn new(wall_ms: u64, mono: tokio::time::Instant) -> Self {
        Self { wall_ms, mono }
    }

    /// From the clocks now.
    pub fn now() -> Self {
        Self::new(crate::store::now_ms(), tokio::time::Instant::now())
    }

    /// How long the computer slept since the last check, when it did; the watch then counts from
    /// now either way.
    pub fn check_at(&mut self, wall_ms: u64, mono: tokio::time::Instant) -> Option<Duration> {
        let wall = Duration::from_millis(wall_ms.saturating_sub(self.wall_ms));
        let awake = mono.saturating_duration_since(self.mono);
        *self = Self::new(wall_ms, mono);
        let slept = wall.saturating_sub(awake);
        (slept >= Self::SLACK).then_some(slept)
    }

    /// ``check_at`` with the clocks now.
    pub fn check(&mut self) -> Option<Duration> {
        self.check_at(crate::store::now_ms(), tokio::time::Instant::now())
    }
}

/// After a wake, how long an open link has to answer a ping before it is dropped and redialed
/// (its ssh tunnel and TCP connection often died while the computer slept). This is only for a
/// stale post-sleep transport; ordinary busy-peer traffic stays on the link.
// timeout: a socket that survived sleep but cannot answer this probe is a dead transport, so
// redialing is safer than holding every queued write indefinitely.
pub const WAKE_PROBE: Duration = Duration::from_secs(30);

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

/// When the transport under a link last read a byte, and the longest gap between two reads
/// since `take_gap` last asked. A link is alive while bytes arrive, also in
/// the middle of a large frame that takes longer than the silence budget to come in, so the
/// budget can be short without cutting a slow but working link (`Peer::serve`).
#[derive(Debug, Clone)]
pub struct Heard {
    origin: tokio::time::Instant,
    at_ms: std::sync::Arc<std::sync::atomic::AtomicU64>,
    gap_ms: std::sync::Arc<std::sync::atomic::AtomicU64>,
}

impl Default for Heard {
    fn default() -> Self {
        Self {
            origin: tokio::time::Instant::now(),
            at_ms: Default::default(),
            gap_ms: Default::default(),
        }
    }
}

impl Heard {
    pub fn mark(&self) {
        let ms = self.origin.elapsed().as_millis() as u64;
        let before = self.at_ms.fetch_max(ms, std::sync::atomic::Ordering::Relaxed);
        self.gap_ms.fetch_max(ms.saturating_sub(before), std::sync::atomic::Ordering::Relaxed);
    }

    /// The longest gap between two reads since the last call (the first counts from when
    /// this was made).
    pub fn take_gap(&self) -> Duration {
        Duration::from_millis(self.gap_ms.swap(0, std::sync::atomic::Ordering::Relaxed))
    }

    /// How long since the last byte (since this was made, before any).
    pub fn silent(&self) -> Duration {
        let at = Duration::from_millis(self.at_ms.load(std::sync::atomic::Ordering::Relaxed));
        self.origin.elapsed().saturating_sub(at)
    }

    pub fn wrap<S>(&self, inner: S) -> HeardStream<S> {
        HeardStream { inner, heard: self.clone() }
    }
}

/// A stream that marks its `Heard` on each read that returned bytes.
pub struct HeardStream<S> {
    inner: S,
    heard: Heard,
}

impl<S: tokio::io::AsyncRead + Unpin> tokio::io::AsyncRead for HeardStream<S> {
    fn poll_read(
        mut self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
        buf: &mut tokio::io::ReadBuf<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        let before = buf.filled().len();
        let polled = std::pin::Pin::new(&mut self.inner).poll_read(cx, buf);
        if matches!(polled, std::task::Poll::Ready(Ok(()))) && buf.filled().len() > before {
            self.heard.mark();
        }
        polled
    }
}

impl<S: tokio::io::AsyncWrite + Unpin> tokio::io::AsyncWrite for HeardStream<S> {
    fn poll_write(
        mut self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
        buf: &[u8],
    ) -> std::task::Poll<std::io::Result<usize>> {
        std::pin::Pin::new(&mut self.inner).poll_write(cx, buf)
    }

    fn poll_flush(
        mut self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        std::pin::Pin::new(&mut self.inner).poll_flush(cx)
    }

    fn poll_shutdown(
        mut self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        std::pin::Pin::new(&mut self.inner).poll_shutdown(cx)
    }
}

/// A fresh jitter in `0.0..1.0` from the OS generator (0.5 if it fails).
pub fn jitter() -> f64 {
    #[cfg(test)]
    if let Some(j) = test_jitter::next() {
        return j;
    }
    let mut b = [0u8; 4];
    if getrandom::fill(&mut b).is_err() {
        return 0.5;
    }
    f64::from(u32::from_le_bytes(b)) / (f64::from(u32::MAX) + 1.0)
}

/// A seeded jitter for this thread's tests, so a run replays draw for draw from its seed.
#[cfg(test)]
pub(crate) mod test_jitter {
    use std::cell::Cell;

    thread_local!(static STATE: Cell<Option<u64>> = const { Cell::new(None) });

    /// `jitter` draws from SplitMix64 at `seed` on this thread from now on.
    pub(crate) fn seed(seed: u64) {
        STATE.with(|s| s.set(Some(seed)));
    }

    /// Back to the OS generator.
    pub(crate) fn clear() {
        STATE.with(|s| s.set(None));
    }

    pub(super) fn next() -> Option<f64> {
        STATE.with(|s| {
            let state = s.get()?.wrapping_add(0x9E37_79B9_7F4A_7C15);
            s.set(Some(state));
            let mut z = state;
            z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
            z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
            z ^= z >> 31;
            Some((z >> 11) as f64 / (1u64 << 53) as f64)
        })
    }
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
    /// The daemon announced a restart; reconnect immediately once, keeping its sessions.
    Restarting,
    /// Never reached, and attempts failed. Attempts go on.
    Offline,
}

impl PeerState {
    /// Its `_acpmux/peer_state_changed` `link` (`protocol/peer_state.rs`), unfolded: a restart
    /// is `restarting` there too. An older app reads `state`, `MachineLink::folded`.
    pub fn wire(self) -> crate::protocol::peer_state::MachineLink {
        use crate::protocol::peer_state::MachineLink as W;
        match self {
            Self::Connecting => W::Connecting,
            Self::Connected => W::Connected,
            Self::Degraded => W::Degraded,
            Self::Reconnecting => W::Reconnecting,
            Self::Restarting => W::Restarting,
            Self::Offline => W::Offline,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Connecting => "connecting",
            Self::Connected => "connected",
            Self::Degraded => "degraded",
            Self::Reconnecting => "reconnecting",
            Self::Restarting => "restarting",
            Self::Offline => "offline",
        }
    }
}

/// The link's history, in wall-clock milliseconds (`store::now_ms`).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Link {
    restarting: bool,
    open: bool,
    ready: bool,
    overdue: bool,
    /// Last frame from the peer (or the saved value from an earlier run).
    pub last_seen: Option<u64>,
    /// When the link last went down, while it is down.
    pub down_since: Option<u64>,
    /// A parked peer's next automatic attempt, preserved across daemon updates.
    pub next_retry_at: Option<u64>,
    /// The next automatic attempt of a link that is down, parked or not (`nextRetryAt` on the
    /// wire); None while a link is open. Past it, an attempt runs or ran. Only reported, never
    /// waited on: the run loop keeps its own delay.
    pub retry_at: Option<u64>,
    /// Failed attempts since the link was last ready.
    pub attempts: u32,
    /// When the link last became ready.
    ready_at: Option<u64>,
    /// When the WebSocket last opened, while it is open.
    opened_at: Option<u64>,
}

impl Link {
    pub fn state(&self) -> PeerState {
        if self.restarting {
            return PeerState::Restarting;
        }
        match (self.open, self.ready && !self.overdue) {
            (true, true) => PeerState::Connected,
            (true, false) => PeerState::Degraded,
            (false, _) if self.last_seen.is_some() => PeerState::Reconnecting,
            (false, _) if self.attempts == 0 && self.down_since.is_none() => PeerState::Connecting,
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

    /// Only an explicit saved outage seeds retry age: an old lastSeen in a quiet peer's
    /// session cache does not prove the link has been down since then.
    pub fn seed_outage(&mut self, down_since: Option<u64>) {
        if !self.open && self.attempts == 0 && self.down_since.is_none() {
            self.down_since = down_since;
        }
    }

    /// A day without a successful handshake parks automatic retries. The first attempt
    /// still runs immediately; an explicit reconnect replaces the instance and also runs
    /// immediately. Existing rows and dead-link request refusal are independent of this delay.
    pub fn retry_delay(&self, backoff: &mut Backoff, now: u64, jitter: f64) -> Duration {
        const DAY_MS: u64 = 24 * 60 * 60 * 1_000;
        if self.down_since.is_some_and(|at| now.saturating_sub(at) >= DAY_MS) {
            // Small positive jitter keeps many retired hosts from retrying in lockstep.
            Duration::from_secs(3_600) + Duration::from_secs(60).mul_f64(jitter.clamp(0.0, 1.0))
        } else {
            backoff.next(jitter)
        }
    }

    /// Save only parked schedules: ordinary short reconnect backoff starts fresh on boot.
    pub fn schedule_retry(&mut self, backoff: &mut Backoff, now: u64, jitter: f64) -> Duration {
        let delay = self.retry_delay(backoff, now, jitter);
        self.next_retry_at = (delay >= Duration::from_secs(3_600))
            .then(|| now.saturating_add(delay.as_millis() as u64));
        delay
    }

    pub fn parked_retry_wait(&self, now: u64) -> Option<Duration> {
        self.next_retry_at.filter(|at| *at > now && self.down_since.is_some()).map(|at| {
            // A wall-clock correction must not strand a peer beyond one retry interval.
            Duration::from_millis(at - now).min(Duration::from_secs(3_660))
        })
    }

    /// The WebSocket opened; the handshake runs.
    pub fn opened(&mut self, now: u64) {
        self.retry_at = None;
        self.opened_at = Some(now);
        self.open = true;
        self.ready = false;
        self.overdue = false;
        self.last_seen = Some(now);
    }

    /// The handshake finished: sessions are listed.
    pub fn ready(&mut self, now: u64) {
        self.restarting = false;
        self.ready = true;
        self.overdue = false;
        self.last_seen = Some(now);
        self.down_since = None;
        self.next_retry_at = None;
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

    /// Close 1012: retain last-seen history, without counting a failed attempt. The state
    /// stays restarting through the next handshake, until readiness or a real failure.
    pub fn restarting(&mut self, now: u64) {
        self.restarting = true;
        self.open = false;
        self.ready = false;
        self.overdue = false;
        self.ready_at = None;
        self.down_since.get_or_insert(now);
    }

    /// How long the link has been ready, while it is.
    pub fn ready_for(&self, now: u64) -> Option<Duration> {
        let at = self.ready_at.filter(|_| self.is_ready())?;
        Some(Duration::from_millis(now.saturating_sub(at)))
    }

    /// The attempt failed or the link dropped. Returns whether the link had
    /// stayed ready for `stable_after` (so the backoff starts over).
    pub fn down(&mut self, now: u64, stable_after: Duration) -> bool {
        self.restarting = false;
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
        "peer_unreachable: {}; the request was not sent; run `acpmux machine ls` and retry after the peer reconnects",
        describe(name, link, error, now)
    )).with_data(
        json!({
            "reason": "peer_unreachable",
            "retryable": true,
            "try": "acpmux machine ls",
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
        let start = tokio::time::Instant::now();
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
        let start = tokio::time::Instant::now();
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
    fn retry_parking_survives_cache_seed_and_ends_at_a_successful_handshake() {
        let mut link = Link::default();
        let mut backoff = Backoff::default();
        let day = 86_400_000;
        link.seed(Some(1_000));
        assert!(link.retry_delay(&mut backoff, 1_000 + day, 0.0) <= Backoff::CAP);
        link.seed_outage(Some(1_000));
        assert!(link.retry_delay(&mut backoff, 1_000 + day - 1, 0.0) <= Backoff::CAP);
        assert_eq!(link.retry_delay(&mut backoff, 1_000 + day, 0.0), Duration::from_secs(3_600));
        assert_eq!(link.retry_delay(&mut backoff, 1_000 + day, 1.0), Duration::from_secs(3_660));
        link.opened(day + 2_000);
        link.down(day + 2_001, STABLE);
        assert!(link.retry_delay(&mut backoff, day + 2_001, 0.0) >= Duration::from_secs(3_600));
        link.opened(day + 3_000);
        link.ready(day + 3_001);
        link.down(day + 3_002, STABLE);
        assert!(link.retry_delay(&mut backoff, day + 3_002, 0.0) <= Backoff::CAP);
    }

    #[test]
    fn parked_schedule_retains_only_the_remaining_wait_and_recovery_clears_it() {
        let now = 86_400_001;
        let mut link = Link::default();
        link.seed_outage(Some(0));
        let delay = link.schedule_retry(&mut Backoff::default(), now, 0.0);
        assert_eq!(delay, Duration::from_secs(3_600));
        assert_eq!(link.parked_retry_wait(now + 120_000), Some(Duration::from_secs(3_480)));
        assert_eq!(link.parked_retry_wait(now + 3_600_000), None);
        assert_eq!(
            link.parked_retry_wait(0),
            Some(Duration::from_secs(3_660)),
            "clock correction is bounded"
        );
        link.opened(now + 2_000);
        link.ready(now + 2_001);
        assert_eq!(link.next_retry_at, None);
        assert_eq!(link.parked_retry_wait(now + 2_001), None);
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
    fn a_wanted_peer_retries_within_seconds_however_long_the_backoff_grew() {
        // The schedule a failed handshake starts: 0.25-0.5 s, 0.5-1 s, 1-2 s, 2-4 s, ...
        let mut backoff = Backoff::default();
        let steps: Vec<_> = (0..4).map(|_| backoff.next(0.999_999)).collect();
        for (step, cap) in steps.iter().zip([500, 1_000, 2_000, 4_000]) {
            assert!(*step <= Duration::from_millis(cap), "{steps:?}");
        }
        assert_eq!(Backoff::wanted(Duration::from_millis(300), 0.0), Duration::from_millis(300));
        for _ in 0..12 {
            let delay = backoff.next(0.999_999);
            let wanted = Backoff::wanted(delay, 0.999_999);
            assert!(wanted <= Backoff::WANTED_CAP && wanted <= delay, "{wanted:?} for {delay:?}");
        }
        assert_eq!(Backoff::wanted(Backoff::CAP, 0.0), Backoff::WANTED_CAP / 2, "never zero");
        let parked = Duration::from_secs(3_600);
        assert!(Backoff::wanted(parked, 1.0) <= Backoff::WANTED_CAP, "a parked peer too");
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
        assert!(e.message.contains("acpmux machine ls"));
        let data = e.data.unwrap();
        assert_eq!(data["reason"], "peer_unreachable");
        assert_eq!(data["retryable"], true);
        assert_eq!(data["try"], "acpmux machine ls");
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

    #[tokio::test(start_paused = true)]
    async fn a_late_answering_peer_gets_more_silence_and_gives_it_back_once_calm() {
        let t = LinkTimings::default();
        let mut budget = SilenceBudget::new(&t);
        let start = tokio::time::Instant::now();
        let secs = Duration::from_secs;
        assert_eq!(budget.current(), secs(6));
        budget.answered_after(secs(2), start);
        assert_eq!(budget.current(), secs(6), "an answer within half the budget changes nothing");
        budget.answered_after(secs(5), start);
        assert_eq!(budget.current(), secs(10), "twice the late gap");
        budget.dropped(start);
        budget.opened(start + t.connect + secs(1));
        assert_eq!(budget.current(), secs(10), "a peer gone for longer than a connect was gone");
        budget.dropped(start);
        budget.opened(start + secs(1));
        assert_eq!(budget.current(), secs(20), "one that opens straight back was slow: doubled");
        budget.opened(start + secs(2));
        assert_eq!(budget.current(), secs(20), "once per drop");
        for _ in 0..4 {
            budget.dropped(start);
            budget.opened(start);
        }
        assert_eq!(budget.current(), SilenceBudget::CAP, "never past the old 80 s");
        // Calm: answers 3 s apart, then a step down each `stable_after`, to the start.
        budget.answered_after(secs(3), start);
        budget.settle(start + t.stable_after - secs(1));
        assert_eq!(budget.current(), SilenceBudget::CAP, "not calm for long enough yet");
        let mut at = start + t.stable_after;
        budget.settle(at);
        assert_eq!(budget.current(), secs(40));
        for want in [20, 10, 6, 6] {
            at += t.stable_after;
            budget.settle(at);
            assert_eq!(budget.current(), secs(want));
        }
        // A step down never goes under twice the longest gap meanwhile.
        budget.answered_after(secs(9), at);
        assert_eq!(budget.current(), secs(18));
        budget.answered_after(secs(8), at);
        budget.settle(at + t.stable_after);
        assert_eq!(budget.current(), secs(16));
    }

    #[test]
    fn a_set_ping_interval_keeps_the_silence_budget_fixed() {
        let t = LinkTimings {
            ping_every: Duration::from_secs(5),
            fixed_silence: true,
            ..LinkTimings::default()
        };
        let mut budget = SilenceBudget::new(&t);
        let now = tokio::time::Instant::now();
        budget.answered_after(Duration::from_secs(14), now);
        budget.dropped(now);
        budget.opened(now);
        assert_eq!(budget.current(), Duration::from_secs(15));
        let slow = LinkTimings { ping_every: Duration::from_secs(40), ..LinkTimings::default() };
        assert_eq!(SilenceBudget::new(&slow).current(), Duration::from_secs(120), "over the cap");
    }

    #[test]
    fn env_sets_the_connect_handshake_and_ping_deadlines() {
        let t = LinkTimings::default();
        assert_eq!(t.silence_budget(), Duration::from_secs(6));
        assert_eq!(t.send, Duration::from_secs(80));
        assert!(t.connect >= Duration::from_secs(30) && t.handshake >= t.connect);
    }
}
