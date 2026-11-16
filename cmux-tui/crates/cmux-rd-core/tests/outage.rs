//! D12, "an outage is not congestion": the recorded `wifi-away` hold schedule
//! (`scripts/measure/screen-stream-eval/wifi-away-holds.json`, the radio on Leo's
//! viewer Mac) replayed through the congestion controller over a simulated link.
//!
//! The link is 4 ms each way with 2% random loss and plenty of capacity. During a
//! hold the radio delivers nothing in either direction: datagrams queue and leave
//! in one burst at the link rate when it ends, and the viewer's feedback waits with
//! them. The host paces each frame and, like the engine's frame gate, encodes a new
//! frame only while fewer than two are unacknowledged. Nothing is congested, so the
//! target must hold through every hold and be back where it was within a second of
//! each one ending. A link that really is too slow still cuts.

use cmux_rd_core::cc::{CcConfig, CongestionController, PathKind};
use cmux_rd_core::pacer::Pacer;
use cmux_rd_proto::Arrival;
use std::collections::VecDeque;

const SCHEDULE: &str =
    include_str!("../../../../scripts/measure/screen-stream-eval/wifi-away-holds.json");

const MTU: usize = 1152;
const FPS: u64 = 60;
const STEP_US: u64 = 250;
const FEEDBACK_US: u64 = 50_000;
const SAMPLE_US: u64 = 10_000;
/// Frames the host may have unacknowledged (the engine's gate on a LAN round trip).
const FRAMES_IN_FLIGHT: u32 = 2;
/// Clean seconds before the schedule starts, so the target has found the link.
const WARMUP_US: u64 = 10_000_000;

/// `[[start s, length s], ...]` under `key` in the schedule, as (start, end) in µs.
fn holds_of(key: &str) -> Vec<(u64, u64)> {
    let at = SCHEDULE.find(&format!("\"{key}\"")).expect("schedule key");
    let open = at + SCHEDULE[at..].find('[').expect("array");
    let mut depth = 0;
    let mut close = open;
    for (i, c) in SCHEDULE[open..].char_indices() {
        match c {
            '[' => depth += 1,
            ']' => {
                depth -= 1;
                if depth == 0 {
                    close = open + i;
                    break;
                }
            }
            _ => {}
        }
    }
    let numbers: Vec<f64> = SCHEDULE[open..close]
        .split(|c: char| !(c.is_ascii_digit() || c == '.'))
        .filter(|s| !s.is_empty())
        .map(|s| s.parse().expect("number"))
        .collect();
    numbers
        .chunks(2)
        .map(|p| {
            let start = (p[0] * 1e6) as u64 + WARMUP_US;
            (start, start + (p[1] * 1e6) as u64)
        })
        .collect()
}

/// Overlapping holds merged, in order (as `rd-netem-linux.py merge_holds` does).
fn merged(mut holds: Vec<(u64, u64)>) -> Vec<(u64, u64)> {
    holds.sort_unstable();
    let mut out: Vec<(u64, u64)> = Vec::new();
    for (a, b) in holds {
        match out.last_mut() {
            Some(last) if a <= last.1 => last.1 = last.1.max(b),
            _ => out.push((a, b)),
        }
    }
    out
}

fn wifi_away() -> Vec<(u64, u64)> {
    let mut all = holds_of("short");
    all.extend(holds_of("long"));
    merged(all)
}

fn wifi_long() -> Vec<(u64, u64)> {
    merged(holds_of("long"))
}

fn schedule_seconds() -> u64 {
    let at = SCHEDULE.find("\"seconds\"").expect("seconds");
    let rest = &SCHEDULE[at + "\"seconds\"".len()..];
    let digits: String = rest
        .chars()
        .skip_while(|c| !c.is_ascii_digit())
        .take_while(|c| c.is_ascii_digit() || *c == '.')
        .collect();
    digits.parse::<f64>().expect("seconds") as u64
}

struct Rng(u64);
impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }
    fn chance(&mut self, p: f64) -> bool {
        (self.next() % 1_000_000) as f64 / 1e6 < p
    }
}

struct Link {
    capacity_bps: f64,
    base_us: u64,
    loss: f64,
    /// Tail drop past this much queue.
    buffer_us: f64,
    holds: Vec<(u64, u64)>,
}

impl Link {
    /// The radio is away at `t`: when it is back.
    fn back_at(&self, t: u64) -> u64 {
        self.holds.iter().find(|&&(a, b)| a <= t && t < b).map_or(t, |&(_, b)| b)
    }
}

