//! Mac-side accept: the hub carrier's direct path between machines on different networks
//! (Leo, 2026-11-25: "why don't we do mac side connect + measure more numbers and do more
//! stuff"). Before it, the direct path ([`super::direct`]) went only to a machine whose name
//! resolved to a private address in the dialer's own network; a Mac at home was never the side
//! another machine connected to, and every circuit to it rode the relay.
//!
//! Now every carrier listens (a port of its own unless `directPort` names one) and, on a dial to
//! a machine it has no private route to, the two trade candidates through the relay and both
//! open toward each other at once:
//!
//! - Candidates ([`local_candidates`]): this machine's LAN IPv4 and global IPv6 addresses on the
//!   listening port, and the router's mapping of that port when PCP or NAT-PMP grants one
//!   ([`portmap`]). Tailscale's ranges stay Tailscale's; a container or VM bridge's
//!   ([`host_bridge`]) is never offered, and a far candidate that is one of this machine's own
//!   addresses ([`own_address`]) is never opened toward.
//! - The offer ([`DIRECT_OFFER_SERVICE`]): one JSON line each way on a kept relay stream. A
//!   machine from before it answers `service.unknown` and the dialer keeps to the relay.
//! - The punch: each side connects from its listening port to each of the other's candidates,
//!   again every [`PUNCH_EVERY`] until one connects or [`PUNCH_WINDOW`] ends. Both sides send:
//!   a stateful firewall or an address-dependent filtering NAT lets in only the address this
//!   side already sent to (cmuxterm-hq handbook, silent-responder-behind-nat.md), and two SYNs
//!   that cross are a TCP simultaneous open. The dialer's connection is the Noise initiator; the
//!   other side hands its to the same [`super::Incoming`] a relay circuit reaches, so the same
//!   node keys admit it.
//! - The first dial to a machine never waits on any of this: it rides the relay while the punch
//!   runs beside it, and the next dial takes the punched connection. A failed punch holds the
//!   machine on the relay for [`PUNCH_HOLD`]; a symmetric NAT on both sides with no mapping
//!   always ends there, as it must.
//! - Churn is bounded ([`PunchHold`]): each miss in a row doubles the hold, jittered, up to
//!   [`PUNCH_HOLD_MAX`]; a punch asked for again within [`PUNCH_STABLE`] of one that connected
//!   (its link did not last) counts as a miss, and only a punched link that lasted that long
//!   clears the count. At most [`MAX_PUNCHES_AT_ONCE`] punches run and at most
//!   [`MAX_ANSWERS_AT_ONCE`] offers are answered at once on this machine; past either a dial
//!   rides the relay. cosmic-gray at load 187, 2026-11-27: 18.5k punch attempts and about 6k
//!   peer disconnects across about 200 peers, with a flat 120 s hold that a short-lived punched
//!   link cleared each time.
//!
//! - The claim ([`Offer::claim`]): the dialer's offer names a random nonce and an answerer that
//!   knows it echoes it. Each side then opens with a 12-byte preamble ([`CLAIM_MAGIC`] and the
//!   nonce) and reads the other's, and a listener that reads one routes the connection by its
//!   nonce ([`Punches::claimed`]): to this machine's own punch for it when this machine dialed,
//!   so the dialer stays the Noise initiator whichever side's SYN made the connection. Before
//!   it, where only the dialer's address took connections (a public VM dialing a NATed Mac),
//!   the answerer's connect reached the dialer's listener, both sides waited as the responder,
//!   and the dialer's own connect then failed on the same pair of addresses: fleet census
//!   2026-11-28, 12,320 punches in 24 h, 2.6% direct, 5,050 "no candidate of 1 connected".
//!   A dialer from before it sends no nonce, and both sides open as they did.
//!
//! Off with `ACPMUX_DIRECT_PUNCH=0` (no listener of its own, no offers) or `directPort` 0.

use std::collections::{HashMap, HashSet};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::sync::{Arc, Mutex, RwLock};
use std::time::{Duration, Instant};

use cmux_remote::crypto::NetworkPeer;
use cmux_remote::provider::LengthDelimitedLink;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt};
use tokio::net::TcpStream;

use super::{
    CircuitLane, CircuitService, DialReport, HubCarrier, HubStream, KeptOpen, MAX_FRAME_BYTES,
    Path, hello_record,
};

#[path = "hub_carrier_portmap.rs"]
pub mod portmap;

#[path = "hub_carrier_reflexive.rs"]
pub mod reflexive;

