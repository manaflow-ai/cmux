//! Piece 2 of cmuxterm-hq docs/design/screen-share-under-100ms.md, goal
//! `screen-share-rate-control`: "Send stage p50 at most 8 ms at any rate and at
//! least 15 Mbps within 1 s of motion on the LAN pair with no fall to the floor".
//!
//! The controller and the pacer over a simulated link (the same model as
//! `outage.rs`): datagrams queue at the bottleneck and leave at its rate, the
//! viewer reports arrivals every 50 ms, and the host encodes a new frame only
//! while fewer than two are unacknowledged. Each scenario prints what the goal
//! reads (seconds from motion to a 15 Mbps target, the lowest target after it,
//! send p50 and p95 per frame) so the record's ceiling has a measured number
//! beside each derived one, and asserts the goal's bounds where the design says
//! they must hold.

use cmux_rd_core::cc::{CcConfig, CongestionController, PathKind};
use cmux_rd_core::pacer::Pacer;
use cmux_rd_proto::Arrival;
use std::collections::VecDeque;

const MTU: usize = 1152;
const STEP_US: u64 = 100;
const FEEDBACK_US: u64 = 50_000;
const SAMPLE_US: u64 = 10_000;
const FRAMES_IN_FLIGHT: u32 = 2;
const GOAL_BPS: u64 = 15_000_000;
const FLOOR_BPS: u64 = 1_000_000;

struct Rng(u64);
impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }
    fn uniform(&mut self) -> f64 {
        (self.next() % 1_000_000) as f64 / 1e6
    }
}

#[derive(Clone, Copy)]
struct Link {
    capacity_bps: f64,
    /// One way.
    base_us: u64,
    /// Extra one-way delay, uniform in [0, jitter_us), per datagram (a radio's
    /// contention, not a queue).
    jitter_us: f64,
}

/// What the screen does: no frames (idle), a small cursor-sized frame, or
/// motion that fills the target (`rate / fps` bytes a frame) times `fill`.
#[derive(Clone, Copy)]
enum Scene {
    Idle,
    Cursor,
    Motion { fill: f64 },
}

struct Sim {
    cc: CongestionController,
    pacer: Pacer,
    rng: Rng,
    now: u64,
    seq: u16,
    queue_free_at: f64,
    in_flight: Vec<(u64, u16, u32)>,
    returning: VecDeque<(u64, Vec<Arrival>, u32)>,
    viewer_newest: u32,
    acked: u32,
    frame: u32,
    fps: u64,
    next_frame: u64,
    next_feedback: u64,
    /// (frame, pushed at, last datagram handed off at)
    sends: Vec<(u32, u64, Option<u64>)>,
    targets: Vec<(u64, u64)>,
    next_sample: u64,
}

impl Sim {
    fn new(path: PathKind, rtt_us: u64, fps: u64) -> Self {
        let mut cc = CongestionController::new(CcConfig::default(), path);
        cc.on_rtt(rtt_us);
        Self {
            cc,
            pacer: Pacer::new(),
            rng: Rng(0x2026_1121_0bad_f00d),
            now: 0,
            seq: 0,
            queue_free_at: 0.0,
            in_flight: Vec::new(),
            returning: VecDeque::new(),
            viewer_newest: 0,
            acked: 0,
            frame: 0,
            fps,
            next_frame: 0,
            next_feedback: FEEDBACK_US,
            sends: Vec::new(),
            targets: Vec::new(),
            next_sample: 0,
        }
    }

