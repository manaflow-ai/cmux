//! The congestion controller against synthetic delay traces: a wired LAN, a Wi-Fi
//! radio's jitter and aggregation, real congestion at a bottleneck, a quiet screen
//! between motion, and a capacity that rises. Each trace runs the real pacer and a
//! simulated bottleneck queue, with feedback every 50 ms as the viewer sends it.

use cmux_rd_core::cc::{CcConfig, CongestionController, PathKind};
use cmux_rd_core::pacer::Pacer;
use cmux_rd_proto::Arrival;
use std::collections::VecDeque;

const MTU: usize = 1152;
const FPS: u64 = 60;
const STEP_US: u64 = 250;
const FEEDBACK_US: u64 = 50_000;

/// Deterministic xorshift.
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
    /// A switch: tens of microseconds.
    Wired,
    /// A radio: aggregates delivered together (0 to 6 ms), and a power-save or
    /// scan stall of 30 to 60 ms about twice a second.
    WiFi,
}

struct Path {
    capacity_bps: f64,
    /// One way, each direction.
    base_us: u64,
    jitter: Jitter,
    /// Tail drop past this much queue.
    buffer_us: f64,
}

struct Sim {
    cc: CongestionController,
    pacer: Pacer,
    rng: Rng,
    now: u64,
    seq: u16,
    queue_free_at: f64,
    stall_until: u64,
    next_stall: u64,
    /// (arrival time on the viewer, seq), not yet reported.
    in_flight: Vec<(u64, u16)>,
    /// Feedback on its way back: (host receive time, arrivals).
    returning: VecDeque<(u64, Vec<Arrival>)>,
    next_frame: u64,
    next_feedback: u64,
    sent: u64,
    dropped: u64,
    /// Tail drops in the current 500 ms loss window, as the host's loss meter reports them:
    /// (window start, sent, dropped).
    loss_window: (u64, u64, u64),
    queue_delays_us: Vec<u64>,
    bytes_delivered: u64,
    /// Viewer clock = host clock + this (only differences matter to the controller).
    viewer_offset: u64,
}

impl Sim {
    fn new(cc: CongestionController) -> Self {
        Self {
            cc,
            pacer: Pacer::new(),
            rng: Rng(0x2026_1116),
            now: 0,
            seq: 0,
            queue_free_at: 0.0,
            stall_until: 0,
            next_stall: 250_000,
            in_flight: Vec::new(),
            returning: VecDeque::new(),
            next_frame: 0,
            next_feedback: FEEDBACK_US,
            sent: 0,
            dropped: 0,
            loss_window: (0, 0, 0),
            queue_delays_us: Vec::new(),
            bytes_delivered: 0,
            viewer_offset: u64::from(u32::MAX) - 3_000_000,
        }
    }

    /// Runs for `duration_us` with the encoder producing `min(target, demand)`.
    /// Returns the target every 100 ms.
    fn run(&mut self, path: &Path, demand_bps: f64, duration_us: u64) -> Vec<u64> {
        let end = self.now + duration_us;
        let mut targets = Vec::new();
        let mut next_sample = self.now;
        while self.now < end {
            if self.now >= self.next_frame {
                self.next_frame += 1_000_000 / FPS;
                let rate = (self.cc.target_bps() as f64).min(demand_bps);
                let bytes = (rate / 8.0 / FPS as f64) as usize;
                let n = bytes.div_ceil(MTU).max(1);
                let frame: Vec<Vec<u8>> = (0..n).map(|_| vec![0; MTU]).collect();
                self.pacer.push_frame(frame, self.cc.target_bps(), 1_000_000 / FPS, self.now);
            }
            for d in self.pacer.due(self.now) {
                self.send(path, d.len());
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
            if self.now >= next_sample {
                next_sample += 100_000;
                targets.push(self.cc.target_bps());
            }
            self.now += STEP_US;
        }
        targets
    }

    fn send(&mut self, path: &Path, len: usize) {
        let seq = self.seq;
        self.seq = self.seq.wrapping_add(1);
        self.sent += 1;
        self.loss_window.1 += 1;
        self.cc.on_sent_bytes(seq, self.now, len);
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
                // Aggregation: a packet waits for the next aggregate boundary.
                arrival += self.rng.below(6_000);
                arrival = arrival.max(self.stall_until);
            }
        }
        self.bytes_delivered += len as u64;
        self.in_flight.push((arrival, seq));
    }
}

