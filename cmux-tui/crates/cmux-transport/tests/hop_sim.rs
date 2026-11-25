//! A deterministic, seeded simulation of phone ⇄ relay PoP ⇄ Mac, comparing
//! hop/1 per-leg repair (R4) and latest-wins (R5) with a plain forwarder.
//! Run with `--nocapture` to see the numbers.

use std::collections::{BTreeMap, HashMap};
use std::time::{Duration, Instant};

use cmux_transport::hop::{Delivered, HopClass, HopRelay, Leg, LegConfig, LegStats, Record, Side};

const TICK: Duration = Duration::from_millis(1);

/// splitmix64: a seeded, portable generator.
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }

    fn below(&mut self, bound: u64) -> u64 {
        self.next() % bound.max(1)
    }
}

/// One direction of a path: fixed delay, uniform jitter, random loss.
struct Link {
    delay: Duration,
    jitter_us: u64,
    loss_permille: u64,
    in_flight: Vec<(Instant, Vec<u8>)>,
    sent: u64,
    bytes: u64,
}

impl Link {
    fn new(delay_ms: u64, jitter_ms: u64, loss_permille: u64) -> Self {
        Self {
            delay: Duration::from_millis(delay_ms),
            jitter_us: jitter_ms * 1000,
            loss_permille,
            in_flight: Vec::new(),
            sent: 0,
            bytes: 0,
        }
    }

    fn send(&mut self, now: Instant, datagram: Vec<u8>, rng: &mut Rng) {
        self.sent += 1;
        self.bytes += datagram.len() as u64;
        let lost = rng.below(1000) < self.loss_permille;
        let jitter = Duration::from_micros(rng.below(self.jitter_us + 1));
        if !lost {
            self.in_flight.push((now + self.delay + jitter, datagram));
        }
    }

    fn due(&mut self, now: Instant) -> Vec<Vec<u8>> {
        let mut due: Vec<(Instant, Vec<u8>)> = Vec::new();
        self.in_flight.retain(|(at, datagram)| {
            if *at <= now {
                due.push((*at, datagram.clone()));
                false
            } else {
                true
            }
        });
        due.sort_by_key(|(at, _)| *at);
        due.into_iter().map(|(_, datagram)| datagram).collect()
    }
}

/// phone ⇄ relay (side A) ... relay (side B) ⇄ mac.
struct Net {
    now: Instant,
    rng: Rng,
    phone: Leg,
    relay: HopRelay,
    mac: Leg,
    phone_up: Link,
    phone_down: Link,
    mac_up: Link,
    mac_down: Link,
}

impl Net {
    fn new(config: LegConfig, phone_link: (u64, u64, u64), mac_link: (u64, u64, u64)) -> Self {
        let now = Instant::now();
        let mut rng = Rng(0x00C0_FFEE);
        let leg = |rng: &mut Rng| Leg::new(config, rng.next() as u32, now);
        let phone = leg(&mut rng);
        let relay = HopRelay::new(leg(&mut rng), leg(&mut rng));
        let mac = leg(&mut rng);
        let (delay, jitter, loss) = phone_link;
        let (mac_delay, mac_jitter, mac_loss) = mac_link;
        Self {
            now,
            rng,
            phone,
            relay,
            mac,
            phone_up: Link::new(delay, jitter, loss),
            phone_down: Link::new(delay, jitter, loss),
            mac_up: Link::new(mac_delay, mac_jitter, mac_loss),
            mac_down: Link::new(mac_delay, mac_jitter, mac_loss),
        }
    }

