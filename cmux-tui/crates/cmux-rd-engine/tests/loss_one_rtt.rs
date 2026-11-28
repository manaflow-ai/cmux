//! Design D6, part P3: loss costs one round trip. A simulated LAN (1 ms round
//! trip) carries the host engine, its pacer and a viewer reassembler that
//! sends feedback the way `cmux-rd-ffi`'s `Receiver` does: at once when a frame
//! is released or a NACK is due, else every 50 ms. A frame that loses one
//! datagram must be released within RTT + 10 ms of its last datagram leaving.

use std::collections::{BTreeMap, HashSet};

use cmux_rd_core::flow::Rect;
use cmux_rd_core::pacer::Pacer;
use cmux_rd_core::reassembly::Reassembler;
use cmux_rd_engine::{EncodeRequest, Encoded, EngineConfig, MediaEngine, Output, TAIL_PROBE_US};
use cmux_rd_proto::{Arrival, DatagramHeader, DatagramKind, Feedback, HEADER_LEN, MAX_ARRIVALS};

const ONE_WAY_US: u64 = 500;
const RTT_US: u64 = 2 * ONE_WAY_US;
const STEP_US: u64 = 100;
const FRAME_INTERVAL_US: u64 = 16_667;
/// The viewer's `nack_after_us` and feedback interval (cmux-rd-ffi `Receiver`).
const NACK_AFTER_US: u64 = 5_000;
const FEEDBACK_INTERVAL_US: u64 = 50_000;

struct Sim {
    engine: MediaEngine,
    pacer: Pacer,
    viewer: Reassembler,
    /// Datagrams on the wire: (arrival time, bytes).
    down: Vec<(u64, Vec<u8>)>,
    up: Vec<(u64, Vec<u8>)>,
    /// (frame, index) the path loses on its first transmission.
    drops: HashSet<(u32, u16)>,
    sent: HashSet<(u32, u16)>,
    /// When each frame's last datagram first left.
    departed: BTreeMap<u32, u64>,
    released: BTreeMap<u32, u64>,
    arrivals: Vec<Arrival>,
    last_feedback_us: u64,
    released_since_feedback: bool,
    next_len: usize,
    encoded: Vec<(u64, u32)>,
}

impl Sim {
    fn new(rtt_tail_probe: bool) -> Self {
        let cfg = EngineConfig {
            width: 1280,
            height: 720,
            max_fps: 60,
            rtt_tail_probe,
            ..EngineConfig::default()
        };
        Self {
            engine: MediaEngine::new(cfg, 0),
            pacer: Pacer::new(),
            viewer: Reassembler::new(200_000),
            down: Vec::new(),
            up: Vec::new(),
            drops: HashSet::new(),
            sent: HashSet::new(),
            departed: BTreeMap::new(),
            released: BTreeMap::new(),
            arrivals: Vec::new(),
            last_feedback_us: 0,
            released_since_feedback: false,
            next_len: 3_000,
            encoded: Vec::new(),
        }
    }

    fn encode(&mut self, req: &EncodeRequest, now: u64) {
        let enc = Encoded {
            access_unit: vec![0x5a; self.next_len],
            idr: req.force_idr,
            t_capture_us: now,
            ltr_token: None,
        };
        let out = self.engine.encoded(req, Some(enc), now).expect("packetize");
        self.encoded.push((now, req.frame));
        self.pacer.push_frame(out.datagrams, self.engine.target_bps(), FRAME_INTERVAL_US, now);
    }

    fn host_output(&mut self, out: Output, now: u64) {
        self.pacer.push_repair(out.datagrams, self.engine.target_bps(), now);
        if let Some(req) = out.encode {
            self.encode(&req, now);
        }
    }

    fn damage(&mut self, len: usize, now: u64) {
        self.next_len = len;
        let rect = Rect { x: 0, y: 0, width: 64, height: 64 };
        if let Some(req) = self.engine.damage(0, rect, now) {
            self.encode(&req, now);
        }
    }

