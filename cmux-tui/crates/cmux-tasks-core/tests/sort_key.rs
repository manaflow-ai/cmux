//! Sort keys arrive from clients (`task.create --sort-key`) and from the op
//! log: any string gives a key or `None`, never a panic, and every key
//! `between` returns sorts strictly between its bounds.

use cmux_tasks_core::sort_key::{MAX_LEN, between, is_valid, sequence};
use proptest::prelude::*;

#[test]
fn validity_follows_the_integer_head() {
    for key in ["a0", "a1V", "b10", "Zz", "Zz1", "a0V"] {
        assert!(is_valid(key), "{key:?}");
    }
    for key in ["", "a", "b1", "a00", "a10", "Z", "!0", "é0", "a0é", "A00000000000000000000000000"]
    {
        assert!(!is_valid(key), "{key:?}");
    }
    assert!(!is_valid(&format!("a0{}", "1".repeat(MAX_LEN))));
}

#[test]
fn between_handles_open_ends_and_rejects_bad_bounds() {
    assert_eq!(between(None, None).as_deref(), Some("a0"));
    assert_eq!(between(Some("a0"), None).as_deref(), Some("a1"));
    assert_eq!(between(None, Some("a0")).as_deref(), Some("Zz"));
    assert_eq!(between(Some("a0"), Some("a1")).as_deref(), Some("a0V"));
    assert_eq!(between(Some("az"), None).as_deref(), Some("b00"));
    assert_eq!(between(None, Some("b00")).as_deref(), Some("az"));
    assert_eq!(between(Some("a1"), Some("a0")), None);
    assert_eq!(between(Some("a0"), Some("a0")), None);
    assert_eq!(between(Some("b1"), None), None);
    assert_eq!(between(None, Some("é")), None);
}

#[test]
fn the_smallest_integer_takes_a_fraction() {
    let smallest = format!("A{}", "0".repeat(26));
    let lower = between(None, Some(&format!("{smallest}1"))).unwrap();
    assert!(lower.starts_with(&smallest) && lower < format!("{smallest}1"));
}

#[test]
fn sequence_is_strictly_increasing() {
    let keys = sequence(2_000);
    assert_eq!(keys.len(), 2_000);
    assert!(keys.windows(2).all(|pair| pair[0] < pair[1]));
    assert!(keys.iter().all(|key| is_valid(key) && key.len() <= 4));
}

#[test]
fn repeated_inserts_into_one_gap_stop_at_max_len() {
    let (low, mut high) = ("a0".to_owned(), "a1".to_owned());
    let mut steps = 0;
    while let Some(key) = between(Some(&low), Some(&high)) {
        assert!(low < key && key < high, "{low} < {key} < {high}");
        high = key;
        steps += 1;
        assert!(steps < 10_000);
    }
    assert!(high.len() <= MAX_LEN);
}

proptest! {
    #[test]
    fn any_bounds_give_an_ordered_key_or_none(a in "[0-9A-Za-z]{0,6}", b in "[0-9A-Za-z]{0,6}", raw in any::<String>()) {
        let _ = between(Some(&raw), None);
        let _ = between(Some(&raw), Some(&raw));
        let _ = between(None, Some(&raw));
        if let Some(key) = between(Some(&a), Some(&b)) {
            prop_assert!(is_valid(&key));
            prop_assert!(a < key && key < b, "{a} < {key} < {b}");
        }
        if let Some(key) = between(Some(&a), None) {
            prop_assert!(a < key);
        }
        if let Some(key) = between(None, Some(&b)) {
            prop_assert!(key < b);
        }
    }
}
