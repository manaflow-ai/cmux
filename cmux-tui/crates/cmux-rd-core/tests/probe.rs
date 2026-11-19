//! D4 bandwidth probes (cmuxterm-hq docs/design/screen-share-under-100ms.md) against the
//! bottleneck-queue simulator of jitter.rs: the real controller, the real pacer and the
//! real probe scheduler, a simulated bottleneck, feedback every 50 ms as the viewer sends
//! it. A quiet screen with probes on learns the path before motion starts; probes over a
//! narrow bottleneck keep its queue short; they stop through an outage and an overuse; and
//! an idle stream's probe bytes stay under the stated bound.

use cmux_rd_core::cc::{CcConfig, CongestionController, PathKind};
use cmux_rd_core::pacer::Pacer;
use cmux_rd_core::probe::{ProbeConfig, ProbeScheduler};
use cmux_rd_proto::Arrival;
use std::collections::VecDeque;

const MTU: usize = 1152;
const FPS: u64 = 60;
const STEP_US: u64 = 250;
const FEEDBACK_US: u64 = 50_000;
/// The first byte of a probe datagram in this simulator (frames are zeros).
const PROBE_MARK: u8 = 0xcc;

struct Rng(u64);
impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }
    fn below(&mut self, n: u64) -> u64 {
        self.next() % n.max(1)
    }
}

#[derive(Clone, Copy)]
enum Jitter {
    Wired,
    /// Aggregation (0 to 6 ms) and a 30 to 60 ms stall about twice a second.
    WiFi,
}

struct Path {
    capacity_bps: f64,
    /// One way, each direction.
    base_us: u64,
    jitter: Jitter,
    buffer_us: f64,
}

struct Sim {
    cc: CongestionController,
    pacer: Pacer,
    prober: Option<ProbeScheduler>,
    rng: Rng,
    now: u64,
    seq: u16,
    queue_free_at: f64,
    stall_until: u64,
    next_stall: u64,
    in_flight: Vec<(u64, u16)>,
    returning: VecDeque<(u64, Vec<Arrival>)>,
    next_frame: u64,
    next_feedback: u64,
    dropped: u64,
    loss_window: (u64, u64, u64),
    queue_delays_us: Vec<u64>,
    probe_bytes: u64,
    /// Trains queued, with whether the controller was frozen or in overuse then.
    trains: Vec<(u64, bool)>,
    viewer_offset: u64,
}

impl Sim {
    fn new(cc: CongestionController, probe: bool) -> Self {
        Self {
            cc,
            pacer: Pacer::new(),
            prober: probe.then(|| ProbeScheduler::new(ProbeConfig::default(), MTU)),
            rng: Rng(0x2026_1119),
            now: 0,
            seq: 0,
            queue_free_at: 0.0,
            stall_until: 0,
            next_stall: 250_000,
            in_flight: Vec::new(),
            returning: VecDeque::new(),
            next_frame: 0,
            next_feedback: FEEDBACK_US,
            dropped: 0,
            loss_window: (0, 0, 0),
            queue_delays_us: Vec::new(),
            probe_bytes: 0,
            trains: Vec::new(),
            viewer_offset: u64::from(u32::MAX) - 3_000_000,
        }
    }

