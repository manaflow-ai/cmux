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
//! Each side picks a random instance number when its tunnel starts, sends it
//! in every hello, and acknowledges the peer's hello by echoing the peer's
//! number. An acknowledgement counts only when it echoes this instance, so a
//! retry the peer queued for an earlier instance of this side (one that
//! restarted) is not taken as one. A hello with a new instance number is a
//! restarted peer: this side starts the exchange over with it.
//! A peer that sends version 1 (no instance numbers) is answered in
//! version 1, and its `heard` flag counts as an acknowledgement, as it did.
//!
//! A hello goes out as soon as a session exists, ahead of that pass's data,
//! and again at 0.25, 0.5, 1 and 2 s until the peer acknowledges it. Each
//! hello also says whether its sender has been acknowledged. A hello is
//! answered at once when it does not acknowledge this side, when its sender
//! is still waiting for this side's acknowledgement (the one this side sent
//! was lost), or when this side has not yet acknowledged the peer's, so a
//! clean exchange is three hellos, and any four hellos of a restart can be
//! lost. An older peer never answers: after [`TRIES`] hellos this side stops
//! and keeps its own mode.

use std::net::{IpAddr, SocketAddr};
use std::time::Duration;

use tokio::time::Instant;

use crate::udp;
use crate::ultra::UltraMode;

/// The overlay UDP port of hello packets: the session's control port, shared
/// with path probes (different magic and length).
pub(crate) const HELLO_PORT: u16 = cmux_transport::probe::PROBE_PORT;
const MAGIC: [u8; 4] = *b"CMXU";
/// 2: the instance numbers.
const VERSION: u8 = 2;
const LEN: usize = 25;
/// Version 1, without instance numbers (9 bytes): what builds with only the
/// control port send. Read, and answered in kind, so a mixed pair still
/// agrees.
const VERSION_1: u8 = 1;
const LEN_1: usize = 9;
/// The `heard` flag: the sender has the receiver's hello, whose instance
/// number it echoes.
const HEARD: u8 = 1;
/// The `acknowledged` flag: the receiver acknowledged the sender's hello.
const ACKNOWLEDGED: u8 = 2;
/// Hellos sent before an unanswered side gives up.
const TRIES: usize = 5;
/// Earlier instances of the peer remembered, so a hello one of them sent
/// that arrives late cannot bring it back.
const RETIRED: usize = 4;
/// The wait after each hello, before the next.
const BACKOFF: [Duration; TRIES - 1] = [
    Duration::from_millis(250),
    Duration::from_millis(500),
    Duration::from_secs(1),
    Duration::from_secs(2),
];

/// One hello: the sender's own mode and instance, the instance of the
/// receiver's hello it has, if any, and whether the receiver acknowledged
/// the sender's.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Hello {
    pub(crate) mode: UltraMode,
    pub(crate) instance: u64,
    pub(crate) heard: Option<u64>,
    pub(crate) acknowledged: bool,
    /// Version 1 on the wire: no instance numbers, and `heard` (any value)
    /// stands for the version-1 flag.
    pub(crate) legacy: bool,
}

