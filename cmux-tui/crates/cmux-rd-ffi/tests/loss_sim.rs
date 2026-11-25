//! A seeded loss simulation of one screen-share session: the host's media
//! engine and the viewer's receiver on a virtual clock, a fixed one-way delay
//! each direction and independent datagram loss. It prints the reassembly
//! stage (each frame's wait from its last shard's arrival to its release),
//! the frames lost and the keyframes forced after the first.
//!
//! `cargo test -p cmux-rd-ffi --test loss_sim -- --nocapture` prints one JSON
//! line per scenario; the assertions hold design D6's bound for the default
//! one (1% loss, 20 ms round trip, 60 fps motion).

use std::collections::{BTreeMap, HashMap};

use cmux_rd_core::flow::Rect;
use cmux_rd_engine::{EncodeRequest, Encoded, EngineConfig, MediaEngine};
use cmux_rd_ffi::{Carrier, Receiver};
use cmux_rd_proto::{DatagramHeader, DatagramKind};

/// xorshift64*: the same loss pattern on every run and every build.
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> f64 {
        self.0 ^= self.0 >> 12;
        self.0 ^= self.0 << 25;
        self.0 ^= self.0 >> 27;
        (self.0.wrapping_mul(0x2545_F491_4F6C_DD1D) >> 11) as f64 / (1u64 << 53) as f64
    }
}

#[derive(Debug, Clone, Copy)]
struct Scenario {
    loss: f64,
    rtt_us: u64,
    fps: u64,
    /// Access-unit bytes of a motion P-frame (about 13 datagrams).
    frame_bytes: usize,
    seconds: u64,
    seed: u64,
}

#[derive(Debug)]
struct Report {
    released: usize,
    p50_us: u64,
    p95_us: u64,
    p99_us: u64,
    max_us: u64,
    /// From a frame's first shard to its release (repairs included), p95 and p99.
    first_p95_us: u64,
    first_p99_us: u64,
    /// The longest gap between two released frames: the stall a person sees.
    max_stall_us: u64,
    lost: u64,
    forced_keyframes: u64,
}

enum Event {
    /// A datagram reaching the viewer.
    ToViewer(Vec<u8>),
    /// A datagram reaching the host.
    ToHost(Vec<u8>),
}

fn percentile(sorted: &[u64], p: f64) -> u64 {
    if sorted.is_empty() {
        return 0;
    }
    sorted[((p / 100.0) * (sorted.len() - 1) as f64).round() as usize]
}