    fn step(&mut self, now: u64) {
        // Host: feedback in, timers, then what the pacer lets out.
        let (due, rest): (Vec<_>, Vec<_>) = self.up.drain(..).partition(|(at, _)| *at <= now);
        self.up = rest;
        for (_, d) in due {
            let out = self.engine.on_datagram(&d, true, now);
            self.host_output(out, now);
        }
        let out = self.engine.tick(true, now);
        self.host_output(out, now);
        if let Some(req) = self.engine.poll(now) {
            self.encode(&req, now);
        }
        for d in self.pacer.due(now) {
            self.engine.datagram_sent(&d, now);
            let (h, _) = DatagramHeader::decode(&d).expect("header");
            let first = self.sent.insert((h.frame, h.index));
            if first {
                self.departed.insert(h.frame, now);
            }
            if first && self.drops.contains(&(h.frame, h.index)) {
                continue;
            }
            self.down.push((now + ONE_WAY_US, d));
        }
        // Viewer: datagrams in, then feedback when the Receiver would send it.
        let (due, rest): (Vec<_>, Vec<_>) = self.down.drain(..).partition(|(at, _)| *at <= now);
        self.down = rest;
        let mut released = Vec::new();
        for (_, d) in due {
            let (h, payload) = DatagramHeader::decode(&d).expect("header");
            if !matches!(h.kind, DatagramKind::Video | DatagramKind::Fec) {
                continue;
            }
            self.arrivals.push(Arrival { transport_seq: h.transport_seq, arrival_us: now as u32 });
            released.extend(self.viewer.push(&h, payload, now));
        }
        released.extend(self.viewer.tick(now));
        for f in released {
            self.released.entry(f.frame).or_insert(now);
            self.released_since_feedback = true;
        }
        let nack_due = self
            .viewer
            .next_nack_us(NACK_AFTER_US, FEEDBACK_INTERVAL_US)
            .is_some_and(|at| now >= at);
        let interval = now.saturating_sub(self.last_feedback_us) >= FEEDBACK_INTERVAL_US
            && !self.arrivals.is_empty();
        if self.released_since_feedback || nack_due || interval {
            let take = self.arrivals.len().min(MAX_ARRIVALS);
            let fb = Feedback {
                acked_frame: self.viewer.last_released(),
                decode_us: 0,
                need_recovery: self.viewer.need_recovery(),
                acked_ltr_tokens: Vec::new(),
                arrivals: self.arrivals.drain(..take).collect(),
                nacks: self.viewer.take_nacks(now, NACK_AFTER_US, FEEDBACK_INTERVAL_US),
            };
            let mut d = Vec::with_capacity(HEADER_LEN + 64);
            DatagramHeader {
                flags: 0,
                kind: DatagramKind::Feedback,
                stream: 0,
                frame: 0,
                index: 0,
                count: 0,
                fec_count: 0,
                transport_seq: 0,
            }
            .encode_into(&mut d);
            d.extend_from_slice(&fb.encode());
            self.up.push((now + ONE_WAY_US, d));
            self.last_feedback_us = now;
            self.released_since_feedback = false;
        }
    }

    fn run(&mut self, from: u64, until: u64) {
        let mut now = from;
        while now < until {
            self.step(now);
            now += STEP_US;
        }
    }

    /// Ten clean frames, so the engine has round-trip samples. Returns the time after them.
    fn warm_up(&mut self) -> u64 {
        let mut now = 0;
        self.next_len = 20_000;
        let first = self.engine.start(now).expect("first frame");
        self.encode(&first, now);
        for _ in 0..10 {
            self.run(now, now + FRAME_INTERVAL_US);
            now += FRAME_INTERVAL_US;
            self.damage(3_000, now);
        }
        self.run(now, now + 4 * FRAME_INTERVAL_US);
        now += 4 * FRAME_INTERVAL_US;
        assert!(self.released.len() >= 10, "warm-up frames all arrive: {:?}", self.released);
        now
    }

    /// Sends one frame of `len` bytes at `now`, losing the first copy of each index
    /// `drop` picks, and returns how long after its last datagram left it was released.
    fn lose(&mut self, now: u64, len: usize, drop: impl Fn(u16) -> Vec<u16>) -> u64 {
        let frame = self.encoded.last().expect("a frame went out").1 + 1;
        let probe = cmux_rd_core::packetize::Packetizer::new(0, cmux_rd_proto::MAX_DATAGRAM_VPC);
        let shards = len.div_ceil(probe.shard_len()) as u16;
        for i in drop(shards) {
            self.drops.insert((frame, i));
        }
        self.damage(len, now);
        assert_eq!(self.encoded.last().map(|e| e.1), Some(frame), "the frame went out at once");
        self.run(now, now + 600_000);
        let released = *self.released.get(&frame).expect("the frame is released");
        let departed = self.departed[&frame];
        released.saturating_sub(departed)
    }
}

