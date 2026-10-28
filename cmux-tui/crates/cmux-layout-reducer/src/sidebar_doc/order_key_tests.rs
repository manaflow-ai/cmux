//! Order keys: every answer is a valid key strictly between its bounds, for
//! every pair of short keys, and the keys the byte-slice rewrite (panic deny)
//! produces are the ones the string version produced.

use super::*;

/// Every valid key of up to three digits over an alphabet with both ends,
/// the middle and the carry digits.
fn short_keys() -> Vec<String> {
    let alphabet = ['0', '1', '9', 'A', 'V', 'Y', 'y', 'z'];
    let mut keys = Vec::new();
    let mut frontier = vec![String::new()];
    for _ in 0..3 {
        let next: Vec<String> = frontier
            .iter()
            .flat_map(|key| alphabet.iter().map(move |digit| format!("{key}{digit}")))
            .collect();
        keys.extend(next.iter().cloned());
        frontier = next;
    }
    keys.retain(|key| is_valid(key));
    keys
}

#[test]
fn between_answers_a_valid_key_strictly_inside_every_pair() {
    let keys = short_keys();
    for low in &keys {
        for high in keys.iter().filter(|high| low < *high) {
            let key = between(Some(low), Some(high));
            assert!(is_valid(&key), "between({low}, {high}) = {key}");
            assert!(
                low.as_str() < key.as_str() && key.as_str() < high.as_str(),
                "{low} < {key} < {high}"
            );
        }
        let after = between(Some(low), None);
        assert!(is_valid(&after) && low.as_str() < after.as_str(), "after {low} = {after}");
        let before = between(None, Some(low));
        assert!(is_valid(&before) && before.as_str() < low.as_str(), "before {low} = {before}");
    }
}

#[test]
fn bounds_out_of_order_or_invalid_fall_back_without_panicking() {
    assert_eq!(between(Some("V"), Some("V")), between(Some("V"), None));
    assert_eq!(between(Some("Y"), Some("A")), between(Some("Y"), None));
    assert_eq!(between(Some("A0"), Some("é")), "V");
    assert_eq!(between(Some(""), Some("")), "V");
    assert!(needs_spread(Some("Y"), Some("A")));
}

#[test]
fn keys_match_the_string_implementation() {
    let cases: [(Option<&str>, Option<&str>, &str); 12] = [
        (None, None, "V"),
        (Some("V"), None, "W"),
        (Some("z"), None, "zV"),
        (Some("zz"), None, "zzV"),
        (None, Some("V"), "U"),
        (None, Some("1"), "0z"),
        (None, Some("11"), "1"),
        (None, Some("01"), "00z"),
        (Some("A"), Some("C"), "B"),
        (Some("A"), Some("B"), "AV"),
        (Some("A1"), Some("A2"), "A1V"),
        (Some("Az"), Some("B1"), "B"),
    ];
    for (low, high, want) in cases {
        assert_eq!(between(low, high), want, "between({low:?}, {high:?})");
    }
    assert_eq!(spread(3), ["F", "U", "j"]);
    assert_eq!(spread(40).len(), 40);
    assert!(spread(40).windows(2).all(|pair| pair[0] < pair[1]));
    assert!(spread(200).iter().all(|key| is_valid(key)));
}