fn run(s: Scenario) -> Report {
    let interval = 1_000_000 / s.fps;
    let one_way = s.rtt_us / 2;
    let mut e = MediaEngine::new(
        EngineConfig {
            width: 1920,
            height: 1080,
            max_fps: s.fps as u32,
            start_bps: 30_000_000,
            max_bps: 60_000_000,
            frames_in_flight: 6,
            ..EngineConfig::default()
        },
        0,
    );
    e.update_frames_in_flight_from_rtt(Some(s.rtt_us));
    let mut r = Receiver::new(Carrier::Datagram, 200_000, 5_000);
    let mut rng = Rng(s.seed | 1);
    // Ordered by delivery time, then by send order.
    let mut queue: BTreeMap<(u64, u64), Event> = BTreeMap::new();
    let mut seq = 0u64;
    let mut last_shard_us: HashMap<u32, u64> = HashMap::new();
    let mut first_shard_us: HashMap<u32, u64> = HashMap::new();
    let mut from_first: Vec<u64> = Vec::new();
    let mut last_release_us: Option<u64> = None;
    let mut max_stall_us = 0u64;
    let mut waits: Vec<u64> = Vec::new();
    let end = s.seconds * 1_000_000;
    let mut next_damage = 0u64;
    let mut pending: Option<EncodeRequest> = None;

    let mut send = |queue: &mut BTreeMap<(u64, u64), Event>,
                    rng: &mut Rng,
                    at: u64,
                    to_viewer: bool,
                    d: Vec<u8>| {
        if rng.next() < s.loss {
            return;
        }
        seq += 1;
        let ev = if to_viewer { Event::ToViewer(d) } else { Event::ToHost(d) };
        queue.insert((at + one_way, seq), ev);
    };

    let mut now = 0u64;
    let mut first = true;
    while now < end {
        // The next thing that happens: a delivery, a damage tick, or a timer.
        let delivery = queue.keys().next().map(|k| k.0).unwrap_or(u64::MAX);
        let viewer_timer = r.next_deadline_us().max(now);
        let host_timer = e.next_deadline_us().unwrap_or(u64::MAX).max(now);
        now = delivery.min(next_damage).min(viewer_timer).min(host_timer).min(end);
        if now >= end {
            break;
        }

        let mut host_out = Vec::new();
        if delivery == now {
            let (_, ev) = queue.pop_first().expect("a delivery");
            match ev {
                Event::ToViewer(d) => {
                    if let Ok((h, _)) = DatagramHeader::decode(&d)
                        && matches!(h.kind, DatagramKind::Video | DatagramKind::Fec)
                    {
                        last_shard_us.insert(h.frame, now);
                        first_shard_us.entry(h.frame).or_insert(now);
                    }
                    r.push_datagram(&d, now).expect("push");
                }
                Event::ToHost(d) => host_out.push(e.on_datagram(&d, true, now)),
            }
        }
        if next_damage == now {
            // Motion: the whole screen changes every frame interval.
            let full = Rect { x: 0, y: 0, width: 1920, height: 1080 };
            let req = if first { e.start(now) } else { e.damage(0, full, now) };
            first = false;
            if let Some(req) = req {
                pending = Some(req);
            }
            next_damage = now + interval;
        }
        host_out.push(e.tick(true, now));
        if let Some(req) = e.poll(now) {
            pending = Some(req);
        }
        for out in host_out {
            for d in out.datagrams {
                send(&mut queue, &mut rng, now, true, d);
            }
            if let Some(req) = out.encode {
                pending = Some(req);
            }
        }
        // The encoder answers at once; a forced keyframe is three P-frames' size.
        if let Some(req) = pending.take() {
            let idr = req.force_idr;
            let len = if idr { s.frame_bytes * 3 } else { s.frame_bytes };
            let enc = Encoded { access_unit: vec![0x5a; len], idr, t_capture_us: now };
            let out = e.encoded(&req, Some(enc), now).expect("encoded");
            for d in out.datagrams {
                send(&mut queue, &mut rng, now, true, d);
            }
        }

        r.tick(now);
        while let Some(frame) = r.pop_frame() {
            if let Some(at) = last_shard_us.get(&frame.frame) {
                waits.push(now.saturating_sub(*at));
            }
            if let Some(at) = first_shard_us.get(&frame.frame) {
                from_first.push(now.saturating_sub(*at));
            }
            if let Some(prev) = last_release_us.replace(now) {
                max_stall_us = max_stall_us.max(now - prev);
            }
        }
        while let Some(fb) = r.feedback(now) {
            send(&mut queue, &mut rng, now, false, fb);
        }
    }
    waits.sort_unstable();
    from_first.sort_unstable();
    let stats = r.stats();
    Report {
        released: waits.len(),
        p50_us: percentile(&waits, 50.0),
        p95_us: percentile(&waits, 95.0),
        p99_us: percentile(&waits, 99.0),
        max_us: waits.last().copied().unwrap_or(0),
        first_p95_us: percentile(&from_first, 95.0),
        first_p99_us: percentile(&from_first, 99.0),
        max_stall_us,
        lost: stats.frames_lost,
        forced_keyframes: e.stats().keyframes.saturating_sub(1),
    }
}

fn print(name: &str, s: Scenario, rep: &Report) {
    println!(
        "{{\"scenario\":\"{name}\",\"loss_pct\":{},\"rtt_ms\":{},\"fps\":{},\"released\":{},\
         \"shard_to_release_ms\":{{\"p50\":{:.1},\"p95\":{:.1},\"p99\":{:.1},\"max\":{:.1}}},\
         \"first_shard_to_release_ms\":{{\"p95\":{:.1},\"p99\":{:.1}}},\"max_stall_ms\":{:.1},\
         \"frames_lost\":{},\"forced_keyframes_after_first\":{}}}",
        s.loss * 100.0,
        s.rtt_us / 1000,
        s.fps,
        rep.released,
        rep.p50_us as f64 / 1e3,
        rep.p95_us as f64 / 1e3,
        rep.p99_us as f64 / 1e3,
        rep.max_us as f64 / 1e3,
        rep.first_p95_us as f64 / 1e3,
        rep.first_p99_us as f64 / 1e3,
        rep.max_stall_us as f64 / 1e3,
        rep.lost,
        rep.forced_keyframes,
    );
}

const DEFAULT: Scenario = Scenario {
    loss: 0.01,
    rtt_us: 20_000,
    fps: 60,
    frame_bytes: 15_000,
    seconds: 60,
    seed: 0x5eed_cafe,
};

#[test]
fn one_percent_loss_costs_at_most_one_round_trip_plus_ten_ms() {
    let rep = run(DEFAULT);
    print("lan-1pct", DEFAULT, &rep);
    assert!(rep.released > 3_000, "the session kept streaming: {rep:?}");
    assert!(
        rep.p95_us <= DEFAULT.rtt_us + 10_000,
        "reassembly p95 {} us over RTT + 10 ms: {rep:?}",
        rep.p95_us
    );
}

#[test]
fn loss_sweep() {
    for (name, loss, rtt_us) in [
        ("lan-0pct", 0.0, 20_000),
        ("lan-3pct", 0.03, 20_000),
        ("near-1pct", 0.01, 5_000),
        ("wan-1pct", 0.01, 80_000),
        ("far-1pct", 0.01, 150_000),
    ] {
        let s = Scenario { loss, rtt_us, ..DEFAULT };
        print(name, s, &run(s));
    }
}
