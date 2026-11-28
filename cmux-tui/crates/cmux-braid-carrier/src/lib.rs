//! Braid's carriers (RFD 0164, slice B7).
//!
//! A carrier moves a link's bytes and knows nothing about the link's classes or keys: plain UDP,
//! TURN over UDP, TCP or TLS, cmux's WebSocket relay, the local signaling hub beside the Mac.
//! Every dial used to hand-wire its own rungs (which server first, which one waits for which, what
//! a blocked network rules out). This crate holds the one answer every dial shares:
//!
//! - [`CarrierKind`]: what a carrier is, and what follows from that (stream or datagram, its MTU,
//!   what it costs, its `link_stat` path name, whether it needs UDP or the internet).
//! - [`Endpoint`]: one place a carrier can open to.
//! - [`NetFacts`] and [`usable`]: what the network rules out (UDP blocked, a proxy as the only way
//!   out, no internet at all).
//! - [`rank`] and [`ladder`]: the order a dial tries what is left, and when each rung starts.
//! - [`Carrier`]: the trait a dial opens a rung through.
//!
//! The crate has no dependencies, so the phone's workspace (`cmux-next-ios/rust`) and cmux-tui
//! both build it as a path dependency.

use std::future::Future;
use std::io;
use std::pin::Pin;
use std::time::Duration;

/// What moves a link's bytes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum CarrierKind {
    /// The local signaling hub on the Mac beside the phone (#53725): no internet needed.
    LocalHub,
    /// Plain UDP between the peers (host, server-reflexive or hole-punched).
    Udp,
    /// Through a TURN server, UDP on this side's leg.
    TurnUdp,
    /// Through a TURN server over TLS (RFC 5766 over TLS; 443 gets through most firewalls).
    TurnTls,
    /// Through a TURN server over plain TCP.
    TurnTcp,
    /// cmux's WebSocket relay over HTTPS, through the system proxy when there is one (#53163,
    /// #53570): the last resort.
    WssRelay,
}

/// What a carrier costs us per byte, cheapest first.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum CostClass {
    /// Peer to peer or on the LAN: nobody's bandwidth but the peers'.
    Free,
    /// A relay whose bandwidth we pay for.
    Relay,
}

impl CarrierKind {
    /// A byte stream (TCP, TLS, WebSocket): datagrams on it are framed with a length prefix, and
    /// a lost segment holds back everything after it.
    pub fn reliable(self) -> bool {
        matches!(self, Self::LocalHub | Self::TurnTls | Self::TurnTcp | Self::WssRelay)
    }

    /// Whether the carrier sends UDP from this side.
    pub fn needs_udp(self) -> bool {
        matches!(self, Self::Udp | Self::TurnUdp)
    }

    /// Whether the carrier reaches a server on the internet. Plain UDP does not need it (a LAN
    /// peer), nor does the local hub.
    pub fn needs_internet(self) -> bool {
        !matches!(self, Self::LocalHub | Self::Udp)
    }

    /// Whether the carrier can go out through an HTTP CONNECT proxy (a TCP leg).
    pub fn proxyable(self) -> bool {
        matches!(self, Self::TurnTls | Self::TurnTcp | Self::WssRelay)
    }

    pub fn cost(self) -> CostClass {
        match self {
            Self::LocalHub | Self::Udp => CostClass::Free,
            Self::TurnUdp | Self::TurnTls | Self::TurnTcp | Self::WssRelay => CostClass::Relay,
        }
    }

    /// The largest datagram the carrier takes in one piece. UDP keeps under the IPv6 minimum MTU
    /// (1280) less IP and UDP headers, and TURN's ChannelData header comes off that; a stream frames
    /// datagrams with a 16-bit length.
    pub fn mtu(self) -> usize {
        match self {
            Self::Udp => 1232,
            Self::TurnUdp => 1228,
            Self::LocalHub | Self::TurnTls | Self::TurnTcp | Self::WssRelay => 65_535,
        }
    }

    /// The path's `link_stat` name: `direct`, `turn`, `turn-tls`, `relay` or `local`. A TURN
    /// server reached over plain TCP reports `turn-tls` too (a stream leg; the phone's `LinkPath`).
    pub fn path_name(self) -> &'static str {
        match self {
            Self::LocalHub => "local",
            Self::Udp => "direct",
            Self::TurnUdp => "turn",
            Self::TurnTls | Self::TurnTcp => "turn-tls",
            Self::WssRelay => "relay",
        }
    }

    /// The rung the kind sits on: a ladder starts every rung's carriers together and the next
    /// rung a stagger later.
    pub fn rung(self) -> Rung {
        match self {
            Self::LocalHub | Self::Udp => Rung::Direct,
            Self::TurnUdp => Rung::Datagram,
            Self::TurnTls | Self::TurnTcp => Rung::Stream,
            Self::WssRelay => Rung::LastResort,
        }
    }
}

/// The steps of a dial's ladder, in order.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Rung {
    /// No server between the peers.
    Direct,
    /// A relay over UDP.
    Datagram,
    /// A relay over a stream (TLS on 443 first): a network that drops UDP.
    Stream,
    /// The WebSocket relay: a network whose only way out is HTTPS.
    LastResort,
}

