use super::*;

#[test]
fn counts_gaps_before_the_newest_arrival_only() {
    let mut m = LossMeter::default();
    for s in 0..10 {
        m.on_sent(s);
    }
    // 0..=4 settled, 2 missing; 5..=9 still in flight.
    assert_eq!(m.on_arrivals([0, 1, 3, 4]), Some(0.2));
    assert_eq!(m.on_arrivals([5, 6, 7, 8, 9]), Some(0.0));
    assert_eq!(m.on_arrivals([]), None);
}

#[test]
fn feedback_split_over_several_messages_is_not_loss() {
    let mut m = LossMeter::default();
    for s in 0..300u16 {
        m.on_sent(s);
    }
    assert_eq!(m.on_arrivals(0..128), Some(0.0));
    assert_eq!(m.on_arrivals(128..256), Some(0.0));
    assert_eq!(m.on_arrivals(256..300), Some(0.0));
}

#[test]
fn wraps_around_u16() {
    let mut m = LossMeter::default();
    for s in [65534u16, 65535, 0, 1] {
        m.on_sent(s);
    }
    assert_eq!(m.on_arrivals([65534, 0, 1]), Some(0.25));
}

#[test]
fn congestion_loss_weights_packets_and_consumes_each_window_once() {
    let mut m = LossMeter::default();
    for seq in 0..100 {
        m.on_sent(seq);
    }
    assert_eq!(m.on_arrivals([0, 1, 3]), Some(0.25));
    assert_eq!(m.take_congestion_loss(50_000), None);
    m.on_arrivals((4..100).filter(|&s| s != 50));
    assert_eq!(m.take_congestion_loss(549_999), None);
    assert_eq!(m.take_congestion_loss(550_000), Some(0.02));
    assert_eq!(m.take_congestion_loss(1_050_000), None);
}

#[test]
fn traffic_after_idle_gets_a_fresh_observation_window() {
    let mut m = LossMeter::default();
    for seq in 0..20 {
        m.on_sent(seq);
    }
    m.on_arrivals(0..20);
    assert_eq!(m.take_congestion_loss(0), None);
    assert_eq!(m.take_congestion_loss(500_000), Some(0.0));

    for seq in 20..220 {
        m.on_sent(seq);
    }
    m.on_arrivals((20..40).filter(|s| ![22, 25, 28].contains(s)));
    assert_eq!(m.take_congestion_loss(1_500_000), None);
    m.on_arrivals(40..220);
    assert_eq!(m.take_congestion_loss(1_999_999), None);
    assert_eq!(m.take_congestion_loss(2_000_000), Some(0.015));
}

#[test]
fn heavy_loss_is_reported_after_a_bounded_observation_window() {
    let mut m = LossMeter::default();
    for seq in 0..100 {
        m.on_sent(seq);
    }
    m.on_arrivals(50..100);
    assert_eq!(m.take_congestion_loss(0), None);
    assert_eq!(m.take_congestion_loss(500_000), Some(0.5));
    assert_eq!(m.take_congestion_loss(500_001), None);
}

#[test]
fn sparse_feedback_waits_for_enough_packets_and_path_change_discards_old_sample() {
    let mut m = LossMeter::default();
    for seq in 0..4 {
        m.on_sent(seq);
    }
    m.on_arrivals([0, 1, 3]);
    assert_eq!(m.take_congestion_loss(0), None);
    assert_eq!(m.take_congestion_loss(500_000), None);
    m.reset_congestion_window();
    for seq in 4..24 {
        m.on_sent(seq);
    }
    m.on_arrivals(4..24);
    assert_eq!(m.take_congestion_loss(600_000), None);
    assert_eq!(m.take_congestion_loss(1_100_000), Some(0.0));
}