    /// One tick: every endpoint sends what is due, every link delivers what
    /// has arrived. Returns the records delivered at the phone and the Mac.
    fn step(&mut self) -> (Vec<Delivered>, Vec<Delivered>) {
        let now = self.now;
        while let Some(datagram) = self.phone.poll_transmit(now) {
            self.phone_up.send(now, datagram, &mut self.rng);
        }
        while let Some(datagram) = self.mac.poll_transmit(now) {
            self.mac_down.send(now, datagram, &mut self.rng);
        }
        while let Some(datagram) = self.relay.poll_transmit(Side::A, now) {
            self.phone_down.send(now, datagram, &mut self.rng);
        }
        while let Some(datagram) = self.relay.poll_transmit(Side::B, now) {
            self.mac_up.send(now, datagram, &mut self.rng);
        }
        for datagram in self.phone_up.due(now) {
            self.relay.handle(Side::A, &datagram, now);
        }
        for datagram in self.mac_down.due(now) {
            self.relay.handle(Side::B, &datagram, now);
        }
        let mut at_phone = Vec::new();
        for datagram in self.phone_down.due(now) {
            at_phone.extend(self.phone.handle(&datagram, now));
        }
        let mut at_mac = Vec::new();
        for datagram in self.mac_up.due(now) {
            at_mac.extend(self.mac.handle(&datagram, now));
        }
        self.now += TICK;
        (at_phone, at_mac)
    }
}

/// Records numbered by a 24-bit id in bytes 1..4 (byte 0 is zero, so a
/// plain record is never read as hop/1).
fn numbered(id: u32, len: usize) -> Vec<u8> {
    let mut bytes = vec![0x5A; len];
    bytes[0] = 0;
    bytes[1..4].copy_from_slice(&id.to_be_bytes()[1..]);
    bytes
}

fn id_of(bytes: &[u8]) -> u32 {
    u32::from_be_bytes([0, bytes[1], bytes[2], bytes[3]])
}

/// An application stream with end-to-end retransmission (a TCP inside the
/// tunnel): resent after `rto` until delivered; latency is from the first
/// send to the first delivery.
struct AppStream {
    class: HopClass,
    len: usize,
    rto: Duration,
    next_id: u32,
    pending: BTreeMap<u32, (Instant, Instant)>,
    latencies: Vec<Duration>,
    app_resends: u64,
}

impl AppStream {
    fn new(class: HopClass, len: usize, rto: Duration) -> Self {
        Self {
            class,
            len,
            rto,
            next_id: 0,
            pending: BTreeMap::new(),
            latencies: Vec::new(),
            app_resends: 0,
        }
    }

    fn send_new(&mut self, leg: &mut Leg, now: Instant) {
        let id = self.next_id;
        self.next_id += 1;
        self.pending.insert(id, (now, now));
        leg.send(Record::new(self.class, numbered(id, self.len)), now).expect("valid record");
    }

    fn resend_due(&mut self, leg: &mut Leg, now: Instant) {
        for (&id, (_, last)) in self.pending.iter_mut() {
            if now.saturating_duration_since(*last) >= self.rto {
                *last = now;
                self.app_resends += 1;
                leg.send(Record::new(self.class, numbered(id, self.len)), now)
                    .expect("valid record");
            }
        }
    }

    fn deliver(&mut self, record: &Record, now: Instant) {
        if let Some((first, _)) = self.pending.remove(&id_of(&record.bytes)) {
            self.latencies.push(now.saturating_duration_since(first));
        }
    }
}

struct Percentiles {
    p50: f64,
    p95: f64,
    p99: f64,
    max: f64,
}

fn percentiles(samples: &[Duration]) -> Percentiles {
    let mut ms: Vec<f64> = samples.iter().map(|d| d.as_secs_f64() * 1000.0).collect();
    ms.sort_by(f64::total_cmp);
    let at = |q: f64| {
        if ms.is_empty() {
            return f64::NAN;
        }
        let index = ((ms.len() as f64 - 1.0) * q).round() as usize;
        ms[index.min(ms.len() - 1)]
    };
    Percentiles { p50: at(0.50), p95: at(0.95), p99: at(0.99), max: at(1.0) }
}

fn sum_stats(stats: &[LegStats]) -> LegStats {
    stats.iter().fold(LegStats::default(), |mut total, s| {
        total.sent += s.sent;
        total.resent += s.resent;
        total.parity_sent += s.parity_sent;
        total.repaired_by_nack += s.repaired_by_nack;
        total.repaired_by_fec += s.repaired_by_fec;
        total.nacks_sent += s.nacks_sent;
        total.tail_probes += s.tail_probes;
        total.dropped_superseded += s.dropped_superseded;
        total.dropped_overflow += s.dropped_overflow;
        total.skipped_superseded_resend += s.skipped_superseded_resend;
        total
    })
}