/// The service name a hello gives [`CircuitService::DirectOffer`].
pub const DIRECT_OFFER_SERVICE: &str = "direct-offer";
/// How often each side opens toward a candidate that has not connected.
pub const PUNCH_EVERY: Duration = Duration::from_millis(250);
/// How long both sides keep opening toward each other.
pub const PUNCH_WINDOW: Duration = Duration::from_secs(3);
/// One connect attempt's bound: past the first SYN retransmit, so a SYN that crosses the far
/// side's finds this one still waiting.
const ATTEMPT_BOUND: Duration = Duration::from_millis(1200);
/// The offer exchange's bound.
const OFFER_BOUND: Duration = Duration::from_secs(3);
/// How long a machine whose punch failed once is dialed over the relay only.
pub const PUNCH_HOLD: Duration = Duration::from_secs(120);
/// The longest hold, however many misses in a row.
pub const PUNCH_HOLD_MAX: Duration = Duration::from_secs(60 * 60);
/// How long a punched link must last before its machine's misses are forgotten: a punch asked
/// for sooner (the last one's link already gone) is churn and counts as a miss.
pub const PUNCH_STABLE: Duration = Duration::from_secs(10 * 60);
/// The most punches this machine runs at once, across every peer.
pub const MAX_PUNCHES_AT_ONCE: usize = 4;
/// The most offers this machine answers (opens toward) at once, across every peer.
pub const MAX_ANSWERS_AT_ONCE: usize = 8;
/// How long a punched connection waits for the dial that takes it.
const PENDING_KEEP: Duration = Duration::from_secs(30);
/// The most candidates an offer carries or a side opens toward.
const MAX_CANDIDATES: usize = 16;
/// The longest offer line.
const MAX_OFFER_BYTES: usize = 4096;
/// A claimed punch's preamble starts with these 4 bytes, then the nonce (8, big-endian). A
/// legacy circuit's first bytes are a length prefix no larger than `MAX_FRAME_BYTES`; 0xFFFF
/// read as either a 2- or a 4-byte prefix is past any first handshake frame.
pub const CLAIM_MAGIC: [u8; 4] = [0xff, 0xff, b'P', b'C'];
/// The preamble's length.
pub const CLAIM_LEN: usize = 12;
/// How long a listener waits for a connection's first bytes before taking it as legacy.
const CLAIM_PEEK_BOUND: Duration = Duration::from_millis(1500);

/// Keep `port`'s public addresses offered while `carrier` lives: the router's mapping
/// ([`portmap`]) and, unless `ACPMUX_PUNCH_REFLEXIVE=0`, the STUN-read address ([`reflexive`]).
pub fn keep_public(carrier: &Arc<HubCarrier>, port: u16) {
    let mapping = Arc::downgrade(carrier);
    super::direct::scope().spawn_named("hub carrier port map", async move {
        portmap::keep_mapped(mapping, port).await;
    });
    if reflexive::enabled() {
        let learning = Arc::downgrade(carrier);
        super::direct::scope().spawn_named("hub carrier public address", async move {
            reflexive::keep_learned(learning, port).await;
        });
    }
}

/// Whether this process punches: unless `ACPMUX_DIRECT_PUNCH=0`.
pub fn enabled() -> bool {
    enabled_by(std::env::var("ACPMUX_DIRECT_PUNCH").ok().as_deref())
}

fn enabled_by(value: Option<&str>) -> bool {
    !matches!(value.map(str::trim), Some("0" | "false" | "off" | "no"))
}

/// One side's candidates, as the offer carries them.
#[derive(Debug, Clone, Default, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct Offer {
    pub candidates: Vec<SocketAddr>,
    /// The dialer's punch nonce, echoed by an answerer that opens with the claim preamble.
    /// Absent from (and ignored by) a machine from before it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub claim: Option<u64>,
}

/// The preamble a claimed punch opens with.
pub fn claim_preamble(nonce: u64) -> [u8; CLAIM_LEN] {
    let mut out = [0u8; CLAIM_LEN];
    out[..4].copy_from_slice(&CLAIM_MAGIC);
    out[4..].copy_from_slice(&nonce.to_be_bytes());
    out
}

/// The nonce of a preamble, or None for anything else.
pub fn claim_nonce(bytes: &[u8]) -> Option<u64> {
    if bytes.len() < CLAIM_LEN || bytes[..4] != CLAIM_MAGIC {
        return None;
    }
    Some(u64::from_be_bytes(bytes[4..CLAIM_LEN].try_into().ok()?))
}

/// A punch nonce: random, never 0.
fn new_nonce() -> u64 {
    let mut bytes = [0u8; 8];
    if getrandom::fill(&mut bytes).is_err() {
        let t = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| d.as_nanos() as u64);
        bytes = (t ^ u64::from(std::process::id()).rotate_left(32)).to_be_bytes();
    }
    u64::from_be_bytes(bytes).max(1)
}

/// Who waits on a claimed punch's nonce on this machine.
pub(crate) enum Claim {
    /// This machine's own punch, the Noise initiator: a connection the far side's SYN made goes
    /// to it.
    Dial(tokio::sync::oneshot::Sender<(TcpStream, SocketAddr)>),
    /// An offer this machine answers: a connection the dialer's SYN made is the responder's.
    Answer,
}

/// What a listener does with a connection whose preamble it read.
pub(crate) enum Claimed {
    /// Hand it to this machine's punch, which dials over it.
    Dial(tokio::sync::oneshot::Sender<(TcpStream, SocketAddr)>),
    /// Accept it as the responder.
    Answer,
}

/// A nonce's claim, removed when the punch or the answer it belongs to ends.
struct ClaimGuard<'a> {
    punches: &'a Punches,
    nonce: u64,
}

impl Drop for ClaimGuard<'_> {
    fn drop(&mut self) {
        self.punches.claims.lock().unwrap_or_else(|e| e.into_inner()).remove(&self.nonce);
    }
}

/// Why a punch made no connection: before the two sides traded candidates (the offer refused,
/// no relay stream, no answer, no candidate) or after.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum PunchMiss {
    /// The offer was never answered over the relay: says nothing about the network between
    /// the two, so the hold does not grow.
    Untraded(String),
    /// Candidates were traded (or refused by a machine without the service) and no
    /// connection opened.
    Missed(String),
}

