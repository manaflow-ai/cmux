use super::*;

#[test]
fn a_connect_counts_its_first_byte_and_winner_and_whether_it_waited_on_direct() {
    let mut stats = LinkStats::new(0);
    stats.opened(&[Via::Wireguard, Via::Ssh], Via::Ssh, 1_000, 1_420);
    let view = stats.view(1_420);
    assert_eq!(view["opens"], 1);
    assert_eq!(view["firstByteMs"], 420);
    assert_eq!(view["winner"], "ssh");
    assert_eq!(view["winnerCarrier"], "ssh");
    assert_eq!(view["waitedOnDirect"], 1, "a direct path was dialed ahead of ssh and lost");

    // Direct first and winning, or ssh first: no wait on a direct path.
    stats.opened(&[Via::Link, Via::Ssh], Via::Link, 2_000, 2_030);
    stats.opened(&[Via::Ssh, Via::Link], Via::Ssh, 3_000, 3_050);
    let view = stats.view(3_050);
    assert_eq!(view["opens"], 3);
    assert_eq!(view["firstByteMs"], 50);
    assert_eq!(view["waitedOnDirect"], 1);
}

#[test]
fn time_on_each_path_and_carrier_adds_up_and_a_move_is_a_switch() {
    let mut stats = LinkStats::new(0);
    stats.serving(Some(Via::Ssh), 0);
    stats.serving(Some(Via::Link), 4_000);
    stats.serving(None, 10_000);
    // Back after an outage on the hub: a switch from the link.
    stats.serving(Some(Via::Hub), 12_000);
    let view = stats.view(13_000);
    assert_eq!(view["switches"], 2);
    assert_eq!(view["serving"], "hub");
    assert_eq!(view["onPathMs"]["ssh"], 4_000);
    assert_eq!(view["onPathMs"]["link"], 6_000);
    assert_eq!(view["onPathMs"]["hub"], 1_000, "the current path counts up to now");
    assert_eq!(view["onCarrierMs"]["direct"], 6_000);
    assert_eq!(view["onCarrierMs"]["ssh"], 4_000);
    assert_eq!(view["onCarrierMs"]["hub"], 1_000);
    // The same path again is no switch.
    stats.serving(None, 13_000);
    stats.serving(Some(Via::Hub), 14_000);
    assert_eq!(stats.view(14_000)["switches"], 2);
}

#[test]
fn round_trip_percentiles_come_from_a_bounded_ring() {
    let mut stats = LinkStats::new(0);
    for ms in 1..=100u64 {
        stats.pong(Via::Hub, ms * 1_000, true);
    }
    let view = stats.view(0);
    let hub = &view["rtt"]["hub"];
    assert_eq!(hub["samples"], RTT_SAMPLES);
    // Only the last 64 (37..=100 ms) are kept.
    assert_eq!(hub["p50Ms"].as_f64(), Some(68.0));
    assert_eq!(hub["p95Ms"].as_f64(), Some(97.0));
    assert_eq!(stats.rtt_p95_ms().get("hub"), Some(&97.0));
    assert!(view["rtt"]["ssh"].is_null(), "no samples, no row");
}

#[test]
fn a_direct_probe_while_relayed_is_an_upgrade_attempt() {
    let mut stats = LinkStats::new(0);
    // Not serving yet: no attempt.
    stats.failed(Via::Wireguard, false);
    stats.serving(Some(Via::Hub), 0);
    stats.failed(Via::Wireguard, false);
    stats.failed(Via::Wireguard, false);
    // The ssh path is not direct; an answering direct path is no attempt.
    stats.failed(Via::Ssh, false);
    stats.pong(Via::Wireguard, 5_000, false);
    stats.pong(Via::Wireguard, 5_000, true);
    let up = &stats.view(0)["directUpgrade"];
    assert_eq!(up["attempts"], 3);
    assert_eq!(up["failures"], 2);
    assert_eq!(up["upgrades"], 1);
    // On a direct path there is nothing to upgrade.
    stats.serving(Some(Via::Wireguard), 1);
    stats.failed(Via::Link, false);
    assert_eq!(stats.view(1)["directUpgrade"]["attempts"], 3);
}

#[test]
fn every_attempt_is_recorded_with_its_transport_in_a_bounded_ring() {
    let mut stats = LinkStats::new(0);
    stats.attempt_failed(Via::Wireguard, 900, false);
    stats.opened(&[Via::Wireguard, Via::Ssh], Via::Ssh, 1_000, 1_420);
    let view = stats.view(1_420);
    let rows = view["attempts"].as_array().unwrap();
    assert_eq!(rows.len(), 2);
    assert_eq!(rows[0]["transport"], "wireguard");
    assert_eq!(rows[0]["outcome"], "failed");
    assert_eq!(rows[0]["firstByteMs"], serde_json::Value::Null);
    assert_eq!(rows[1]["transport"], "ssh");
    assert_eq!(rows[1]["carrier"], "ssh");
    assert_eq!(rows[1]["outcome"], "opened");
    assert_eq!(rows[1]["firstByteMs"], 420);

    for i in 0..(ATTEMPT_SAMPLES as u64 * 2) {
        stats.opened(&[Via::Wireguard], Via::Wireguard, i * 10, i * 10 + 5);
    }
    let view = stats.view(10_000);
    assert_eq!(view["attempts"].as_array().unwrap().len(), ATTEMPT_SAMPLES);
}
