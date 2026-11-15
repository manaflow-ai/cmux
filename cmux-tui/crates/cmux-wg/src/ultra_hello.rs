//! Ultra mode agreed inside the tunnel.
//!
//! Each side tells the other the ultra mode it was started with in a small
//! overlay UDP packet to [`HELLO_PORT`]. WireGuard encrypts and authenticates
//! it like any packet, so only the genuine peer can set what this side sends,
//! unlike a mode read from parity, whose header is not authenticated. Both
//! sides then send in [`UltraMode::agree`] of the two modes, the stronger one,
//! so turning the mode on at one end (the iPhone's setting, a desktop's)
//! protects both directions. A side that learns it will receive repair data
//! starts keeping datagrams before the peer's first parity, so the first group
//! after the hello is rebuilt too.
//!
//! The port is the session's control port, which path probes already own:
//! no application can bind it (`bind_datagram` refuses it on every build that
//! has probes), and a probe has its own magic and length. A build without the
//! hello therefore drops a hello, never hands it to a service. The port the
//! first hellos used, 4103, is remote desktop's.
//!
//! Each side picks a random instance number when its tunnel starts, and a
//! random challenge, new at start and whenever the peer's instance changes.
//! Every hello carries both, and echoes the peer's challenge: an
//! acknowledgement counts only when it echoes this side's current challenge.
//! A hello the peer queued for an earlier instance of this side, or a late
//! one from an instance of the peer that has since restarted, echoes an old
//! challenge, so it acknowledges nothing, however many of them arrive late.
//! A hello with a new instance number is a restarted peer: this side starts
//! the exchange over with it. A late hello from an earlier instance looks
//! like one too, so this side starts over with that instance; its retries
//! then reach the live instance, which answers, and this side starts over
//! with that one.
//!
//! A version-1 peer (no instance numbers or challenges) is read, and its
//! `heard` flag counts as an acknowledgement, as it did, except on the hello
//! that moves this side to it. A version-2 side always sends version 2.
//! While it does not know its peer, or knows it as version 1, each hello also
//! goes out as a version-1 copy from another source port: a version-1 build
//! takes the copy (so one that went quiet before this side restarted
//! answers it), and a version-2 build drops it. A version-1 hello from the
//! control port therefore always comes from a version-1 build, and two
//! version-2 sides never fall back to version 1 with each other.
//!
//! A hello goes out as soon as a session exists, ahead of that pass's data,
//! and again at 0.25, 0.5, 1 and 2 s until the peer acknowledges it. Each
//! hello also says whether its sender has been acknowledged. A hello is
//! answered at once when it does not acknowledge this side, when its sender
//! is still waiting for this side's acknowledgement (the one this side sent
//! was lost), or when this side has not yet acknowledged the peer's, so a
//! clean exchange is three hellos, and any four hellos of a restart can be
//! lost. A build without the hello never answers: after [`TRIES`] hellos this
//! side stops and keeps its own mode.

use std::net::{IpAddr, SocketAddr};
use std::time::Duration;

use tokio::time::Instant;

use crate::udp;
use crate::ultra::UltraMode;

/// The overlay UDP port of hello packets: the session's control port, shared
/// with path probes (different magic and length).
pub(crate) const HELLO_PORT: u16 = cmux_transport::probe::PROBE_PORT;
/// The source port of the version-1 copy a hello goes out with while the
/// peer is unknown or version 1. A version-1 build reads only the destination port, so
/// it takes the copy as a hello; a version-2 build drops a version-1 hello
/// from any port but [`HELLO_PORT`], since the version-2 one carries the
/// same mode.
const DISCOVERY_PORT: u16 = HELLO_PORT + 2;
const MAGIC: [u8; 4] = *b"CMXU";
/// 2: instance numbers and challenges.
const VERSION: u8 = 2;
const LEN: usize = 33;
/// Version 1, without instance numbers (9 bytes): what builds with only the
/// control port send. Read, and answered in kind, so a mixed pair still
/// agrees.
const VERSION_1: u8 = 1;
const LEN_1: usize = 9;
/// The `heard` flag: the sender has the receiver's hello, whose challenge it
/// echoes.
const HEARD: u8 = 1;
/// The `acknowledged` flag: the receiver acknowledged the sender's hello.
const ACKNOWLEDGED: u8 = 2;
/// The `metered` flag: the sender's network is metered (cellular), so repair
/// sent to it stays within `ultra_auto::METERED_OVERHEAD` times the data.
/// Builds before it ignore the bit.
const METERED: u8 = 4;
/// Hellos sent before an unanswered side gives up.
const TRIES: usize = 5;
/// The wait after each hello, before the next.
const BACKOFF: [Duration; TRIES - 1] = [
    Duration::from_millis(250),
    Duration::from_millis(500),
    Duration::from_secs(1),
    Duration::from_secs(2),
];

