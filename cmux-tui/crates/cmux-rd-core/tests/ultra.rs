use cmux_rd_core::cc::{CcConfig, CongestionController, PathKind, UltraConfig};
use cmux_rd_core::profile::EncodeProfile;
use cmux_rd_proto::Arrival;

fn ultra() -> CongestionController {
    let mut cc = CongestionController::new(CcConfig::default(), PathKind::DirectWan);
    cc.set_profile(EncodeProfile::Ultra);
    cc.on_probe_capacity(cc.probe_generation(), 200_000_000);
    cc
}

fn feedback(cc: &mut CongestionController, seq: u16, sent: u64, delay: u64, loss: f64) {
    cc.on_sent_bytes(seq, sent, 1200);
    let arrivals = [Arrival { transport_seq: seq, arrival_us: (sent + delay) as u32 }];
    cc.on_feedback(&arrivals, loss, sent + delay + 10_000);
}

#[test]
fn standard_remains_default_and_does_not_adopt_probe_capacity() {
    let mut cc = CongestionController::new(CcConfig::default(), PathKind::DirectWan);
    assert_eq!(cc.profile(), EncodeProfile::Standard);
    cc.on_probe_capacity(cc.probe_generation(), 1_000_000_000);
    assert_eq!(cc.target_bps(), CcConfig::default().start_bps);
}

#[test]
fn ultra_uses_measured_capacity_and_configurable_wire_ceiling() {
    let mut cc = ultra();
    assert_eq!(cc.wire_budget_bps(), 150_000_000);
    assert!(cc.target_bps() <= cc.wire_budget_bps());
    cc.configure_ultra(UltraConfig { max_wire_bps: 120_000_000, ..UltraConfig::default() });
    cc.on_probe_capacity(cc.probe_generation(), 100_000_000);
    assert_eq!(cc.wire_budget_bps(), 100_000_000);
    cc.on_probe_capacity(cc.probe_generation(), u64::MAX);
    assert_eq!(cc.wire_budget_bps(), 120_000_000);
    cc.on_probe_capacity(cc.probe_generation(), 0);
    assert_eq!(cc.wire_budget_bps(), 120_000_000, "invalid probe is ignored");
}

#[test]
fn ultra_requires_standing_queue_and_cuts_only_once_per_response_window() {
    let mut cc = ultra();
    cc.on_rtt(400_000);
    feedback(&mut cc, 0, 0, 20_000, 0.0);
    for i in 1..=4 {
        feedback(&mut cc, i, u64::from(i) * 50_000, 50_000, 0.0);
        assert_eq!(cc.wire_budget_bps(), 150_000_000, "less than 200 ms of queue");
    }
    feedback(&mut cc, 5, 250_000, 50_000, 0.0);
    let cut = cc.wire_budget_bps();
    assert!(cut < 150_000_000);
    cc.on_rtt(1_000); // Cannot shorten the already frozen response window.
    for i in 6..=11 {
        feedback(&mut cc, i, u64::from(i) * 50_000, 50_000, 0.9);
        assert_eq!(cc.wire_budget_bps(), cut);
    }
    feedback(&mut cc, 12, 600_000, 20_000, 0.0);
    assert_eq!(cc.wire_budget_bps(), 150_000_000, "restore held rate after clear");
}

#[test]
fn ultra_jitter_and_idle_gaps_are_not_a_standing_queue() {
    let mut cc = ultra();
    for i in 0..30 {
        let delay = if i % 2 == 0 { 10_000 } else { 70_000 };
        feedback(&mut cc, i, u64::from(i) * 50_000, delay, 0.02);
        assert_eq!(cc.wire_budget_bps(), 150_000_000);
    }
    // An isolated high-delay packet after a quiet screen cannot extend the
    // pre-idle queue observation into a false 500 ms standing queue.
    feedback(&mut cc, 30, 2_000_000, 100_000, 0.02);
    assert_eq!(cc.wire_budget_bps(), 150_000_000);
}