impl std::fmt::Display for PunchMiss {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Untraded(why) | Self::Missed(why) => f.write_str(why),
        }
    }
}

/// Whether `ip` is one a machine on another network might reach this one at: a LAN IPv4 (a
/// machine on the same LAN), a public IPv4 on the interface, or a global or unique-local IPv6.
/// Never loopback, link-local, multicast or Tailscale's ranges (100.64/10, fd7a:115c:a1e0::/48).
pub fn candidate_ip(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => {
            let o = v4.octets();
            let cgnat = o[0] == 100 && (o[1] & 0xc0) == 64;
            !(v4.is_loopback()
                || v4.is_link_local()
                || v4.is_unspecified()
                || v4.is_multicast()
                || v4.is_broadcast()
                || cgnat)
        }
        IpAddr::V6(v6) => {
            if v6.to_ipv4_mapped().is_some() {
                return false;
            }
            let s = v6.segments();
            let tailscale = s[0] == 0xfd7a && s[1] == 0x115c && s[2] == 0xa1e0;
            let link_local = (s[0] & 0xffc0) == 0xfe80;
            !(v6.is_loopback()
                || v6.is_unspecified()
                || v6.is_multicast()
                || link_local
                || tailscale)
        }
    }
}

/// The candidates of a machine listening on `port` with these interface addresses and its
/// `mapped` public addresses (the router's mapping, then the port's STUN-read public address,
/// [`reflexive`]): the mapped first (reachable from anywhere), then IPv6 (no NAT between two
/// IPv6 hosts), then LAN IPv4. Deduplicated, at most [`MAX_CANDIDATES`].
pub fn local_candidates(
    port: u16,
    addresses: impl IntoIterator<Item = IpAddr>,
    mapped: impl IntoIterator<Item = SocketAddr>,
) -> Vec<SocketAddr> {
    let mut v6 = Vec::new();
    let mut v4 = Vec::new();
    for ip in addresses.into_iter().filter(|ip| candidate_ip(*ip)) {
        match ip {
            IpAddr::V6(_) => v6.push(SocketAddr::new(ip, port)),
            IpAddr::V4(_) => v4.push(SocketAddr::new(ip, port)),
        }
    }
    let mut out = Vec::new();
    for candidate in mapped.into_iter().chain(v6).chain(v4) {
        if !out.contains(&candidate) && out.len() < MAX_CANDIDATES {
            out.push(candidate);
        }
    }
    out
}

/// Whether `name` is a bridge or virtual link a container or VM host keeps for its own guests
/// (Docker's `docker0` and `br-*`, libvirt, LXD/LXC, podman, CNI, veth pairs). Its address is
/// the same on every such host (Docker's 172.17.0.1), so no other machine reaches this one at
/// it: offered, it sends the far side's punch into the far side's own bridge.
pub fn host_bridge(name: &str) -> bool {
    const PREFIXES: [&str; 11] = [
        "docker", "br-", "veth", "virbr", "lxdbr", "lxcbr", "podman", "cni", "flannel", "cali",
        "vnet",
    ];
    PREFIXES.iter().any(|p| name.starts_with(p))
}

/// Whether `ip` is one of this machine's own addresses, on any interface, up or down: a socket
/// binds to it. A connect to it reaches this machine, never the far one, so a far side's
/// candidate that is one (another host's `docker0` 172.17.0.1, a VM template's address) is a
/// connection to this machine's own listener.
pub fn own_address(ip: IpAddr) -> bool {
    std::net::UdpSocket::bind(SocketAddr::new(ip, 0)).is_ok()
}

/// The far side's candidates this side opens toward: no wildcard, loopback only from loopback
/// (tests), none of this machine's own addresses, at most [`MAX_CANDIDATES`].
fn usable_toward(candidates: &[SocketAddr]) -> Vec<SocketAddr> {
    usable_toward_from(candidates, own_address)
}

fn usable_toward_from(candidates: &[SocketAddr], own: impl Fn(IpAddr) -> bool) -> Vec<SocketAddr> {
    let mut out: Vec<SocketAddr> = Vec::new();
    for c in candidates {
        let ip = c.ip();
        let ok = c.port() != 0 && (ip.is_loopback() || (candidate_ip(ip) && !own(ip)));
        if ok && !out.contains(c) && out.len() < MAX_CANDIDATES {
            out.push(*c);
        }
    }
    out
}