fn lan_controller() -> CongestionController {
    CongestionController::new(CcConfig::default(), PathKind::DirectLan)
}

fn wired() -> Path {
    Path { capacity_bps: 1e9, base_us: 300, jitter: Jitter::Wired, buffer_us: 50_000.0 }
}

fn wifi() -> Path {
    Path { capacity_bps: 250e6, base_us: 2_000, jitter: Jitter::WiFi, buffer_us: 200_000.0 }
}

fn mbps(bps: u64) -> f64 {
    bps as f64 / 1e6
}

#[test]
fn wired_lan_reaches_the_motion_rate_within_a_second_from_the_wan_start() {
    let mut sim = Sim::new(lan_controller());
    let targets = sim.run(&wired(), 40e6, 3_000_000);
    println!("wired targets (Mbps): {:?}", targets.iter().map(|&t| mbps(t)).collect::<Vec<_>>());
    // 8 Mbps start, no RTT reported: doubling per second at most, from evidence.
    assert!(targets[10] >= 15_000_000, "1 s: {}", mbps(targets[10]));
    assert!(targets[20] >= 30_000_000, "2 s: {}", mbps(targets[20]));
    assert_eq!(sim.dropped, 0);
}

#[test]
fn a_measured_lan_round_trip_starts_high() {
    let mut cc = lan_controller();
    cc.on_rtt(800);
    assert_eq!(cc.target_bps(), 30_000_000);
    let mut sim = Sim::new(cc);
    let targets = sim.run(&wired(), 40e6, 2_000_000);
    assert!(targets.iter().all(|&t| t >= 30_000_000), "{targets:?}");
    // A WAN round trip does not.
    let mut wan = lan_controller();
    wan.on_rtt(20_000);
    assert_eq!(wan.target_bps(), 8_000_000);
    // Nor a relay.
    let mut relay = CongestionController::new(CcConfig::default(), PathKind::DoRelay);
    relay.on_rtt(800);
    assert!(relay.target_bps() <= CcConfig::default().relay_max_bps);
}

#[test]
fn wifi_jitter_and_stalls_do_not_pin_the_rate_low() {
    let mut cc = lan_controller();
    cc.on_rtt(4_000);
    let mut sim = Sim::new(cc);
    let targets = sim.run(&wifi(), 25e6, 60_000_000);
    let low = targets.iter().copied().min().unwrap();
    let after_warmup = &targets[20..];
    let mean = after_warmup.iter().sum::<u64>() as f64 / after_warmup.len() as f64;
    println!("wifi: min {} mean {} Mbps, dropped {}", mbps(low), mean / 1e6, sim.dropped);
    assert!(low >= 15_000_000, "Wi-Fi jitter cut the target to {} Mbps", mbps(low));
    assert!(mean >= 22e6, "mean target {} Mbps", mean / 1e6);
    assert_eq!(sim.dropped, 0);
}

#[test]
fn real_congestion_cuts_to_the_bottleneck_and_holds_the_queue_short() {
    let mut cc = lan_controller();
    cc.on_rtt(1_000);
    let mut sim = Sim::new(cc);
    let path =
        Path { capacity_bps: 10e6, base_us: 1_000, jitter: Jitter::Wired, buffer_us: 300_000.0 };
    let targets = sim.run(&path, 40e6, 30_000_000);
    println!(
        "congestion targets (Mbps): {:?}",
        targets.iter().step_by(5).map(|&t| mbps(t)).collect::<Vec<_>>()
    );
    // From 30 Mbps onto a 10 Mbps link: under 13 Mbps within one second.
    assert!(targets[..=10].iter().any(|&t| t <= 13_000_000), "{:?}", &targets[..=10]);
    let steady = &targets[50..];
    let mean = steady.iter().sum::<u64>() as f64 / steady.len() as f64;
    assert!((6e6..=11.5e6).contains(&mean), "steady mean {} Mbps", mean / 1e6);
    let mut delays = sim.queue_delays_us[sim.queue_delays_us.len() / 3..].to_vec();
    delays.sort_unstable();
    let p95 = delays[delays.len() * 95 / 100];
    assert!(p95 < 100_000, "queue p95 {p95} us");
}

