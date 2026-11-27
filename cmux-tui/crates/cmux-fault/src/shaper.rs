//! A deterministic link shaper: an in-process TCP proxy that plays a phone's link between a client
//! and a daemon (rate, one-way delay, jitter, loss, a blackout, an address change), driven by a
//! named [`LinkProfile`] from `link-profiles.json` and a seed, so two runs with one seed make the
//! same link decisions. The mobile network-conditions harness
//! (`scripts/measure/ios-network-conditions.sh`) runs every surface through one.
//!
//! The model, per direction, shared by every connection through the shaper (one radio link):
//!
//! - **rate**: bytes leave in 1460-byte segments, each after the one before it has serialized
//!   (`size * 8 / rate_kbit`), so a big snapshot queues behind itself and behind other streams;
//! - **delay and jitter**: each segment then takes `rtt_ms / 2` plus a seeded draw in
//!   `0..=jitter_ms`; TCP delivers in order, so a late segment holds the ones behind it (head of
//!   line), which is what an app over TCP sees;
//! - **loss**: a segment is lost with `loss_percent`; a lost segment arrives one retransmission
//!   timeout later (`max(rto_min_ms, 2 * rtt_ms)`, doubling while the retransmission is lost too);
//! - **blackout** ([`Shaper::blackout`]): nothing arrives for the window. Each connection keeps
//!   one retransmission timer per direction, as TCP does (RFC 6298 5.1): it starts when the first
//!   segment goes into the dark and doubles from there, and the first try after the window ends
//!   carries that segment; the rest of the backlog, and anything sent while the timer was still
//!   backing off, follows it at the link's rate (so a 30 s blackout can cost far more than 30 s,
//!   as it does on a phone). A new connection's SYN backs off from 1 s the same way;
//! - **address change** ([`Shaper::address_change`]): the phone's address changes, so every live
//!   connection goes silent for good (no reset reaches the phone: its peer's packets go to the
//!   old address) and new connections stall for the profile's handoff stall, then flow;
//! - **internet down** ([`Shaper::internet_down`]): the phone has two paths to the Mac, the LAN
//!   (the shaper's own address) and the internet ([`Shaper::open_internet_path`], a second
//!   listener to its own upstream, such as a relay). The internet path goes dead: its live
//!   connections go silent for good and new ones are refused at once, while the LAN path keeps
//!   the profile's numbers and never drops. The internet path rides the same radio link (one
//!   phone, one Wi-Fi); the WAN leg past the router is not modeled, only up or down.
//!
//! [`UdpShaper`] is the same link for datagrams (the phone's real transport is UDP): no
//! retransmission, jitter reorders, plus a NAT rebinding and one-way loss.
//!
//! Loopback adds nothing worth counting next to these numbers; the proxy runs on the bench's
//! machine beside the daemon.

use std::net::SocketAddr;
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use cmux_scope::Scope;
use serde::{Deserialize, Serialize};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{mpsc, watch};
use tokio::time::Instant;

use crate::rng::Rng;
use crate::trace::Trace;

mod udp;
pub use udp::{UdpCounters, UdpShaper, Way};

/// One TCP segment's payload (an MSS on a 1500-byte path).
pub const SEGMENT: usize = 1460;
/// Linux's `TCP_RTO_MAX`.
const RTO_MAX: Duration = Duration::from_secs(120);
/// The first SYN retransmission (RFC 6298 section 2.1's initial RTO).
const SYN_RTO: Duration = Duration::from_secs(1);
/// Bytes a direction may hold in flight before the sender waits (a radio bearer's buffer).
const QUEUE_SEGMENTS: usize = 256;

