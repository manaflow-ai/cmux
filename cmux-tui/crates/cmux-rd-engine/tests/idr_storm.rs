//! The keyframe storm on loss: a loss costs a keyframe only when NACK repair
//! (or a keyframe already on its way) cannot recover it, loss keyframes are
//! at least 250 ms apart, and their size is bounded. Measured before this on
//! a Mac pair: every loss made the viewer ask for an IDR, 13 to 39 IDRs per
//! 10 s and about 0 fps at every pinned rate from 20 to 150 Mbps.
//!
//! The simulation runs the real engine against the real reassembler on a
//! virtual clock with seeded loss, so every run is the same.

use std::collections::VecDeque;

use cmux_rd_core::flow::Rect;
use cmux_rd_core::reassembly::Reassembler;
use cmux_rd_engine::{
    EncodeRequest, Encoded, EngineConfig, IdrHold, IdrReason, MIN_FORCED_IDR_INTERVAL_US,
    MediaEngine, Output,
};
use cmux_rd_proto::{Arrival, DatagramHeader, DatagramKind, Feedback, MAX_ARRIVALS};

fn engine(rtt_us: u64) -> MediaEngine {
    let mut e = MediaEngine::new(
        EngineConfig {
            width: 1920,
            height: 1080,
            max_fps: 60,
            start_bps: 20_000_000,
            max_bps: 20_000_000,
            ..EngineConfig::default()
        },
        0,
    );
    e.update_frames_in_flight_from_rtt(Some(rtt_us));
    e
}

fn feedback(fb: &Feedback) -> Vec<u8> {
    let mut d = DatagramHeader {
        flags: 0,
        kind: DatagramKind::Feedback,
        stream: 0,
        frame: 0,
        index: 0,
        count: 0,
        fec_count: 0,
        transport_seq: 0,
    }
    .encode()
    .to_vec();
    d.extend_from_slice(&fb.encode());
    d
}

fn send(e: &mut MediaEngine, req: &EncodeRequest, len: usize, now: u64) -> Vec<Vec<u8>> {
    let au = vec![0x5a; len];
    e.encoded(req, Some(Encoded { access_unit: au, idr: req.force_idr, t_capture_us: now }), now)
        .expect("encoded")
        .datagrams
}

/// A start keyframe the viewer acknowledged, then a P-frame it lost.
fn after_a_loss(rtt_us: u64) -> MediaEngine {
    let mut e = engine(rtt_us);
    let first = e.start(0).expect("first");
    send(&mut e, &first, 60_000, 0);
    e.on_datagram(
        &feedback(&Feedback { acked_frame: first.frame, ..Feedback::default() }),
        true,
        0,
    );
    let small = Rect { x: 0, y: 0, width: 64, height: 64 };
    let p = e.damage(0, small, 20_000).expect("a P-frame");
    send(&mut e, &p, 15_000, 20_000);
    e
}

fn ask(acked_frame: u32) -> Vec<u8> {
    feedback(&Feedback { acked_frame, need_recovery: true, ..Feedback::default() })
}

/// A recovery keyframe on a 150 ms path is still arriving or being repaired
/// 260 ms later; the viewer's requests sent meanwhile do not cost a second
/// one. Once its repair window (200 ms + RTT) passes unacknowledged it is
/// lost, and the next request gets a keyframe.
#[test]
fn a_recovery_request_waits_while_the_last_keyframe_can_still_be_repaired() {
    let rtt = 150_000;
    let mut e = after_a_loss(rtt);
    let idr = e.on_datagram(&ask(1), true, 300_000).encode.expect("recovery");
    assert_eq!(idr.idr_reason, Some(IdrReason::Recovery));
    send(&mut e, &idr, 60_000, 300_000);

    let out = e.on_datagram(&ask(1), true, 560_000);
    assert!(out.encode.is_none_or(|r| !r.force_idr), "a second keyframe while the first repairs");
    assert_eq!(out.idr_held, Some((0, IdrHold::Repairing { frame: idr.frame })));

    let out = e.on_datagram(&ask(1), true, 300_000 + 200_000 + rtt);
    let again = out.encode.expect("the keyframe was lost: recover again");
    assert_eq!(again.idr_reason, Some(IdrReason::Recovery));
    assert_eq!(e.idr_holds(0), 1);
}

/// An acknowledged keyframe ends the hold: a loss after it is a new loss,
/// answered as soon as the 250 ms spacing allows.
#[test]
fn a_new_loss_after_the_keyframe_is_acknowledged_is_answered_after_the_spacing() {
    let mut e = after_a_loss(20_000);
    let idr = e.on_datagram(&ask(1), true, 300_000).encode.expect("recovery");
    send(&mut e, &idr, 60_000, 300_000);
    let out = e.on_datagram(&ask(idr.frame), true, 400_000);
    assert_eq!(out.idr_held, Some((0, IdrHold::Spacing)));
    let out = e.on_datagram(&ask(idr.frame), true, 300_000 + MIN_FORCED_IDR_INTERVAL_US);
    assert!(out.encode.expect("recovery").force_idr);
}

