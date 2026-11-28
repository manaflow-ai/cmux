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

/// The candidates of a machine listening on `port` with these interface addresses and the
/// router's `mapped` address: the mapping first (reachable from anywhere), then IPv6 (no NAT
/// between two IPv6 hosts), then LAN IPv4. Deduplicated, at most [`MAX_CANDIDATES`].
pub fn local_candidates(
    port: u16,
    addresses: impl IntoIterator<Item = IpAddr>,
    mapped: Option<SocketAddr>,
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
        local_candidates(port, addresses, mapped)
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
                Err(why) => {
                    tracing::info!("hub carrier punch: none ({why}); the relay");
                    punch.stats.failed.fetch_add(1, Relaxed);
                    punch.miss(&daemon);
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
    ) -> Result<(TcpStream, SocketAddr), String> {
        self.direct.punch.stats.tried.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let port = self.direct.punch.listen_port().ok_or("no punch port")?;
        let ours = Offer { candidates: self.direct.punch.candidates() };
        let mut report = DialReport::default();
        let hello = hello_record(CircuitService::DirectOffer);
        let stream = match self
            .kept_open(daemon, CircuitLane::Cheap, hello, &[], &mut report, Path::Relay)
            .await
        {
            KeptOpen::Stream(stream) => stream,
            KeptOpen::Refused(refusal) => return Err(format!("offer refused: {refusal}")),
            KeptOpen::Failed(why) | KeptOpen::Lost(why) | KeptOpen::Plain(why) => {
                return Err(format!("no offer stream: {why}"));
            }
        };
        let theirs = tokio::time::timeout(OFFER_BOUND, exchange(stream, &ours))
            .await
            .map_err(|_| format!("no offer answer in {OFFER_BOUND:?}"))??;
        let toward = usable_toward(&theirs.candidates);
        if toward.is_empty() {
            return Err("the machine offered no candidate".into());
        }
        tracing::debug!(
            "hub carrier punch: {} for {}: ours {:?}, theirs {:?}",
            daemon,
            lane.name(),
            ours.candidates,
            toward
        );
        open_toward(port, &toward, PUNCH_WINDOW).await.ok_or_else(|| {
            format!("no candidate of {} connected in {PUNCH_WINDOW:?}", toward.len())
        })
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
        let ours = Offer { candidates: self.direct.punch.candidates() };
        let (read, mut write) = tokio::io::split(io);
        let mut read = tokio::io::BufReader::new(read);
        let theirs = match tokio::time::timeout(OFFER_BOUND, read_offer(&mut read)).await {
            Ok(Ok(theirs)) => theirs,
            _ => return,
        };
        if write_offer(&mut write, &ours).await.is_err() {
            return;
        }
        let _ = write.shutdown().await;
        self.direct.punch.stats.answered.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let toward = usable_toward(&theirs.candidates);
        let Some((tcp, from)) = open_toward(port, &toward, PUNCH_WINDOW).await else { return };
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
/// not connected, until `window` ends: the first connection, and where it went.
pub async fn open_toward(
    port: u16,
    toward: &[SocketAddr],
    window: Duration,
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
                if let Ok(Ok(tcp)) = tokio::time::timeout(bound, connect_from(port, address)).await
                {
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