    /// Runs for `duration_us` with the encoder producing `min(target, demand)`; returns
    /// the target every 100 ms, the first sample at the start.
    fn run(&mut self, path: &Path, demand_bps: f64, duration_us: u64) -> Vec<u64> {
        let end = self.now + duration_us;
        let mut targets = Vec::new();
        let mut next_sample = self.now;
        while self.now < end {
            if self.now >= next_sample {
                next_sample += 100_000;
                targets.push(self.cc.target_bps());
            }
            if self.now >= self.next_frame {
                self.next_frame += 1_000_000 / FPS;
                let rate = (self.cc.target_bps() as f64).min(demand_bps);
                let bytes = (rate / 8.0 / FPS as f64) as usize;
                let n = bytes.div_ceil(MTU).max(1);
                let frame: Vec<Vec<u8>> = (0..n).map(|_| vec![0; MTU]).collect();
                self.pacer.push_frame(frame, self.cc.target_bps(), 1_000_000 / FPS, self.now);
            }
            self.probe();
            for d in self.pacer.due(self.now) {
                self.send(path, &d);
            }
            if self.now >= self.next_feedback {
                self.next_feedback += FEEDBACK_US;
                let now = self.now;
                let (arrived, rest): (Vec<_>, Vec<_>) =
                    self.in_flight.drain(..).partition(|&(t, _)| t <= now);
                self.in_flight = rest;
                let arrivals: Vec<Arrival> = arrived
                    .iter()
                    .map(|&(t, s)| Arrival {
                        transport_seq: s,
                        arrival_us: t.wrapping_add(self.viewer_offset) as u32,
                    })
                    .collect();
                self.returning.push_back((now + path.base_us, arrivals));
            }
            while self.returning.front().is_some_and(|(t, _)| *t <= self.now) {
                let (_, arrivals) = self.returning.pop_front().unwrap();
                let (since, sent, dropped) = self.loss_window;
                let loss = if self.now - since >= 500_000 && sent >= 20 {
                    self.loss_window = (self.now, 0, 0);
                    dropped as f64 / sent as f64
                } else {
                    0.0
                };
                self.cc.on_feedback(&arrivals, loss, self.now);
            }
            self.now += STEP_US;
        }
        targets
    }

    /// As the host does: a train only on an empty pacer, each probe timed from its queueing
    /// and again when it leaves.
    fn probe(&mut self) {
        let Some(prober) = self.prober.as_mut() else { return };
        if !self.pacer.is_empty() {
            return;
        }
        let frozen_or_overuse =
            self.cc.frozen() || self.cc.usage() == cmux_rd_core::cc::Usage::Overuse;
        let Some(train) = prober.poll(self.now, self.cc.probe_view(self.now)) else { return };
        self.trains.push((self.now, frozen_or_overuse));
        let datagrams = (0..train.datagrams)
            .map(|_| {
                let seq = self.seq;
                self.seq = self.seq.wrapping_add(1);
                self.cc.on_probe_sent(seq, self.now, MTU);
                let mut d = vec![0; MTU];
                d[0] = PROBE_MARK;
                d[1..3].copy_from_slice(&seq.to_le_bytes());
                d
            })
            .collect();
        self.pacer.push_probe(datagrams, train.rate_bps, self.now);
    }

    fn send(&mut self, path: &Path, d: &[u8]) {
        let len = d.len();
        let seq = if d[0] == PROBE_MARK {
            let seq = u16::from_le_bytes([d[1], d[2]]);
            self.cc.on_departed(seq, self.now);
            self.probe_bytes += len as u64;
            seq
        } else {
            let seq = self.seq;
            self.seq = self.seq.wrapping_add(1);
            self.cc.on_sent_bytes(seq, self.now, len);
            seq
        };
        self.loss_window.1 += 1;
        let at_bottleneck = (self.now + path.base_us) as f64;
        let queue_us = (self.queue_free_at - at_bottleneck).max(0.0);
        if queue_us > path.buffer_us {
            self.dropped += 1;
            self.loss_window.2 += 1;
            return;
        }
        self.queue_delays_us.push(queue_us as u64);
        let start = self.queue_free_at.max(at_bottleneck);
        let done = start + len as f64 * 8.0 * 1e6 / path.capacity_bps;
        self.queue_free_at = done;
        let mut arrival = done as u64;
        match path.jitter {
            Jitter::Wired => arrival += self.rng.below(60),
            Jitter::WiFi => {
                if arrival >= self.next_stall {
                    self.stall_until = arrival + 30_000 + self.rng.below(30_000);
                    self.next_stall = arrival + 300_000 + self.rng.below(400_000);
                }
                arrival += self.rng.below(6_000);
                arrival = arrival.max(self.stall_until);
            }
        }
        self.in_flight.push((arrival, seq));
    }
}