#[test]
fn wifi_congestion_is_still_found_through_the_jitter() {
    let mut cc = lan_controller();
    cc.on_rtt(4_000);
    let mut sim = Sim::new(cc);
    let path = Path { capacity_bps: 12e6, ..wifi() };
    let targets = sim.run(&path, 40e6, 30_000_000);
    let steady = &targets[50..];
    let mean = steady.iter().sum::<u64>() as f64 / steady.len() as f64;
    println!("wifi congestion: steady mean {} Mbps", mean / 1e6);
    assert!(mean <= 14e6, "steady mean {} Mbps over a 12 Mbps radio", mean / 1e6);
    assert!(mean >= 6e6, "steady mean {} Mbps", mean / 1e6);
}

#[test]
fn a_quiet_screen_between_motion_keeps_the_rate() {
    let mut cc = lan_controller();
    cc.on_rtt(4_000);
    let mut sim = Sim::new(cc);
    let path = wifi();
    sim.run(&path, 30e6, 5_000_000);
    let before = sim.cc.target_bps();
    // Ten seconds of a static screen: small frames, the radio's stalls continue.
    sim.run(&path, 0.3e6, 10_000_000);
    let quiet = sim.cc.target_bps();
    let targets = sim.run(&path, 30e6, 2_000_000);
    println!("idle: before {} quiet {} after {:?}", mbps(before), mbps(quiet), &targets[..5]);
    assert!(quiet >= before * 3 / 4, "the quiet screen cut {} to {}", mbps(before), mbps(quiet));
    assert!(targets[5] >= 20_000_000, "0.5 s into motion: {} Mbps", mbps(targets[5]));
}

#[test]
fn a_rate_cut_by_a_burst_of_loss_recovers_fast_toward_the_measured_capacity() {
    let mut cc = lan_controller();
    cc.on_rtt(1_000);
    let mut sim = Sim::new(cc);
    let path =
        Path { capacity_bps: 20e6, base_us: 1_000, jitter: Jitter::Wired, buffer_us: 300_000.0 };
    sim.run(&path, 40e6, 10_000_000);
    let settled = sim.cc.target_bps();
    assert!(sim.cc.capacity_bps().is_some());
    // A loss burst halves it.
    sim.cc.on_feedback(&[], 0.9, sim.now);
    let cut = sim.cc.target_bps();
    assert!(cut < settled * 2 / 3);
    let targets = sim.run(&path, 40e6, 1_000_000);
    println!("recover: settled {} cut {} after {:?}", mbps(settled), mbps(cut), targets);
    assert!(sim.cc.target_bps() >= settled * 4 / 5, "{} after 1 s", mbps(sim.cc.target_bps()));
}

#[test]
fn a_capacity_that_rises_is_found() {
    let mut cc = lan_controller();
    cc.on_rtt(1_000);
    let mut sim = Sim::new(cc);
    let mut path =
        Path { capacity_bps: 10e6, base_us: 1_000, jitter: Jitter::Wired, buffer_us: 300_000.0 };
    sim.run(&path, 60e6, 10_000_000);
    assert!(sim.cc.target_bps() < 13_000_000);
    path.capacity_bps = 50e6;
    let targets = sim.run(&path, 60e6, 8_000_000);
    println!("rise: {:?}", targets.iter().step_by(5).map(|&t| mbps(t)).collect::<Vec<_>>());
    assert!(targets.iter().any(|&t| t >= 35_000_000), "never found the new capacity");
}

// Older single-packet traces, kept: bounded jitter must not ratchet the rate.

fn trace(
    cc: &mut CongestionController,
    start: u64,
    interval: u64,
    first_seq: u16,
    delays: &[(u64, u64)],
) -> Vec<(u64, u64)> {
    let mut events = Vec::with_capacity(delays.len() * 2);
    for (i, &(forward, reverse)) in delays.iter().enumerate() {
        let sent = start + i as u64 * interval;
        let seq = first_seq.wrapping_add(i as u16);
        events.push((sent, 0, seq, 0));
        events.push((sent + forward + reverse, 1, seq, (sent + forward) as u32));
    }
    events.sort_unstable();
    let mut targets = Vec::with_capacity(delays.len());
    for (now, kind, seq, arrived) in events {
        if kind == 0 {
            cc.on_sent(seq, now);
        } else {
            cc.on_feedback(&[Arrival { transport_seq: seq, arrival_us: arrived }], 0.0, now);
            targets.push((now, cc.target_bps()));
        }
    }
    targets
}