/// The file every harness reads.
pub const PROFILES_JSON: &str = include_str!("../link-profiles.json");

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
pub struct ProfileFile {
    pub version: u32,
    pub profiles: Vec<LinkProfile>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
pub struct LinkProfile {
    pub name: String,
    pub version: u32,
    /// Phone to daemon, kbit/s; 0 is unlimited.
    pub up_kbit: u64,
    /// Daemon to phone, kbit/s; 0 is unlimited.
    pub down_kbit: u64,
    pub rtt_ms: u64,
    #[serde(default)]
    pub jitter_ms: u64,
    /// Per segment, each direction.
    #[serde(default)]
    pub loss_percent: f64,
    #[serde(default = "default_rto_min")]
    pub rto_min_ms: u64,
    /// What the profile does to the link once the surface is live (the harness calls it).
    #[serde(default)]
    pub disruption: Option<Disruption>,
    #[serde(default)]
    pub source: String,
}

fn default_rto_min() -> u64 {
    200
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Disruption {
    /// Nothing gets through for `duration_ms`.
    Blackout { duration_ms: u64 },
    /// The address changes; new connections stall a seeded draw in `stall_ms` (inclusive).
    AddressChange { stall_ms: [u64; 2] },
    /// The internet path dies; the LAN path (the shaper's own address) keeps its numbers.
    InternetDown,
}

impl LinkProfile {
    /// Whether the profile's disruption drops the LAN link the shaper's own address carries
    /// (a blackout or an address change); an internet-only outage does not.
    pub fn disrupts_lan(&self) -> bool {
        matches!(
            self.disruption,
            Some(Disruption::Blackout { .. } | Disruption::AddressChange { .. })
        )
    }
}

/// Which of the phone's two paths a connection takes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Route {
    /// Phone and Mac on one network: the shaper's own address.
    Lan,
    /// Through the internet (a relay): [`Shaper::open_internet_path`].
    Internet,
}

impl ProfileFile {
    pub fn parse(text: &str) -> Result<Self, String> {
        let file: Self =
            serde_json::from_str(text).map_err(|error| format!("link profiles: {error}"))?;
        for profile in &file.profiles {
            if !(0.0..100.0).contains(&profile.loss_percent) {
                return Err(format!("link profile {}: loss_percent is 0 to <100", profile.name));
            }
        }
        Ok(file)
    }

    pub fn load(path: &Path) -> Result<Self, String> {
        let text = std::fs::read_to_string(path)
            .map_err(|error| format!("{}: {error}", path.display()))?;
        Self::parse(&text)
    }

    /// The profiles that ship in the crate. A file that does not parse gives no profiles, so every
    /// lookup names the missing row; `every_profile_parses_and_names_its_source` keeps the shipped file parsing.
    pub fn builtin() -> Self {
        Self::parse(PROFILES_JSON).unwrap_or(Self { version: 0, profiles: Vec::new() })
    }

    pub fn get(&self, name: &str) -> Option<&LinkProfile> {
        self.profiles.iter().find(|profile| profile.name == name)
    }
}

impl LinkProfile {
    /// The name a result row carries: `lte@1`, or `lte@1+relay-80@1` behind a relay hop
    /// ([`Shaper::start_through`]).
    pub fn label(&self, relay: Option<&LinkProfile>) -> String {
        match relay {
            Some(hop) => format!("{}@{}+{}@{}", self.name, self.version, hop.name, hop.version),
            None => format!("{}@{}", self.name, self.version),
        }
    }

    fn one_way(&self) -> Duration {
        Duration::from_micros(self.rtt_ms * 500)
    }

    fn rto(&self) -> Duration {
        Duration::from_millis(self.rto_min_ms.max(2 * self.rtt_ms))
    }

    fn serialize(&self, bytes: usize, down: bool) -> Duration {
        let kbit = if down { self.down_kbit } else { self.up_kbit };
        if kbit == 0 {
            return Duration::ZERO;
        }
        Duration::from_nanos((bytes as u64 * 8 * 1_000_000) / kbit)
    }
}

/// The link's state both directions share: when each direction's radio is next free, when the
/// link is dark, and which connections the last address change orphaned.
struct Link {
    profile: LinkProfile,
    free_at: [Instant; 2],
    dark: Option<(Instant, Instant)>,
    /// Connections numbered below this one belong to an old address: silent for good.
    orphaned_below: u64,
    /// New connections wait until then (an address change's stall).
    stalled_until: Option<Instant>,
    /// The internet path is dead: its connections are silent and new ones refused.
    internet_down: bool,
}

impl Link {
    /// Whether connection `index` on `path` delivers nothing (an old address, a dead path).
    fn silent(&self, index: u64, path: Route) -> bool {
        index < self.orphaned_below || (path == Route::Internet && self.internet_down)
    }

    /// When a segment sent now arrives: [`Link::schedule_at`].
    fn schedule(
        &mut self,
        bytes: usize,
        down: bool,
        rng: &mut Rng,
        floor: Instant,
        recovery: &mut Option<Recovery>,
    ) -> Instant {
        self.schedule_at(Instant::now(), bytes, down, rng, floor, recovery)
    }