    fn run(&mut self, link: Link, scene: Scene, until_us: u64) {
        let interval = 1_000_000 / self.fps;
        while self.now < until_us {
            if self.now >= self.next_frame {
                self.next_frame += interval;
                let bytes = match scene {
                    Scene::Idle => 0,
                    Scene::Cursor => 600,
                    Scene::Motion { fill } => {
                        (self.cc.target_bps() as f64 / 8.0 / self.fps as f64 * fill) as usize
                    }
                };
                if bytes > 0 && self.frame - self.acked < FRAMES_IN_FLIGHT {
                    self.frame += 1;
                    let n = bytes.div_ceil(MTU).max(1);
                    let frame: Vec<Vec<u8>> = (0..n)
                        .map(|_| {
                            let mut d = vec![0; MTU.min(bytes.max(16))];
                            d[..4].copy_from_slice(&self.frame.to_le_bytes());
                            d
                        })
                        .collect();
                    self.sends.push((self.frame, self.now, None));
                    self.pacer.push_frame(frame, self.cc.target_bps(), interval, self.now);
                }
            }
            for d in self.pacer.due(self.now) {
                let frame = u32::from_le_bytes(d[..4].try_into().unwrap());
                if let Some(s) = self.sends.iter_mut().rev().find(|s| s.0 == frame) {
                    s.2 = Some(self.now);
                }
                self.send(link, d.len(), frame);
            }
            if self.now >= self.next_feedback {
                self.next_feedback += FEEDBACK_US;
                let now = self.now;
                let (arrived, rest): (Vec<_>, Vec<_>) =
                    self.in_flight.drain(..).partition(|&(t, _, _)| t <= now);
                self.in_flight = rest;
                for &(_, _, f) in &arrived {
                    self.viewer_newest = self.viewer_newest.max(f);
                }
                let arrivals = arrived
                    .iter()
                    .map(|&(t, s, _)| Arrival { transport_seq: s, arrival_us: t as u32 })
                    .collect();
                self.returning.push_back((now + link.base_us, arrivals, self.viewer_newest));
            }
            while self.returning.front().is_some_and(|(t, _, _)| *t <= self.now) {
                let (_, arrivals, newest) = self.returning.pop_front().unwrap();
                self.acked = self.acked.max(newest);
                self.cc.on_feedback(&arrivals, 0.0, self.now);
            }
            if self.now >= self.next_sample {
                self.next_sample += SAMPLE_US;
                self.targets.push((self.now, self.cc.target_bps()));
            }
            self.now += STEP_US;
        }
    }

    fn send(&mut self, link: Link, len: usize, frame: u32) {
        let seq = self.seq;
        self.seq = self.seq.wrapping_add(1);
        self.cc.on_sent_bytes(seq, self.now, len);
        let at = (self.now + link.base_us) as f64;
        let start = self.queue_free_at.max(at);
        self.queue_free_at = start + len as f64 * 8.0 * 1e6 / link.capacity_bps;
        let jitter = self.rng.uniform() * link.jitter_us;
        self.in_flight.push(((self.queue_free_at + jitter) as u64, seq, frame));
    }

    /// Seconds from `from_us` until the target first reaches `bps`.
    fn reach_s(&self, from_us: u64, bps: u64) -> Option<f64> {
        self.targets
            .iter()
            .find(|&&(t, v)| t >= from_us && v >= bps)
            .map(|&(t, _)| (t - from_us) as f64 / 1e6)
    }

    fn min_target_after(&self, from_us: u64) -> u64 {
        self.targets.iter().filter(|&&(t, _)| t >= from_us).map(|&(_, v)| v).min().unwrap()
    }

    /// Send stage per frame (pushed to last datagram handed off), ms, p50 / p95,
    /// for frames pushed at or after `from_us`.
    fn send_ms(&self, from_us: u64) -> (f64, f64, usize) {
        let mut xs: Vec<f64> = self
            .sends
            .iter()
            .filter(|s| s.1 >= from_us)
            .filter_map(|s| s.2.map(|done| (done - s.1) as f64 / 1e3))
            .collect();
        xs.sort_by(f64::total_cmp);
        let at = |p: f64| xs[((p * xs.len() as f64).ceil() as usize).saturating_sub(1)];
        (at(0.5), at(0.95), xs.len())
    }
}

const WIRED: Link = Link { capacity_bps: 940e6, base_us: 250, jitter_us: 0.0 };
const WIFI: Link = Link { capacity_bps: 120e6, base_us: 2_000, jitter_us: 3_000.0 };

fn report(name: &str, sim: &Sim, motion_at: u64) -> (Option<f64>, u64, (f64, f64, usize)) {
    let reach = sim.reach_s(motion_at, GOAL_BPS);
    let low = sim.min_target_after(motion_at + 1_000_000);
    let send = sim.send_ms(motion_at);
    println!(
        "{name}: target at motion {:.1} Mbps, 15 Mbps after {:?} s, lowest after 1 s {:.1} Mbps, \
         final {:.1} Mbps, send p50 {:.2} / p95 {:.2} ms (n {})",
        sim.targets.iter().find(|&&(t, _)| t >= motion_at).unwrap().1 as f64 / 1e6,
        reach,
        low as f64 / 1e6,
        sim.cc.target_bps() as f64 / 1e6,
        send.0,
        send.1,
        send.2
    );
    (reach, low, send)
}