fn controller() -> CongestionController {
    CongestionController::new(CcConfig::default(), PathKind::DirectWan)
}

#[test]
fn stationary_jitter_alternating_delays_do_not_ratchet_bitrate_down() {
    for phase in 0..2 {
        let mut cc = controller();
        let initial = cc.target_bps();
        let delays: Vec<_> = (0..300)
            .map(|i| (if (i + phase) % 2 == 0 { 12_500 } else { 37_500 }, 25_000))
            .collect();
        let samples = trace(&mut cc, 0, 33_333, 0, &delays);
        let minimum = samples.iter().map(|&(_, target)| target).min().unwrap();
        assert!(minimum >= initial, "phase={phase}: alternating delay cut {initial} to {minimum}");
    }
}

fn jitter(state: &mut u64) -> u64 {
    *state ^= *state << 13;
    *state ^= *state >> 7;
    *state ^= *state << 17;
    12_500 + *state % 25_001
}

#[test]
fn stationary_jitter_independent_seeds_do_not_collapse_over_a_minute() {
    for seed in [1, 7, 31, 0x1234_5678, 20_261_114, 2_026_141_500, 2_026_141_600, u64::MAX] {
        for fps in [30, 60] {
            let mut cc = controller();
            let initial = cc.target_bps();
            let mut state = seed;
            let delays: Vec<_> =
                (0..fps * 60).map(|_| (jitter(&mut state), jitter(&mut state))).collect();
            let samples = trace(&mut cc, 0, 1_000_000 / fps, 0, &delays);
            let minimum = samples.iter().map(|&(_, target)| target).min().unwrap();
            assert!(minimum >= initial / 2, "seed={seed} fps={fps}: collapsed to {minimum}");
            assert!(cc.target_bps() >= initial, "seed={seed} fps={fps}: eroded");
        }
    }
}

#[test]
fn sustained_queue_growth_cuts() {
    let mut cc = controller();
    let initial = cc.target_bps();
    // Each 60 fps burst waits 2 ms longer than the last: a queue growing 12% of real time.
    // The trend filter needs a few hundred milliseconds of it (a radio scatters more).
    let delays: Vec<_> = (0..90).map(|i| (25_000 + i * 2_000, 25_000)).collect();
    let samples = trace(&mut cc, 0, 16_667, 0, &delays);
    let cut = samples.iter().position(|&(_, t)| t < initial).expect("never cut");
    println!("sustained growth: cut at {} us", samples[cut].0);
    assert!(samples[cut].0 < 1_200_000, "cut only at {} us", samples[cut].0);
}

#[test]
fn queue_growth_survives_transport_and_arrival_clock_wrap() {
    let mut cc = controller();
    let initial = cc.target_bps();
    let delays: Vec<_> = (0..90).map(|i| (25_000 + i * 2_000, 25_000)).collect();
    trace(&mut cc, u64::from(u32::MAX) - 300_000, 16_667, u16::MAX - 20, &delays);
    assert!(cc.target_bps() < initial);
}

#[test]
fn a_delay_step_does_not_keep_reducing_a_flat_path() {
    let mut cc = controller();
    let initial = cc.target_bps();
    let delays: Vec<_> = (0..90).map(|i| (if i == 0 { 25_000 } else { 45_000 }, 25_000)).collect();
    trace(&mut cc, 0, 33_333, 0, &delays);
    assert!(cc.target_bps() >= initial, "a fixed path delay is not a growing queue");
}

#[test]
fn loss_reduces_immediately_without_qualified_delay_evidence() {
    let mut cc = controller();
    let initial = cc.target_bps();
    cc.on_feedback(&[], 0.10, 0);
    assert_eq!(cc.target_bps(), initial);
    cc.on_feedback(&[], 0.4, 1);
    assert_eq!(cc.target_bps(), initial * 4 / 5);
}