/// The carrier's punch state.
#[derive(Default)]
pub(crate) struct Punches {
    /// The port this carrier listens on for direct connections, when it does.
    listen_port: RwLock<Option<u16>>,
    /// The carrier itself, which a punch beside a dial runs on.
    carrier: RwLock<std::sync::Weak<HubCarrier>>,
    /// The router's mapping of that port, when one was granted.
    mapped: RwLock<Option<SocketAddr>>,
    /// That port's public address as a STUN server saw it ([`reflexive`]), when one answered.
    reflexive: RwLock<Option<SocketAddr>>,
    /// Interface addresses a test names in place of this machine's own.
    addresses: RwLock<Option<Vec<IpAddr>>>,
    /// Punched connections waiting for a dial, by machine and lane.
    pending: Mutex<HashMap<(String, CircuitLane), (TcpStream, SocketAddr, Instant)>>,
    /// Punches running now.
    running: Mutex<HashSet<(String, CircuitLane)>>,
    /// Machines whose punch failed, until when and how many times in a row.
    held: Mutex<HashMap<String, PunchHold>>,
    /// When a punch last connected, by machine and lane (`PUNCH_STABLE`).
    punched_at: Mutex<HashMap<(String, CircuitLane), Instant>>,
    /// Offers being answered now (`MAX_ANSWERS_AT_ONCE`).
    answering: std::sync::atomic::AtomicUsize,
    /// Claimed punches running now, by nonce ([`Claim`]).
    claims: Mutex<HashMap<u64, Claim>>,
    /// Counts for `_acpmux/carrier` and the tests.
    pub(crate) stats: PunchStats,
}

/// One machine's hold off the punch: until when, and the misses in a row that set it.
#[derive(Clone, Copy, Debug)]
pub(crate) struct PunchHold {
    pub(crate) until: Instant,
    pub(crate) misses: u32,
}

/// The hold after `misses` misses in a row: `PUNCH_HOLD` doubled per miss after the first,
/// never past `PUNCH_HOLD_MAX`, spread by `jitter` (0 to 1) over 75% to 125% so 200 peers'
/// holds do not end together.
pub(crate) fn hold_for(misses: u32, jitter: f64) -> Duration {
    let doubled = PUNCH_HOLD.saturating_mul(1u32 << misses.saturating_sub(1).min(16));
    let base = doubled.min(PUNCH_HOLD_MAX);
    base.mul_f64(0.75 + 0.5 * jitter.clamp(0.0, 1.0)).min(PUNCH_HOLD_MAX)
}

/// An offer being answered, counted in `Punches::answering` until it drops.
struct Answering<'a>(&'a std::sync::atomic::AtomicUsize);

impl Drop for Answering<'_> {
    fn drop(&mut self) {
        self.0.fetch_sub(1, std::sync::atomic::Ordering::Relaxed);
    }
}

#[derive(Default)]
pub(crate) struct PunchStats {
    pub(crate) tried: std::sync::atomic::AtomicU64,
    pub(crate) punched: std::sync::atomic::AtomicU64,
    pub(crate) failed: std::sync::atomic::AtomicU64,
    pub(crate) answered: std::sync::atomic::AtomicU64,
    /// Punches not started (`MAX_PUNCHES_AT_ONCE`) or offers not answered
    /// (`MAX_ANSWERS_AT_ONCE`) because this machine was at its cap.
    pub(crate) capped: std::sync::atomic::AtomicU64,
    /// Punches asked for again within `PUNCH_STABLE` of one that connected.
    pub(crate) churned: std::sync::atomic::AtomicU64,
}

impl Punches {
    fn listen_port(&self) -> Option<u16> {
        *self.listen_port.read().unwrap_or_else(|e| e.into_inner())
    }

    fn candidates(&self) -> Vec<SocketAddr> {
        let Some(port) = self.listen_port() else { return Vec::new() };
        let mapped = *self.mapped.read().unwrap_or_else(|e| e.into_inner());
        let reflexive = *self.reflexive.read().unwrap_or_else(|e| e.into_inner());
        let named = self.addresses.read().unwrap_or_else(|e| e.into_inner()).clone();
        if let Some(named) = named {
            // A test's addresses as named, loopback included.
            return named.into_iter().map(|ip| SocketAddr::new(ip, port)).collect();
        }
        let addresses = cmux_netwatch::usable()
            .unwrap_or_default()
            .into_iter()
            .filter(|(name, _)| !host_bridge(name))
            .map(|(_, ip)| ip);
        local_candidates(port, addresses, mapped.into_iter().chain(reflexive))
    }

    fn held_off(&self, daemon: &str) -> bool {
        self.held_off_at(daemon, Instant::now())
    }

    /// An ended hold keeps its count, so the next miss holds longer; only a punched link that
    /// lasted (`may_start`) forgets it.
    pub(crate) fn held_off_at(&self, daemon: &str, now: Instant) -> bool {
        let held = self.held.lock().unwrap_or_else(|e| e.into_inner());
        held.get(daemon).is_some_and(|h| now < h.until)
    }

    /// A punch to `daemon` failed (or its punched path did): hold it off, longer for each miss
    /// in a row.
    pub(crate) fn miss(&self, daemon: &str) {
        self.miss_at(daemon, Instant::now(), crate::peer_link::jitter());
    }

    /// A punch to `daemon` whose offer went unanswered: hold it off for one `PUNCH_HOLD`
    /// (jittered) without counting a miss, so a relay hiccup does not grow the hold the way a
    /// network that refuses every SYN does.
    pub(crate) fn pause(&self, daemon: &str) {
        self.pause_at(daemon, Instant::now(), crate::peer_link::jitter());
    }

    pub(crate) fn pause_at(&self, daemon: &str, now: Instant, jitter: f64) -> PunchHold {
        let mut held = self.held.lock().unwrap_or_else(|e| e.into_inner());
        let misses = held.get(daemon).map_or(0, |h| h.misses);
        let until = now + hold_for(1, jitter);
        let hold = match held.get(daemon) {
            Some(h) if h.until > until => *h,
            _ => PunchHold { until, misses },
        };
        held.insert(daemon.to_owned(), hold);
        hold
    }