fn mbps(bps: u64) -> f64 {
    bps as f64 / 1e6
}

/// A WAN controller: the round trip is no LAN's, so the start is `start_bps` (8 Mbit/s).
fn wan(rtt_us: u64) -> CongestionController {
    let mut cc = CongestionController::new(CcConfig::default(), PathKind::DirectWan);
    cc.on_rtt(rtt_us);
    cc
}

fn path(capacity_bps: f64, rtt_us: u64, jitter: Jitter) -> Path {
    Path { capacity_bps, base_us: rtt_us / 2, jitter, buffer_us: 300_000.0 }
}

/// (target at motion start, at motion start + 1 s) after `quiet_us` of a quiet screen.
fn motion_after_quiet(probe: bool, p: &Path, rtt_us: u64, quiet_us: u64) -> (u64, u64, Sim) {
    let mut sim = Sim::new(wan(rtt_us), probe);
    sim.run(p, 0.3e6, quiet_us);
    let motion = sim.run(p, 40e6, 2_000_000);
    (motion[0], motion[10], sim)
}

/// D4 (a): on a 10 to 20 ms round trip with 50 Mbit/s, a quiet screen with probes on
/// starts motion at 15 Mbit/s or more; with probes off it starts where it did before
/// probes existed (the 8 Mbit/s start: the quiet stream alone never grows it).
#[test]
fn probes_on_a_quiet_wan_screen_start_motion_at_the_right_rate() {
    for rtt_us in [10_000, 20_000] {
        let p = path(50e6, rtt_us, Jitter::Wired);
        let (off0, off1, off) = motion_after_quiet(false, &p, rtt_us, 5_000_000);
        let (on0, on1, on) = motion_after_quiet(true, &p, rtt_us, 5_000_000);
        println!(
            "rtt {} ms: off {:.1} / {:.1} Mbps, on {:.1} / {:.1} Mbps at motion +0 / +1 s; \
             {} trains, {} probe bytes, {} dropped",
            rtt_us / 1000,
            mbps(off0),
            mbps(off1),
            mbps(on0),
            mbps(on1),
            on.trains.len(),
            on.probe_bytes,
            on.dropped
        );
        assert!(off0 < 15_000_000, "probes off: the quiet screen grew to {}", mbps(off0));
        assert_eq!(off.probe_bytes, 0);
        assert!(off.trains.is_empty());
        assert!(on0 >= 15_000_000, "rtt {rtt_us}: motion start {} Mbps", mbps(on0));
        assert!(on1 >= 15_000_000, "rtt {rtt_us}: motion +1 s {} Mbps", mbps(on1));
        assert!(on0 <= 50_000_000, "over the capacity: {} Mbps", mbps(on0));
        assert!(on1 >= off1, "probes on never start slower: {} < {}", mbps(on1), mbps(off1));
        assert_eq!(on.dropped, 0);
    }
}

/// D4 (a) through a radio's jitter and stalls: probes still lift the quiet start.
#[test]
fn probes_on_a_quiet_wifi_wan_screen_still_lift_the_start() {
    let rtt_us = 15_000;
    let p = path(50e6, rtt_us, Jitter::WiFi);
    let (off0, off1, _) = motion_after_quiet(false, &p, rtt_us, 5_000_000);
    let (on0, on1, on) = motion_after_quiet(true, &p, rtt_us, 5_000_000);
    println!(
        "wifi rtt 15 ms: off {:.1} / {:.1}, on {:.1} / {:.1} Mbps; {} trains",
        mbps(off0),
        mbps(off1),
        mbps(on0),
        mbps(on1),
        on.trains.len()
    );
    assert!(on0 >= 15_000_000, "motion start {} Mbps", mbps(on0));
    assert!(on1 >= 15_000_000, "motion +1 s {} Mbps", mbps(on1));
}