/// One hello: the sender's own mode, instance and challenge, the receiver's
/// challenge if the sender has the receiver's hello, and whether the
/// receiver acknowledged the sender's.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Hello {
    pub(crate) mode: UltraMode,
    pub(crate) instance: u64,
    pub(crate) challenge: u64,
    pub(crate) echo: Option<u64>,
    pub(crate) acknowledged: bool,
    /// The sender's network is metered: keep repair sent to it capped.
    pub(crate) metered: bool,
    /// Version 1 on the wire: no instance numbers or challenges, and `echo`
    /// (any value) stands for the version-1 `heard` flag.
    pub(crate) legacy: bool,
}

impl Hello {
    fn encode(self) -> Vec<u8> {
        let (kind, a, b) = self.mode.wire();
        if self.legacy {
            let flags = if self.echo.is_some() { HEARD } else { 0 };
            let mut bytes = MAGIC.to_vec();
            bytes.extend_from_slice(&[VERSION_1, flags, kind, a, b]);
            return bytes;
        }
        let mut bytes = [0u8; LEN];
        bytes[..4].copy_from_slice(&MAGIC);
        bytes[4] = VERSION;
        bytes[5] = if self.echo.is_some() { HEARD } else { 0 }
            | if self.acknowledged { ACKNOWLEDGED } else { 0 }
            | if self.metered { METERED } else { 0 };
        bytes[6] = kind;
        bytes[7] = a;
        bytes[8] = b;
        bytes[9..17].copy_from_slice(&self.instance.to_be_bytes());
        bytes[17..25].copy_from_slice(&self.challenge.to_be_bytes());
        bytes[25..33].copy_from_slice(&self.echo.unwrap_or(0).to_be_bytes());
        bytes.to_vec()
    }

    fn decode(payload: &[u8]) -> Option<Self> {
        if let Ok(&[m0, m1, m2, m3, VERSION_1, flags, kind, a, b]) =
            <&[u8; LEN_1]>::try_from(payload)
            && [m0, m1, m2, m3] == MAGIC
        {
            return Some(Self {
                mode: UltraMode::from_wire(kind, a, b),
                instance: 0,
                challenge: 0,
                echo: (flags & HEARD != 0).then_some(0),
                // Version 1 has no such flag; its own rule (answer until
                // told) applies.
                acknowledged: true,
                metered: false,
                legacy: true,
            });
        }
        let bytes: &[u8; LEN] = payload.try_into().ok()?;
        if bytes[..4] != MAGIC || bytes[4] != VERSION {
            return None;
        }
        let number = |range: std::ops::Range<usize>| {
            bytes.get(range).and_then(|slice| slice.try_into().ok()).map(u64::from_be_bytes)
        };
        let instance = number(9..17)?;
        let challenge = number(17..25)?;
        let echo = (bytes[5] & HEARD != 0).then(|| number(25..33)).flatten();
        let acknowledged = bytes[5] & ACKNOWLEDGED != 0;
        let metered = bytes[5] & METERED != 0;
        let mode = UltraMode::from_wire(bytes[6], bytes[7], bytes[8]);
        Some(Self { mode, instance, challenge, echo, acknowledged, metered, legacy: false })
    }
}

/// The overlay packet carrying `hello` from `source` to `destination`.
pub(crate) fn packet(source: IpAddr, destination: IpAddr, hello: Hello) -> Vec<u8> {
    let from = SocketAddr::new(source, HELLO_PORT);
    let to = SocketAddr::new(destination, HELLO_PORT);
    udp::packet(from, to, &hello.encode())
}

