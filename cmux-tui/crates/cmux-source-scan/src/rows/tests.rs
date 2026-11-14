use super::*;

fn left(named: &[&str], found: &[&str]) -> (Vec<String>, Vec<String>) {
    let u = unmatched(named, found, |n, f| f.contains(n));
    (
        u.missing.iter().map(ToString::to_string).collect(),
        u.extra.iter().map(ToString::to_string).collect(),
    )
}

#[test]
fn a_second_copy_is_extra_and_two_named_copies_take_both() {
    let none: Vec<String> = Vec::new();
    assert_eq!(left(&["a"], &["1: a", "1: a"]), (none.clone(), vec!["1: a".to_string()]));
    assert_eq!(left(&["a", "a"], &["1: a", "1: a"]), (none.clone(), none.clone()));
    assert_eq!(left(&["a", "a"], &["1: a"]), (vec!["a".to_string()], none.clone()));
    assert_eq!(left(&[], &["1: a"]), (none.clone(), vec!["1: a".to_string()]));
    assert_eq!(left(&[], &[]), (none.clone(), none));
}

/// A broad name listed first must not take the one finding a narrow name needs.
#[test]
fn the_pairing_does_not_hang_on_the_order_names_come_in() {
    let none: Vec<String> = Vec::new();
    let found = ["1: closure B", "1: closure"];
    assert_eq!(left(&["closure", "closure B"], &found), (none.clone(), none.clone()));
    assert_eq!(left(&["closure B", "closure"], &found), (none.clone(), none));
}
