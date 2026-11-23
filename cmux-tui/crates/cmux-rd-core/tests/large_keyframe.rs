//! A 1080p motion keyframe from a Linux host (0.5 MB, about 500 datagrams) through a
//! drop-tail bottleneck slower than the controller's target, into the viewer's
//! reassembler (hq#19915: huge-blue to air-blue showed 3 fps with 20 % loss, and none
//! at 6 Mbit/s). Run with `--nocapture` for the numbers.

use cmux_rd_core::pacer::Pacer;
use cmux_rd_core::packetize::Packetizer;
use cmux_rd_core::reassembly::Reassembler;
use cmux_rd_proto::{DatagramHeader, FrameBody, REF_NONE, flags};

const MTU: usize = 1152;
const DEADLINE_US: u64 = 200_000;

/// A link of `capacity_bps` with a drop-tail queue of `buffer_us` at that rate.
struct Bottleneck {
    bytes_per_us: f64,
    buffer_bytes: f64,
    free_at: f64,
}

impl Bottleneck {
    fn new(capacity_bps: f64, buffer_us: f64) -> Self {
        let bytes_per_us = capacity_bps / 8.0 / 1e6;
        Self { bytes_per_us, buffer_bytes: bytes_per_us * buffer_us, free_at: 0.0 }
    }

    /// When the datagram leaves the link, or `None` when the queue drops it.
    fn offer(&mut self, at_us: u64, bytes: usize) -> Option<u64> {
        let at = at_us as f64;
        let queued = (self.free_at - at).max(0.0) * self.bytes_per_us;
        if queued + bytes as f64 > self.buffer_bytes {
            return None;
        }
        self.free_at = self.free_at.max(at) + bytes as f64 / self.bytes_per_us;
        Some(self.free_at.ceil() as u64)
    }
}

struct Run {
    sent: usize,
    dropped: usize,
    /// When the keyframe was released to the decoder, from its first send.
    released_us: Option<u64>,
}

/// One keyframe of `bytes` paced at `target_bps` through `link` (or, `old`, spread
/// evenly over 8 ms as the uncapped pacer sent it); no repairs, so the keyframe is
/// shown only if every datagram arrives and the deadline allows it.
fn send_keyframe(bytes: usize, target_bps: u64, mut link: Bottleneck, old: bool) -> Run {
    let mut packetizer = Packetizer::new(0, MTU);
    let body = FrameBody { t_capture_us: 0, ref_frame: REF_NONE, access_unit: vec![7; bytes] };
    let frame = packetizer.packetize(1, flags::KEYFRAME, &body, 0).expect("packetize");
    let mut pacer = Pacer::new();
    if !old {
        pacer.push_frame(frame.datagrams.clone(), target_bps, 33_333, 0);
    }
    let mut arrivals = Vec::new();
    let (mut sent, mut dropped) = (0, 0);
    let mut now = 0;
    if old {
        let n = frame.datagrams.len() as u64;
        for (i, d) in frame.datagrams.into_iter().enumerate() {
            sent += 1;
            match link.offer(i as u64 * 8_000 / n, d.len()) {
                Some(at) => arrivals.push((at, d)),
                None => dropped += 1,
            }
        }
    }
    loop {
        for d in pacer.due(now) {
            sent += 1;
            match link.offer(now, d.len()) {
                Some(at) => arrivals.push((at, d)),
                None => dropped += 1,
            }
        }
        match pacer.next_deadline_us() {
            Some(t) => now = t.max(now + 1),
            None => break,
        }
    }
    let mut viewer = Reassembler::new(DEADLINE_US);
    let mut released_us = None;
    for (at, d) in &arrivals {
        let (h, payload) = DatagramHeader::decode(d).expect("decode");
        if viewer.push(&h, payload, *at).iter().any(|f| f.frame == 1) {
            released_us = Some(*at);
        }
    }
    Run { sent, dropped, released_us }
}

/// The real pair's numbers: a 0.5 MB keyframe, a 19 Mbit/s target and a path that
/// delivered under 8 Mbit/s, here with a 100 ms queue. A path that much slower than the
/// target drops part of any keyframe (NACKs repair it, now inside the deadline); the
/// capped pacer only has to lose less of it than the 8 ms burst did.
#[test]
fn a_motion_keyframe_loses_less_through_a_slow_bottleneck() {
    let link = || Bottleneck::new(8e6, 100_000.0);
    let old = send_keyframe(500_000, 19_000_000, link(), true);
    let new = send_keyframe(500_000, 19_000_000, link(), false);
    println!(
        "19 Mbit/s target, 8 Mbit/s path: 8 ms burst lost {} of {}, paced lost {} of {}",
        old.dropped, old.sent, new.dropped, new.sent
    );
    assert_eq!(old.sent, new.sent);
    assert!(new.dropped < old.dropped, "paced {} vs burst {}", new.dropped, old.dropped);
}

/// A target the path can carry (the controller has converged): the keyframe arrives
/// whole and is released, though its last shard lands well after 200 ms.
#[test]
fn a_keyframe_longer_than_the_deadline_to_arrive_is_released() {
    // 6 Mbit/s target and path (the pair's capped run), a 0.5 MB keyframe: 670 ms of wire.
    let run = send_keyframe(500_000, 6_000_000, Bottleneck::new(6e6, 1_000_000.0), false);
    println!(
        "6 Mbit/s: {} of {} lost, released at {:?} us",
        run.dropped, run.sent, run.released_us
    );
    assert_eq!(run.dropped, 0);
    let released = run.released_us.expect("the keyframe is shown");
    assert!(released > DEADLINE_US, "it took longer than one deadline to arrive: {released}");
}
