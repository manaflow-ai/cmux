use super::compare;
use std::cmp::Ordering;

#[test]
fn numbers_compare_by_value_and_case_is_ignored() {
    assert_eq!(compare("iPhone 9", "iPhone 17"), Ordering::Less);
    assert_eq!(compare("ipad", "iPhone"), Ordering::Less);
    assert_eq!(compare("iPhone 17e", "iPhone 17"), Ordering::Greater);
    assert_eq!(compare("a", "a"), Ordering::Equal);
}
