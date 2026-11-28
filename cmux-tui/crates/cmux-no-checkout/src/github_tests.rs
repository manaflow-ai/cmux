use super::*;

#[test]
fn only_owner_name_repositories_and_https_or_loopback_apis() {
    for ok in ["pallets/click", "a-b/c.d_e"] {
        assert!(GitHub::new(GITHUB_API, ok, None, None).is_ok(), "{ok}");
    }
    for bad in ["", "a", "a/b/c", "../x", "a/..", "a/b c", "a/b?x"] {
        assert!(GitHub::new(GITHUB_API, bad, None, None).is_err(), "{bad}");
    }
    assert!(GitHub::new("http://api.github.com", "a/b", None, None).is_err());
    assert!(GitHub::new("http://127.0.0.1:9", "a/b", None, None).is_ok());
}

#[test]
fn url_parts_are_escaped() {
    assert_eq!(escape("feat/a b#c"), "feat/a%20b%23c");
    assert_eq!(escape("main"), "main");
}