    /// When a segment sent at `now` arrives: its serialization, the delay, jitter, loss and a
    /// blackout's retransmission backoff, never before `floor` (TCP's in-order delivery).
    /// `recovery` is the direction's one retransmission timer through a blackout.
    fn schedule_at(
        &mut self,
        now: Instant,
        bytes: usize,
        down: bool,
        rng: &mut Rng,
        floor: Instant,
        recovery: &mut Option<Recovery>,
    ) -> Instant {
        let lane = usize::from(down);
        let free_at = lane_mut(&mut self.free_at, lane);
        let start = (*free_at).max(now);
        let left = start + self.profile.serialize(bytes, down);
        *free_at = left;
        let mut jitter = Duration::ZERO;
        if self.profile.jitter_ms > 0 {
            jitter = Duration::from_millis(rng.range(0, self.profile.jitter_ms));
        }
        let mut arrive = left + self.profile.one_way() + jitter;
        let mut rto = self.profile.rto();
        while lost(rng, self.profile.loss_percent) {
            arrive += rto;
            rto = (rto * 2).min(RTO_MAX);
        }
        if let Some(window @ (from, until)) = self.dark {
            // The connection's timer through this window, if a segment already started it.
            let held = recovery.filter(|timer| timer.window == window).map(|timer| timer.drain);
            // Sent into the dark (or still on the air when it fell), or sent while the timer is
            // still backing off (cwnd is down to one segment: nothing new goes out before the
            // retransmission lands).
            if (left < until && arrive > from) || held.is_some_and(|drain| left < drain) {
                // The first such segment starts the one timer; the first try after the window
                // carries it, and the backlog drains behind it at the link's rate.
                let start = held.unwrap_or_else(|| self.retry_after(left.max(from), until));
                let sent = start.max(left) + self.profile.serialize(bytes, down);
                *recovery = Some(Recovery { window, drain: sent });
                arrive = sent + self.profile.one_way();
            }
        }
        arrive.max(floor)
    }

    /// The first try on the doubling ladder from a timer started at `started` that lands at or
    /// after `until`.
    fn retry_after(&self, started: Instant, until: Instant) -> Instant {
        let mut rto = self.profile.rto();
        let mut retry = started + rto;
        while retry < until {
            rto = (rto * 2).min(RTO_MAX);
            retry += rto;
        }
        retry
    }

    /// When a new connection's handshake completes, or `None` while the link is dark for good.
    fn connect_at(&self, now: Instant) -> Instant {
        let mut at = now + self.profile.one_way() * 2;
        if let Some(stall) = self.stalled_until {
            at = at.max(stall + self.profile.one_way() * 2);
        }
        if let Some((from, until)) = self.dark
            && now < until
            && at > from
        {
            let mut retry = now.max(from) + SYN_RTO;
            let mut rto = SYN_RTO;
            while retry < until {
                rto = (rto * 2).min(RTO_MAX);
                retry += rto;
            }
            at = retry + self.profile.one_way() * 2;
        }
        at
    }
}

/// One direction's retransmission timer through a blackout: TCP keeps one per connection, not
/// one per segment (#59268). `drain` is when the radio is free behind the backlog it carries.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Recovery {
    window: (Instant, Instant),
    drain: Instant,
}

fn lost(rng: &mut Rng, percent: f64) -> bool {
    if percent <= 0.0 {
        return false;
    }
    // 53 random bits as a fraction in [0, 1).
    let draw = (rng.next_u64() >> 11) as f64 / (1_u64 << 53) as f64;
    draw * 100.0 < percent
}

/// What crossed the link, for the report's bytes and round trips.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize)]
pub struct Counters {
    pub connections: u64,
    pub up_bytes: u64,
    pub down_bytes: u64,
    /// Times the client spoke after the daemon did (or first): request/response turns.
    pub up_turns: u64,
}

#[derive(Default)]
struct Counting {
    connections: AtomicU64,
    up_bytes: AtomicU64,
    down_bytes: AtomicU64,
    up_turns: AtomicU64,
    /// Which way the last chunk went (1 up, 2 down), across every connection.
    last: AtomicU64,
    /// [`Shaper::trace_wire`]: each connection's open and every read, into the run's trace.
    wire: Mutex<Option<Trace>>,
    /// Lines `wire` may still take (a bulk run reads thousands of chunks).
    wire_left: AtomicU64,
}