struct Sim {
    cc: CongestionController,
    pacer: Pacer,
    rng: Rng,
    now: u64,
    seq: u16,
    queue_free_at: f64,
    /// (arrival on the viewer, seq, frame), not yet reported.
    in_flight: Vec<(u64, u16, u32)>,
    /// Feedback on its way back: (host receive time, arrivals, newest frame seen).
    returning: VecDeque<(u64, Vec<Arrival>, u32)>,
    viewer_newest: u32,
    acked: u32,
    /// Frames the encoder may have unacknowledged.
    in_flight_frames: u32,
    frame: u32,
    next_frame: u64,
    next_feedback: u64,
    loss_window: (u64, u64, u64),
    queue_delays_us: Vec<u64>,
    /// (time, target) every [`SAMPLE_US`].
    targets: Vec<(u64, u64)>,
    next_sample: u64,
}

impl Sim {
    fn new(rtt_us: u64, in_flight_frames: u32) -> Self {
        let mut cc = CongestionController::new(CcConfig::default(), PathKind::DirectLan);
        cc.on_rtt(rtt_us);
        Self {
            cc,
            pacer: Pacer::new(),
            rng: Rng(0x0d12_2026_1116),
            now: 0,
            seq: 0,
            queue_free_at: 0.0,
            in_flight: Vec::new(),
            returning: VecDeque::new(),
            viewer_newest: 0,
            acked: 0,
            in_flight_frames,
            frame: 0,
            next_frame: 0,
            next_feedback: FEEDBACK_US,
            loss_window: (0, 0, 0),
            queue_delays_us: Vec::new(),
            targets: Vec::new(),
            next_sample: 0,
        }
    }

    /// Runs to `end_us` with the encoder filling the target.
    fn run(&mut self, link: &Link, end_us: u64) {
        while self.now < end_us {
            if self.now >= self.next_frame {
                self.next_frame += 1_000_000 / FPS;
                if self.frame - self.acked < self.in_flight_frames {
                    self.frame += 1;
                    let bytes = (self.cc.target_bps() as f64 / 8.0 / FPS as f64) as usize;
                    let n = bytes.div_ceil(MTU).max(1);
                    let frame: Vec<Vec<u8>> = (0..n)
                        .map(|i| {
                            let mut d = vec![0; MTU];
                            d[..4].copy_from_slice(&self.frame.to_le_bytes());
                            d[4] = u8::from(i == 0);
                            d
                        })
                        .collect();
                    self.pacer.push_frame(frame, self.cc.target_bps(), 1_000_000 / FPS, self.now);
                }
            }
            for d in self.pacer.due(self.now) {
                let frame = u32::from_le_bytes(d[..4].try_into().unwrap());
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
                let at = link.back_at(now) + link.base_us;
                self.returning.push_back((at, arrivals, self.viewer_newest));
            }
            while self.returning.front().is_some_and(|(t, _, _)| *t <= self.now) {
                let (_, arrivals, newest) = self.returning.pop_front().unwrap();
                self.acked = self.acked.max(newest);
                let (since, sent, dropped) = self.loss_window;
                let loss = if self.now - since >= 500_000 && sent >= 20 {
                    self.loss_window = (self.now, 0, 0);
                    dropped as f64 / sent as f64
                } else {
                    0.0
                };
                self.cc.on_feedback(&arrivals, loss, self.now);
            }
            if self.now >= self.next_sample {
                self.next_sample += SAMPLE_US;
                self.targets.push((self.now, self.cc.target_bps()));
            }
            self.now += STEP_US;
        }
    }

    fn send(&mut self, link: &Link, len: usize, frame: u32) {
        let seq = self.seq;
        self.seq = self.seq.wrapping_add(1);
        self.loss_window.1 += 1;
        self.cc.on_sent_bytes(seq, self.now, len);
        if self.rng.chance(link.loss) {
            self.loss_window.2 += 1;
            return;
        }
        let at = (self.now + link.base_us) as f64;
        let start = link.back_at(self.queue_free_at.max(at) as u64) as f64;
        if start - at > link.buffer_us {
            self.loss_window.2 += 1;
            return;
        }
        self.queue_delays_us.push((start - at) as u64);
        self.queue_free_at = start + len as f64 * 8.0 * 1e6 / link.capacity_bps;
        self.in_flight.push((self.queue_free_at as u64, seq, frame));
    }

    fn target_at(&self, t: u64) -> u64 {
        let i = self.targets.partition_point(|&(at, _)| at <= t);
        self.targets[i.saturating_sub(1)].1
    }
}

fn mbps(bps: u64) -> f64 {
    bps as f64 / 1e6
}

fn radio(holds: Vec<(u64, u64)>, loss: f64) -> Link {
    Link { capacity_bps: 100e6, base_us: 4_000, loss, buffer_us: 2_000_000.0, holds }
}

