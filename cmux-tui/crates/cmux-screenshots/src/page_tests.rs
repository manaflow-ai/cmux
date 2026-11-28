use super::*;

#[test]
fn matches_the_page_in_any_case() {
    assert!(matches(ADDRESS));
    assert!(matches("CMUX://Screenshots"));
    assert!(matches("cmux://screenshots/anything?q=1"));
    assert!(!matches("cmux://settings"));
    assert!(!matches("https://screenshots"));
    assert!(!matches("cmux:screenshots"));
    assert!(!matches("screenshots"));
}
