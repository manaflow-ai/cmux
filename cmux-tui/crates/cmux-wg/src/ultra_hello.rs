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
            | if self.acknowledged { ACKNOWLEDGED } else { 0 };
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
        let mode = UltraMode::from_wire(bytes[6], bytes[7], bytes[8]);
        Some(Self { mode, instance, challenge, echo, acknowledged, legacy: false })
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
}

/// One tunnel's side of the agreement.
#[derive(Debug)]
pub(crate) struct Negotiation {
    /// The mode this side was started with.
    configured: UltraMode,
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
        self.peer =
            Some(Peer { mode: hello.mode, instance: hello.instance, challenge: hello.challenge });
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
            legacy: false,
        })
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
mod tests {
    use std::net::Ipv4Addr;

    use cmux_transport::Probe;
    use cmux_transport::probe::PROBE_LEN;

    use super::*;

    const FEC: UltraMode = UltraMode::Fec { group: 8, parity: 2 };
    const RS: UltraMode = UltraMode::Rs { group: 4, parity: 4 };

    fn addresses() -> (IpAddr, IpAddr) {
        (IpAddr::V4(Ipv4Addr::new(10, 0, 0, 1)), IpAddr::V4(Ipv4Addr::new(10, 0, 0, 2)))
    }

    fn hello(mode: UltraMode, instance: u64, challenge: u64, echo: Option<u64>) -> Hello {
        Hello { mode, instance, challenge, echo, acknowledged: false, legacy: false }
    }

    #[test]
    fn a_hello_round_trips_through_its_packet() {
        let (a, b) = addresses();
        for mode in [UltraMode::Off, UltraMode::Duplicate { copies: 3 }, FEC, RS] {
            for echo in [None, Some(0), Some(u64::MAX)] {
                for acknowledged in [false, true] {
                    let hello = Hello {
                        acknowledged,
                        ..hello(mode, 0x0123_4567_89ab_cdef, 0xfedc_ba98_7654_3210, echo)
                    };
                    assert_eq!(decode(&packet(a, b, hello)), Some(hello));
                }
            }
        }
        let probe = udp::packet(SocketAddr::new(a, 4102), SocketAddr::new(b, 4102), &[0; 15]);
        assert_eq!(decode(&probe), None, "a probe is not a hello");
        let mut wrong = hello(FEC, 1, 2, None).encode();
        wrong[0] ^= 1;
        assert_eq!(Hello::decode(&wrong), None, "the magic is checked");
    }

    /// The hello rides the probe port, which no build lets a service bind,
    /// and a build that knows only probes refuses it as one; the 9-byte
    /// version-1 hello on remote desktop's port 4103 is application data.
    #[test]
    fn a_hello_is_never_application_data() {
        let (a, b) = addresses();
        let hello = Hello { acknowledged: true, ..hello(RS, 7, 8, Some(9)) };
        let bytes = packet(a, b, hello);
        let (_, destination, payload) = udp::parse(&bytes).unwrap();
        assert_eq!(destination.port(), cmux_transport::probe::PROBE_PORT);
        assert_ne!(payload.len(), PROBE_LEN);
        assert!(Probe::decode(payload).is_err(), "an older build's probe parser drops it");
        let old = [b'C', b'M', b'X', b'U', 1, 0, 3, 4, 4];
        let media = udp::packet(SocketAddr::new(a, 4103), SocketAddr::new(b, 4103), &old);
        assert_eq!(decode(&media), None, "remote desktop's payload is its own");
    }

    #[test]
    fn an_unknown_kind_reads_as_off() {
        let mut bytes = Hello { acknowledged: true, ..hello(FEC, 3, 5, Some(4)) }.encode();
        bytes[6] = 0xEE;
        let expected = Hello { acknowledged: true, ..hello(UltraMode::Off, 3, 5, Some(4)) };
        assert_eq!(Hello::decode(&bytes), Some(expected));
    }