#[test]
fn ultra_path_change_discards_measurement_and_old_path_feedback() {
    let mut cc = ultra();
    cc.on_sent_bytes(91, 0, 1200);
    cc.on_path_changed(PathKind::DoRelay);
    assert_eq!(cc.wire_budget_bps(), CcConfig::default().relay_max_bps);
    cc.on_feedback(&[Arrival { transport_seq: 91, arrival_us: 500_000 }], 0.0, 600_000);
    cc.on_probe_capacity(cc.probe_generation(), 1_000_000_000);
    assert_eq!(cc.wire_budget_bps(), CcConfig::default().relay_max_bps);
    cc.on_path_changed(PathKind::DirectWan);
    assert_eq!(cc.wire_budget_bps(), CcConfig::default().start_bps);
    cc.on_rtt(1_000);
    assert_eq!(cc.wire_budget_bps(), CcConfig::default().start_bps, "RTT alone is not capacity");
}

#[test]
fn ultra_underfilled_encoder_never_grows_without_a_probe_measurement() {
    let mut cc = CongestionController::new(CcConfig::default(), PathKind::DirectWan);
    cc.set_profile(EncodeProfile::Ultra);
    for i in 0..100 {
        feedback(&mut cc, i, u64::from(i) * 50_000, 20_000, 0.0);
    }
    assert_eq!(cc.wire_budget_bps(), CcConfig::default().start_bps);
}

#[test]
fn ultra_rejects_old_path_probe_and_honors_configured_queue_limits() {
    let mut cc = ultra();
    let old_generation = cc.probe_generation();
    cc.on_path_changed(PathKind::DirectWan);
    assert!(!cc.on_probe_capacity(old_generation, 1_000_000_000));
    assert_eq!(cc.wire_budget_bps(), CcConfig::default().start_bps);
    assert!(cc.on_probe_capacity(cc.probe_generation(), 200_000_000));
    cc.configure_ultra(UltraConfig {
        max_wire_bps: 150_000_000,
        queue_floor_us: 30_000,
        standing_queue_us: 300_000,
    });
    feedback(&mut cc, 0, 0, 20_000, 0.0);
    for i in 1..=10 {
        feedback(&mut cc, i, u64::from(i) * 50_000, 40_000, 0.0);
    }
    assert_eq!(cc.wire_budget_bps(), 150_000_000, "20 ms queue is below configured floor");
    for i in 11..=16 {
        feedback(&mut cc, i, u64::from(i) * 50_000, 80_000, 0.0);
        assert_eq!(cc.wire_budget_bps(), 150_000_000, "less than configured 300 ms");
    }
    feedback(&mut cc, 17, 850_000, 80_000, 0.0);
    assert!(cc.wire_budget_bps() < 150_000_000);
}

/// D10 (2026-11-17): loss over what FEC covers (5%) lasting more than a second is a cut
/// signal in ultra too, one cut per response window like a standing queue; the held rate
/// returns once the loss is back under it. Loss samples come about every 500 ms (the
/// engine's loss meter); feedback between them carries 0.0.
#[test]
fn ultra_cuts_on_loss_over_five_percent_for_a_second_once_per_window() {
    let mut cc = ultra();
    // `feedback` reports at sent + 30 ms with a steady 20 ms delay: never a queue.
    let mut seq = 0u16;
    let mut step = |cc: &mut CongestionController, sent: u64, loss: f64| {
        feedback(cc, seq, sent, 20_000, loss);
        seq += 1;
        cc.wire_budget_bps()
    };
    for sent in (0..1_000_000).step_by(50_000) {
        let loss = if sent % 500_000 == 0 { 0.2 } else { 0.0 };
        assert_eq!(step(&mut cc, sent, loss), 150_000_000, "under a second of loss");
    }
    // The third 20% sample, a second after the first: cut.
    let cut = step(&mut cc, 1_000_000, 0.2);
    assert!(cut < 150_000_000, "a second of loss over 5% cuts");
    // Once per response window (200 ms here), while the loss lasts.
    for sent in [1_050_000, 1_100_000, 1_150_000] {
        assert_eq!(step(&mut cc, sent, 0.0), cut, "one cut per window");
    }
    let again = step(&mut cc, 1_250_000, 0.0);
    assert!(again < cut, "the next window cuts again");
    // A sample at or under 5% ends it: the held rate returns.
    assert_eq!(step(&mut cc, 1_500_000, 0.05), 150_000_000);
}

