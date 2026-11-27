//! The state of one peer link (`peer.rs`): how long its connect, handshake
//! and keepalive may take, how long it waits between attempts, and what a
//! client is told while the link is down. A loaded peer (swap full, threads
//! stuck in the kernel) answers late; it is shown `degraded` or
//! `reconnecting` with its last-known sessions, never dropped.

use crate::rpc::RpcError;
use acpmux_list_types::resume::ResumeErrorClass;
use serde_json::{Value, json};
use std::time::Duration;

/// Deadlines of one link. `ACPMUX_PEER_TIMEOUT_SECS` sets the connect
/// deadline (the handshake gets three times it), `ACPMUX_PEER_PING_SECS`
/// the keepalive interval, for a host that is slow even when well, and
/// `ACPMUX_PEER_REQUEST_SECS` how long one request waits for its answer, and
/// `ACPMUX_PEER_START_SECS` how long a forwarded `session/new` waits;
/// `ACPMUX_PEER_REPLACE_SECS` (off by default) dials a silent link's replacement sooner.
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
    /// The checks of a silent link scale with its measured round trip
    /// (`peer_link_quality::probe_wait`, `silence_floor`): on in every daemon. Off, they keep the
    /// fixed constants, which the link-quality tests measure against.
    pub rtt_adaptive: bool,
    /// `ACPMUX_PEER_REPLACE_SECS`: a silent link dials its replacement (while it still reads)
    /// after this much silence, when that is under the silence budget. Off (`None`) by
    /// default: the replacement dials when the budget runs out. The link is still dropped at
    /// twice the budget, as without it.
    pub replace_after: Option<Duration>,
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
    /// How long a request waits for a link that is coming back (`Peer::await_reconnect`) before
    /// it is refused as `peer_unreachable`. Zero refuses at once.
    pub reconnect_wait: Duration,
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
            rtt_adaptive: true,
            replace_after: None,
            send: Duration::from_secs(80),
            stable_after: Duration::from_secs(60),
            request: Duration::from_secs(600),
            start: START_DEFAULT,
            reconnect_wait: Duration::from_secs(5),
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
        if let Some(n) = std::env::var("ACPMUX_PEER_REPLACE_SECS")
            .ok()
            .and_then(|v| v.trim().parse::<f64>().ok())
            .filter(|n| n.is_finite() && *n > 0.0)
        {
            t.replace_after = Some(Duration::from_secs_f64(n));
        }
        if let Some(n) = secs("ACPMUX_PEER_REQUEST_SECS") {
            t.request = Duration::from_secs(n);
        }
        if let Some(n) = secs("ACPMUX_PEER_START_SECS") {
            t.start = Duration::from_secs(n);
        }
        if let Some(ms) = std::env::var("ACPMUX_PEER_RECONNECT_WAIT_MS")
            .ok()
            .and_then(|v| v.trim().parse::<u64>().ok())
        {
            t.reconnect_wait = Duration::from_millis(ms);
        }
        t
    }

    /// How long the peer may stay silent before the link is dropped, until it answers late
    /// (`SilenceBudget`).
    pub fn silence_budget(&self) -> Duration {
        self.ping_every * self.ping_misses
    }

    /// How long a link may stay silent before it dials a replacement, under the current
    /// `silence` budget: `replace_after` when set and shorter, else the budget itself.
    pub fn replace_at(&self, silence: Duration) -> Duration {
        self.replace_after.map_or(silence, |after| after.min(silence))
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
///
/// A network loss teaches it nothing: a link whose redial failed or was started over (the
/// network was gone, which a slow peer's redial is not) opens with the budget back at the start,
/// never doubled. Run 43783279032 grew it 6 -> 12 -> 20 s from 10 s network drops, and each drop
/// after that took the grown budget to be noticed.
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
    /// A dial since the last link failed or was started over (`dial_struggled`).
    struggled: bool,
    /// The last link was dropped by a request that got no answer (`probe_dropped`).
    probe_dropped: bool,
    /// A link a request probe dropped opened again at the first try: the peer is slow, not
    /// gone, so requests to it wait out the budget rather than drop the link. Until the budget
    /// is back at the start.
    slow_proven: bool,
    /// The smoothed time a stamped ping waited for its pong, and its mean deviation (RFC 6298),
    /// on this peer's links (`answered_in`): how late this peer answers now, as measured.
    srtt: Option<Duration>,
    rttvar: Duration,
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
            struggled: false,
            probe_dropped: false,
            slow_proven: false,
            srtt: None,
            rttvar: Duration::ZERO,
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

    /// A stamped ping was answered after `rtt`. A host at load 80 answers its pings seconds
    /// late, and so does a link from a loaded Mac whose ssh tunnel waits for a CPU: the round
    /// trip, smoothed (RFC 6298: 7/8 of the last estimate, its deviation 3/4), sets how long a
    /// request's probe waits ([`Self::probe_wait`]), and the budget is kept at twice its
    /// retransmit timeout. cosmic-gray, 2026-11-22, load 80 to 100: 788 links dropped in 3 h,
    /// 295 by a probe after 2 s on a link silent 2 to 5 s, 493 for 6 to 19 s of silence.
    pub fn answered_in(&mut self, rtt: Duration, now: tokio::time::Instant) {
        match self.srtt {
            None => {
                self.srtt = Some(rtt);
                self.rttvar = rtt / 2;
            }
            Some(srtt) => {
                let deviation = srtt.abs_diff(rtt);
                self.rttvar = (self.rttvar * 3 + deviation) / 4;
                self.srtt = Some((srtt * 7 + rtt) / 8);
            }
        }
        self.raise(self.rto() * 2, now);
    }

    /// The retransmit timeout of the measured round trip: its smoothed value and four times its
    /// deviation. Zero before any pong.
    pub fn rto(&self) -> Duration {
        self.srtt.map_or(Duration::ZERO, |srtt| srtt + self.rttvar * 4)
    }

    /// How long a request's probe on a silent link waits for an answer: `floor`
    /// (`NETWORK_PROBE`, a dead network found in 2 s), or this peer's measured retransmit
    /// timeout when it answers later than that, never past the silence budget.
    pub fn probe_wait(&self, floor: Duration) -> Duration {
        if self.fixed {
            return floor;
        }
        floor.max(self.rto()).min(self.current.max(floor))
    }

    /// The link is dropped for silence.
    pub fn dropped(&mut self, now: tokio::time::Instant) {
        self.dropped_at = Some(now);
    }

    /// A dial opened no path, or was started over (a client asked while it was still
    /// connecting): the network was gone. Not a link that opened and then dropped in its
    /// handshake, which a slow peer does too.
    pub fn dial_struggled(&mut self) {
        self.struggled = true;
    }

    /// The link is dropped because a request on it got no answer within `NETWORK_PROBE`.
    pub fn probe_dropped(&mut self) {
        self.probe_dropped = true;
    }

    /// Whether a request on a silent link may check it at once (`NETWORK_PROBE`) rather than wait
    /// out the budget: not for a peer that proved slow, nor with a fixed budget.
    pub fn may_probe(&self) -> bool {
        !self.fixed && !self.slow_proven
    }

    /// A new link's WebSocket opened: the peer's daemon answers.
    pub fn opened(&mut self, now: tokio::time::Instant) {
        let struggled = std::mem::take(&mut self.struggled);
        let probed = std::mem::take(&mut self.probe_dropped);
        let dropped = self.dropped_at.take();
        if struggled {
            // The network was gone: what the last links taught does not carry into the next drop.
            self.current = self.floor;
            self.moved_at = None;
            self.longest = Duration::ZERO;
            self.slow_proven = false;
            // A new route: its round trip is measured again.
            self.srtt = None;
            self.rttvar = Duration::ZERO;
            return;
        }
        if probed {
            self.slow_proven = true;
            self.raise(self.current * 2, now);
        } else if dropped.is_some_and(|at| now.saturating_duration_since(at) <= self.reopen) {
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
        // Nor under twice the measured round trip's timeout: a peer that still answers late
        // keeps the room it needs (`answered_in`).
        self.current = (self.current / 2)
            .max(self.longest * 2)
            .max(self.rto() * 2)
            .max(self.floor)
            .min(self.cap);
        self.moved_at = (self.current > self.floor).then_some(now);
        self.longest = Duration::ZERO;
        if self.moved_at.is_none() {
            self.slow_proven = false;
        }
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

    /// The first wait after the remote refused this computer's ssh login.
    pub const LOGIN_REFUSED_BASE: Duration = Duration::from_secs(5 * 60);
    /// The longest wait between refused logins.
    pub const LOGIN_REFUSED_CAP: Duration = Duration::from_secs(60 * 60);

    /// The least wait after the `refusals`-th refused ssh login in a row (1 for the first):
    /// doubling from `LOGIN_REFUSED_BASE` to `LOGIN_REFUSED_CAP`, plus up to a fifth more with
    /// `jitter`. A refused key does not fix itself in seconds, and each attempt counts against the
    /// remote's limit on failed logins (a ban tool blocks an address after a few in minutes), so a
    /// computer never redials it in a loop; an explicit reconnect still tries at once.
    pub fn login_refused(refusals: u32, jitter: f64) -> Duration {
        let doublings = refusals.saturating_sub(1).min(8);
        let step =
            Self::LOGIN_REFUSED_BASE.saturating_mul(1u32 << doublings).min(Self::LOGIN_REFUSED_CAP);
        step + step.mul_f64(jitter.clamp(0.0, 1.0) / 5.0)
    }

    /// The first wait after ssh refused the machine's host key.
    pub const HOST_KEY_REFUSED_BASE: Duration = Duration::from_secs(15);
    /// The longest wait between refused host keys.
    pub const HOST_KEY_REFUSED_CAP: Duration = Duration::from_secs(2 * 60);

    /// The least wait after the `refusals`-th refused host key in a row (1 for the first):
    /// doubling from `HOST_KEY_REFUSED_BASE` to `HOST_KEY_REFUSED_CAP`, plus up to a fifth more
    /// with `jitter`. ssh stops before it logs in, so no attempt counts against a ban tool, and
    /// the cause is often brief: a peer whose ssh works again links within minutes. Under the
    /// refused login's hour a host-key error held cosmic-gray's link down for about 2 h after
    /// ssh worked again (Air-Blue, 2026-11-26).
    pub fn host_key_refused(refusals: u32, jitter: f64) -> Duration {
        let doublings = refusals.saturating_sub(1).min(8);
        let step = Self::HOST_KEY_REFUSED_BASE
            .saturating_mul(1u32 << doublings)
            .min(Self::HOST_KEY_REFUSED_CAP);
        step + step.mul_f64(jitter.clamp(0.0, 1.0) / 5.0)
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
//
// The long bound: only for a peer that proved slow (`SilenceBudget::may_probe` is false, also
// with a fixed `ACPMUX_PEER_PING_SECS`). Every other link gets `wake_probe` (the network probe's
// 2 s): opening the lid on the same network used to freeze a remote chat up to 30 s.
pub const WAKE_PROBE: Duration = Duration::from_secs(30);

/// How long a link has after a wake to answer its ping: the 2 s network probe
/// (`peer_network::NETWORK_PROBE`) for a peer that may be probed, else `WAKE_PROBE`. A peer whose
/// short wake probe dropped a link that then reopened proves slow (`SilenceBudget::probe_dropped`
/// then `opened`), so it gets the long bound from then on: a slow link pays one extra handshake,
/// not one per wake, and a wake never starts a redial loop.
pub fn wake_probe(may_probe: bool, network_probe: Duration) -> Duration {
    if may_probe { network_probe.min(WAKE_PROBE) } else { WAKE_PROBE }
}

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

/// How a frame write is bounded: by `budget` of silence on the transport's writes (`wrote`, the
/// bytes it took), so a large frame on a slow uplink that keeps moving is never cut off, and one
/// that moved nothing for `budget` is. A running wake probe's deadline stays a total cap, so a
/// write to a link that died while the computer slept never holds the probe past it. With no
/// `wrote` (a test transport), `budget` counts from the start (`write_deadline`).
pub async fn write_within<F, T>(
    write: F,
    budget: Duration,
    wake_probe: Option<tokio::time::Instant>,
    wrote: Option<&cmux_deadline::Progress>,
) -> Option<T>
where
    F: std::future::Future<Output = T>,
{
    let now = tokio::time::Instant::now();
    match wrote {
        Some(wrote) => {
            let cap = wake_probe.map(|probe| probe.saturating_duration_since(now));
            cmux_deadline::progress_timeout(budget, cap, wrote, write).await.ok()
        }
        None => tokio::time::timeout_at(write_deadline(now, budget, wake_probe), write).await.ok(),
    }
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
    /// Bytes the transport took from a write (`cmux_deadline::ProgressIo`): a frame write ends
    /// on `send` of silence since the last byte went out, not `send` after it started
    /// (`write_within`).
    wrote: cmux_deadline::Progress,
    /// Bytes the transport read, counted as they arrive (also inside a frame not yet whole):
    /// a read through the link waits on this, not on a fixed time (`server::peer_forward`).
    read: cmux_deadline::Progress,
}

impl Default for Heard {
    fn default() -> Self {
        Self {
            origin: tokio::time::Instant::now(),
            at_ms: Default::default(),
            gap_ms: Default::default(),
            wrote: cmux_deadline::Progress::new(),
            read: cmux_deadline::Progress::new(),
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

    /// The transport's write progress: each byte it took from a write.
    pub fn wrote(&self) -> &cmux_deadline::Progress {
        &self.wrote
    }

    /// The transport's read progress: each byte it read.
    pub fn read(&self) -> &cmux_deadline::Progress {
        &self.read
    }

    pub fn wrap<S>(&self, inner: S) -> HeardStream<S> {
        self.wrap_early(inner, Vec::new())
    }

    /// [`Self::wrap`], with `early` (a whole WebSocket frame, `masked_text_frame`) written right
    /// behind the first write, which is the HTTP upgrade request: the peer's first request
    /// travels in the request's own flight instead of a round trip after its 101.
    pub fn wrap_early<S>(&self, inner: S, early: Vec<u8>) -> HeardStream<S> {
        HeardStream {
            inner: cmux_deadline::ProgressIo::new(inner, self.wrote.clone()),
            heard: self.clone(),
            early,
            pending: Vec::new(),
        }
    }
}

/// How long this daemon may keep a link from reading before the silence it saw meanwhile is
/// no longer counted as the peer's (`ReaderHeld`).
pub const READER_HELD: Duration = Duration::from_millis(500);

/// When this daemon last stopped reading a link, and since when it reads it again after holding
/// it at least `READER_HELD`. The link's loop reads only while it waits in its `select!`: a step
/// that awaits (a notice waiting for room in the hub's queue, a write behind a large frame)
/// reads nothing, and the transport's `Heard` marks no byte however many the peer sent.
/// Counted as the peer's silence, a few seconds of that dropped a healthy link: about 42 resets
/// in two hours of the link from the Mac to a lane VM, each "machine is unreachable; queued
/// here" for the sends meanwhile.
#[derive(Debug)]
pub struct ReaderHeld {
    stopped: std::sync::Mutex<Option<tokio::time::Instant>>,
    since: tokio::time::Instant,
}

impl Default for ReaderHeld {
    fn default() -> Self {
        Self { stopped: std::sync::Mutex::new(None), since: tokio::time::Instant::now() }
    }
}

impl ReaderHeld {
    /// The read for one `select!`: dropped as the select returns, before any branch's handler
    /// runs, so the time it stops is the time this daemon stopped reading.
    pub fn listen<F>(&self, read: F) -> Listen<'_, F> {
        Listen { read, held: self }
    }

    /// The loop is about to read again: how long it did not, when that was `READER_HELD` or
    /// more (the silence measured from now on).
    pub fn resume(&mut self) -> Option<Duration> {
        let stopped =
            self.stopped.get_mut().unwrap_or_else(std::sync::PoisonError::into_inner).take()?;
        let now = tokio::time::Instant::now();
        let held = now.saturating_duration_since(stopped);
        if held < READER_HELD {
            return None;
        }
        self.since = now;
        Some(held)
    }

    /// How long this daemon has read the link without holding it `READER_HELD`: no silence
    /// longer than this is the peer's.
    pub fn reading(&self) -> Duration {
        self.since.elapsed()
    }
}

/// A link's read inside its `select!` (`ReaderHeld::listen`).
pub struct Listen<'a, F> {
    read: F,
    held: &'a ReaderHeld,
}

impl<F: std::future::Future + Unpin> std::future::Future for Listen<'_, F> {
    type Output = F::Output;

    fn poll(
        mut self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<F::Output> {
        std::pin::Pin::new(&mut self.read).poll(cx)
    }
}

impl<F> Drop for Listen<'_, F> {
    fn drop(&mut self) {
        *self.held.stopped.lock().unwrap_or_else(std::sync::PoisonError::into_inner) =
            Some(tokio::time::Instant::now());
    }
}

/// A stream that marks its `Heard` on each read that returned bytes.
pub struct HeardStream<S> {
    /// Its writes count toward `Heard::wrote`.
    inner: cmux_deadline::ProgressIo<S>,
    heard: Heard,
    /// Bytes to send behind the first write (`Heard::wrap_early`).
    early: Vec<u8>,
    /// Bytes taken from a write but not yet on the inner stream.
    pending: Vec<u8>,
}

/// One client WebSocket text frame for `payload`, masked with a fresh random key (RFC 6455 5.3).
pub fn masked_text_frame(payload: &[u8]) -> Vec<u8> {
    let mut mask = [0u8; 4];
    let _ = getrandom::fill(&mut mask);
    let mut frame = Vec::with_capacity(payload.len() + 14);
    frame.push(0x81);
    match payload.len() {
        n if n < 126 => frame.push(0x80 | n as u8),
        n if n <= u16::MAX as usize => {
            frame.push(0x80 | 126);
            frame.extend_from_slice(&(n as u16).to_be_bytes());
        }
        n => {
            frame.push(0x80 | 127);
            frame.extend_from_slice(&(n as u64).to_be_bytes());
        }
    }
    frame.extend_from_slice(&mask);
    frame.extend(
        payload
            .iter()
            .enumerate()
            .map(|(i, b)| b ^ mask.get(i % mask.len()).copied().unwrap_or_default()),
    );
    frame
}

impl<S: tokio::io::AsyncWrite + Unpin> HeardStream<S> {
    /// Write out what a write left behind (`early`).
    fn drain(&mut self, cx: &mut std::task::Context<'_>) -> std::task::Poll<std::io::Result<()>> {
        use std::task::Poll;
        use tokio::io::AsyncWrite as _;
        while !self.pending.is_empty() {
            match std::pin::Pin::new(&mut self.inner).poll_write(cx, &self.pending) {
                Poll::Ready(Ok(0)) => {
                    return Poll::Ready(Err(std::io::ErrorKind::WriteZero.into()));
                }
                Poll::Ready(Ok(n)) => {
                    self.pending.drain(..n);
                }
                Poll::Ready(Err(e)) => return Poll::Ready(Err(e)),
                Poll::Pending => return Poll::Pending,
            }
        }
        Poll::Ready(Ok(()))
    }
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
            self.heard.read.bump_by((buf.filled().len() - before) as u64);
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
        std::task::ready!(self.drain(cx))?;
        if self.early.is_empty() {
            return std::pin::Pin::new(&mut self.inner).poll_write(cx, buf);
        }
        // The first write, and the frame behind it, go out together; the flush finishes them.
        let early = std::mem::take(&mut self.early);
        self.pending.extend_from_slice(buf);
        self.pending.extend_from_slice(&early);
        if let std::task::Poll::Ready(Err(e)) = self.drain(cx) {
            return std::task::Poll::Ready(Err(e));
        }
        std::task::Poll::Ready(Ok(buf.len()))
    }

    fn poll_flush(
        mut self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        std::task::ready!(self.drain(cx))?;
        std::pin::Pin::new(&mut self.inner).poll_flush(cx)
    }

    fn poll_shutdown(
        mut self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        std::task::ready!(self.drain(cx))?;
        std::pin::Pin::new(&mut self.inner).poll_shutdown(cx)
    }
}

/// What one connect attempt's end means to the link's resume (`acpmux_list_types::resume`),
/// from typed facts, never its error text: `clean` when it ended with no error (a restart's
/// Close 1012, a move to another path, a stop), `refused` when the remote refused the ssh login
/// or the token (`login_refused`, HTTP 401/403), `timed_out` when the connect or the handshake
/// ran past its [`LinkTimings`] deadline. Any other failure is the network's or the socket's.
/// The class goes to the log only: the link's bound is its park schedule
/// ([`Link::park_at_start`], [`Link::retry_delay`]).
pub fn link_end_class(clean: bool, refused: bool, timed_out: bool) -> ResumeErrorClass {
    if refused {
        ResumeErrorClass::Auth
    } else if clean {
        ResumeErrorClass::CleanClose
    } else if timed_out {
        ResumeErrorClass::DeadlineExceeded
    } else {
        ResumeErrorClass::Transient
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
    /// Not dialed on purpose (`peer_demand.rs`): reachable when last linked; use connects it.
    Idle,
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
            Self::Idle => W::Idle,
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
            Self::Idle => "idle",
        }
    }
}

/// A link whose peer was heard less than this ago is taken to be on its way back (`Link::coming_back`).
pub const COMING_BACK_MS: u64 = 30_000;

/// How long a link stays down before its automatic retries park on an hourly schedule.
pub const PARK_AFTER_MS: u64 = 24 * 60 * 60 * 1_000;

/// The link's history, in wall-clock milliseconds (`store::now_ms`).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Link {
    restarting: bool,
    /// Left undialed until something uses the peer (`peer_demand.rs`, `Link::idle`).
    pub(crate) idle: bool,
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
        if self.idle && !self.open {
            // Down when it was last linked: offline, and it reconnects on use.
            return if self.down_since.is_some() { PeerState::Offline } else { PeerState::Idle };
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

    /// Whether a request should wait for this link (`Peer::await_reconnect`): it is open and
    /// finishing its handshake, its daemon is restarting, its first attempt has not ended, or the
    /// peer was heard less than [`COMING_BACK_MS`] ago. A peer never reached, or not heard for
    /// longer, is not waited for.
    pub fn coming_back(&self, now: u64) -> bool {
        self.open
            || self.restarting
            || (self.attempts == 0 && self.down_since.is_none())
            || self.last_seen.is_some_and(|at| now.saturating_sub(at) < COMING_BACK_MS)
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
        if self.down_since.is_some_and(|at| now.saturating_sub(at) >= PARK_AFTER_MS) {
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

    /// Down a day or more without a successful handshake, and not trying one now: automatic
    /// retries are hourly (`parked` on the wire), and a list shows it as gone quiet rather than
    /// failing. A link whose WebSocket is open is retrying this moment, so it is not parked
    /// while that handshake runs.
    pub fn parked(&self, now: u64) -> bool {
        !self.open && self.down_since.is_some_and(|at| now.saturating_sub(at) >= PARK_AFTER_MS)
    }

    /// A parked peer's saved wait when this daemon starts, reported as `retry_at`
    /// (`nextRetryAt`) like every later wait, so a list can say when it is tried next.
    pub fn park_at_start(&mut self, now: u64) -> Option<Duration> {
        let wait = self.parked_retry_wait(now)?;
        self.retry_at = Some(now.saturating_add(wait.as_millis() as u64));
        Some(wait)
    }

    pub fn parked_retry_wait(&self, now: u64) -> Option<Duration> {
        self.next_retry_at.filter(|at| *at > now && self.down_since.is_some()).map(|at| {
            // A wall-clock correction must not strand a peer beyond one retry interval.
            Duration::from_millis(at - now).min(Duration::from_secs(3_660))
        })
    }

    /// The WebSocket opened; the handshake runs.
    pub fn opened(&mut self, now: u64) {
        self.idle = false;
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

    /// Left undialed until something uses the peer, or closed because nothing did
    /// (`peer_demand.rs`): no failed attempt counts, no outage starts, no attempt is scheduled.
    pub fn idle(&mut self) {
        (self.idle, self.restarting, self.open, self.ready, self.overdue) =
            (true, false, false, false, false);
        (self.ready_at, self.opened_at, self.retry_at) = (None, None, None);
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
        "peer_unreachable: {}; the request was not sent; `acpmux machine ls` shows when it reconnects",
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

    /// A refused host key waits seconds, then minutes, and never past its cap: unlike a
    /// refused login it costs the remote nothing, and an hour's wait kept a link down for 2 h.
    #[test]
    fn a_refused_host_key_waits_a_bounded_backoff() {
        assert_eq!(Backoff::host_key_refused(1, 0.0), Backoff::HOST_KEY_REFUSED_BASE);
        assert_eq!(Backoff::host_key_refused(2, 0.0), 2 * Backoff::HOST_KEY_REFUSED_BASE);
        let cap = Backoff::HOST_KEY_REFUSED_CAP;
        for n in 1..1_000 {
            assert!(Backoff::host_key_refused(n, 1.0) <= cap + cap / 5);
        }
        assert_eq!(Backoff::host_key_refused(u32::MAX, 0.0), cap);
        assert!(Backoff::host_key_refused(1, 1.0) < Backoff::login_refused(1, 0.0));
    }

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
    fn a_peer_parked_when_the_daemon_starts_reports_its_next_retry_and_is_parked() {
        // 2026-11-14: four lane VMs, stopped for a week; after a daemon restart
        // `machine ls` showed nextRetryAt null with a countdown frozen in the error text.
        let day = PARK_AFTER_MS;
        let mut link = Link::default();
        link.seed_outage(Some(0));
        link.schedule_retry(&mut Backoff::default(), day + 1, 0.0);
        let mut restarted = Link::default();
        restarted.seed_outage(link.down_since);
        restarted.next_retry_at = link.next_retry_at;
        let now = day + 1 + 600_000;
        assert_eq!(restarted.park_at_start(now), Some(Duration::from_secs(3_000)));
        assert_eq!(restarted.retry_at, Some(now + 3_000_000), "nextRetryAt is reported");
        assert!(restarted.parked(now));
        assert!(!restarted.parked(day - 1), "under a day down is not parked");
        restarted.opened(now + 1);
        restarted.ready(now + 2);
        assert!(!restarted.parked(now + 3), "a handshake ends the parking");
        assert_eq!(Link::default().park_at_start(now), None, "never down: nothing parked");
    }

    #[test]
    fn a_parked_peer_retrying_now_is_not_parked_while_its_handshake_runs() {
        let day = PARK_AFTER_MS;
        let mut link = Link::default();
        link.seed_outage(Some(0));
        assert!(link.parked(day + 1));
        link.opened(day + 2);
        assert!(!link.parked(day + 3), "the hourly retry's handshake is running");
        link.down(day + 4, Duration::from_secs(60));
        assert!(link.parked(day + 5), "the retry failed: parked again");
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

    /// A request waits for a link that was heard moments ago or has not tried yet, never for
    /// one that never answered or has been quiet for long (`Peer::await_reconnect`).
    #[test]
    fn a_request_waits_only_for_a_link_on_its_way_back() {
        assert!(Link::default().coming_back(0), "its first attempt has not ended");
        let mut blip = Link::default();
        blip.opened(0);
        blip.ready(0);
        blip.down(1_000, STABLE);
        assert!(blip.coming_back(COMING_BACK_MS - 1), "heard moments ago");
        assert!(!blip.coming_back(COMING_BACK_MS + 1), "quiet for long");
        let mut never = Link::default();
        never.down(1_000, STABLE);
        assert!(!never.coming_back(1_001), "never reached: refused at once");
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

    /// cosmic-gray at load 80 to 100: its pongs came 2 to 5 s late, and a request's probe gave up
    /// after a fixed 2 s. The measured round trip sets the probe's wait and keeps the budget up
    /// while the peer stays late; a fast peer keeps the 2 s probe and the 6 s budget.
    #[tokio::test(start_paused = true)]
    async fn a_measured_slow_round_trip_widens_the_probe_and_keeps_the_budget() {
        let t = LinkTimings::default();
        let probe = Duration::from_secs(2);
        let ms = Duration::from_millis;
        let secs = Duration::from_secs;
        let start = tokio::time::Instant::now();
        let mut fast = SilenceBudget::new(&t);
        for _ in 0..20 {
            fast.answered_in(ms(40), start);
        }
        assert_eq!(fast.probe_wait(probe), probe, "a fast peer: a dead network still found in 2 s");
        assert_eq!(fast.current(), secs(6));

        let mut slow = SilenceBudget::new(&t);
        assert_eq!(slow.probe_wait(probe), probe, "nothing measured yet");
        for late in [3_000, 4_500, 2_500, 5_000, 3_500, 4_000] {
            slow.answered_in(ms(late), start);
        }
        let wait = slow.probe_wait(probe);
        assert!(wait >= secs(6), "a probe waits past the peer's late answers: {wait:?}");
        assert!(wait <= slow.current(), "never past the budget: {wait:?}");
        assert!(slow.current() >= secs(12), "{:?}", slow.current());
        // Calm for a while, still late: the budget does not fall back under what it needs.
        let mut at = start;
        for _ in 0..5 {
            at += t.stable_after;
            slow.answered_in(ms(4_000), at);
            slow.settle(at);
        }
        assert!(slow.current() >= slow.rto() * 2, "{:?} < 2 x {:?}", slow.current(), slow.rto());
        // The load goes: answers fast again, and it comes back down to the start.
        for _ in 0..60 {
            slow.answered_in(ms(40), at);
        }
        for _ in 0..6 {
            at += t.stable_after;
            slow.settle(at);
        }
        assert_eq!(slow.current(), secs(6));
        assert_eq!(slow.probe_wait(probe), probe);
        // A fixed `ACPMUX_PEER_PING_SECS` keeps both.
        let fixed = LinkTimings { fixed_silence: true, ..t };
        let mut fixed = SilenceBudget::new(&fixed);
        fixed.answered_in(secs(5), start);
        assert_eq!((fixed.current(), fixed.probe_wait(probe)), (secs(6), probe));
    }

    /// Run 43783279032: 10 s network drops grew the budget 6 -> 12 -> 20 s, and each later drop
    /// took the grown budget to be noticed. A redial that failed first was a network loss.
    #[tokio::test(start_paused = true)]
    async fn a_network_loss_neither_grows_the_budget_nor_keeps_a_grown_one() {
        let t = LinkTimings::default();
        let mut budget = SilenceBudget::new(&t);
        let start = tokio::time::Instant::now();
        let secs = Duration::from_secs;
        budget.answered_after(secs(5), start);
        assert_eq!(budget.current(), secs(10));
        budget.dropped(start);
        budget.dial_struggled();
        budget.opened(start + secs(1));
        assert_eq!(
            budget.current(),
            secs(6),
            "a redial that failed first: back at the start, not doubled"
        );
        budget.dropped(start);
        budget.dial_struggled();
        budget.opened(start + secs(1));
        assert_eq!(
            budget.current(),
            secs(6),
            "a connect started over while the network was down: same"
        );
        budget.dropped(start);
        budget.opened(start + secs(1));
        assert_eq!(budget.current(), secs(12), "a clean reopen still reads as a slow peer");
    }

    /// A request probe that dropped a link which opened again at once found a slow peer: the
    /// budget doubles and requests stop probing it until the budget is back at the start.
    #[tokio::test(start_paused = true)]
    async fn a_slow_peer_found_by_a_request_probe_is_not_probed_again() {
        let t = LinkTimings::default();
        let mut budget = SilenceBudget::new(&t);
        let start = tokio::time::Instant::now();
        let secs = Duration::from_secs;
        assert!(budget.may_probe());
        budget.probe_dropped();
        budget.opened(start);
        assert_eq!(budget.current(), secs(12));
        assert!(!budget.may_probe(), "slow, not gone");
        budget.settle(start + t.stable_after);
        assert_eq!(budget.current(), secs(6));
        assert!(budget.may_probe(), "calm again: requests may check the link");
        budget.probe_dropped();
        budget.dial_struggled();
        budget.opened(start);
        assert!(
            budget.may_probe() && budget.current() == secs(6),
            "a probe drop whose redial failed was a network loss"
        );
    }

    #[test]
    fn the_replace_setting_is_off_by_default_and_never_past_the_budget() {
        let t = LinkTimings::default();
        assert_eq!(t.replace_after, None);
        assert_eq!(t.replace_at(Duration::from_secs(6)), Duration::from_secs(6));
        let early = LinkTimings { replace_after: Some(Duration::from_secs(5)), ..t };
        assert_eq!(early.replace_at(Duration::from_secs(6)), Duration::from_secs(5));
        assert_eq!(early.replace_at(Duration::from_secs(4)), Duration::from_secs(4));
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