fn all_stats(net: &Net) -> LegStats {
    sum_stats(&[
        net.phone.stats(),
        net.relay.leg(Side::A).stats(),
        net.relay.leg(Side::B).stats(),
        net.mac.stats(),
    ])
}

struct LossyOutcome {
    input: Percentiles,
    input_delivered: f64,
    bulk: Percentiles,
    bulk_delivered: f64,
    app_resends: u64,
    stats: LegStats,
    wire_bytes: u64,
}

/// Scenario 1: phone leg 70 ms RTT, 0-10 ms jitter, 3% loss each way; Mac
/// leg 10 ms RTT, clean. The phone types (64 B input every 20 ms) while the
/// Mac streams bulk to it (1000 B every 5 ms). Both run a TCP-like
/// end-to-end resend after 200 ms.
fn lossy_phone_leg(config: LegConfig) -> LossyOutcome {
    let mut net = Net::new(config, (35, 10, 30), (5, 0, 0));
    let rto = Duration::from_millis(200);
    let mut input = AppStream::new(HopClass::Input, 64, rto);
    let mut bulk = AppStream::new(HopClass::Bulk, 1000, rto);
    let traffic_ticks = 60_000u64;
    for tick in 0..traffic_ticks + 3_000 {
        let now = net.now;
        if tick < traffic_ticks {
            if tick % 20 == 0 {
                input.send_new(&mut net.phone, now);
            }
            if tick % 5 == 0 {
                bulk.send_new(&mut net.mac, now);
            }
        }
        input.resend_due(&mut net.phone, now);
        bulk.resend_due(&mut net.mac, now);
        let (at_phone, at_mac) = net.step();
        for delivered in at_mac {
            input.deliver(&delivered.record, now);
        }
        for delivered in at_phone {
            bulk.deliver(&delivered.record, now);
        }
    }
    let wire_bytes = net.phone_up.bytes + net.phone_down.bytes;
    LossyOutcome {
        input: percentiles(&input.latencies),
        input_delivered: input.latencies.len() as f64 / f64::from(input.next_id),
        bulk: percentiles(&bulk.latencies),
        bulk_delivered: bulk.latencies.len() as f64 / f64::from(bulk.next_id),
        app_resends: input.app_resends + bulk.app_resends,
        stats: all_stats(&net),
        wire_bytes,
    }
}

fn print_lossy(name: &str, outcome: &LossyOutcome) {
    let s = &outcome.stats;
    println!(
        "{name:<22} input p50/p95/p99/max {:6.1} {:6.1} {:6.1} {:6.1} ms ({:.2}% delivered) | \
         bulk p50/p95/p99 {:6.1} {:6.1} {:6.1} ms ({:.2}%) | app resends {} | \
         hop resent {} parity {} nack-repaired {} fec-repaired {} tail probes {} | phone-leg bytes {}",
        outcome.input.p50,
        outcome.input.p95,
        outcome.input.p99,
        outcome.input.max,
        outcome.input_delivered * 100.0,
        outcome.bulk.p50,
        outcome.bulk.p95,
        outcome.bulk.p99,
        outcome.bulk_delivered * 100.0,
        outcome.app_resends,
        s.resent,
        s.parity_sent,
        s.repaired_by_nack,
        s.repaired_by_fec,
        s.tail_probes,
        outcome.wire_bytes,
    );
}

#[test]
fn per_leg_repair_cuts_tail_latency_on_a_lossy_phone_leg() {
    let plain = lossy_phone_leg(LegConfig::plain());
    let nack_only = lossy_phone_leg(LegConfig { fec: false, ..LegConfig::default() });
    let repair = lossy_phone_leg(LegConfig::default());
    println!("scenario 1: phone leg 70 ms RTT +0-10 ms jitter, 3% loss; Mac leg 10 ms RTT; 60 s");
    print_lossy("plain forwarder", &plain);
    print_lossy("hop/1 NACK only", &nack_only);
    print_lossy("hop/1 NACK + FEC", &repair);
    assert!(repair.input_delivered > 0.999 && repair.bulk_delivered > 0.999);
    assert!(repair.input.p99 < plain.input.p99, "repair must cut input p99");
    assert!(repair.bulk.p99 < plain.bulk.p99, "repair must cut bulk p99");
    assert!(repair.app_resends < plain.app_resends / 4);
}