    /// Wait on `nonce` for a connection the far side's SYN made: as `claim` says.
    fn claim_nonce(&self, nonce: u64, claim: Claim) -> ClaimGuard<'_> {
        self.claims.lock().unwrap_or_else(|e| e.into_inner()).insert(nonce, claim);
        ClaimGuard { punches: self, nonce }
    }

    /// Who takes a connection whose preamble named `nonce`: a dial's claim is taken (one
    /// connection each), an answer's stays until the answer ends. None: no punch here knows it.
    pub(crate) fn claimed(&self, nonce: u64) -> Option<Claimed> {
        let mut claims = self.claims.lock().unwrap_or_else(|e| e.into_inner());
        match claims.get(&nonce)? {
            Claim::Answer => Some(Claimed::Answer),
            Claim::Dial(_) => match claims.remove(&nonce) {
                Some(Claim::Dial(tx)) => Some(Claimed::Dial(tx)),
                _ => None,
            },
        }
    }

    pub(crate) fn miss_at(&self, daemon: &str, now: Instant, jitter: f64) -> PunchHold {
        let mut held = self.held.lock().unwrap_or_else(|e| e.into_inner());
        let misses = held.get(daemon).map_or(0, |h| h.misses).saturating_add(1);
        let hold = PunchHold { until: now + hold_for(misses, jitter), misses };
        held.insert(daemon.to_owned(), hold);
        hold
    }

    /// The hold on `daemon` now, if any (tests and `_acpmux/carrier`).
    pub(crate) fn hold(&self, daemon: &str) -> Option<PunchHold> {
        self.held.lock().unwrap_or_else(|e| e.into_inner()).get(daemon).copied()
    }

    /// A punch to `daemon` on `lane` connected at `now`.
    pub(crate) fn connected_at(&self, daemon: &str, lane: CircuitLane, now: Instant) {
        self.punched_at
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .insert((daemon.to_owned(), lane), now);
    }

    /// A punch to `daemon` on `lane` is wanted at `now`: whether it may start. One asked for
    /// within `PUNCH_STABLE` of the last that connected is churn (that link did not last): a
    /// miss, and no punch. One after a link that lasted forgets the misses.
    pub(crate) fn may_start(&self, daemon: &str, lane: CircuitLane, now: Instant) -> bool {
        let key = (daemon.to_owned(), lane);
        let last = self.punched_at.lock().unwrap_or_else(|e| e.into_inner()).remove(&key);
        match last {
            Some(at) if now.saturating_duration_since(at) < PUNCH_STABLE => {
                self.stats.churned.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                self.miss_at(daemon, now, crate::peer_link::jitter());
                false
            }
            Some(_) => {
                self.held.lock().unwrap_or_else(|e| e.into_inner()).remove(daemon);
                true
            }
            None => true,
        }
    }

    /// Claim a running slot for a punch to `daemon` on `lane`: false while one to it runs, or
    /// `MAX_PUNCHES_AT_ONCE` run.
    pub(crate) fn claim(&self, daemon: &str, lane: CircuitLane) -> bool {
        let mut running = self.running.lock().unwrap_or_else(|e| e.into_inner());
        let key = (daemon.to_owned(), lane);
        if running.contains(&key) {
            return false;
        }
        if running.len() >= MAX_PUNCHES_AT_ONCE {
            self.stats.capped.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            return false;
        }
        running.insert(key)
    }

    pub(crate) fn release(&self, daemon: &str, lane: CircuitLane) {
        self.running.lock().unwrap_or_else(|e| e.into_inner()).remove(&(daemon.to_owned(), lane));
    }

    /// Claim a slot to answer an offer, or None at `MAX_ANSWERS_AT_ONCE`.
    fn answer_slot(&self) -> Option<Answering<'_>> {
        use std::sync::atomic::Ordering::Relaxed;
        let taken = self.answering.fetch_add(1, Relaxed);
        let slot = Answering(&self.answering);
        if taken >= MAX_ANSWERS_AT_ONCE {
            self.stats.capped.fetch_add(1, Relaxed);
            return None;
        }
        Some(slot)
    }

    fn has_pending(&self, daemon: &str, lane: CircuitLane) -> bool {
        let mut pending = self.pending.lock().unwrap_or_else(|e| e.into_inner());
        let key = (daemon.to_owned(), lane);
        match pending.get(&key) {
            Some((_, _, at)) if at.elapsed() < PENDING_KEEP => true,
            Some(_) => {
                pending.remove(&key);
                false
            }
            None => false,
        }
    }

    fn take_pending(&self, daemon: &str, lane: CircuitLane) -> Option<(TcpStream, SocketAddr)> {
        let (tcp, address, at) = self
            .pending
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .remove(&(daemon.to_owned(), lane))?;
        (at.elapsed() < PENDING_KEEP).then_some((tcp, address))
    }
}

impl HubCarrier {
    /// Listen for direct connections on `port` for punches: the port candidates name and both
    /// sides open from.
    pub fn set_punch_port(self: &Arc<Self>, port: u16) {
        *self.direct.punch.carrier.write().unwrap_or_else(|e| e.into_inner()) =
            Arc::downgrade(self);
        *self.direct.punch.listen_port.write().unwrap_or_else(|e| e.into_inner()) = Some(port);
    }