    #[test]
    fn both_sides_agree_on_the_stronger_mode() {
        let modes = [UltraMode::Off, UltraMode::Duplicate { copies: 2 }, FEC, RS];
        for a in modes {
            for b in modes {
                assert_eq!(UltraMode::agree(a, b), UltraMode::agree(b, a), "{a:?} {b:?}");
            }
            assert_eq!(UltraMode::agree(a, UltraMode::Off), a, "off defers to {a:?}");
        }
        assert_eq!(UltraMode::agree(FEC, RS), RS);
        // Same bytes (2x): Reed-Solomon rebuilds more than copies do.
        assert_eq!(UltraMode::agree(UltraMode::Duplicate { copies: 2 }, RS), RS);
    }

    #[test]
    fn a_peer_cannot_ask_for_more_than_four_times_the_datagrams() {
        let costly = UltraMode::Rs { group: 1, parity: 15 };
        assert_eq!(UltraMode::agree(FEC, costly), FEC, "16x is refused");
        assert_eq!(UltraMode::agree(costly, FEC), costly, "this side's own mode stays");
        let dup4 = UltraMode::Duplicate { copies: 4 };
        assert_eq!(UltraMode::agree(UltraMode::Off, dup4), dup4, "4x is allowed");
    }

    /// Unanswered hellos stop after `TRIES`, on the backoff; the driver's
    /// wake deadline goes away with them.
    #[test]
    fn an_unanswered_side_gives_up() {
        let mut side = Negotiation::new(RS);
        let mut now = Instant::now();
        let mut sent = 0;
        for _ in 0..100 {
            if side.due(now).is_some() {
                side.sent(now);
                sent += 1;
            }
            now += Duration::from_millis(100);
        }
        assert_eq!(sent, TRIES);
        assert_eq!(side.deadline(), None);
        assert_eq!(side.mode(), RS, "its own mode stays");
    }

    /// Two sides exchange hellos until both are acknowledged, then go
    /// quiet, and both send in the same mode.
    #[test]
    fn two_sides_agree_and_go_quiet() {
        let (mut client, mut server) = (Negotiation::new(RS), Negotiation::new(UltraMode::Off));
        let now = Instant::now();
        let mut exchanged = 0;
        for _ in 0..10 {
            if let Some(hello) = client.due(now) {
                client.sent(now);
                server.receive(hello);
                exchanged += 1;
            }
            if let Some(hello) = server.due(now) {
                server.sent(now);
                client.receive(hello);
                exchanged += 1;
            }
        }
        assert_eq!((client.mode(), server.mode()), (RS, RS));
        assert!(client.due(now + Duration::from_secs(60)).is_none());
        assert!(server.due(now + Duration::from_secs(60)).is_none());
        assert_eq!(exchanged, 3, "a hello, an answer, and its acknowledgement");
    }

    /// A restarted peer's first hello has not heard this side: it is
    /// answered even after this side's own retries ended, with a new
    /// challenge the new instance must echo.
    #[test]
    fn a_restarted_peer_is_answered() {
        let mut side = Negotiation::with_numbers(UltraMode::Off, 1, 100);
        let now = Instant::now();
        side.receive(hello(FEC, 10, 1000, Some(100)));
        let answer = Hello { acknowledged: true, ..hello(UltraMode::Off, 1, 100, Some(1000)) };
        assert_eq!(side.due(now), Some(answer));
        side.sent(now);
        assert!(side.due(now).is_none(), "acknowledged both ways");
        side.receive(hello(RS, 11, 1100, Some(100)));
        assert_ne!(side.challenge, 100, "a new challenge for the new instance");
        assert!(!side.acknowledged, "the old challenge acknowledges nothing");
        let answer = hello(UltraMode::Off, 1, side.challenge, Some(1100));
        assert_eq!(side.due(now), Some(answer), "it starts over with the new instance");
        side.sent(now);
        assert_eq!(side.mode(), RS);
        side.receive(Hello { acknowledged: true, ..hello(RS, 11, 1100, Some(side.challenge)) });
        assert!(side.due(now).is_none(), "the new instance acknowledged this side");
    }