impl Counting {
    /// One wire line, while the budget lasts; nothing when the wire trace is off.
    fn wire(&self, line: impl FnOnce() -> String) {
        let trace = lock(&self.wire);
        let Some(trace) = trace.as_ref() else { return };
        if self
            .wire_left
            .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |n| n.checked_sub(1))
            .is_ok()
        {
            trace.note(line());
        }
    }
}

pub struct Shaper {
    addr: SocketAddr,
    link: Arc<Mutex<Link>>,
    seed: u64,
    rng: Mutex<Rng>,
    counting: Arc<Counting>,
    epoch: Arc<watch::Sender<u64>>,
    scope: Arc<Scope>,
    trace: Trace,
}

impl Shaper {
    /// A shaper on a free loopback port to `upstream` with `profile`'s link, seeded.
    pub async fn start(
        upstream: SocketAddr,
        profile: LinkProfile,
        seed: u64,
        trace: &Trace,
    ) -> std::io::Result<Self> {
        let listener = TcpListener::bind("127.0.0.1:0").await?;
        let addr = listener.local_addr()?;
        let now = Instant::now();
        trace.note(format!("shaper {} v{} seed {seed}", profile.name, profile.version));
        let link = Arc::new(Mutex::new(Link {
            profile,
            free_at: [now, now],
            dark: None,
            orphaned_below: 0,
            stalled_until: None,
            internet_down: false,
        }));
        let counting = Arc::new(Counting::default());
        let epoch = Arc::new(watch::channel(0_u64).0);
        let scope = Arc::new(Scope::new("cmux-fault shaper"));
        let shaper = Self {
            addr,
            link,
            seed,
            rng: Mutex::new(Rng::new(seed ^ 0xD15C_0DE5)),
            counting,
            epoch,
            scope,
            trace: trace.clone(),
        };
        shaper.accept(listener, upstream, Route::Lan);
        Ok(shaper)
    }

    /// Opens the phone's second path, through the internet to `upstream` (a relay), on a free
    /// loopback port, and returns it. It shares the radio link with the LAN path and dies with
    /// [`Shaper::internet_down`].
    pub async fn open_internet_path(&self, upstream: SocketAddr) -> std::io::Result<SocketAddr> {
        let listener = TcpListener::bind("127.0.0.1:0").await?;
        let addr = listener.local_addr()?;
        self.trace.note(format!("shaper internet path {addr}"));
        self.accept(listener, upstream, Route::Internet);
        Ok(addr)
    }

    fn accept(&self, listener: TcpListener, upstream: SocketAddr, path: Route) {
        let (link, counting, epoch) =
            (self.link.clone(), self.counting.clone(), self.epoch.clone());
        let weak = Arc::downgrade(&self.scope);
        let seed = self.seed;
        self.scope.spawn_until_cancelled("shaper accept", async move {
            while let Ok((near, _)) = listener.accept().await {
                let Some(scope) = weak.upgrade() else { return };
                // One numbering across both paths: the seed's streams and an address change's
                // cut-off both key on it.
                let index = counting.connections.fetch_add(1, Ordering::SeqCst);
                let (link, counting, epoch) = (link.clone(), counting.clone(), epoch.subscribe());
                scope.spawn_until_cancelled("shaper connection", async move {
                    connection(near, upstream, path, index, seed, link, counting, epoch).await;
                });
            }
        });
    }

    /// The phone's link to a peer one more hop away: `profile` in front of `relay` (a second
    /// shaped link, the relay between a Mac and its Cloud machine) in front of `upstream`. Each
    /// hop ends its own TCP connection, as a relaying host does. The first shaper is the phone's
    /// link (its address, counters and disruptions); the second is the hop, alive as long as
    /// the caller keeps it. Without `relay` it is [`Shaper::start`].
    pub async fn start_through(
        upstream: SocketAddr,
        profile: LinkProfile,
        relay: Option<&LinkProfile>,
        seed: u64,
        trace: &Trace,
    ) -> std::io::Result<(Self, Option<Self>)> {
        let hop = match relay {
            Some(relay) => {
                Some(Self::start(upstream, relay.clone(), seed ^ 0x5E1A_7000, trace).await?)
            }
            None => None,
        };
        let upstream = hop.as_ref().map_or(upstream, Self::addr);
        Ok((Self::start(upstream, profile, seed, trace).await?, hop))
    }

