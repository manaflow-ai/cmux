use super::*;

#[test]
fn an_old_list_is_due_once_and_a_fresh_or_unprobed_one_is_not() {
    let t0 = Instant::now();
    let mut ages = LiveAges::default();
    ages.started("claude", t0);
    ages.started("codex", t0 + Duration::from_secs(10 * 60));
    let later = t0 + LIVE_MAX_AGE + Duration::from_secs(1);
    let due = ages.claim_due(["claude", "codex", "never"], later);
    assert_eq!(due, BTreeSet::from(["claude".to_owned()]));
    // A second read while that probe runs starts no other.
    assert!(ages.claim_due(["claude"], later + Duration::from_secs(5)).is_empty());
    // Once it is old again, it is due again.
    let again = later + LIVE_MAX_AGE;
    assert_eq!(ages.claim_due(["claude"], again), BTreeSet::from(["claude".to_owned()]));
}