/// The version-1 copy of `hello`, sent beside it while the peer is unknown
/// or version 1 (see [`Negotiation::discovering`]).
pub(crate) fn discovery_packet(source: IpAddr, destination: IpAddr, hello: Hello) -> Vec<u8> {
    let from = SocketAddr::new(source, DISCOVERY_PORT);
    let to = SocketAddr::new(destination, HELLO_PORT);
    udp::packet(from, to, &Hello { legacy: true, ..hello }.encode())
}

/// The hello in a decrypted packet, or `None` for every other packet,
/// including a version-2 peer's version-1 copy.
pub(crate) fn decode(packet: &[u8]) -> Option<Hello> {
    let (source, destination, payload) = udp::parse(packet)?;
    if destination.port() != HELLO_PORT {
        return None;
    }
    Hello::decode(payload).filter(|hello| !hello.legacy || source.port() == HELLO_PORT)
}

/// A random number: an instance number for a tunnel that is starting, or a
/// challenge.
fn fresh_number() -> u64 {
    let mut bytes = [0u8; 8];
    // Without operating system randomness the clock still tells two apart.
    if getrandom::fill(&mut bytes).is_err() {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |elapsed| elapsed.as_nanos());
        bytes = (nanos as u64).to_be_bytes();
    }
    u64::from_be_bytes(bytes)
}

/// The peer, as its latest hello described it.
#[derive(Debug, Clone, Copy)]
struct Peer {
    mode: UltraMode,
    instance: u64,
    challenge: u64,
    metered: bool,
}

/// One tunnel's side of the agreement.
#[derive(Debug)]
pub(crate) struct Negotiation {
    /// The mode this side asks for: the one it was started with, or what
    /// Auto wants now ([`Negotiation::advertise`]).
    configured: UltraMode,
    /// This side's network is metered (Auto on cellular).
    metered: bool,
    /// This side's instance number.
    instance: u64,
    /// The challenge the peer must echo to acknowledge this side: new when
    /// the peer's instance changes.
    challenge: u64,
    /// The peer, once its hello arrived.
    peer: Option<Peer>,
    /// The peer speaks version 1: hellos to it also go out as version-1
    /// copies, and its `heard` flag acknowledges this side.
    peer_legacy: bool,
    /// The peer sent a version-2 hello in this tunnel: a version-1 hello
    /// since is a late one from before it upgraded (or a downgrade), and
    /// never acknowledges this side.
    seen_version_2: bool,
    /// The peer's hello echoed this side's current challenge.
    acknowledged: bool,
    /// Hellos sent without an acknowledgement.
    sent: usize,
    /// When the next unacknowledged hello is due; `None` before the first.
    next: Option<Instant>,
    /// This side sent a hello echoing the peer's current challenge.
    told: bool,
    /// A hello arrived that did not acknowledge this side, whose sender is
    /// still waiting for an acknowledgement, or before this side echoed the
    /// peer's challenge: answer it.
    answer: bool,
    /// Off only to stand in for a build without the hello (tests): it sends
    /// none, and a hello reaching it is an ordinary packet.
    enabled: bool,
}

impl Negotiation {
    pub(crate) fn new(configured: UltraMode) -> Self {
        Self::with_numbers(configured, fresh_number(), fresh_number())
    }

    fn with_numbers(configured: UltraMode, instance: u64, challenge: u64) -> Self {
        Self {
            configured,
            metered: false,
            instance,
            challenge,
            peer: None,
            peer_legacy: false,
            seen_version_2: false,
            acknowledged: false,
            sent: 0,
            next: None,
            told: false,
            answer: false,
            enabled: true,
        }
    }

    /// A side that behaves as a build without the hello did: it keeps
    /// `configured`, sends no hello and does not intercept one.
    pub(crate) fn without_hello(configured: UltraMode) -> Self {
        Self { enabled: false, ..Self::new(configured) }
    }

    /// Whether this side takes hellos out of the packets it receives.
    pub(crate) fn intercepts(&self) -> bool {
        self.enabled
    }

    /// The mode both sides send in: the agreement, or this side's own until
    /// the peer's hello arrives.
    pub(crate) fn mode(&self) -> UltraMode {
        match self.peer {
            Some(peer) => UltraMode::agree(self.configured, peer.mode),
            None => self.configured,
        }
    }