    pub fn addr(&self) -> SocketAddr {
        self.addr
    }

    pub fn seed(&self) -> u64 {
        self.seed
    }

    pub fn counters(&self) -> Counters {
        Counters {
            connections: self.counting.connections.load(Ordering::SeqCst),
            up_bytes: self.counting.up_bytes.load(Ordering::SeqCst),
            down_bytes: self.counting.down_bytes.load(Ordering::SeqCst),
            up_turns: self.counting.up_turns.load(Ordering::SeqCst),
        }
    }

    /// Notes every connection's open and every read (`c3 up 517B, lands +35ms`) in the trace
    /// this shaper was started with, up to `lines` lines: the round trips a dial takes, one by
    /// one. Off unless called; a read costs one mutex check while it is off.
    pub fn trace_wire(&self, lines: u64) {
        self.counting.wire_left.store(lines, Ordering::SeqCst);
        *lock(&self.counting.wire) = Some(self.trace.clone());
    }

    pub fn reset_counters(&self) {
        for counter in [
            &self.counting.up_bytes,
            &self.counting.down_bytes,
            &self.counting.up_turns,
            &self.counting.last,
        ] {
            counter.store(0, Ordering::SeqCst);
        }
    }

    /// Nothing gets through from now for `duration`; returns when the link is back.
    pub fn blackout(&self, duration: Duration) -> Instant {
        let now = Instant::now();
        let until = now + duration;
        self.trace.note(format!("fault blackout {} ms", duration.as_millis()));
        lock(&self.link).dark = Some((now, until));
        until
    }

    /// The phone's address changes now: live connections go silent for good, new ones stall a
    /// seeded draw in the profile's range (or `stall`). Returns when new connections flow.
    pub fn address_change(&self, stall: Option<Duration>) -> Instant {
        let mut link = lock(&self.link);
        let stall = stall.unwrap_or_else(|| match link.profile.disruption {
            Some(Disruption::AddressChange { stall_ms: [lo, hi] }) => {
                Duration::from_millis(lock(&self.rng).range(lo, hi.max(lo)))
            }
            _ => Duration::from_secs(2),
        });
        let until = Instant::now() + stall;
        link.orphaned_below = self.counting.connections.load(Ordering::SeqCst);
        link.stalled_until = Some(until);
        drop(link);
        self.trace.note(format!("fault address-change stall {} ms", stall.as_millis()));
        self.epoch.send_modify(|epoch| *epoch += 1);
        until
    }

    /// The internet path dies now (and stays dead): its live connections go silent, new ones are
    /// refused. The LAN path is untouched, so this returns now.
    pub fn internet_down(&self) -> Instant {
        lock(&self.link).internet_down = true;
        self.trace.note("fault internet-down");
        self.epoch.send_modify(|epoch| *epoch += 1);
        Instant::now()
    }

    /// The profile's own disruption, if it has one; returns when the LAN link is back.
    pub fn disrupt(&self) -> Option<Instant> {
        let disruption = lock(&self.link).profile.disruption.clone()?;
        Some(match disruption {
            Disruption::Blackout { duration_ms } => {
                self.blackout(Duration::from_millis(duration_ms))
            }
            Disruption::AddressChange { .. } => self.address_change(None),
            Disruption::InternetDown => self.internet_down(),
        })
    }

    pub fn profile(&self) -> LinkProfile {
        lock(&self.link).profile.clone()
    }
}

impl Drop for Shaper {
    fn drop(&mut self) {
        self.scope.token().cancel();
    }
}

fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|error| error.into_inner())
}