/// The goal's own case: a LAN share, motion from the first frame.
#[test]
fn wired_lan_motion_from_start_reaches_15_mbps_within_1_s() {
    let mut sim = Sim::new(PathKind::DirectLan, 500, 60);
    sim.run(WIRED, Scene::Motion { fill: 1.0 }, 10_000_000);
    let (reach, low, send) = report("wired, motion from start, 60 fps", &sim, 0);
    assert!(reach.is_some_and(|s| s <= 1.0));
    assert!(low > FLOOR_BPS);
    assert!(send.0 <= 8.0, "send p50 {:.2} ms", send.0);
}

/// Idle for 20 s (no frames: the host skips unchanged frames), then motion.
#[test]
fn wired_lan_idle_then_motion() {
    let mut sim = Sim::new(PathKind::DirectLan, 500, 60);
    sim.run(WIRED, Scene::Idle, 20_000_000);
    sim.run(WIRED, Scene::Motion { fill: 1.0 }, 30_000_000);
    let (reach, low, _) = report("wired, 20 s idle then motion", &sim, 20_000_000);
    assert!(reach.is_some_and(|s| s <= 1.0));
    assert!(low > FLOOR_BPS);
}

/// A cursor blinking for 20 s (one small datagram a frame) then motion: the
/// quiet-screen path of `decrease` and the "do not run ahead of the encoder"
/// gate of `increase` both apply here.
#[test]
fn wired_lan_cursor_then_motion() {
    let mut sim = Sim::new(PathKind::DirectLan, 500, 60);
    sim.run(WIRED, Scene::Cursor, 20_000_000);
    sim.run(WIRED, Scene::Motion { fill: 1.0 }, 30_000_000);
    let (reach, low, _) = report("wired, 20 s cursor then motion", &sim, 20_000_000);
    assert!(reach.is_some_and(|s| s <= 1.0));
    assert!(low > FLOOR_BPS);
}

/// The same on a radio leg with 3 ms of per-datagram jitter: the overuse
/// detector sees jitter during the quiet part.
#[test]
fn wifi_cursor_then_motion() {
    let mut sim = Sim::new(PathKind::DirectLan, 4_000, 60);
    sim.run(WIFI, Scene::Cursor, 20_000_000);
    sim.run(WIFI, Scene::Motion { fill: 1.0 }, 30_000_000);
    let (reach, low, _) = report("wifi 3 ms jitter, 20 s cursor then motion", &sim, 20_000_000);
    assert!(reach.is_some_and(|s| s <= 1.0));
    assert!(low > FLOOR_BPS);
}

/// A path over the LAN round trip (no fast start): 8 Mbps start, 2x a second.
#[test]
fn routed_path_motion_from_start() {
    let mut sim = Sim::new(PathKind::DirectLan, 20_000, 60);
    let link = Link { capacity_bps: 200e6, base_us: 10_000, jitter_us: 0.0 };
    sim.run(link, Scene::Motion { fill: 1.0 }, 10_000_000);
    report("routed 20 ms rtt, motion from start", &sim, 0);
}

/// Send stage "at any rate": frames at the budget (`rate / fps`), at 60 and
/// 30 fps, and frames at twice the budget (an encoder overshoot, a keyframe
/// smaller than the pacer's rise). The pacer drains a frame at 2.5x the target,
/// or within half a frame interval or 8 ms, whichever is shorter, so send stays
/// at or under 8 ms at 30 fps too (11.4 ms before the absolute window).
#[test]
fn send_stage_at_budget_and_over_budget() {
    let mut rows = Vec::new();
    for (fps, fill) in [(60, 1.0), (60, 2.0), (30, 1.0), (30, 0.3)] {
        let mut sim = Sim::new(PathKind::DirectLan, 500, fps);
        sim.run(WIRED, Scene::Motion { fill }, 6_000_000);
        let (_, _, send) =
            report(&format!("send, {fps} fps, frame {fill}x budget"), &sim, 2_000_000);
        rows.push((fps, fill, send.0));
    }
    // "at any rate": every row.
    assert!(rows.iter().all(|r| r.2 <= 8.0), "{rows:?}");
}