    /// Offer `mapped` (a router's mapping of the punch port) as a candidate.
    pub fn set_punch_mapped(&self, mapped: Option<SocketAddr>) {
        *self.direct.punch.mapped.write().unwrap_or_else(|e| e.into_inner()) = mapped;
    }

    /// Offer `reflexive` (the punch port's public address as a STUN server saw it) as a
    /// candidate.
    pub fn set_punch_reflexive(&self, reflexive: Option<SocketAddr>) {
        *self.direct.punch.reflexive.write().unwrap_or_else(|e| e.into_inner()) = reflexive;
    }

    /// Offer these addresses in place of this machine's interfaces (tests).
    #[doc(hidden)]
    pub fn set_punch_addresses(&self, addresses: Vec<IpAddr>) {
        *self.direct.punch.addresses.write().unwrap_or_else(|e| e.into_inner()) = Some(addresses);
    }

    /// Whether this machine listens for punched connections (answers offers).
    pub fn punch_listening(&self) -> bool {
        self.direct.punch.listen_port().is_some()
    }

    /// The candidates this machine offers now.
    pub fn punch_candidates(&self) -> Vec<SocketAddr> {
        self.direct.punch.candidates()
    }

    /// Punches tried, connected, failed, and offers this machine answered.
    pub fn punch_counts(&self) -> (u64, u64, u64, u64) {
        use std::sync::atomic::Ordering::Relaxed;
        let s = &self.direct.punch.stats;
        (
            s.tried.load(Relaxed),
            s.punched.load(Relaxed),
            s.failed.load(Relaxed),
            s.answered.load(Relaxed),
        )
    }

    /// Whether a punched connection to `daemon` waits for a dial on `lane`.
    pub fn punch_ready(&self, daemon: &str, lane: CircuitLane) -> bool {
        self.direct.punch.has_pending(daemon, lane)
    }

    /// The punch path's answer for a dial to `daemon` on `lane`, when it has one: its kept
    /// direct circuit is live, or a punched connection waits. Else a punch starts beside this
    /// dial (once at a time, not while the machine is held off) and the dial rides the relay.
    pub(crate) fn punch_path(&self, daemon: &str, lane: CircuitLane) -> Option<Path> {
        let punch = &self.direct.punch;
        punch.listen_port()?;
        if self.direct.kept.live_on(daemon, lane).is_some() || punch.has_pending(daemon, lane) {
            return Some(Path::Punched);
        }
        if punch.held_off(daemon) {
            return None;
        }
        let carrier = punch.carrier.read().unwrap_or_else(|e| e.into_inner()).upgrade()?;
        if !punch.claim(daemon, lane) {
            return None;
        }
        if !punch.may_start(daemon, lane, Instant::now()) {
            punch.release(daemon, lane);
            return None;
        }
        let daemon = daemon.to_owned();
        super::direct::scope().spawn_named("hub carrier punch", async move {
            let punched = carrier.punch(&daemon, lane).await;
            let punch = &carrier.direct.punch;
            use std::sync::atomic::Ordering::Relaxed;
            match punched {
                Ok((tcp, address)) => {
                    tracing::info!("hub carrier punch: {address} connected for {}", lane.name());
                    punch.stats.punched.fetch_add(1, Relaxed);
                    punch.connected_at(&daemon, lane, Instant::now());
                    punch
                        .pending
                        .lock()
                        .unwrap_or_else(|e| e.into_inner())
                        .insert((daemon.clone(), lane), (tcp, address, Instant::now()));
                }
                Err(miss) => {
                    tracing::info!("hub carrier punch: none ({miss}); the relay");
                    punch.stats.failed.fetch_add(1, Relaxed);
                    match miss {
                        PunchMiss::Untraded(_) => punch.pause(&daemon),
                        PunchMiss::Missed(_) => punch.miss(&daemon),
                    }
                }
            }
            punch.release(&daemon, lane);
        });
        None
    }

    /// The punched connection to `daemon` on `lane` with the Noise handshake done.
    pub(crate) async fn open_punched(
        &self,
        daemon: &str,
        lane: CircuitLane,
    ) -> Result<(cmux_remote::crypto::SecureLink, super::DialStages), String> {
        let (tcp, address) = self
            .direct
            .punch
            .take_pending(daemon, lane)
            .ok_or("punch: no punched connection waits")?;
        self.secure_direct(daemon, tcp, address, super::DialStages::default()).await
    }

