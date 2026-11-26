//! The last-good memory: order, freshness, forget and the off switch.

use std::time::Duration;

use super::LastGood;

#[test]
fn the_remembered_winner_goes_first_and_the_rest_keep_their_order() {
    let memory = LastGood::new(Duration::from_secs(60));
    assert_eq!(memory.order(&"peer", &["v6", "v4", "v6b"]), (vec!["v6", "v4", "v6b"], None));
    memory.record("peer", "v4", Duration::from_millis(40));
    assert_eq!(
        memory.order(&"peer", &["v6", "v4", "v6b"]),
        (vec!["v4", "v6", "v6b"], Some(Duration::from_millis(40)))
    );
    // Another peer is unaffected.
    assert_eq!(memory.order(&"other", &["v6", "v4"]), (vec!["v6", "v4"], None));
}

#[test]
fn a_winner_the_resolver_no_longer_returns_changes_nothing() {
    let memory = LastGood::new(Duration::from_secs(60));
    memory.record("peer", "gone", Duration::from_millis(40));
    assert_eq!(memory.order(&"peer", &["v6", "v4"]), (vec!["v6", "v4"], None));
}

#[test]
fn a_stale_or_forgotten_winner_is_not_used() {
    let memory = LastGood::new(Duration::ZERO);
    memory.record("peer", "v4", Duration::from_millis(40));
    assert_eq!(memory.order(&"peer", &["v6", "v4"]), (vec!["v6", "v4"], None));
    let memory = LastGood::new(Duration::from_secs(60));
    memory.record("peer", "v4", Duration::from_millis(40));
    memory.forget(&"peer");
    assert!(memory.get(&"peer").is_none());
}
