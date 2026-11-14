use cmux_rd_core::cc::{CcConfig, CongestionController, PathKind};
use cmux_rd_proto::Arrival;

// Schedule sends and feedback on one causal clock. Reverse jitter affects when
// feedback runs, never the receiver's recorded arrival timestamp. Sorting also
// exercises feedback reordering at 60 fps instead of advancing time backwards.
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
        assert!(
            minimum >= initial,
            "phase={phase}: bounded alternating delay cut {initial} to {minimum}"
        );
    }
}

fn jitter(state: &mut u64) -> u64 {
    // Fixed local generator: these independent seeds are not a claim to replay
    // netem's different PRNG or the closed-loop native stream's packet schedule.
    *state ^= *state << 13;
    *state ^= *state >> 7;
    *state ^= *state << 17;
    12_500 + *state % 25_001
}

#[test]
fn stationary_jitter_independent_seeds_do_not_collapse_over_a_minute() {
    for seed in [1, 7, 31, 0x1234_5678, 20_261_114, 20_261_415_00, 20_261_416_00, u64::MAX] {
        for fps in [30, 60] {
            let mut cc = controller();
            let initial = cc.target_bps();
            let mut state = seed;
            let delays: Vec<_> =
                (0..fps * 60).map(|_| (jitter(&mut state), jitter(&mut state))).collect();
            let samples = trace(&mut cc, 0, 1_000_000 / fps, 0, &delays);
            let minimum = samples.iter().map(|&(_, target)| target).min().unwrap();
            let final_target = cc.target_bps();
            println!("jitter seed={seed} fps={fps} minimum={minimum} final={final_target}");
            assert!(minimum >= initial / 2, "seed={seed} fps={fps}: collapsed to {minimum}");
            assert!(
                final_target >= initial * 3 / 4,
                "seed={seed} fps={fps}: persistent erosion to {final_target}"
            );
        }
    }
}

#[test]
fn sustained_queue_growth_still_cuts_within_four_bursts() {
    let mut cc = controller();
    let initial = cc.target_bps();
    let delays = [(25_000, 25_000), (35_000, 25_000), (45_000, 25_000), (55_000, 25_000)];
    let samples = trace(&mut cc, 0, 100_000, 0, &delays);
    assert!(samples.iter().any(|&(now, target)| now <= 380_000 && target < initial));
}

#[test]
fn tapering_queue_growth_does_not_need_an_accelerating_gradient() {
    let mut cc = controller();
    let initial = cc.target_bps();
    let delays: Vec<_> = [25_000, 35_000, 43_000, 49_000, 53_000, 56_000, 59_000, 62_000]
        .into_iter()
        .map(|forward| (forward, 25_000))
        .collect();
    trace(&mut cc, 0, 33_333, 0, &delays);
    assert!(cc.target_bps() < initial, "a tapering but still growing queue must back off");
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
fn a_delay_step_does_not_keep_reducing_a_flat_path() {
    let mut cc = controller();
    let initial = cc.target_bps();
    let delays: Vec<_> = (0..90).map(|i| (if i == 0 { 25_000 } else { 45_000 }, 25_000)).collect();
    let samples = trace(&mut cc, 0, 33_333, 0, &delays);
    let early_minimum = samples[..15].iter().map(|&(_, target)| target).min().unwrap();
    assert!(cc.target_bps() > early_minimum);
    assert!(cc.target_bps() > initial / 2, "a fixed path delay is not a growing queue");
}

#[test]
fn queue_growth_survives_transport_and_arrival_clock_wrap() {
    let mut cc = controller();
    let initial = cc.target_bps();
    let delays = [(25_000, 25_000), (35_000, 25_000), (45_000, 25_000), (55_000, 25_000)];
    trace(&mut cc, u64::from(u32::MAX) - 30_000, 100_000, u16::MAX - 1, &delays);
    assert!(cc.target_bps() < initial);
}