/// A user name and secret a carrier signs in to its server with (TURN's long-term credential).
#[derive(Clone, PartialEq, Eq)]
pub struct Login {
    pub user: String,
    pub secret: String,
}

impl std::fmt::Debug for Login {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Login").field("user", &self.user).finish_non_exhaustive()
    }
}

/// One place a carrier can open to.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Endpoint {
    pub kind: CarrierKind,
    /// `host:port` (`[v6]:port`) to connect to.
    pub address: String,
    /// The host name, for TLS server name verification.
    pub host: String,
    pub login: Option<Login>,
}

impl Endpoint {
    /// The port of [`Self::address`], when it names one.
    pub fn port(&self) -> Option<u16> {
        self.address.rsplit_once(':').and_then(|(_, port)| port.parse().ok())
    }

    /// TLS on 443 looks like any HTTPS connection to a firewall.
    pub fn on_443(&self) -> bool {
        self.port() == Some(443)
    }
}

/// What the dial knows about this side's network.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct NetFacts {
    /// UDP gets nowhere (a setting, or STUN asked and nothing came back).
    pub udp_blocked: bool,
    /// The only way out is an HTTP CONNECT proxy, which most allow to 443 alone.
    pub proxy_only: bool,
    /// The internet is reachable at all.
    pub internet: bool,
    /// Relay only: skip every direct path (the debug "simulate distant network" mode).
    pub relay_only: bool,
}

impl Default for NetFacts {
    fn default() -> Self {
        Self { udp_blocked: false, proxy_only: false, internet: true, relay_only: false }
    }
}

/// Whether `endpoint` can work on a network with `facts`.
pub fn usable(endpoint: &Endpoint, facts: NetFacts) -> bool {
    let kind = endpoint.kind;
    if facts.relay_only && kind.cost() == CostClass::Free {
        return false;
    }
    if !facts.internet && kind.needs_internet() {
        return false;
    }
    if facts.udp_blocked && kind.needs_udp() {
        return false;
    }
    if facts.proxy_only && kind.needs_internet() && !(kind.proxyable() && endpoint.on_443()) {
        return false;
    }
    true
}

/// Where `endpoint` goes in a dial's order, lower first: by rung, then within a rung TLS on 443
/// before other TLS before plain TCP (a firewall passes 443 most often, and TLS hides what the
/// stream carries).
pub fn rank(endpoint: &Endpoint) -> (Rung, u8) {
    let within = match endpoint.kind {
        CarrierKind::TurnTls if endpoint.on_443() => 0,
        CarrierKind::TurnTls => 1,
        CarrierKind::TurnTcp => 2,
        _ => 0,
    };
    (endpoint.kind.rung(), within)
}

/// The best endpoint of `kinds` in `candidates` that `facts` leave usable; the first listed wins
/// a tie, so the service's own order breaks it.
pub fn best<'a>(
    candidates: &'a [Endpoint],
    kinds: &[CarrierKind],
    facts: NetFacts,
) -> Option<&'a Endpoint> {
    candidates
        .iter()
        .filter(|endpoint| kinds.contains(&endpoint.kind) && usable(endpoint, facts))
        .min_by_key(|endpoint| rank(endpoint))
}

/// One step of a dial: open `endpoint` once `start_after` has passed since the dial began.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Step {
    pub endpoint: Endpoint,
    pub start_after: Duration,
}

/// The order a dial opens `candidates` in, and when: unusable ones dropped, the rest ranked
/// ([`rank`]), and each rung starting `stagger` after the one before. A rung with nothing usable
/// costs no time, so on a network that drops UDP the stream rung starts at once.
pub fn ladder(candidates: &[Endpoint], facts: NetFacts, stagger: Duration) -> Vec<Step> {
    let mut usable: Vec<&Endpoint> =
        candidates.iter().filter(|endpoint| usable(endpoint, facts)).collect();
    usable.sort_by_key(|endpoint| rank(endpoint));
    let mut steps = Vec::with_capacity(usable.len());
    let mut start_after = Duration::ZERO;
    let mut previous: Option<Rung> = None;
    for endpoint in usable {
        let rung = endpoint.kind.rung();
        if previous.is_some_and(|previous| previous != rung) {
            start_after += stagger;
        }
        previous = Some(rung);
        steps.push(Step { endpoint: endpoint.clone(), start_after });
    }
    steps
}

/// A future a carrier opens with.
pub type OpenFuture<'a, L> = Pin<Box<dyn Future<Output = io::Result<L>> + Send + 'a>>;

/// Something a dial opens a link's bytes through.
pub trait Carrier: Send + Sync {
    /// What an open gives: a TURN allocation, a relay join, a socket.
    type Link: Send + 'static;

    fn kind(&self) -> CarrierKind;

    fn reliable(&self) -> bool {
        self.kind().reliable()
    }

    fn mtu(&self) -> usize {
        self.kind().mtu()
    }

    fn cost(&self) -> CostClass {
        self.kind().cost()
    }

    /// Open to `endpoint`, whose kind is [`Self::kind`]. A caller that gives up drops the
    /// future; a carrier whose open must still release what it set up does that itself.
    fn open<'a>(&'a self, endpoint: &'a Endpoint) -> OpenFuture<'a, Self::Link>;
}

#[cfg(test)]
#[path = "tests.rs"]
mod tests;