#[test]
fn ultra_never_cuts_on_loss_at_or_under_five_percent() {
    let mut cc = ultra();
    for i in 0..100u16 {
        let sent = u64::from(i) * 50_000;
        let loss = if i % 10 == 0 { 0.05 } else { 0.0 };
        feedback(&mut cc, i, sent, 20_000, loss);
        assert_eq!(cc.wire_budget_bps(), 150_000_000, "5% loss for 5 s only raises FEC");
    }
}

/// Until a train measures the path (a jittery path's trains never do), ultra's rate moves
/// by standard's measured rules within its own ceiling instead of sitting at the start
/// rate (netem, 15 ms jitter and 1% loss: standard held 49 Mbit/s, ultra delivered no frame).
#[test]
fn unmeasured_ultra_moves_like_standard_until_a_train_counts() {
    let mut standard = CongestionController::new(CcConfig::default(), PathKind::DirectWan);
    let mut unmeasured = CongestionController::new(CcConfig::default(), PathKind::DirectWan);
    unmeasured.set_profile(EncodeProfile::Ultra);
    let mut seq = 0u16;
    for batch in 0..400u64 {
        let mut arrivals = Vec::new();
        for i in 0..10u64 {
            let sent = (batch * 10 + i) * 1_000;
            for cc in [&mut standard, &mut unmeasured] {
                cc.on_sent_bytes(seq, sent, 1_200);
            }
            arrivals.push(Arrival { transport_seq: seq, arrival_us: (sent + 20_000) as u32 });
            seq = seq.wrapping_add(1);
        }
        let now = (batch * 10 + 10) * 1_000 + 20_000;
        standard.on_feedback(&arrivals, 0.0, now);
        unmeasured.on_feedback(&arrivals, 0.0, now);
        assert_eq!(unmeasured.wire_budget_bps(), standard.target_bps(), "batch {batch}");
    }
    assert!(standard.target_bps() > CcConfig::default().start_bps, "it grew on evidence");

    // A train that counts takes over at the delivered goodput.
    assert!(unmeasured.on_probe_capacity(unmeasured.probe_generation(), 100_000_000));
    assert_eq!(unmeasured.wire_budget_bps(), 100_000_000);
}

/// Ultra's encoder targets the held rate; its strict pacer releases at the probed capacity
/// (2.5x the held rate until one is measured), so a frame burst drains instead of queueing
/// for good. Standard paces at its target.
#[test]
fn ultra_paces_at_the_probed_capacity_over_the_held_rate() {
    let mut cc = CongestionController::new(CcConfig::default(), PathKind::DirectWan);
    assert_eq!(cc.pacing_bps(), cc.target_bps(), "standard");
    cc.set_profile(EncodeProfile::Ultra);
    let start = CcConfig::default().start_bps;
    assert_eq!(cc.pacing_bps(), start * 5 / 2, "unmeasured: 2.5x the start rate");
    cc.on_probe_capacity(cc.probe_generation(), 100_000_000);
    assert_eq!(cc.wire_budget_bps(), 100_000_000);
    assert_eq!(cc.pacing_bps(), 100_000_000, "paced at the capacity");
    cc.on_probe_capacity(cc.probe_generation(), 1_000_000_000);
    assert_eq!(cc.wire_budget_bps(), 150_000_000, "held under the ceiling");
    assert_eq!(cc.pacing_bps(), 1_000_000_000);
}