/// A loss keyframe that came out larger than 100 ms of the target makes the
/// next one ask the encoder for a lower rate; P-frames keep the full target.
#[test]
fn a_loss_keyframe_larger_than_its_budget_bounds_the_next_ones_rate() {
    let mut e = after_a_loss(20_000);
    let idr = e.on_datagram(&ask(1), true, 300_000).encode.expect("recovery");
    let target = idr.target_kbps;
    // 100 ms at the target, twice over.
    let budget = target as usize * 100 / 8;
    send(&mut e, &idr, 2 * budget, 300_000);
    let next = e.on_datagram(&ask(1), true, 700_000).encode.expect("recovery");
    assert!(next.force_idr);
    // Twice the budget: about half the rate (the target itself may move a little).
    assert!(
        next.target_kbps > target * 4 / 10 && next.target_kbps < target * 6 / 10,
        "asked at {} kbps, want about {}",
        next.target_kbps,
        target / 2
    );
    send(&mut e, &next, 15_000, 700_000);
    e.on_datagram(
        &feedback(&Feedback { acked_frame: next.frame, ..Feedback::default() }),
        true,
        710_000,
    );
    let small = Rect { x: 0, y: 0, width: 64, height: 64 };
    let p = e.damage(0, small, 720_000).expect("a P-frame");
    assert!(!p.force_idr);
    assert!(p.target_kbps > next.target_kbps, "a P-frame asks for the full target");
}

/// A path between the engine and one viewer reassembler, 1 ms steps.
struct Sim {
    host: MediaEngine,
    viewer: Reassembler,
    one_way_us: u64,
    to_viewer: VecDeque<(u64, Vec<u8>)>,
    to_host: VecDeque<(u64, Vec<u8>)>,
    arrivals: Vec<Arrival>,
    released_since_feedback: bool,
    last_feedback_us: u64,
    /// Seen (frame, index, kind) of every datagram, to tell a repair from a first copy.
    seen: std::collections::HashSet<(u32, u16, bool)>,
    /// Frames the path drops whole, repairs too (decided at their first datagram).
    dropped_frames: std::collections::HashMap<u32, bool>,
    rng: u64,
    /// Every keyframe the engine asked for: (time, reason).
    idrs: Vec<(u64, Option<IdrReason>)>,
    holds: Vec<(u64, IdrHold)>,
    released: u64,
}

#[derive(Clone, Copy)]
enum Loss {
    /// First copies are lost with this probability; NACK repairs always arrive.
    Repairable(f64),
    /// Each frame is lost whole with this probability, every copy and repair
    /// of it: no NACK or parity can bring it back.
    Sustained(f64),
}

impl Sim {
    fn new(rtt_us: u64) -> Self {
        Self {
            host: engine(rtt_us),
            viewer: Reassembler::new(200_000),
            one_way_us: rtt_us / 2,
            to_viewer: VecDeque::new(),
            to_host: VecDeque::new(),
            arrivals: Vec::new(),
            released_since_feedback: false,
            last_feedback_us: 0,
            seen: Default::default(),
            dropped_frames: Default::default(),
            rng: 0x2545_f491_4f6c_dd1d,
            idrs: Vec::new(),
            holds: Vec::new(),
            released: 0,
        }
    }

    fn chance(&mut self) -> f64 {
        // xorshift64: deterministic.
        self.rng ^= self.rng << 13;
        self.rng ^= self.rng >> 7;
        self.rng ^= self.rng << 17;
        (self.rng >> 11) as f64 / (1u64 << 53) as f64
    }

    fn handle(&mut self, out: Output, now: u64, loss: Loss) {
        if let Some((_, hold)) = out.idr_held {
            self.holds.push((now, hold));
        }
        for d in out.datagrams {
            self.transmit(d, now, loss);
        }
        if let Some(req) = out.encode {
            self.encode(&req, now, loss);
        }
    }

    fn transmit(&mut self, d: Vec<u8>, now: u64, loss: Loss) {
        let Ok((h, _)) = DatagramHeader::decode(&d) else { return };
        let media = matches!(h.kind, DatagramKind::Video | DatagramKind::Fec);
        let first = !media || self.seen.insert((h.frame, h.index, h.kind == DatagramKind::Fec));
        let lost = media
            && match loss {
                Loss::Repairable(p) => first && self.chance() < p,
                Loss::Sustained(p) => {
                    let roll = self.chance() < p;
                    *self.dropped_frames.entry(h.frame).or_insert(roll)
                }
            };
        if !lost {
            self.to_viewer.push_back((now + self.one_way_us, d));
        }
    }

    fn encode(&mut self, req: &EncodeRequest, now: u64, loss: Loss) {
        // A P-frame of 15 KB; a keyframe of 3 bytes per asked kbps (60 KB at
        // 20 Mbps), so a lower asked rate gives a smaller keyframe.
        let len = if req.force_idr { req.target_kbps as usize * 3 } else { 15_000 };
        if req.force_idr {
            assert!(req.idr_reason.is_some(), "every keyframe the engine asks for has a reason");
            self.idrs.push((now, req.idr_reason));
        }
        let au = vec![0x5a; len];
        let enc = Encoded { access_unit: au, idr: req.force_idr, t_capture_us: now };
        let out = self.host.encoded(req, Some(enc), now).expect("packetize");
        self.handle(out, now, loss);
    }

