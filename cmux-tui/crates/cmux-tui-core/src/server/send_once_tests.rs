use super::*;

#[test]
fn a_key_is_applied_once() {
    let mut keys = SentKeys::new(TTL, 8);
    let now = Instant::now();
    assert!(keys.claim("a", now));
    assert!(!keys.claim("a", now));
    assert!(keys.claim("b", now));
}

#[test]
fn a_forgotten_key_applies_again() {
    let mut keys = SentKeys::new(TTL, 8);
    let now = Instant::now();
    assert!(keys.claim("a", now));
    keys.forget("a");
    assert!(keys.claim("a", now));
}

#[test]
fn keys_are_bounded_in_count_and_age() {
    let mut keys = SentKeys::new(Duration::from_secs(10), 2);
    let now = Instant::now();
    assert!(keys.claim("a", now));
    assert!(keys.claim("b", now));
    assert!(keys.claim("c", now));
    assert_eq!(keys.len(), 2);
    assert!(keys.claim("a", now), "the oldest key went first");
    let later = now + Duration::from_secs(11);
    assert!(keys.claim("c", later), "an expired key applies again");
    assert_eq!(keys.len(), 1);
}
