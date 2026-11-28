use super::*;

fn profile(down_kbit: u64, rtt_ms: u64, jitter_ms: u64, loss_percent: f64) -> LinkProfile {
    LinkProfile {
        name: "test".to_owned(),
        version: 1,
        up_kbit: down_kbit,
        down_kbit,
        rtt_ms,
        jitter_ms,
        loss_percent,
        rto_min_ms: 200,
        disruption: None,
        source: String::new(),
    }
}

#[test]
fn no_link_delivers_on_send() {
    let mut link = Link::new(None, Rng::new(1));
    assert_eq!(link.deliver(5_000, 100_000), 5_000);
}

#[test]
fn rate_and_delay_hold() {
    // 256 kbit/s: one 1460-byte segment serializes in 45.625 ms.
    let mut link = Link::new(Some(profile(256, 100, 0, 0.0)), Rng::new(1));
    let first = link.deliver(0, SEGMENT);
    assert_eq!(first, 45_625 + 50_000);
    // A megabyte sent at once cannot arrive faster than the rate.
    let done = link.deliver(0, 1_000_000);
    let min_us = (1_000_000 + SEGMENT as u64) * 8 * 1000 / 256;
    assert!(done >= min_us, "{done} < {min_us}");
}

#[test]
fn loss_holds_a_segment_one_rto() {
    // 99.9% loss on the first draw is a near certainty: the RTO is max(200, 2 * 100) ms.
    let mut link = Link::new(Some(profile(0, 100, 0, 99.9)), Rng::new(3));
    assert!(link.deliver(0, 10) >= 50_000 + 200_000);
}