    fn viewer_step(&mut self, now: u64) {
        while self.to_viewer.front().is_some_and(|(at, _)| *at <= now) {
            let (_, d) = self.to_viewer.pop_front().expect("front");
            let (h, payload) = DatagramHeader::decode(&d).expect("header");
            self.arrivals.push(Arrival { transport_seq: h.transport_seq, arrival_us: now as u32 });
            let released = self.viewer.push(&h, payload, now);
            self.released += released.len() as u64;
            self.released_since_feedback |= !released.is_empty();
        }
        let released = self.viewer.tick(now);
        self.released += released.len() as u64;
        self.released_since_feedback |= !released.is_empty();
        let nack_due =
            self.viewer.next_nack_us(5_000, 50_000).is_some_and(|deadline| now >= deadline);
        let interval = now.saturating_sub(self.last_feedback_us) >= 50_000;
        if !(self.released_since_feedback || nack_due || interval) {
            return;
        }
        self.released_since_feedback = false;
        self.last_feedback_us = now;
        let take = self.arrivals.len().min(MAX_ARRIVALS);
        let fb = Feedback {
            acked_frame: self.viewer.last_released(),
            decode_us: 0,
            need_recovery: self.viewer.need_recovery(),
            arrivals: self.arrivals.drain(..take).collect(),
            nacks: self.viewer.take_nacks(now, 5_000, 50_000),
        };
        self.to_host.push_back((now + self.one_way_us, feedback(&fb)));
    }

    /// Ten seconds of full-screen motion at 60 fps.
    fn run(&mut self, loss: Loss) {
        let full = Rect { x: 0, y: 0, width: 1920, height: 1080 };
        if let Some(req) = self.host.start(0) {
            self.encode(&req, 0, loss);
        }
        let mut next_damage = 16_667;
        for ms in 1..=10_000u64 {
            let now = ms * 1000;
            while self.to_host.front().is_some_and(|(at, _)| *at <= now) {
                let (_, d) = self.to_host.pop_front().expect("front");
                let out = self.host.on_datagram(&d, true, now);
                self.handle(out, now, loss);
            }
            let out = self.host.tick(true, now);
            self.handle(out, now, loss);
            if now >= next_damage {
                next_damage += 16_667;
                if let Some(req) = self.host.damage(0, full, now) {
                    self.encode(&req, now, loss);
                }
            }
            if let Some(req) = self.host.poll(now) {
                self.encode(&req, now, loss);
            }
            self.viewer_step(now);
        }
    }

    fn loss_idrs(&self) -> Vec<(u64, Option<IdrReason>)> {
        self.idrs.iter().copied().filter(|(_, r)| r.is_some_and(IdrReason::is_loss)).collect()
    }
}

/// Every lost shard can be NACK-repaired: ten seconds of motion at 5% loss
/// on a 20 ms path and at 3% on a 150 ms path cost no keyframe after the
/// first, and frames keep flowing.
#[test]
fn a_loss_stream_that_nack_repairs_costs_zero_keyframes() {
    for (rtt, p) in [(20_000, 0.05), (150_000, 0.03)] {
        let mut sim = Sim::new(rtt);
        sim.run(Loss::Repairable(p));
        assert_eq!(sim.idrs.len(), 1, "rtt {rtt} us, {p} loss: keyframes {:?}", sim.idrs);
        assert_eq!(sim.idrs[0].1, Some(IdrReason::Start));
        assert!(sim.released > 300, "rtt {rtt} us: only {} frames released", sim.released);
    }
}

/// Loss NACK cannot repair (5% of frames lost whole, repairs too): keyframes
/// still recover the stream, but two loss keyframes are never closer than
/// 250 ms, each says why, and the gate's holds are what kept them apart.
#[test]
fn sustained_unrecoverable_loss_spaces_keyframes_at_least_250_ms_apart() {
    for rtt in [20_000, 150_000] {
        let mut sim = Sim::new(rtt);
        sim.run(Loss::Sustained(0.05));
        let idrs = sim.loss_idrs();
        assert!(
            idrs.len() >= 2,
            "rtt {rtt} us: the loss needs keyframes: {:?}, released {}, holds {:?}, frames {}",
            sim.idrs,
            sim.released,
            &sim.holds[..sim.holds.len().min(5)],
            sim.host.stats().frames
        );
        for pair in idrs.windows(2) {
            let gap = pair[1].0 - pair[0].0;
            assert!(
                gap >= MIN_FORCED_IDR_INTERVAL_US,
                "rtt {rtt} us: keyframes {gap} us apart: {:?}",
                sim.idrs
            );
        }
        // At most one loss keyframe per 250 ms of the run.
        assert!(idrs.len() <= 40, "rtt {rtt} us: {} loss keyframes", idrs.len());
        assert!(!sim.holds.is_empty(), "rtt {rtt} us: the gate never had to hold");
    }
}
