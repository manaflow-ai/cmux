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
    assert_eq!(cc.ultra_fec_ratio(), None);
}

#[test]
fn ultra_uses_measured_capacity_and_configurable_wire_ceiling() {
    let mut cc = ultra();
    assert_eq!(cc.wire_budget_bps(), 150_000_000);
    assert!(cc.target_bps() < cc.wire_budget_bps(), "parity fits inside wire budget");
    cc.configure_ultra(UltraConfig { max_wire_bps: 120_000_000, ..UltraConfig::default() });
    cc.on_probe_capacity(cc.probe_generation(), 100_000_000);
    assert_eq!(cc.wire_budget_bps(), 80_000_000);
    cc.on_probe_capacity(cc.probe_generation(), u64::MAX);
    assert_eq!(cc.wire_budget_bps(), 120_000_000);
    cc.on_probe_capacity(cc.probe_generation(), 0);
    assert_eq!(cc.wire_budget_bps(), 120_000_000, "invalid probe is ignored");
}

#[test]
fn ultra_loss_buys_parity_without_cutting_or_exceeding_wire_rate() {
    let mut cc = ultra();
    for (i, loss) in [0.0, 0.02, 0.2, 0.5, 1.0].into_iter().enumerate() {
        feedback(&mut cc, i as u16, i as u64 * 50_000, 20_000, loss);
        assert_eq!(cc.wire_budget_bps(), 150_000_000);
        let ratio = cc.ultra_fec_ratio().unwrap();
        assert!((ratio - (loss * 2.0).max(0.1)).abs() < 1e-9);
        assert!(cc.target_bps() as f64 * (1.0 + ratio) <= cc.wire_budget_bps() as f64);
    }
    cc.on_feedback(&[], f64::NAN, 1_000_000);
    assert_eq!(cc.ultra_fec_ratio(), Some(2.0), "invalid loss cannot erase evidence");
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