    /// Whether the hello due now also goes out as a version-1 copy (see
    /// [`discovery_packet`]): while this side has no hello from its peer,
    /// which may be a version-1 build that went quiet before this side
    /// started, and while the peer is a version-1 build.
    pub(crate) fn discovering(&self) -> bool {
        self.peer.is_none() || self.peer_legacy
    }

    /// Take the peer's hello. Returns the mode to send in now.
    pub(crate) fn receive(&mut self, hello: Hello) -> UltraMode {
        let previous = self.peer;
        let restarted = previous.is_some_and(|peer| peer.instance != hello.instance);
        if restarted {
            // A new instance of the peer knows nothing of this side (or the
            // hello is a late one from an earlier instance, whose retries
            // the live instance answers): start over with a new challenge,
            // so this side's hellos go out again until that instance echoes
            // it, whatever the one before had heard.
            self.challenge = fresh_number();
            self.acknowledged = false;
            self.sent = 0;
            self.next = None;
            self.told = false;
        }
        if previous.is_none_or(|peer| peer.challenge != hello.challenge) {
            // The peer's challenge is new to this side: echo it.
            self.told = false;
        }
        self.peer = Some(Peer {
            mode: hello.mode,
            instance: hello.instance,
            challenge: hello.challenge,
            metered: hello.metered,
        });
        self.peer_legacy = hello.legacy;
        self.seen_version_2 |= !hello.legacy;
        // A version-1 `heard` flag cannot say which instance of this side it
        // heard. So the version-1 hello that moves this side to a version-1
        // peer does not acknowledge it, and once the peer has sent version 2
        // no version-1 hello does (late ones from before it upgraded can
        // arrive several at a time): this side keeps sending until a
        // version-1 build answers its copy, or the live version-2 peer
        // answers its hello. A peer that downgrades within one tunnel still
        // gets this side's mode from the copies, and this side takes its
        // mode; this side just stops after its tries.
        let acknowledges = if hello.legacy {
            !restarted && !self.seen_version_2 && hello.echo.is_some()
        } else {
            hello.echo == Some(self.challenge)
        };
        if acknowledges {
            self.acknowledged = true;
            self.next = None;
        } else {
            // It has not heard this side's current challenge.
            self.told = false;
        }
        self.answer |= !self.told || !hello.acknowledged;
        self.mode()
    }

    /// The hello to send now, if one is due; the caller sends it (once a
    /// session exists) and reports it with [`Negotiation::sent`].
    pub(crate) fn due(&self, now: Instant) -> Option<Hello> {
        let retry = !self.acknowledged && self.sent < TRIES && self.next.is_none_or(|at| now >= at);
        (self.enabled && (self.answer || retry)).then_some(Hello {
            mode: self.configured,
            instance: self.instance,
            challenge: self.challenge,
            echo: self.peer.map(|peer| peer.challenge),
            acknowledged: self.acknowledged,
            metered: self.metered,
            legacy: false,
        })
    }

    /// Ask for `mode` from now on (Auto turned repair data on or off), on a
    /// network that is `metered` or not. A change goes out in a hello at
    /// once, with a new challenge, so it is retried until the peer echoes
    /// it; the peer then sends in the agreement of the two again.
    pub(crate) fn advertise(&mut self, mode: UltraMode, metered: bool) {
        if (mode, metered) == (self.configured, self.metered) {
            return;
        }
        self.configured = mode;
        self.metered = metered;
        self.challenge = fresh_number();
        self.acknowledged = false;
        self.sent = 0;
        self.next = None;
        self.answer = true;
    }

    /// Whether repair sent now stays within the metered cap: this side's
    /// network is metered, or the peer's is.
    pub(crate) fn metered(&self) -> bool {
        self.metered || self.peer.is_some_and(|peer| peer.metered)
    }

    pub(crate) fn sent(&mut self, now: Instant) {
        self.answer = false;
        self.told |= self.peer.is_some();
        if self.acknowledged || self.sent >= TRIES {
            return;
        }
        self.next = BACKOFF.get(self.sent).map(|wait| now + *wait);
        self.sent += 1;
    }

    /// When the driver must wake for the next hello.
    pub(crate) fn deadline(&self) -> Option<Instant> {
        if !self.enabled || self.acknowledged || self.sent >= TRIES { None } else { self.next }
    }
}

#[cfg(test)]
#[path = "ultra_hello_tests.rs"]
mod tests;