    /// Trade candidates with `daemon` through the relay, then both open toward each other.
    async fn punch(
        &self,
        daemon: &str,
        lane: CircuitLane,
    ) -> Result<(TcpStream, SocketAddr), PunchMiss> {
        use PunchMiss::{Missed, Untraded};
        self.direct.punch.stats.tried.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let port = self.direct.punch.listen_port().ok_or(Untraded("no punch port".into()))?;
        let nonce = new_nonce();
        let ours = Offer { candidates: self.direct.punch.candidates(), claim: Some(nonce) };
        // Claimed before the offer goes out: the answerer may connect before its answer lands.
        let (claimed_tx, claimed_rx) = tokio::sync::oneshot::channel();
        let _claim = self.direct.punch.claim_nonce(nonce, Claim::Dial(claimed_tx));
        let mut report = DialReport::default();
        let hello = hello_record(CircuitService::DirectOffer);
        let stream = match self
            .kept_open(daemon, CircuitLane::Cheap, hello, &[], &mut report, Path::Relay)
            .await
        {
            KeptOpen::Stream(stream) => stream,
            KeptOpen::Refused(refusal) => return Err(Missed(format!("offer refused: {refusal}"))),
            KeptOpen::Failed(why) | KeptOpen::Lost(why) | KeptOpen::Plain(why) => {
                return Err(Untraded(format!("no offer stream: {why}")));
            }
        };
        let theirs = tokio::time::timeout(OFFER_BOUND, exchange(stream, &ours))
            .await
            .map_err(|_| Untraded(format!("no offer answer in {OFFER_BOUND:?}")))?
            .map_err(Untraded)?;
        let toward = usable_toward(&theirs.candidates);
        if toward.is_empty() {
            return Err(Missed("the machine offered no candidate".into()));
        }
        let claim = (theirs.claim == Some(nonce)).then_some(nonce);
        tracing::debug!(
            "hub carrier punch: {} for {}: ours {:?}, theirs {:?}, claimed {}",
            daemon,
            lane.name(),
            ours.candidates,
            toward,
            claim.is_some()
        );
        let missed = || {
            Missed(format!(
                "no candidate of {} connected in {PUNCH_WINDOW:?}; ours {:?}, theirs {:?}",
                toward.len(),
                ours.candidates,
                toward
            ))
        };
        if claim.is_none() {
            return open_toward(port, &toward, PUNCH_WINDOW, None).await.ok_or_else(missed);
        }
        // Whichever opens first: this side's connect, or the far side's reaching this
        // listener ([`Punches::claimed`]).
        let mut claimed_rx = claimed_rx;
        let opened = open_toward(port, &toward, PUNCH_WINDOW, claim);
        tokio::select! {
            found = opened => match found {
                Some(found) => Ok(found),
                // A preamble the listener read just as the window ended.
                None => tokio::time::timeout(ATTEMPT_BOUND, &mut claimed_rx)
                    .await
                    .ok()
                    .and_then(Result::ok)
                    .ok_or_else(missed),
            },
            Ok(found) = &mut claimed_rx => Ok(found),
        }
    }

