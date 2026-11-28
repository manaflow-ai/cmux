use super::token_matches;

#[test]
fn token_comparison() {
    assert!(token_matches(b"abc", b"abc"));
    assert!(!token_matches(b"abd", b"abc"));
    assert!(!token_matches(b"ab", b"abc"));
    assert!(!token_matches(b"", b"abc"));
}