/// D4 (b): probes over a 10 Mbit/s bottleneck keep its queue under the congestion tests'
/// bound (p95 under 100 ms) and the target near the capacity, on a quiet screen and then
/// in motion that asks for four times the capacity.
#[test]
fn probes_over_a_narrow_bottleneck_keep_the_queue_short_and_the_target_near_capacity() {
    let rtt_us = 15_000;
    let p = path(10e6, rtt_us, Jitter::Wired);
    let mut sim = Sim::new(wan(rtt_us), true);
    let quiet = sim.run(&p, 0.3e6, 10_000_000);
    let quiet_delays = sim.queue_delays_us.clone();
    let after_quiet = sim.cc.target_bps();
    let motion = sim.run(&p, 40e6, 20_000_000);
    println!(
        "10 Mbps: quiet {:?}, after quiet {} Mbps, capacity {:?}, {} trains",
        quiet.iter().step_by(10).map(|&t| mbps(t)).collect::<Vec<_>>(),
        mbps(after_quiet),
        sim.cc.capacity_bps(),
        sim.trains.len()
    );
    assert!(sim.trains.len() >= 5, "probes ran on the quiet screen");
    assert!((7_000_000..=10_500_000).contains(&after_quiet), "{} Mbps", mbps(after_quiet));
    let mut d = quiet_delays;
    d.sort_unstable();
    let quiet_p95 = d[d.len() * 95 / 100];
    let quiet_max = *d.last().unwrap();
    assert!(quiet_p95 < 100_000, "quiet queue p95 {quiet_p95} us");
    assert!(quiet_max < 100_000, "a train queued {quiet_max} us");
    let steady = &motion[50..];
    let mean = steady.iter().sum::<u64>() as f64 / steady.len() as f64;
    assert!((6e6..=11.5e6).contains(&mean), "steady mean {} Mbps", mean / 1e6);
    let mut delays = sim.queue_delays_us[sim.queue_delays_us.len() / 3..].to_vec();
    delays.sort_unstable();
    let p95 = delays[delays.len() * 95 / 100];
    assert!(p95 < 100_000, "queue p95 {p95} us");
}

/// D4 (b), the existing congestion trace with probes on: the same bounds hold.
#[test]
fn real_congestion_with_probes_on_still_cuts_and_holds_the_queue_short() {
    let mut cc = CongestionController::new(CcConfig::default(), PathKind::DirectLan);
    cc.on_rtt(1_000);
    let mut sim = Sim::new(cc, true);
    let p =
        Path { capacity_bps: 10e6, base_us: 1_000, jitter: Jitter::Wired, buffer_us: 300_000.0 };
    let targets = sim.run(&p, 40e6, 30_000_000);
    assert!(targets[..=11].iter().any(|&t| t <= 13_000_000), "{:?}", &targets[..=11]);
    let steady = &targets[50..];
    let mean = steady.iter().sum::<u64>() as f64 / steady.len() as f64;
    assert!((6e6..=11.5e6).contains(&mean), "steady mean {} Mbps", mean / 1e6);
    let mut delays = sim.queue_delays_us[sim.queue_delays_us.len() / 3..].to_vec();
    delays.sort_unstable();
    let p95 = delays[delays.len() * 95 / 100];
    assert!(p95 < 100_000, "queue p95 {p95} us");
}