impl Hello {
    fn encode(self) -> Vec<u8> {
        let (kind, a, b) = self.mode.wire();
        if self.legacy {
            let flags = if self.heard.is_some() { HEARD } else { 0 };
            let mut bytes = MAGIC.to_vec();
            bytes.extend_from_slice(&[VERSION_1, flags, kind, a, b]);
            return bytes;
        }
        let mut bytes = [0u8; LEN];
        bytes[..4].copy_from_slice(&MAGIC);
        bytes[4] = VERSION;
        bytes[5] = if self.heard.is_some() { HEARD } else { 0 }
            | if self.acknowledged { ACKNOWLEDGED } else { 0 };
        bytes[6] = kind;
        bytes[7] = a;
        bytes[8] = b;
        bytes[9..17].copy_from_slice(&self.instance.to_be_bytes());
        bytes[17..25].copy_from_slice(&self.heard.unwrap_or(0).to_be_bytes());
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
                heard: (flags & HEARD != 0).then_some(0),
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
        let heard = (bytes[5] & HEARD != 0).then(|| number(17..25)).flatten();
        let acknowledged = bytes[5] & ACKNOWLEDGED != 0;
        let mode = UltraMode::from_wire(bytes[6], bytes[7], bytes[8]);
        Some(Self { mode, instance, heard, acknowledged, legacy: false })
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

/// A random instance number for a tunnel that is starting.
fn fresh_instance() -> u64 {
    let mut bytes = [0u8; 8];
    // Without operating system randomness the clock still tells two starts
    // apart.
    if getrandom::fill(&mut bytes).is_err() {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |elapsed| elapsed.as_nanos());
        bytes = (nanos as u64).to_be_bytes();
    }
    u64::from_be_bytes(bytes)
}

/// One tunnel's side of the agreement.
#[derive(Debug)]
pub(crate) struct Negotiation {
    /// The mode this side was started with.
    configured: UltraMode,
    /// This side's instance number.
    instance: u64,
    /// The peer's mode and instance, once its hello arrived.
    peer: Option<(UltraMode, u64)>,
    /// Instances of the peer it restarted from, newest last: their hellos
    /// are ignored.
    retired: Vec<u64>,
    /// The peer speaks version 1: hellos to it go out in version 1, and its
    /// `heard` flag acknowledges this side.
    peer_legacy: bool,
    /// The peer's hello echoed this side's instance.
    acknowledged: bool,
    /// Hellos sent without an acknowledgement.
    sent: usize,
    /// When the next unacknowledged hello is due; `None` before the first.
    next: Option<Instant>,
    /// This side sent a hello acknowledging the peer's current instance.
    told: bool,
    /// A hello arrived that did not acknowledge this side, whose sender is
    /// still waiting for an acknowledgement, or before this side acknowledged
    /// the peer's: answer it.
    answer: bool,
    /// Off only to stand in for a build without the hello (tests): it sends
    /// none, and a hello reaching it is an ordinary packet.
    enabled: bool,
}

impl Negotiation {
    pub(crate) fn new(configured: UltraMode) -> Self {
        Self::with_instance(configured, fresh_instance())
    }

    fn with_instance(configured: UltraMode, instance: u64) -> Self {
        Self {
            configured,
            instance,
            peer: None,
            retired: Vec::new(),
            peer_legacy: false,
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
            Some((peer, _)) => UltraMode::agree(self.configured, peer),
            None => self.configured,
        }
    }