#[test]
fn repeated_loss_reports_cut_once_per_response_window() {
    let mut cc = controller();
    cc.on_feedback(&[], 0.4, 1);
    let reduced = cc.target_bps();
    // One rolling loss window is reported at frame/feedback cadence. Repeating
    // it cannot repeatedly reduce a rate the receiver has not seen yet.
    for now in [16_667, 33_334, 50_001, 100_001, 199_999, 200_000] {
        cc.on_feedback(&[], 0.4, now);
        assert_eq!(cc.target_bps(), reduced, "another reduction at {now} us");
    }
    cc.on_feedback(&[], 0.4, 200_001);
    assert_eq!(cc.target_bps(), reduced * 4 / 5);
}

#[test]
fn delay_and_loss_in_one_report_choose_one_reduction() {
    let mut delay_only = controller();
    let mut combined = controller();
    for seq in 0..90u16 {
        let sent = u64::from(seq) * 16_667;
        let arrived = sent + 25_000 + u64::from(seq) * 2_000;
        let now = arrived + 25_000;
        let arrivals = [Arrival { transport_seq: seq, arrival_us: arrived as u32 }];
        delay_only.on_sent(seq, sent);
        combined.on_sent(seq, sent);
        let before = delay_only.target_bps();
        delay_only.on_feedback(&arrivals, 0.0, now);
        if delay_only.target_bps() < before {
            combined.on_feedback(&arrivals, 0.4, now);
            // Delay asks for 0.85x and loss for 0.8x: choose 0.8x, not 0.68x.
            assert_eq!(combined.target_bps(), before * 4 / 5);
            combined.on_feedback(&[], 0.4, now + 1);
            assert_eq!(combined.target_bps(), before * 4 / 5);
            return;
        }
        combined.on_feedback(&arrivals, 0.0, now);
    }
    panic!("trace never produced delay overuse");
}

#[test]
fn response_window_waits_for_rtt_and_keeps_its_original_deadline() {
    let mut cc = controller();
    cc.on_rtt(500_000);
    cc.on_feedback(&[], 0.4, 1);
    let reduced = cc.target_bps();
    cc.on_rtt(50_000);
    cc.on_feedback(&[], 0.4, 200_001);
    assert_eq!(cc.target_bps(), reduced, "RTT update shortened an outstanding response window");
    cc.on_feedback(&[], 0.4, 500_000);
    assert_eq!(cc.target_bps(), reduced);
    cc.on_feedback(&[], 0.4, 500_001);
    assert_eq!(cc.target_bps(), reduced * 4 / 5);
}

#[test]
fn path_change_clears_the_previous_response_window() {
    let mut cc = controller();
    cc.on_rtt(500_000);
    cc.on_feedback(&[], 0.4, 1);
    let reduced = cc.target_bps();
    cc.on_path_changed(PathKind::DirectWan);
    cc.on_feedback(&[], 0.4, 2);
    assert_eq!(cc.target_bps(), reduced * 4 / 5, "old path prevented a new path's first cut");
    let reduced = cc.target_bps();
    cc.on_feedback(&[], 0.4, 200_002);
    assert_eq!(cc.target_bps(), reduced * 4 / 5, "old RTT survived the path change");
}

#[test]
fn a_path_change_discards_delay_state_and_applies_the_relay_cap() {
    let mut cc = controller();
    let delays: Vec<_> = (0..10).map(|i| (25_000 + i * 2_000, 25_000)).collect();
    trace(&mut cc, 0, 16_667, 0, &delays);
    cc.on_path_changed(PathKind::DoRelay);
    assert!(cc.target_bps() <= CcConfig::default().relay_max_bps);
    assert_eq!(cc.capacity_bps(), None);
}

#[test]
fn retransmitted_sequences_are_not_timed() {
    let mut cc = controller();
    let initial = cc.target_bps();
    cc.on_sent(1, 0);
    cc.on_retransmitted(1);
    // Only the repair's very late receipt would show; it is excluded.
    cc.on_feedback(&[Arrival { transport_seq: 1, arrival_us: 900_000 }], 0.0, 1_000_000);
    assert_eq!(cc.target_bps(), initial);
}