struct FrameOutcome {
    delay: Percentiles,
    frames_sent: u64,
    frames_delivered: u64,
    bulk_delivered: u64,
    stats: LegStats,
}

/// Scenario 2: phone leg 150 ms RTT, 1% loss, the PoP's egress to the
/// phone paced at 125 KB/s. The Mac sends 4 interactive streams at 60 fps
/// of 600 B frames (144 KB/s, more than the leg carries) plus bulk.
fn congested_frames(latest_wins: bool) -> FrameOutcome {
    let config = LegConfig { latest_wins, ..LegConfig::default() };
    let mut net = Net::new(config, (75, 4, 10), (5, 0, 0));
    net.relay.leg_mut(Side::A).set_pacing_rate(Some(125_000));
    let mut sent_at: HashMap<(u32, u32), Instant> = HashMap::new();
    let mut delays = Vec::new();
    let mut frames_sent = 0;
    let mut bulk_delivered = 0;
    let mut bulk_id = 0;
    let traffic_ticks = 30_000u64;
    for tick in 0..traffic_ticks + 3_000 {
        let now = net.now;
        if tick < traffic_ticks {
            // 60 fps: a frame every 16 or 17 ms per stream, streams offset.
            for key in 0..4u32 {
                let frame = (tick * 60 + u64::from(key) * 250) / 1000;
                let previous = ((tick.max(1) - 1) * 60 + u64::from(key) * 250) / 1000;
                if tick == 0 || frame != previous {
                    let seq = frame as u32;
                    sent_at.insert((key, seq), now);
                    frames_sent += 1;
                    let record = Record::tagged(key, seq, numbered(seq, 600));
                    net.mac.send(record, now).expect("valid record");
                }
            }
            if tick % 10 == 0 {
                net.mac
                    .send(Record::new(HopClass::Bulk, numbered(bulk_id, 1000)), now)
                    .expect("valid record");
                bulk_id += 1;
            }
        }
        let (at_phone, _) = net.step();
        for delivered in at_phone {
            match delivered.record.tag {
                Some(tag) => {
                    if let Some(at) = sent_at.remove(&(tag.key, tag.seq)) {
                        delays.push(now.saturating_duration_since(at));
                    }
                }
                None => bulk_delivered += 1,
            }
        }
    }
    FrameOutcome {
        delay: percentiles(&delays),
        frames_sent,
        frames_delivered: delays.len() as u64,
        bulk_delivered,
        stats: all_stats(&net),
    }
}

fn print_frames(name: &str, outcome: &FrameOutcome) {
    let s = &outcome.stats;
    println!(
        "{name:<16} frame delay p50/p95/p99/max {:7.1} {:7.1} {:7.1} {:7.1} ms | frames {} sent, \
         {} delivered, {} superseded, {} overflowed | bulk delivered {} | resends skipped as \
         superseded {}",
        outcome.delay.p50,
        outcome.delay.p95,
        outcome.delay.p99,
        outcome.delay.max,
        outcome.frames_sent,
        outcome.frames_delivered,
        s.dropped_superseded,
        s.dropped_overflow,
        outcome.bulk_delivered,
        s.skipped_superseded_resend,
    );
}

#[test]
fn latest_wins_bounds_frame_delay_on_a_congested_leg() {
    let off = congested_frames(false);
    let on = congested_frames(true);
    println!(
        "scenario 2: phone leg 150 ms RTT, 1% loss, PoP egress paced 125 KB/s; 4 x 60 fps x 600 B \
         class-1 frames + 100 KB/s bulk; 30 s"
    );
    print_frames("R5 off", &off);
    print_frames("R5 on", &on);
    assert!(on.delay.p95 < off.delay.p95 / 2.0, "latest-wins must bound frame delay");
    assert!(on.stats.dropped_superseded > 0);
}
