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
    Hello { mode, instance, challenge, echo, acknowledged: false, metered: false, legacy: false }
}

#[test]
fn a_hello_round_trips_through_its_packet() {
    let (a, b) = addresses();
    for mode in [UltraMode::Off, UltraMode::Duplicate { copies: 3 }, FEC, RS] {
        for echo in [None, Some(0), Some(u64::MAX)] {
            for (acknowledged, metered) in [(false, false), (true, false), (false, true)] {
                let hello = Hello {
                    acknowledged,
                    metered,
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
        let retry = !self.acknowledged && self.sent < TRIES && self.next.is_none_or(|at| now >= at);
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
            metered: false,
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
        let Ok(&[m0, m1, m2, m3, VERSION_1, flags, kind, a, b]) = <&[u8; LEN_1]>::try_from(payload)
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
            let (from, to, source, destination) =
                if forward { (&mut *a, &mut *b, one, two) } else { (&mut *b, &mut *a, two, one) };
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

/// Auto: a side that asks for a new mode mid-tunnel (it saw loss) moves
/// both sides to it, and back when it asks for off again, whichever four of
/// the first ten packets of each change are lost; then both go quiet.
#[test]
fn an_auto_side_moves_both_sides_and_back() {
    let start = Instant::now();
    for mask in losses() {
        let mut auto = Negotiation::with_numbers(UltraMode::Off, 1, 100);
        let mut peer = Negotiation::with_numbers(UltraMode::Off, 2, 200);
        exchange(&mut auto, &mut peer, start, 200, &|_| false);
        assert_eq!((auto.mode(), peer.mode()), (UltraMode::Off, UltraMode::Off));

        let lossy = start + Duration::from_secs(60);
        auto.advertise(RS, false);
        assert_eq!(auto.mode(), RS, "this side sends repair at once");
        assert!(auto.due(lossy).is_some(), "and tells the peer at once");
        exchange(&mut auto, &mut peer, lossy, 200, &lose(mask));
        assert_eq!((auto.mode(), peer.mode()), (RS, RS), "on, lost {mask:010b}");
        assert!(!auto.metered() && !peer.metered());

        let clean = lossy + Duration::from_secs(60);
        auto.advertise(UltraMode::Off, true);
        exchange(&mut auto, &mut peer, clean, 200, &lose(mask));
        assert_eq!(
            (auto.mode(), peer.mode()),
            (UltraMode::Off, UltraMode::Off),
            "off, {mask:010b}"
        );
        assert!(peer.metered(), "the peer keeps repair to a metered side capped");
        let later = clean + Duration::from_secs(120);
        assert!(quiet(&auto, later) && quiet(&peer, later), "lost {mask:010b}");
    }
}

/// Asking again for what this side already asks for sends nothing.
#[test]
fn advertising_the_same_mode_sends_no_hello() {
    let start = Instant::now();
    let mut auto = Negotiation::with_numbers(UltraMode::Off, 1, 100);
    let mut peer = Negotiation::with_numbers(UltraMode::Off, 2, 200);
    exchange(&mut auto, &mut peer, start, 200, &|_| false);
    let later = start + Duration::from_secs(60);
    auto.advertise(UltraMode::Off, false);
    assert!(quiet(&auto, later));
}