    /// Take the peer's hello. Returns the mode to send in now.
    pub(crate) fn receive(&mut self, hello: Hello) -> UltraMode {
        if !hello.legacy && self.retired.contains(&hello.instance) {
            // Late, from an instance the peer restarted from.
            return self.mode();
        }
        let previous = self.peer.map(|(_, instance)| instance);
        let restarted = previous.is_some_and(|instance| instance != hello.instance);
        if let Some(old) = previous.filter(|_| restarted) {
            if self.retired.len() >= RETIRED {
                self.retired.remove(0);
            }
            self.retired.push(old);
            // A new instance of the peer knows nothing of this side: start
            // over, so this side's hellos go out again until it acknowledges
            // them, whatever the old instance had heard.
            self.acknowledged = false;
            self.sent = 0;
            self.next = None;
            self.told = false;
        }
        self.peer = Some((hello.mode, hello.instance));
        self.peer_legacy = hello.legacy;
        // The hello that announces a new instance does not also acknowledge
        // this side: this side's own hello must reach that instance first.
        let acknowledges = !restarted
            && if hello.legacy {
                hello.heard.is_some()
            } else {
                hello.heard == Some(self.instance)
            };
        if acknowledges {
            self.acknowledged = true;
            self.next = None;
        } else {
            // It has not heard this instance (or heard an earlier one).
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
            heard: self.peer.map(|(_, instance)| instance),
            acknowledged: self.acknowledged,
            legacy: self.peer_legacy,
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

    #[test]
    fn a_hello_round_trips_through_its_packet() {
        let (a, b) = addresses();
        for mode in [UltraMode::Off, UltraMode::Duplicate { copies: 3 }, FEC, RS] {
            for heard in [None, Some(0), Some(u64::MAX)] {
                for acknowledged in [false, true] {
                    let instance = 0x0123_4567_89ab_cdef;
                    let hello = Hello { mode, instance, heard, acknowledged, legacy: false };
                    assert_eq!(decode(&packet(a, b, hello)), Some(hello));
                }
            }
        }
        let probe = udp::packet(SocketAddr::new(a, 4102), SocketAddr::new(b, 4102), &[0; 15]);
        assert_eq!(decode(&probe), None, "a probe is not a hello");
        let mut wrong =
            Hello { mode: FEC, instance: 1, heard: None, acknowledged: false, legacy: false }
                .encode();
        wrong[0] ^= 1;
        assert_eq!(Hello::decode(&wrong), None, "the magic is checked");
    }

    /// The hello rides the probe port, which no build lets a service bind,
    /// and a build that knows only probes refuses it as one; the 9-byte
    /// version-1 hello on remote desktop's port 4103 is application data.
    #[test]
    fn a_hello_is_never_application_data() {
        let (a, b) = addresses();
        let hello =
            Hello { mode: RS, instance: 7, heard: Some(9), acknowledged: true, legacy: false };
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
        let mut bytes =
            Hello { mode: FEC, instance: 3, heard: Some(4), acknowledged: true, legacy: false }
                .encode();
        bytes[6] = 0xEE;
        let expected = Hello {
            mode: UltraMode::Off,
            instance: 3,
            heard: Some(4),
            acknowledged: true,
            legacy: false,
        };
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
    /// answered even after this side's own retries ended.
    #[test]
    fn a_restarted_peer_is_answered() {
        let mut side = Negotiation::with_instance(UltraMode::Off, 1);
        let now = Instant::now();
        side.receive(Hello {
            mode: FEC,
            instance: 10,
            heard: Some(1),
            acknowledged: false,
            legacy: false,
        });
        let answer = Hello {
            mode: UltraMode::Off,
            instance: 1,
            heard: Some(10),
            acknowledged: true,
            legacy: false,
        };
        assert_eq!(side.due(now), Some(answer));
        side.sent(now);
        assert!(side.due(now).is_none(), "acknowledged both ways");
        side.receive(Hello {
            mode: RS,
            instance: 11,
            heard: None,
            acknowledged: false,
            legacy: false,
        });
        let answer = Hello {
            mode: UltraMode::Off,
            instance: 1,
            heard: Some(11),
            acknowledged: false,
            legacy: false,
        };
        assert_eq!(side.due(now), Some(answer), "it starts over with the new instance");
        side.sent(now);
        assert_eq!(side.mode(), RS);
        side.receive(Hello {
            mode: RS,
            instance: 11,
            heard: Some(1),
            acknowledged: true,
            legacy: false,
        });
        assert!(side.due(now).is_none(), "the new instance acknowledged this side");
    }

    /// Hellos between two sides over a link that loses the ones `lost`
    /// picks (by the order they were sent, from 0), for `steps` ticks of
    /// 50 ms. Returns how many were sent.
    fn exchange(
        a: &mut Negotiation,
        b: &mut Negotiation,
        start: Instant,
        steps: u32,
        lost: &dyn Fn(usize) -> bool,
    ) -> usize {
        let mut sent = 0;
        for step in 0..steps {
            let now = start + Duration::from_millis(50) * step;
            for forward in [true, false] {
                let (from, to) = if forward { (&mut *a, &mut *b) } else { (&mut *b, &mut *a) };
                if let Some(hello) = from.due(now) {
                    from.sent(now);
                    if !lost(sent) {
                        to.receive(hello);
                    }
                    sent += 1;
                }
            }
        }
        sent
    }

    /// The case the instance numbers exist for. The surviving side heard the
    /// peer's old instance but not yet been acknowledged, so its retries say
    /// it heard the peer. The peer restarts in another mode, and its first
    /// hello and its answer to the survivor's retry are both lost. Before,
    /// the restarted side took that retry as an acknowledgement and went
    /// quiet, and the two sides kept different modes; now the retry
    /// acknowledges no one, the restarted side keeps trying, and both land
    /// on the same mode.
    #[test]
    fn a_stale_acknowledgement_does_not_end_a_restarted_peers_hellos() {
        let start = Instant::now();
        let mut survivor = Negotiation::with_instance(UltraMode::Off, 1);
        let old = Negotiation::with_instance(UltraMode::Off, 2);
        // The old instance's hello arrived; the survivor's own was lost, so
        // it is still retrying, now saying it heard instance 2.
        survivor.receive(old.due(start).unwrap());
        survivor.sent(start);
        let retry = survivor.due(start + Duration::from_secs(1)).unwrap();
        assert_eq!(retry.heard, Some(2));

        let mut restarted = Negotiation::with_instance(FEC, 3);
        // Its first hello is lost.
        restarted.sent(start);
        // The survivor's retry arrives; the answer to it is lost.
        restarted.receive(retry);
        assert!(!restarted.acknowledged, "an acknowledgement of instance 2 is not one of 3");
        assert!(restarted.due(start).is_some(), "it answers");
        restarted.sent(start);

        let later = start + Duration::from_millis(100);
        exchange(&mut survivor, &mut restarted, later, 200, &|_| false);
        assert_eq!(survivor.mode(), FEC);
        assert_eq!(restarted.mode(), FEC);
        assert!(survivor.acknowledged && restarted.acknowledged);
        let quiet = later + Duration::from_secs(60);
        assert!(survivor.due(quiet).is_none() && restarted.due(quiet).is_none());
    }

    /// A peer that restarts after the two sides went quiet: the survivor
    /// starts over with the new instance (even after its own retries ran
    /// out), and both send in the new agreement and go quiet, whichever four
    /// of the first ten hellos after the restart are lost.
    #[test]
    fn a_peer_restart_resets_the_negotiation_through_loss() {
        let start = Instant::now();
        for lost in (0u32..1 << 10).filter(|mask| mask.count_ones() <= 4) {
            let mut survivor = Negotiation::with_instance(UltraMode::Off, 1);
            let mut old = Negotiation::with_instance(RS, 2);
            exchange(&mut survivor, &mut old, start, 200, &|_| false);
            assert_eq!(survivor.mode(), RS);
            assert!(survivor.due(start + Duration::from_secs(60)).is_none());

            let mut restarted = Negotiation::with_instance(FEC, 3);
            let later = start + Duration::from_secs(60);
            let lose = |n: usize| n < 10 && lost & (1 << n) != 0;
            exchange(&mut survivor, &mut restarted, later, 400, &lose);
            assert_eq!((survivor.mode(), restarted.mode()), (FEC, FEC), "lost {lost:010b}");
            assert!(survivor.acknowledged && restarted.acknowledged, "lost {lost:010b}");
            let quiet = later + Duration::from_secs(120);
            assert!(survivor.due(quiet).is_none() && restarted.due(quiet).is_none());
        }
    }

    /// A version-1 hello (from a build with only the control port), as that
    /// build put it on the wire.
    fn version_1(mode: UltraMode, heard: bool) -> Hello {
        let (kind, a, b) = mode.wire();
        Hello::decode(&[b'C', b'M', b'X', b'U', 1, u8::from(heard), kind, a, b]).unwrap()
    }

    /// A version-1 peer: this side reads its hellos, answers it in version
    /// 1, takes its `heard` flag as an acknowledgement, and the two agree.
    /// Its hellos never count as a restart.
    #[test]
    fn a_version_1_peer_still_agrees() {
        let now = Instant::now();
        let mut side = Negotiation::with_instance(UltraMode::Off, 1);
        let first = side.due(now).unwrap();
        assert_eq!(first.encode().len(), LEN, "version 2 until the peer is known");
        side.sent(now);
        assert_eq!(side.receive(version_1(RS, false)), RS, "the peer's RS is taken up");
        let answer = side.due(now).unwrap();
        let wire = answer.encode();
        assert_eq!(wire.len(), LEN_1);
        assert_eq!(wire[4..6], [VERSION_1, HEARD], "version 1, saying it heard the peer");
        side.sent(now);
        side.receive(version_1(RS, true));
        assert!(side.acknowledged, "the version-1 heard flag acknowledges this side");
        assert!(side.due(now + Duration::from_secs(60)).is_none(), "quiet");
        assert_eq!(side.mode(), RS);
        // Its next hello (a retry) is not a restart: nothing starts over.
        side.receive(version_1(RS, true));
        assert!(side.acknowledged && side.due(now + Duration::from_secs(60)).is_none());
    }

    /// A hello from the instance the peer restarted from, delivered late
    /// (it echoes this side, so it would look like an acknowledgement),
    /// does not bring that instance or its mode back.
    #[test]
    fn a_late_hello_from_a_retired_instance_is_ignored() {
        let start = Instant::now();
        let mut survivor = Negotiation::with_instance(UltraMode::Off, 1);
        let mut old = Negotiation::with_instance(RS, 2);
        exchange(&mut survivor, &mut old, start, 200, &|_| false);
        let late = old.due(start).unwrap_or(Hello {
            mode: RS,
            instance: 2,
            heard: Some(1),
            acknowledged: true,
            legacy: false,
        });
        let mut restarted = Negotiation::with_instance(FEC, 3);
        let later = start + Duration::from_secs(60);
        exchange(&mut survivor, &mut restarted, later, 200, &|_| false);
        assert_eq!(survivor.mode(), FEC);
        assert_eq!(survivor.receive(late), FEC, "instance 2 stays retired");
        assert!(survivor.acknowledged);
        assert!(survivor.due(later + Duration::from_secs(60)).is_none());
    }
}
