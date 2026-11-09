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
//! A hello goes out as soon as a session exists, ahead of that pass's data,
//! and again at 0.25, 0.5, 1 and 2 s until the peer's hello says it heard
//! this side's. A hello is answered at once when it has not heard this
//! side's, or when this side has not yet said it heard the peer's, so a
//! clean exchange is three hellos. An older peer never answers: after [`TRIES`] hellos this side stops
//! and keeps its own mode, and the older peer drops the packets (no socket is
//! bound to the port).

use std::net::{IpAddr, SocketAddr};
use std::time::Duration;

use tokio::time::Instant;

use crate::udp;
use crate::ultra::UltraMode;

/// The overlay UDP port of hello packets (path probes use 4102).
pub(crate) const HELLO_PORT: u16 = 4103;
const MAGIC: [u8; 4] = *b"CMXU";
const VERSION: u8 = 1;
const LEN: usize = 9;
/// The `heard` flag: the sender has the receiver's hello.
const HEARD: u8 = 1;
/// Hellos sent before an unanswered side gives up.
const TRIES: usize = 5;
/// The wait after each hello, before the next.
const BACKOFF: [Duration; TRIES - 1] = [
    Duration::from_millis(250),
    Duration::from_millis(500),
    Duration::from_secs(1),
    Duration::from_secs(2),
];

/// One hello: the sender's own mode, and whether it has the receiver's.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Hello {
    pub(crate) mode: UltraMode,
    pub(crate) heard: bool,
}

impl Hello {
    fn encode(self) -> [u8; LEN] {
        let (kind, a, b) = self.mode.wire();
        let mut bytes = [0u8; LEN];
        bytes[..4].copy_from_slice(&MAGIC);
        bytes[4] = VERSION;
        bytes[5] = if self.heard { HEARD } else { 0 };
        bytes[6] = kind;
        bytes[7] = a;
        bytes[8] = b;
        bytes
    }

    fn decode(payload: &[u8]) -> Option<Self> {
        let bytes: [u8; LEN] = payload.try_into().ok()?;
        let [m0, m1, m2, m3, version, flags, kind, a, b] = bytes;
        if [m0, m1, m2, m3] != MAGIC || version != VERSION {
            return None;
        }
        Some(Self { mode: UltraMode::from_wire(kind, a, b), heard: flags & HEARD != 0 })
    }
}

/// The overlay packet carrying `hello` from `source` to `destination`.
pub(crate) fn packet(source: IpAddr, destination: IpAddr, hello: Hello) -> Vec<u8> {
    let from = SocketAddr::new(source, HELLO_PORT);
    let to = SocketAddr::new(destination, HELLO_PORT);
    udp::packet(from, to, &hello.encode())
}

/// The hello in a decrypted packet, or `None` for every other packet.
pub(crate) fn decode(packet: &[u8]) -> Option<Hello> {
    let (_, destination, payload) = udp::parse(packet)?;
    if destination.port() != HELLO_PORT {
        return None;
    }
    Hello::decode(payload)
}

/// One tunnel's side of the agreement.
#[derive(Debug)]
pub(crate) struct Negotiation {
    /// The mode this side was started with.
    configured: UltraMode,
    /// The peer's mode, once its hello arrived.
    peer: Option<UltraMode>,
    /// The peer's hello said it has this side's.
    acknowledged: bool,
    /// Hellos sent without an acknowledgement.
    sent: usize,
    /// When the next unacknowledged hello is due; `None` before the first.
    next: Option<Instant>,
    /// This side sent a hello saying it has the peer's.
    told: bool,
    /// A hello arrived that had not heard this side's, or before this side
    /// said it has the peer's: answer it.
    answer: bool,
}

impl Negotiation {
    pub(crate) fn new(configured: UltraMode) -> Self {
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

    /// The mode both sides send in: the agreement, or this side's own until
    /// the peer's hello arrives.
    pub(crate) fn mode(&self) -> UltraMode {
        match self.peer {
            Some(peer) => UltraMode::agree(self.configured, peer),
            None => self.configured,
        }
    }

    /// Take the peer's hello. Returns the mode to send in now.
    pub(crate) fn receive(&mut self, hello: Hello) -> UltraMode {
        self.peer = Some(hello.mode);
        if hello.heard {
            self.acknowledged = true;
            self.next = None;
        } else {
            // A restarted peer: it needs this side's hello again.
            self.told = false;
        }
        self.answer |= !self.told;
        self.mode()
    }

    /// The hello to send now, if one is due; the caller sends it (once a
    /// session exists) and reports it with [`Negotiation::sent`].
    pub(crate) fn due(&self, now: Instant) -> Option<Hello> {
        let retry = !self.acknowledged && self.sent < TRIES && self.next.is_none_or(|at| now >= at);
        (self.answer || retry)
            .then_some(Hello { mode: self.configured, heard: self.peer.is_some() })
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
        if self.acknowledged || self.sent >= TRIES { None } else { self.next }
    }
}

#[cfg(test)]
mod tests {
    use std::net::Ipv4Addr;

    use super::*;

    const FEC: UltraMode = UltraMode::Fec { group: 8, parity: 2 };
    const RS: UltraMode = UltraMode::Rs { group: 4, parity: 4 };

    #[test]
    fn a_hello_round_trips_through_its_packet() {
        let (a, b) =
            (IpAddr::V4(Ipv4Addr::new(10, 0, 0, 1)), IpAddr::V4(Ipv4Addr::new(10, 0, 0, 2)));
        for mode in [UltraMode::Off, UltraMode::Duplicate { copies: 3 }, FEC, RS] {
            for heard in [false, true] {
                let hello = Hello { mode, heard };
                assert_eq!(decode(&packet(a, b, hello)), Some(hello));
            }
        }
        let probe = udp::packet(SocketAddr::new(a, 4102), SocketAddr::new(b, 4102), &[0; 9]);
        assert_eq!(decode(&probe), None, "only the hello port");
        let mut wrong = Hello { mode: FEC, heard: false }.encode();
        wrong[0] ^= 1;
        assert_eq!(Hello::decode(&wrong), None, "the magic is checked");
    }

    #[test]
    fn an_unknown_kind_reads_as_off() {
        let mut bytes = Hello { mode: FEC, heard: true }.encode();
        bytes[6] = 0xEE;
        assert_eq!(Hello::decode(&bytes), Some(Hello { mode: UltraMode::Off, heard: true }));
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
    fn a_peer_cannot_ask_for_more_than_four_times_the_bytes() {
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
    /// answered even after this side's own retries ended.
    #[test]
    fn a_restarted_peer_is_answered() {
        let mut side = Negotiation::new(UltraMode::Off);
        let now = Instant::now();
        side.receive(Hello { mode: FEC, heard: true });
        assert_eq!(side.due(now), Some(Hello { mode: UltraMode::Off, heard: true }));
        side.sent(now);
        assert!(side.due(now).is_none(), "acknowledged both ways");
        side.receive(Hello { mode: RS, heard: false });
        assert_eq!(side.due(now), Some(Hello { mode: UltraMode::Off, heard: true }));
        side.sent(now);
        assert!(side.due(now).is_none());
        assert_eq!(side.mode(), RS);
    }
}