    /// A version-1 build's side as that build had it: no instance numbers,
    /// and it takes any 9-byte version-1 hello sent to the control port,
    /// whatever its source port.
    struct Version1 {
        configured: UltraMode,
        peer: Option<UltraMode>,
        acknowledged: bool,
        sent: usize,
        next: Option<Instant>,
        told: bool,
        answer: bool,
    }

    impl Version1 {
        fn new(configured: UltraMode) -> Self {
            Self {
                configured,
                peer: None,
                acknowledged: false,
                sent: 0,
                next: None,
                told: false,
                answer: false,
            }
        }

        fn mode(&self) -> UltraMode {
            self.peer.map_or(self.configured, |peer| UltraMode::agree(self.configured, peer))
        }

        fn due(&self, now: Instant) -> bool {
            let retry =
                !self.acknowledged && self.sent < TRIES && self.next.is_none_or(|at| now >= at);
            self.answer || retry
        }
    }

    /// One side of an exchange of hello packets.
    trait Endpoint {
        /// The packets this side sends now.
        fn send(&mut self, now: Instant, from: IpAddr, to: IpAddr) -> Vec<Vec<u8>>;
        fn take(&mut self, packet: &[u8]);
    }

    /// As the driver sends: the hello, and its version-1 copy while
    /// discovering.
    impl Endpoint for Negotiation {
        fn send(&mut self, now: Instant, from: IpAddr, to: IpAddr) -> Vec<Vec<u8>> {
            let Some(hello) = self.due(now) else { return Vec::new() };
            let mut packets = vec![packet(from, to, hello)];
            if self.discovering() {
                packets.push(discovery_packet(from, to, hello));
            }
            self.sent(now);
            packets
        }

        fn take(&mut self, packet: &[u8]) {
            if let Some(hello) = decode(packet) {
                self.receive(hello);
            }
        }
    }

    impl Endpoint for Version1 {
        fn send(&mut self, now: Instant, from: IpAddr, to: IpAddr) -> Vec<Vec<u8>> {
            if !self.due(now) {
                return Vec::new();
            }
            let hello = Hello {
                mode: self.configured,
                instance: 0,
                challenge: 0,
                echo: self.peer.map(|_| 0),
                acknowledged: true,
                legacy: true,
            };
            self.answer = false;
            self.told |= self.peer.is_some();
            if !self.acknowledged && self.sent < TRIES {
                self.next = BACKOFF.get(self.sent).map(|wait| now + *wait);
                self.sent += 1;
            }
            vec![packet(from, to, hello)]
        }

        fn take(&mut self, packet: &[u8]) {
            let Some((_, destination, payload)) = udp::parse(packet) else { return };
            let Ok(&[m0, m1, m2, m3, VERSION_1, flags, kind, a, b]) =
                <&[u8; LEN_1]>::try_from(payload)
            else {
                return;
            };
            if destination.port() != HELLO_PORT || [m0, m1, m2, m3] != MAGIC {
                return;
            }
            self.peer = Some(UltraMode::from_wire(kind, a, b));
            if flags & HEARD != 0 {
                self.acknowledged = true;
                self.next = None;
            } else {
                self.told = false;
            }
            self.answer |= !self.told;
        }
    }