#[allow(clippy::too_many_arguments, reason = "one connection: each is its own part")]
async fn connection(
    near: TcpStream,
    upstream: SocketAddr,
    path: Route,
    index: u64,
    seed: u64,
    link: Arc<Mutex<Link>>,
    counting: Arc<Counting>,
    epoch: watch::Receiver<u64>,
) {
    // A dead internet path refuses at once (the router answers; the uplink behind it is out).
    if path == Route::Internet && lock(&link).internet_down {
        return;
    }
    let ready = lock(&link).connect_at(Instant::now());
    crate::timer::sleep_until(ready).await;
    if lock(&link).silent(index, path) {
        return;
    }
    counting.wire(|| format!("c{index} open (connect landed)"));
    let Ok(far) = TcpStream::connect(upstream).await else { return };
    let _ = near.set_nodelay(true);
    let _ = far.set_nodelay(true);
    let (near_read, near_write) = near.into_split();
    let (far_read, far_write) = far.into_split();
    // One stream per connection and direction: the link's decisions for this connection do not
    // depend on how other connections' tasks interleave.
    let mut root = Rng::new(seed);
    let up_rng = root.split(index.wrapping_mul(2) + 1);
    let down_rng = root.split(index.wrapping_mul(2) + 2);
    let up = direction(
        near_read,
        far_write,
        false,
        path,
        index,
        up_rng,
        link.clone(),
        counting.clone(),
        epoch.clone(),
    );
    let down = direction(far_read, near_write, true, path, index, down_rng, link, counting, epoch);
    tokio::select! { () = up => {}, () = down => {} }
}

#[allow(
    clippy::too_many_arguments,
    reason = "one direction of one connection: each is its own part"
)]
async fn direction(
    mut from: tokio::net::tcp::OwnedReadHalf,
    mut to: tokio::net::tcp::OwnedWriteHalf,
    down: bool,
    path: Route,
    index: u64,
    mut rng: Rng,
    link: Arc<Mutex<Link>>,
    counting: Arc<Counting>,
    mut epoch: watch::Receiver<u64>,
) {
    let (send, mut receive) = mpsc::channel::<(Instant, Vec<u8>)>(QUEUE_SEGMENTS);
    let writer_link = link.clone();
    let writer = async move {
        while let Some((at, segment)) = receive.recv().await {
            crate::timer::sleep_until(at).await;
            // Still on the air when the address changed (it goes to the old address too) or the
            // internet path died.
            if lock(&writer_link).silent(index, path) {
                continue;
            }
            if to.write_all(&segment).await.is_err() {
                return;
            }
        }
    };
    let reader = async move {
        let mut buffer = vec![0_u8; 64 * 1024];
        let mut floor = Instant::now();
        let mut recovery = None;
        loop {
            let read = tokio::select! {
                read = from.read(&mut buffer) => read,
                _ = epoch.changed() => continue,
            };
            let chunk = match read {
                Ok(0) | Err(_) => return,
                Ok(n) => buffer.get(..n).unwrap_or_default(),
            };
            let (bytes, way) =
                if down { (&counting.down_bytes, 2) } else { (&counting.up_bytes, 1) };
            bytes.fetch_add(chunk.len() as u64, Ordering::SeqCst);
            if counting.last.swap(way, Ordering::SeqCst) != way && !down {
                counting.up_turns.fetch_add(1, Ordering::SeqCst);
            }
            let read_at = Instant::now();
            let mut lands = None;
            for segment in chunk.chunks(SEGMENT) {
                let at = {
                    let mut link = lock(&link);
                    if link.silent(index, path) {
                        None
                    } else {
                        Some(link.schedule(segment.len(), down, &mut rng, floor, &mut recovery))
                    }
                };
                // An orphaned connection's bytes go to an address that is gone, a dead path's
                // nowhere.
                let Some(at) = at else { continue };
                lands = Some(at);
                floor = at;
                if send.send((at, segment.to_vec())).await.is_err() {
                    return;
                }
            }
            counting.wire(|| {
                let way = if down { "down" } else { "up" };
                match lands {
                    Some(at) => format!(
                        "c{index} {way} {}B, lands +{}ms",
                        chunk.len(),
                        at.saturating_duration_since(read_at).as_millis()
                    ),
                    None => format!("c{index} {way} {}B, dropped (link silent)", chunk.len()),
                }
            });
        }
    };
    tokio::select! { () = writer => {}, () = reader => {} }
}

/// One of an (up, down) pair by lane, 0 up and anything else down, without indexing.
pub(crate) fn lane<T>(pair: &[T; 2], lane: usize) -> &T {
    let [up, down] = pair;
    if lane == 0 { up } else { down }
}

pub(crate) fn lane_mut<T>(pair: &mut [T; 2], lane: usize) -> &mut T {
    let [up, down] = pair;
    if lane == 0 { up } else { down }
}

#[cfg(test)]
#[path = "shaper_tests.rs"]
mod tests;
