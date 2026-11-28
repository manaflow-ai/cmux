use super::*;

fn hosts(names: &[&str]) -> Vec<String> {
    names.iter().map(|s| (*s).to_owned()).collect()
}

#[test]
fn a_machine_is_asked_at_most_once_a_minute_and_never_twice_at_once() {
    let mut h = HubHealth::default();
    assert_eq!(h.due(&hosts(&["a", "b"]), 1_000), hosts(&["a", "b"]));
    // Out: not asked again, even past a minute.
    assert!(h.due(&hosts(&["a"]), 1_000 + EVERY_MS).is_empty());
    h.answered("a", Some(json!({"cpus": 4})), 2_000);
    assert!(h.due(&hosts(&["a"]), 2_000).is_empty(), "asked within the minute");
    assert_eq!(h.due(&hosts(&["a"]), 1_000 + EVERY_MS), hosts(&["a"]));
    assert_eq!(h.reading("a"), Some((2_000, json!({"cpus": 4}))));
    // No answer keeps the last reading, and records the failed read.
    h.answered("a", None, 3_000);
    assert_eq!(h.reading("a"), Some((2_000, json!({"cpus": 4}))));
    assert_eq!(h.failed_at("a"), Some(3_000));
    // An answer clears the failure.
    h.answered("a", Some(json!({"cpus": 4})), 4_000);
    assert_eq!(h.failed_at("a"), None);
}

#[test]
fn no_more_than_in_flight_asks_are_out() {
    let mut h = HubHealth::default();
    let many: Vec<String> = (0..20).map(|i| format!("h{i}")).collect();
    assert_eq!(h.due(&many, 0).len(), IN_FLIGHT);
    assert!(h.due(&many, 0).is_empty());
    h.answered("h0", None, 1);
    assert_eq!(h.due(&many, 1), hosts(&["h8"]));
}

#[test]
fn interest_lasts_fifteen_minutes_after_the_last_placement() {
    let mut h = HubHealth::default();
    assert!(!h.wanted(0));
    assert!(!h.interested(0), "no loop ran before");
    assert!(h.wanted(INTEREST_MS - 1));
    assert!(h.interested(10), "the loop still runs");
    assert!(!h.wanted(10 + INTEREST_MS));
}

#[test]
fn a_machine_the_book_no_longer_lists_is_dropped() {
    let mut h = HubHealth::default();
    h.due(&hosts(&["a", "b"]), 0);
    h.answered("a", Some(json!({})), 1);
    h.answered("b", Some(json!({})), 1);
    h.retain(&["a".to_owned()].into_iter().collect());
    assert!(h.reading("b").is_none());
    assert!(h.reading("a").is_some());
}
