use super::*;

#[test]
fn the_threshold_is_four_round_trips_at_least_100_ms() {
    assert_eq!(outage_threshold_us(None), 100_000);
    assert_eq!(outage_threshold_us(Some(10_000)), 100_000);
    assert_eq!(outage_threshold_us(Some(40_000)), 160_000);
}

#[test]
fn a_silence_past_the_threshold_is_away_until_an_arrival() {
    let mut s = ViewerLinkState::default();
    s.on_arrival(0, None);
    assert!(!s.is_away(100_000, None));
    assert!(s.is_away(100_001, None));
    assert_eq!(s.away_total_us_at(100_000, None), 0, "not an outage yet");
    assert_eq!(s.away_total_us_at(300_000, None), 300_000, "counted from the silence start");
    s.on_arrival(300_000, None);
    assert!(!s.is_away(300_000, None));
    assert_eq!(s.away_total_us(), 300_000);
}