const TARGET_US: u64 = RTT_US + 10_000;

#[test]
fn one_lost_datagram_mid_frame_costs_one_round_trip() {
    let mut sim = Sim::new(false);
    let now = sim.warm_up();
    let waited = sim.lose(now, 150_000, |n| vec![n / 2]);
    eprintln!("released {waited} us after the last datagram left");
    assert!(waited <= TARGET_US, "released {waited} us after the last datagram left");
}

/// The fleet's 52 ms case: the frame's first NACK goes out before a later gap is
/// seen; the later gap must not wait for the 50 ms retry of the first request.
#[test]
fn a_late_gap_after_the_frames_first_nack_costs_one_round_trip() {
    let mut sim = Sim::new(false);
    let now = sim.warm_up();
    let waited = sim.lose(now, 150_000, |n| vec![1, n - 2]);
    eprintln!("released {waited} us after the last datagram left");
    assert!(waited <= TARGET_US, "released {waited} us after the last datagram left");
}

/// A one-datagram frame without parity leaves the viewer nothing to NACK: only the
/// host's tail probe recovers it. With `rtt_tail_probe` the probe waits a round
/// trip; without it (the default) it still waits the fixed `TAIL_PROBE_US`.
#[test]
fn a_lost_one_datagram_frame_costs_one_round_trip_with_the_rtt_tail_probe() {
    let mut sim = Sim::new(true);
    let now = sim.warm_up();
    let waited = sim.lose(now, 300, |_| vec![0]);
    eprintln!("rtt probe: released {waited} us after the datagram left");
    assert!(waited <= TARGET_US, "released {waited} us after the datagram left");

    let mut sim = Sim::new(false);
    let now = sim.warm_up();
    let waited = sim.lose(now, 300, |_| vec![0]);
    assert!(
        (TAIL_PROBE_US..TAIL_PROBE_US + TARGET_US).contains(&waited),
        "the default probe still waits {TAIL_PROBE_US} us: released after {waited} us"
    );
}

/// The RTT probe backs off when its probes are lost too, and still ends in a
/// keyframe no sooner than the fixed schedule does.
#[test]
fn rtt_tail_probes_back_off_and_the_keyframe_keeps_its_time() {
    let mut sim = Sim::new(true);
    let now = sim.warm_up();
    let frame = sim.encoded.last().expect("frame").1 + 1;
    sim.next_len = 300;
    let rect = Rect { x: 0, y: 0, width: 8, height: 8 };
    let req = sim.engine.damage(0, rect, now).expect("encode");
    let enc = Encoded { access_unit: vec![1; 300], idr: false, t_capture_us: now, ltr_token: None };
    let out = sim.engine.encoded(&req, Some(enc), now).expect("packetize");
    assert_eq!(out.datagrams.len(), 1);
    sim.engine.datagram_sent(&out.datagrams[0], now);
    // Nothing reaches the viewer: every probe is lost too.
    let mut probes = Vec::new();
    let mut t = now;
    let idr_at = loop {
        t += STEP_US;
        let out = sim.engine.tick(true, t);
        for d in &out.datagrams {
            assert_eq!(DatagramHeader::decode(d).expect("header").0.frame, frame);
            sim.engine.datagram_sent(d, t);
            probes.push(t - now);
        }
        if let Some(req) = out.encode {
            assert!(req.force_idr);
            break t - now;
        }
        assert!(t - now < 2_000_000, "no keyframe");
    };
    assert!(probes[0] <= 10_000, "the first probe waits a round trip: {probes:?}");
    let gaps: Vec<u64> = probes.windows(2).map(|w| w[1] - w[0]).collect();
    assert!(gaps.windows(2).all(|g| g[1] >= g[0]), "probes back off: {probes:?}");
    assert!(gaps.iter().all(|&g| g <= TAIL_PROBE_US), "no wait over {TAIL_PROBE_US}: {probes:?}");
    let give_up = TAIL_PROBE_US * (u64::from(cmux_rd_engine::TAIL_PROBES) + 1);
    assert!((give_up..give_up + STEP_US).contains(&idr_at), "keyframe at {idr_at} us");
}