/// D4 (c): no train while the path is away (an outage, D12), and none while an overuse
/// or its cut is in force; the next one goes once the controller may act again.
#[test]
fn probes_stop_during_an_outage_and_while_overuse_is_in_force() {
    // An outage: feedback flows, then a datagram goes unanswered for 500 ms.
    let mut cc = wan(15_000);
    let mut prober = ProbeScheduler::new(ProbeConfig::default(), MTU);
    assert!(prober.poll(0, cc.probe_view(0)).is_none());
    cc.on_sent_bytes(0, 100_000, MTU);
    cc.on_feedback(&[Arrival { transport_seq: 0, arrival_us: 107_500 }], 0.0, 115_000);
    cc.on_sent_bytes(1, 200_000, MTU);
    cc.on_feedback(&[], 0.0, 700_000);
    assert!(cc.frozen(), "500 ms of silence is an outage");
    let view = cc.probe_view(1_000_000);
    assert!(!view.may_probe);
    assert_eq!(prober.poll(1_000_000, view), None, "no train while the path is away");
    // Back: a datagram sent after the outage arrives.
    cc.on_sent_bytes(2, 1_100_000, MTU);
    cc.on_feedback(&[Arrival { transport_seq: 2, arrival_us: 1_107_500 }], 0.0, 1_115_000);
    assert!(!cc.frozen());
    assert!(prober.poll(2_000_000, cc.probe_view(2_000_000)).is_some(), "probes resume");

    // Overuse: a queue growing 2 ms per 60 fps burst cuts the target.
    let mut cc = wan(15_000);
    let initial = cc.target_bps();
    let mut prober = ProbeScheduler::new(ProbeConfig::default(), MTU);
    prober.poll(0, cc.probe_view(0));
    let mut cut_at = None;
    for i in 0..90u64 {
        let sent = 2_000_000 + 16_667 * i;
        cc.on_sent(i as u16, sent);
        let arrived = sent + 25_000 + i * 2_000;
        cc.on_feedback(
            &[Arrival { transport_seq: i as u16, arrival_us: arrived as u32 }],
            0.0,
            arrived + 25_000,
        );
        if cc.target_bps() < initial {
            cut_at = Some(arrived + 25_000);
            break;
        }
    }
    let cut_at = cut_at.expect("the growing queue cut the target");
    let view = cc.probe_view(cut_at);
    assert!(!view.may_probe, "overuse {:?} or its cut is in force", cc.usage());
    assert_eq!(prober.poll(cut_at, view), None);

    // In the simulator: a WAN path through a radio that goes away for 250 ms twice; no
    // train is queued while the controller is frozen or in overuse.
    let mut sim = Sim::new(wan(15_000), true);
    let p = path(50e6, 15_000, Jitter::Wired);
    for _ in 0..2 {
        sim.run(&p, 0.3e6, 2_000_000);
        let back = sim.now + 250_000;
        sim.queue_free_at = sim.queue_free_at.max(back as f64);
        sim.run(&p, 0.3e6, 1_000_000);
    }
    assert!(!sim.trains.is_empty());
    assert!(sim.trains.iter().all(|&(_, held)| !held), "{:?}", sim.trains);
}

/// D4 (d): over 10 s of a quiet screen, probe bytes stay under the stated bound: one
/// train a second of at most `max_datagrams` datagrams (64 x 1152 bytes: 590 kbit/s),
/// and at most `rate_factor * train_us` (4%) of the highest target in that time.
#[test]
fn idle_probe_bytes_over_ten_seconds_stay_under_the_bound() {
    let config = ProbeConfig::default();
    let p = path(50e6, 15_000, Jitter::Wired);
    let mut sim = Sim::new(wan(15_000), true);
    let targets = sim.run(&p, 0.3e6, 10_000_000);
    let top = targets.iter().copied().max().unwrap_or(0).max(sim.cc.target_bps());
    let per_train = config.max_train_bytes(top, MTU);
    let bound = 10 * (config.max_datagrams * MTU) as u64;
    let share_bound = (top as f64 * config.rate_factor * config.train_us as f64 / 8e6) as u64 * 10;
    println!(
        "idle 10 s: {} trains, {} probe bytes ({:.0} kbit/s); bounds {} bytes, {} by share \
         (top target {} Mbps, {} per train)",
        sim.trains.len(),
        sim.probe_bytes,
        sim.probe_bytes as f64 * 8.0 / 10.0 / 1e3,
        bound,
        share_bound,
        mbps(top),
        per_train
    );
    assert!(sim.trains.len() <= 10, "{} trains in 10 s", sim.trains.len());
    assert!(sim.probe_bytes <= bound, "{} probe bytes over {bound}", sim.probe_bytes);
    assert!(sim.probe_bytes <= share_bound.max(10 * (config.min_datagrams * MTU) as u64));
}