    /// Hello packets between two sides over a link that loses the ones
    /// `lost` picks (by the order they were sent, from 0), for `steps` ticks
    /// of 50 ms. Returns how many were sent.
    fn exchange(
        a: &mut (dyn Endpoint + 'static),
        b: &mut (dyn Endpoint + 'static),
        start: Instant,
        steps: u32,
        lost: &dyn Fn(usize) -> bool,
    ) -> usize {
        let (one, two) = addresses();
        let mut sent = 0;
        for step in 0..steps {
            let now = start + Duration::from_millis(50) * step;
            for forward in [true, false] {
                let (from, to, source, destination) = if forward {
                    (&mut *a, &mut *b, one, two)
                } else {
                    (&mut *b, &mut *a, two, one)
                };
                for packet in from.send(now, source, destination) {
                    if !lost(sent) {
                        to.take(&packet);
                    }
                    sent += 1;
                }
            }
        }
        sent
    }

    /// Every set of at most four of the first ten packets.
    fn losses() -> impl Iterator<Item = u32> {
        (0u32..1 << 10).filter(|mask| mask.count_ones() <= 4)
    }

    fn lose(mask: u32) -> impl Fn(usize) -> bool {
        move |n| n < 10 && mask & (1 << n) != 0
    }

    fn quiet(side: &Negotiation, now: Instant) -> bool {
        side.due(now).is_none()
    }

    /// The case the challenges exist for. The surviving side heard the
    /// peer's old instance but has not yet been acknowledged, so its retries
    /// echo that instance's challenge. The peer restarts in another mode,
    /// and its first hello and its answer to the survivor's retry are both
    /// lost. The retry acknowledges no one, the restarted side keeps trying,
    /// and both land on the same mode.
    #[test]
    fn a_stale_acknowledgement_does_not_end_a_restarted_peers_hellos() {
        let start = Instant::now();
        let mut survivor = Negotiation::with_numbers(UltraMode::Off, 1, 100);
        let old = Negotiation::with_numbers(UltraMode::Off, 2, 200);
        // The old instance's hello arrived; the survivor's own was lost, so
        // it is still retrying, echoing instance 2's challenge.
        survivor.receive(old.due(start).unwrap());
        survivor.sent(start);
        let retry = survivor.due(start + Duration::from_secs(1)).unwrap();
        assert_eq!(retry.echo, Some(200));

        let mut restarted = Negotiation::with_numbers(FEC, 3, 300);
        // Its first hello is lost.
        restarted.sent(start);
        // The survivor's retry arrives; the answer to it is lost.
        restarted.receive(retry);
        assert!(!restarted.acknowledged, "an echo of instance 2's challenge is not one of 3's");
        assert!(restarted.due(start).is_some(), "it answers");
        restarted.sent(start);

        let later = start + Duration::from_millis(100);
        exchange(&mut survivor, &mut restarted, later, 200, &|_| false);
        assert_eq!(survivor.mode(), FEC);
        assert_eq!(restarted.mode(), FEC);
        assert!(survivor.acknowledged && restarted.acknowledged);
        let after = later + Duration::from_secs(60);
        assert!(quiet(&survivor, after) && quiet(&restarted, after));
    }

    /// A peer that restarts after the two sides went quiet: the survivor
    /// starts over with the new instance (even after its own retries ran
    /// out), and both send in the new agreement and go quiet, whichever four
    /// of the first ten packets after the restart are lost.
    #[test]
    fn a_peer_restart_resets_the_negotiation_through_loss() {
        let start = Instant::now();
        for mask in losses() {
            let mut survivor = Negotiation::with_numbers(UltraMode::Off, 1, 100);
            let mut old = Negotiation::with_numbers(RS, 2, 200);
            exchange(&mut survivor, &mut old, start, 200, &|_| false);
            assert_eq!(survivor.mode(), RS);
            assert!(quiet(&survivor, start + Duration::from_secs(60)));

            let mut restarted = Negotiation::with_numbers(FEC, 3, 300);
            let later = start + Duration::from_secs(60);
            exchange(&mut survivor, &mut restarted, later, 400, &lose(mask));
            assert_eq!((survivor.mode(), restarted.mode()), (FEC, FEC), "lost {mask:010b}");
            assert!(survivor.acknowledged && restarted.acknowledged, "lost {mask:010b}");
            let after = later + Duration::from_secs(120);
            assert!(quiet(&survivor, after) && quiet(&restarted, after), "lost {mask:010b}");
        }
    }

    /// The peer's instance 2 (RS) sends its first hello, which is delayed,
    /// and restarts as instance 3 (FEC). Instance 3's first hello arrives,
    /// the survivor's answer is lost, then instance 2's delayed hello
    /// arrives, from an instance the survivor never saw. The survivor starts
    /// over with instance 2, but nothing it hears from instance 2 can
    /// acknowledge it, so it keeps sending; instance 3 answers, and the two
    /// agree on FEC, whichever four of the next ten packets are lost.
    #[test]
    fn a_delayed_hello_from_an_unseen_earlier_instance_is_overruled() {
        let start = Instant::now();
        let (one, two) = addresses();
        for mask in losses() {
            let mut survivor = Negotiation::with_numbers(UltraMode::Off, 1, 100);
            let mut earlier = Negotiation::with_numbers(RS, 2, 200);
            let mut live = Negotiation::with_numbers(FEC, 3, 300);
            let delayed = earlier.send(start, two, one);
            for packet in live.send(start, two, one) {
                survivor.take(&packet);
            }
            let lost_answer = survivor.send(start, one, two);
            assert!(!lost_answer.is_empty());
            for packet in &delayed {
                survivor.take(packet);
            }
            assert_eq!(survivor.mode(), RS, "it took up the delayed hello");
            let later = start + Duration::from_millis(50);
            exchange(&mut survivor, &mut live, later, 400, &lose(mask));
            assert_eq!((survivor.mode(), live.mode()), (FEC, FEC), "lost {mask:010b}");
            assert!(survivor.acknowledged && live.acknowledged, "lost {mask:010b}");
            let after = later + Duration::from_secs(120);
            assert!(quiet(&survivor, after) && quiet(&live, after), "lost {mask:010b}");
        }
    }

    /// Late hellos from the instance the peer restarted from, after the
    /// survivor agreed with the new one: each echoes the survivor's
    /// challenge as it was, so the survivor starts over with the old
    /// instance but is never acknowledged by it, however many arrive; its
    /// hellos reach the live instance, which answers, and the agreement
    /// comes back, even with the survivor's first answer lost.
    #[test]
    fn late_hellos_from_a_retired_instance_cannot_hold_the_survivor() {
        let start = Instant::now();
        let (one, two) = addresses();
        let mut survivor = Negotiation::with_numbers(UltraMode::Off, 1, 100);
        let mut old = Negotiation::with_numbers(RS, 2, 200);
        exchange(&mut survivor, &mut old, start, 200, &|_| false);
        let late = Hello { acknowledged: true, ..hello(RS, 2, 200, Some(survivor.challenge)) };
        let mut live = Negotiation::with_numbers(FEC, 3, 300);
        let later = start + Duration::from_secs(60);
        exchange(&mut survivor, &mut live, later, 200, &|_| false);
        assert_eq!(survivor.mode(), FEC);

        let now = later + Duration::from_secs(30);
        assert_eq!(survivor.receive(late), RS, "it starts over with instance 2");
        assert!(!survivor.send(now, one, two).is_empty(), "its answer, lost");
        for _ in 0..3 {
            survivor.receive(late);
            assert!(!survivor.acknowledged, "an old echo acknowledges nothing");
        }
        assert!(survivor.due(now + Duration::from_secs(1)).is_some(), "still sending");
        exchange(&mut survivor, &mut live, now, 400, &|_| false);
        assert_eq!((survivor.mode(), live.mode()), (FEC, FEC));
        assert!(survivor.acknowledged && live.acknowledged);
        let after = now + Duration::from_secs(120);
        assert!(quiet(&survivor, after) && quiet(&live, after));
    }

    /// A version-1 hello (from a build with only the control port), as that
    /// build put it on the wire.
    fn version_1(mode: UltraMode, heard: bool) -> Hello {
        let (kind, a, b) = mode.wire();
        Hello::decode(&[b'C', b'M', b'X', b'U', 1, u8::from(heard), kind, a, b]).unwrap()
    }

    /// A version-1 peer: this side reads its hellos, answers in version 2
    /// with a version-1 copy, takes its `heard` flag as an acknowledgement,
    /// and the two agree. Its hellos never count as a restart.
    #[test]
    fn a_version_1_peer_still_agrees() {
        let now = Instant::now();
        let mut side = Negotiation::with_numbers(UltraMode::Off, 1, 100);
        let first = side.due(now).unwrap();
        assert_eq!(first.encode().len(), LEN, "version 2 until the peer is known");
        side.sent(now);
        assert_eq!(side.receive(version_1(RS, false)), RS, "the peer's RS is taken up");
        let answer = side.due(now).unwrap();
        assert_eq!(answer.encode().len(), LEN, "a version-2 side always sends version 2");
        assert!(side.discovering(), "and a version-1 copy to a version-1 peer");
        let (a, b) = addresses();
        let copy = discovery_packet(a, b, answer);
        let (_, _, payload) = udp::parse(&copy).unwrap();
        assert_eq!(payload.len(), LEN_1);
        assert_eq!(payload[4..6], [VERSION_1, HEARD], "version 1, saying it heard the peer");
        side.sent(now);
        side.receive(version_1(RS, true));
        assert!(side.acknowledged, "the version-1 heard flag acknowledges this side");
        assert!(quiet(&side, now + Duration::from_secs(60)));
        assert_eq!(side.mode(), RS);
        // Its next hello (a retry) is not a restart: nothing starts over.
        side.receive(version_1(RS, true));
        assert!(side.acknowledged && quiet(&side, now + Duration::from_secs(60)));
    }

    /// Until its peer is known, a side's hello also goes out in version 1
    /// from another port: a version-1 build takes it, a version-2 build
    /// drops it (the version-2 hello beside it says the same).
    #[test]
    fn the_version_1_copy_reaches_only_a_version_1_build() {
        let (a, b) = addresses();
        let side = Negotiation::with_numbers(RS, 1, 100);
        assert!(side.discovering());
        let first = side.due(Instant::now()).unwrap();
        let copy = discovery_packet(a, b, first);
        assert_eq!(decode(&copy), None, "a version-2 build drops the copy");
        let mut old = Version1::new(UltraMode::Off);
        old.take(&copy);
        assert_eq!(old.mode(), RS, "a version-1 build takes it");
        assert!(old.answer, "and answers it");
        let mut known = Negotiation::with_numbers(RS, 1, 100);
        known.receive(hello(FEC, 2, 200, None));
        assert!(!known.discovering(), "no copy once a version-2 peer is known");
        known.receive(version_1(FEC, false));
        assert!(known.discovering(), "copies again for a version-1 peer");
    }

    /// A version-1 build and a version-2 one agree and go quiet; the
    /// version-2 side restarts. The version-1 side drops its version-2
    /// hellos but takes their version-1 copies and answers, and the two
    /// agree again, whichever four of the first ten packets are lost.
    #[test]
    fn a_quiet_version_1_peer_answers_a_restarted_side() {
        let start = Instant::now();
        for mask in losses() {
            let mut old = Version1::new(RS);
            let mut side = Negotiation::with_numbers(UltraMode::Off, 1, 100);
            exchange(&mut side, &mut old, start, 200, &|_| false);
            assert_eq!((side.mode(), old.mode()), (RS, RS));
            let after = start + Duration::from_secs(60);
            assert!(quiet(&side, after) && !old.due(after));

            let mut restarted = Negotiation::with_numbers(UltraMode::Off, 2, 200);
            exchange(&mut restarted, &mut old, after, 400, &lose(mask));
            assert_eq!((restarted.mode(), old.mode()), (RS, RS), "lost {mask:010b}");
            assert!(restarted.acknowledged && old.acknowledged, "lost {mask:010b}");
            let quiet_at = after + Duration::from_secs(120);
            assert!(quiet(&restarted, quiet_at) && !old.due(quiet_at), "lost {mask:010b}");
        }
    }

    /// A late version-1 hello after the peer upgraded: this side (Off)
    /// agreed with a version-1 build (RS), which upgraded to version 2
    /// (FEC), and the two agreed again. A version-1 `heard` hello the old
    /// build sent arrives late. This side moves to it but is not
    /// acknowledged by it; its version-2 hellos reach the upgraded peer,
    /// which answers, and both end on FEC, with this side's first answer
    /// lost and any three of the next ten packets too. Two version-2 sides
    /// never talk version 1 to each other, so the late hello cannot move
    /// the upgraded peer.
    #[test]
    fn a_late_version_1_hello_after_an_upgrade_is_overruled() {
        let start = Instant::now();
        let (one, two) = addresses();
        for mask in (0u32..1 << 10).filter(|mask| mask.count_ones() <= 3) {
            let mut side = Negotiation::with_numbers(UltraMode::Off, 1, 100);
            let mut old = Version1::new(RS);
            exchange(&mut side, &mut old, start, 200, &|_| false);
            assert_eq!(side.mode(), RS);
            let mut upgraded = Negotiation::with_numbers(FEC, 2, 200);
            let later = start + Duration::from_secs(60);
            exchange(&mut side, &mut upgraded, later, 400, &|_| false);
            assert_eq!((side.mode(), upgraded.mode()), (FEC, FEC));
            assert!(!side.discovering() && !upgraded.discovering(), "both version 2");

            let now = later + Duration::from_secs(60);
            assert_eq!(side.receive(version_1(RS, true)), RS, "it moves to the late hello");
            assert!(!side.acknowledged, "which does not acknowledge it");
            side.receive(version_1(RS, true));
            assert!(!side.acknowledged, "nor does a second late one");
            assert!(!side.send(now, one, two).is_empty(), "its answer, lost");
            exchange(&mut side, &mut upgraded, now, 400, &lose(mask));
            assert_eq!((side.mode(), upgraded.mode()), (FEC, FEC), "lost {mask:010b}");
            assert!(side.acknowledged && upgraded.acknowledged, "lost {mask:010b}");
            let after = now + Duration::from_secs(120);
            assert!(quiet(&side, after) && quiet(&upgraded, after), "lost {mask:010b}");
        }
    }

    /// Several late version-1 hellos from before the peer upgraded arrive
    /// together, before this side has sent anything: none acknowledges this
    /// side, which keeps sending until the upgraded peer answers, and both
    /// end on FEC whichever four of the next ten packets are lost.
    #[test]
    fn repeated_late_version_1_hellos_cannot_hold_this_side() {
        let start = Instant::now();
        for late in [2, 4] {
            for mask in losses() {
                let mut side = Negotiation::with_numbers(UltraMode::Off, 1, 100);
                let mut old = Version1::new(RS);
                exchange(&mut side, &mut old, start, 200, &|_| false);
                let mut upgraded = Negotiation::with_numbers(FEC, 2, 200);
                let later = start + Duration::from_secs(60);
                exchange(&mut side, &mut upgraded, later, 400, &|_| false);
                assert_eq!((side.mode(), upgraded.mode()), (FEC, FEC));

                for _ in 0..late {
                    side.receive(version_1(RS, true));
                }
                assert!(!side.acknowledged, "{late} late hellos acknowledge nothing");
                let now = later + Duration::from_secs(60);
                exchange(&mut side, &mut upgraded, now, 400, &lose(mask));
                let lost = format!("{late} late, lost {mask:010b}");
                assert_eq!((side.mode(), upgraded.mode()), (FEC, FEC), "{lost}");
                assert!(side.acknowledged && upgraded.acknowledged, "{lost}");
                let after = now + Duration::from_secs(120);
                assert!(quiet(&side, after) && quiet(&upgraded, after), "{lost}");
            }
        }
    }

    /// A version-2 peer replaced by a version-1 build within one tunnel (a
    /// downgrade): this side is never acknowledged by it, but each side
    /// takes the other's mode, from its hellos and this side's copies.
    #[test]
    fn a_downgraded_peer_still_agrees_on_the_mode() {
        let start = Instant::now();
        let mut side = Negotiation::with_numbers(FEC, 1, 100);
        let mut peer = Negotiation::with_numbers(UltraMode::Off, 2, 200);
        exchange(&mut side, &mut peer, start, 200, &|_| false);
        let mut downgraded = Version1::new(RS);
        let later = start + Duration::from_secs(60);
        exchange(&mut side, &mut downgraded, later, 600, &|_| false);
        assert_eq!((side.mode(), downgraded.mode()), (RS, RS));
        assert!(quiet(&side, later + Duration::from_secs(120)), "it stops after its tries");
    }
}
