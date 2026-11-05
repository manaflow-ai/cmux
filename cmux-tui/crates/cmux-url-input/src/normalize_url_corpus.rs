//! The daemon normalization corpus, moved with the rule from cmux-tui-core
//! (browser/tests/reconfigure_and_attach.rs) unchanged.

use super::normalize_url;

#[test]
fn normalizes_browser_urls() {
    assert_eq!(normalize_url("example.com"), "https://example.com");
    assert_eq!(normalize_url("example.com:8080"), "https://example.com:8080");
    assert_eq!(normalize_url(" https://example.com "), "https://example.com");
    assert_eq!(normalize_url("https://example.com/a"), "https://example.com/a");
    assert_eq!(normalize_url("about:blank"), "about:blank");
    assert_eq!(normalize_url("file:///tmp/test.html"), "file:///tmp/test.html");
    assert_eq!(normalize_url("mailto:test@example.com"), "mailto:test@example.com");
    assert_eq!(normalize_url("localhost:3000/path"), "http://localhost:3000/path");
    assert_eq!(normalize_url("127.0.0.1/test"), "http://127.0.0.1/test");
    assert_eq!(normalize_url("[::1]:8080"), "http://[::1]:8080");
    assert_eq!(normalize_url("plainwords"), "https://www.google.com/search?q=plainwords");
    assert_eq!(normalize_url("two words?"), "https://www.google.com/search?q=two%20words%3F");
}

/// Intranet addresses load over http, the way Chrome and the cmux-next
/// omnibar (BrowserURLResolver) take them: `go/gday` at a company whose
/// DNS search domain resolves `go` (user 2026-10-20). A single label needs
/// a path, a trailing slash or a port; alone it is still a search.
#[test]
fn intranet_addresses_load_over_http() {
    assert_eq!(normalize_url("go/gday"), "http://go/gday");
    assert_eq!(normalize_url("go/"), "http://go/");
    assert_eq!(normalize_url("wiki/Team-Page?x=1"), "http://wiki/Team-Page?x=1");
    assert_eq!(normalize_url("myhost:8080"), "http://myhost:8080");
    assert_eq!(normalize_url("devbox:8080/api"), "http://devbox:8080/api");
    assert_eq!(normalize_url("nas.local"), "http://nas.local");
    assert_eq!(normalize_url("grafana.internal:3000/d"), "http://grafana.internal:3000/d");
    assert_eq!(normalize_url("192.168.1.10/admin"), "http://192.168.1.10/admin");
    assert_eq!(normalize_url("10.0.0.5"), "http://10.0.0.5");
    assert_eq!(normalize_url("go"), "https://www.google.com/search?q=go");
    assert_eq!(normalize_url("1234/5678"), "https://www.google.com/search?q=1234%2F5678");
    assert_eq!(normalize_url("8.8.8.8"), "https://8.8.8.8");
    assert_eq!(normalize_url("example.com/a"), "https://example.com/a");
    for input in ["go/gday", "myhost:8080", "nas.local"] {
        let once = normalize_url(input);
        assert_eq!(normalize_url(&once), once, "not idempotent for {input:?}");
    }
}

#[test]
fn normalization_is_idempotent() {
    for input in ["localhost:3000", "example.com", "two words?", "mailto:x@y.z"] {
        let once = normalize_url(input);
        assert_eq!(normalize_url(&once), once, "not idempotent for {input:?}");
    }
}