/// The schedule against the same link without holds: the floor is 80% of the clean
/// target, and each hold's target is back within a second of the hold ending.
fn replay(name: &str, holds: Vec<(u64, u64)>, loss: f64) {
    let end = WARMUP_US + schedule_seconds() * 1_000_000;
    let mut clean = Sim::new(8_000, FRAMES_IN_FLIGHT);
    clean.run(&radio(Vec::new(), loss), end);
    let after: Vec<u64> =
        clean.targets.iter().filter(|&&(t, _)| t >= WARMUP_US).map(|&(_, v)| v).collect();
    let clean_mean = after.iter().sum::<u64>() as f64 / after.len() as f64;

    let mut sim = Sim::new(8_000, FRAMES_IN_FLIGHT);
    sim.run(&radio(holds.clone(), loss), end + 1_000_000);
    let (low_at, low) = sim
        .targets
        .iter()
        .filter(|&&(t, _)| t >= WARMUP_US)
        .copied()
        .min_by_key(|&(_, v)| v)
        .unwrap();
    let mut late = Vec::new();
    for &(a, b) in &holds {
        let before = sim.target_at(a);
        let back = sim
            .targets
            .iter()
            .find(|&&(t, v)| t >= b && v as f64 >= 0.97 * before as f64)
            .map(|&(t, _)| t - b);
        if back.is_none_or(|us| us > 1_000_000) {
            late.push((a, b - a, mbps(before), back, mbps(sim.target_at(b + 1_000_000))));
        }
    }
    println!(
        "{name}: clean mean {:.1} Mbps, held run min {:.1} Mbps at {:.2} s, {} holds, {} not back within 1 s",
        clean_mean / 1e6,
        mbps(low),
        low_at as f64 / 1e6,
        holds.len(),
        late.len()
    );
    for (a, len, before, back, at_1s) in late.iter().take(8) {
        println!(
            "  hold at {:.3} s for {} ms: before {before:.1} Mbps, back after {:?} ms, 1 s later {at_1s:.1} Mbps",
            *a as f64 / 1e6,
            len / 1000,
            back.map(|us| us / 1000),
        );
    }
    assert!(
        low as f64 >= 0.8 * clean_mean,
        "{name}: target fell to {:.1} Mbps at {:.2} s, under 80% of the clean {:.1} Mbps",
        mbps(low),
        low_at as f64 / 1e6,
        clean_mean / 1e6
    );
    assert!(
        late.is_empty(),
        "{name}: {} holds not back at their pre-outage target within 1 s",
        late.len()
    );
}

#[test]
fn wifi_away_schedule_holds_the_target_through_every_outage() {
    replay("wifi-away", wifi_away(), 0.02);
}

#[test]
fn wifi_long_schedule_holds_the_target_through_every_outage() {
    replay("wifi-long", wifi_long(), 0.0);
}

/// A 10 Mbps link with a real queue still cuts to the bottleneck, as before D12,
/// with and without the radio's holds on top.
#[test]
fn a_bandwidth_limited_link_still_cuts() {
    let mut failures = Vec::new();
    for (name, holds) in [("clean", Vec::new()), ("wifi-away", wifi_away())] {
        let link =
            Link { capacity_bps: 10e6, base_us: 1_000, loss: 0.0, buffer_us: 300_000.0, holds };
        // No frame gate: the encoder keeps filling the target, so a queue grows at the
        // bottleneck (the gate would hold it to two frames and hide the trend).
        let mut sim = Sim::new(1_000, u32::MAX);
        assert_eq!(sim.cc.target_bps(), 30_000_000);
        sim.run(&link, 40_000_000);
        let first_cut = sim.targets.iter().find(|&&(_, v)| v <= 13_000_000).map(|&(t, _)| t);
        let steady: Vec<u64> =
            sim.targets.iter().filter(|&&(t, _)| t >= 15_000_000).map(|&(_, v)| v).collect();
        let mean = steady.iter().sum::<u64>() as f64 / steady.len() as f64;
        let mut delays = sim.queue_delays_us[sim.queue_delays_us.len() / 3..].to_vec();
        delays.sort_unstable();
        let p95 = delays[delays.len() * 95 / 100];
        println!(
            "bandwidth-limited {name}: under 13 Mbps at {:?} ms, steady mean {:.1} Mbps, queue p95 {p95} us",
            first_cut.map(|t| t / 1000),
            mean / 1e6
        );
        failures.extend(
            [
                first_cut
                    .is_none_or(|t| t > 1_000_000)
                    .then(|| format!("{name}: not under 13 Mbps within 1 s")),
                (mean > 11.5e6).then(|| {
                    format!("{name}: steady mean {:.1} Mbps over a 10 Mbps link", mean / 1e6)
                }),
                (mean < 6e6).then(|| format!("{name}: steady mean {:.1} Mbps", mean / 1e6)),
                (name == "clean" && p95 >= 100_000).then(|| format!("{name}: queue p95 {p95} us")),
            ]
            .into_iter()
            .flatten(),
        );
    }
    assert!(failures.is_empty(), "{failures:#?}");
}