    /// Serve one offer stream from `from`: read its candidates, answer ours, and open toward
    /// them; a connection that opens goes to [`super::Incoming`] as the responder. Boxed as
    /// `Send`: accepting the punched link reads it through the mux that served this offer, a
    /// cycle rustc cannot prove `Send` through an opaque `async fn`.
    pub(crate) fn serve_offer(
        self: Arc<Self>,
        io: tokio::io::DuplexStream,
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = ()> + Send>> {
        Box::pin(self.serve_offer_now(io))
    }

    async fn serve_offer_now(self: Arc<Self>, io: tokio::io::DuplexStream) {
        let Some(port) = self.direct.punch.listen_port() else { return };
        // At the cap the offer goes unanswered: the dialer's punch fails and holds it off.
        let Some(_slot) = self.direct.punch.answer_slot() else { return };
        let (read, mut write) = tokio::io::split(io);
        let mut read = tokio::io::BufReader::new(read);
        let theirs = match tokio::time::timeout(OFFER_BOUND, read_offer(&mut read)).await {
            Ok(Ok(theirs)) => theirs,
            _ => return,
        };
        // The dialer's nonce, echoed: both sides then open with the preamble.
        let claim = theirs.claim.filter(|&n| n != 0);
        let _claim = claim.map(|n| self.direct.punch.claim_nonce(n, Claim::Answer));
        let ours = Offer { candidates: self.direct.punch.candidates(), claim };
        if write_offer(&mut write, &ours).await.is_err() {
            return;
        }
        let _ = write.shutdown().await;
        self.direct.punch.stats.answered.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let toward = usable_toward(&theirs.candidates);
        let Some((tcp, from)) = open_toward(port, &toward, PUNCH_WINDOW, claim).await else {
            return;
        };
        tracing::info!("hub carrier punch: answered, {from} connected");
        let Some(incoming) = self.direct.incoming() else { return };
        let _ = tcp.set_nodelay(true);
        let (read, write) = tcp.into_split();
        let link = LengthDelimitedLink::new(
            format!("hub carrier punched from {from}"),
            MAX_FRAME_BYTES,
            read,
            write,
        );
        incoming.accept(Box::new(link), NetworkPeer::Tcp).await;
    }
}

async fn exchange(stream: HubStream, ours: &Offer) -> Result<Offer, String> {
    let (read, mut write) = tokio::io::split(stream);
    write_offer(&mut write, ours).await.map_err(|e| format!("offer: {e}"))?;
    let mut read = tokio::io::BufReader::new(read);
    read_offer(&mut read).await
}

async fn write_offer(
    write: &mut (impl tokio::io::AsyncWrite + Unpin),
    offer: &Offer,
) -> std::io::Result<()> {
    let mut line = serde_json::to_vec(offer).map_err(std::io::Error::other)?;
    line.push(b'\n');
    write.write_all(&line).await?;
    write.flush().await
}

async fn read_offer(read: &mut (impl tokio::io::AsyncBufRead + Unpin)) -> Result<Offer, String> {
    let mut line = Vec::new();
    let mut limited = tokio::io::AsyncReadExt::take(read, MAX_OFFER_BYTES as u64);
    limited.read_until(b'\n', &mut line).await.map_err(|e| format!("offer: {e}"))?;
    serde_json::from_slice(&line).map_err(|e| format!("offer: {e}"))
}

/// Open from local `port` toward each of `toward`, again every [`PUNCH_EVERY`] while one has
/// not connected, until `window` ends: the first connection, and where it went. With `claim`,
/// a connection counts once the far side answered its preamble ([`preamble_connected`]).
pub async fn open_toward(
    port: u16,
    toward: &[SocketAddr],
    window: Duration,
    claim: Option<u64>,
) -> Option<(TcpStream, SocketAddr)> {
    let deadline = tokio::time::Instant::now() + window;
    let mut tries = tokio::task::JoinSet::new();
    for address in toward.iter().copied() {
        tries.spawn(async move {
            loop {
                let now = tokio::time::Instant::now();
                if now >= deadline {
                    return None;
                }
                let started = now;
                let bound = ATTEMPT_BOUND.min(deadline - now);
                let attempt = async {
                    let mut tcp = connect_from(port, address).await.ok()?;
                    if let Some(nonce) = claim {
                        preamble_connected(&mut tcp, nonce).await.ok()?;
                    }
                    Some(tcp)
                };
                if let Ok(Some(tcp)) = tokio::time::timeout(bound, attempt).await {
                    return Some((tcp, address));
                }
                tokio::time::sleep_until((started + PUNCH_EVERY).min(deadline)).await;
            }
        });
    }
    while let Some(done) = tries.join_next().await {
        if let Ok(Some(found)) = done {
            tries.abort_all();
            return Some(found);
        }
    }
    None
}

/// A connecting side's preamble: send ours, then read the same back, from the far listener
/// that routed it or, in a simultaneous open, from the far side's own connect.
pub async fn preamble_connected(tcp: &mut TcpStream, nonce: u64) -> std::io::Result<()> {
    use tokio::io::AsyncReadExt;
    let ours = claim_preamble(nonce);
    tcp.write_all(&ours).await?;
    let mut theirs = [0u8; CLAIM_LEN];
    tcp.read_exact(&mut theirs).await?;
    if theirs == ours { Ok(()) } else { Err(std::io::Error::other("another punch's preamble")) }
}

/// A listener's read of an accepted connection's preamble: the nonce, with the preamble read
/// off, or None (nothing read) for a legacy connection, or when its first bytes do not come
/// within [`CLAIM_PEEK_BOUND`].
pub async fn preamble_accepted(tcp: &TcpStream) -> Option<u64> {
    let read = async {
        let mut buf = [0u8; CLAIM_LEN];
        loop {
            let n = tcp.peek(&mut buf).await.ok()?;
            if n == 0 || buf[..n.min(4)] != CLAIM_MAGIC[..n.min(4)] {
                return None;
            }
            if n >= CLAIM_LEN {
                return claim_nonce(&buf);
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    };
    let nonce = tokio::time::timeout(CLAIM_PEEK_BOUND, read).await.ok().flatten()?;
    let mut sink = [0u8; CLAIM_LEN];
    let mut got = 0;
    while got < CLAIM_LEN {
        tcp.readable().await.ok()?;
        match tcp.try_read(&mut sink[got..]) {
            Ok(0) => return None,
            Ok(n) => got += n,
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {}
            Err(_) => return None,
        }
    }
    Some(nonce)
}

/// A connect to `to` from local `port`, the port shared with this machine's listener.
async fn connect_from(port: u16, to: SocketAddr) -> std::io::Result<TcpStream> {
    let socket = match to {
        SocketAddr::V4(_) => tokio::net::TcpSocket::new_v4()?,
        SocketAddr::V6(_) => tokio::net::TcpSocket::new_v6()?,
    };
    socket.set_reuseaddr(true)?;
    #[cfg(unix)]
    socket.set_reuseport(true)?;
    let local: IpAddr = match to {
        SocketAddr::V4(_) => Ipv4Addr::UNSPECIFIED.into(),
        SocketAddr::V6(_) => Ipv6Addr::UNSPECIFIED.into(),
    };
    socket.bind(SocketAddr::new(local, port))?;
    socket.connect(to).await
}

/// A listener on `port` (0: one of its own) that punches can share: SO_REUSEADDR and
/// SO_REUSEPORT, IPv6 with IPv4 too, else IPv4 only.
pub fn punch_listener(port: u16) -> std::io::Result<tokio::net::TcpListener> {
    let listen = |local: SocketAddr| -> std::io::Result<tokio::net::TcpListener> {
        let socket = match local {
            SocketAddr::V4(_) => tokio::net::TcpSocket::new_v4()?,
            SocketAddr::V6(_) => tokio::net::TcpSocket::new_v6()?,
        };
        socket.set_reuseaddr(true)?;
        #[cfg(unix)]
        socket.set_reuseport(true)?;
        socket.bind(local)?;
        socket.listen(256)
    };
    // A port of its own on IPv6 first: then IPv4 binds the same one.
    listen(SocketAddr::new(Ipv6Addr::UNSPECIFIED.into(), port))
        .or_else(|_| listen(SocketAddr::new(Ipv4Addr::UNSPECIFIED.into(), port)))
}

#[cfg(test)]
#[path = "hub_carrier_punch_tests.rs"]
mod tests;
