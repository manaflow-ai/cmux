//! Chrome's URLBlocklist / URLAllowlist filter format, with the examples of Chrome's admin help
//! (support.google.com/chrome/a/answer/9942583): the Swift `BrowserURLFilterTests`, ported.

use crate::ops;
use crate::url_filter::*;
use serde_json::json;

fn blocks_with(blocklist: &[&str], allowlist: &[&str], url: &str) -> bool {
    UrlFilter::new(blocklist, allowlist).blocks(url)
}

fn blocks(blocklist: &[&str], url: &str) -> bool {
    blocks_with(blocklist, &[], url)
}

#[test]
fn host_matches_itself_and_subdomains() {
    assert!(blocks(&["example.com"], "https://example.com"));
    assert!(blocks(&["example.com"], "http://mail.example.com/inbox"));
    assert!(blocks(&["example.com"], "https://EXAMPLE.com./"));
    assert!(!blocks(&["example.com"], "https://notexample.com"));
    assert!(!blocks(&["example.com"], "https://example.com.evil.org"));
}

#[test]
fn leading_dot_matches_only_the_host() {
    assert!(blocks(&[".example.com"], "https://example.com/a"));
    assert!(!blocks(&[".example.com"], "https://mail.example.com"));
}

#[test]
fn scheme_port_path_and_query() {
    assert!(blocks(&["https://*"], "https://a.org"));
    assert!(!blocks(&["https://*"], "http://a.org"));
    assert!(blocks(&["example.com/path"], "https://example.com/path/more"));
    assert!(!blocks(&["example.com/path"], "https://example.com/other"));
    assert!(blocks(&["example.com:8080"], "http://example.com:8080/"));
    assert!(!blocks(&["example.com:8080"], "http://example.com/"));
    assert!(blocks(&["youtube.com/watch?v=V1"], "https://www.youtube.com/watch?v=V1&t=3"));
    assert!(!blocks(&["youtube.com/watch?v=V1"], "https://www.youtube.com/watch?v=V2"));
    assert!(blocks(&["file://*"], "file:///Users/me/secret.txt"));
    assert!(blocks(&["192.168.1.1"], "http://192.168.1.1/admin"));
}

/// Block everything except an allowlist: the classic kiosk policy.
#[test]
fn allowlist_is_the_exception_and_the_more_specific_filter_wins() {
    assert!(!blocks_with(&["*"], &["example.com"], "https://docs.example.com/a"));
    assert!(blocks_with(&["*"], &["example.com"], "https://other.org"));
    assert!(blocks_with(
        &["example.com/private"],
        &["example.com"],
        "https://example.com/private/x"
    ));
    assert!(!blocks_with(&["example.com/private"], &["example.com"], "https://example.com/public"));
    assert!(!blocks_with(&["example.com"], &["example.com"], "https://example.com")); // a tie: allowed
    assert!(!blocks_with(
        &["example.org/private"],
        &["example.org/private/handbook"],
        "https://example.org/private/handbook/1"
    ));
}

#[test]
fn cmux_pages_and_blank_are_never_blocked() {
    assert!(!blocks(&["*"], "about:blank"));
    assert!(!blocks(&["*"], "cmux-page://cmux/newtab"));
    assert!(!blocks(&["*"], "cmux://history"));
}

#[test]
fn unreadable_filters_are_ignored() {
    assert!(UrlFilter::new(&["*.example.com", "", "  "], &[]).is_empty());
    assert!(UrlFilter::NONE.is_empty());
    assert!(!blocks(&[], "https://example.com"));
}

/// The doc comment's example.
#[test]
fn block_everything_but_one_site() {
    let filter = UrlFilter::new(&["*"], &["example.com"]);
    assert!(!filter.blocks("https://www.example.com/a"));
    assert!(filter.blocks("https://other.org"));
}

#[test]
fn rules_parse_like_the_swift_rule() {
    let rule = UrlFilterRule::parse(" HTTPS://.Example.COM.:8443/a/b*?x=1&&y ").unwrap();
    assert_eq!(
        rule,
        UrlFilterRule {
            scheme: Some("https".into()),
            host: "example.com".into(),
            matches_subdomains: false,
            port: Some(8443),
            path: "/a/b".into(),
            query: vec!["x=1".into(), "y".into()],
        }
    );
    assert_eq!(rule.specificity(), Specificity { host: 11, path: 4, query: 2 });
    let any_scheme = UrlFilterRule::parse("*://example.com:*/*").unwrap();
    assert_eq!(any_scheme.scheme, None);
    assert_eq!(any_scheme.port, None);
    assert_eq!(any_scheme.path, "");
    assert!(any_scheme.matches_subdomains);
    assert!(!UrlFilterRule::parse("10.0.0.1").unwrap().matches_subdomains);
    assert!(!UrlFilterRule::parse("[::1]:8080").unwrap().matches_subdomains);
    assert_eq!(UrlFilterRule::parse("[::1]:8080").unwrap().host, "[::1]");
    assert_eq!(
        UrlFilterRule::parse("*").unwrap().specificity(),
        Specificity { host: 0, path: 0, query: 0 }
    );
    assert_eq!(UrlFilterRule::parse("a*b.com"), None);
}

#[test]
fn ports_ip_literals_and_query_values() {
    // A filter port matches the scheme's default port when the URL names none.
    assert!(blocks(&["example.com:443"], "https://example.com/"));
    assert!(!blocks(&["example.com:443"], "http://example.com/"));
    assert!(blocks(&["[::1]"], "http://[::1]:3000/"));
    assert!(!blocks(&["1.1.1.1"], "http://2.1.1.1.1/"));
    // `name` alone needs the parameter with any value.
    assert!(blocks(&["example.com?debug"], "https://example.com/?debug=1"));
    assert!(!blocks(&["example.com?debug"], "https://example.com/?nodebug"));
    // A query value is compared percent-encoded.
    assert!(blocks(&["example.com?q=a%20b"], "https://example.com/?q=a%20b"));
    // The path is compared percent-encoded too.
    assert!(blocks(&["example.com/a%20b"], "https://example.com/a%20b/c"));
}

#[test]
fn the_ops_answer_for_the_filter() {
    let request = json!({"blocklist": ["*"], "allowlist": ["example.com"], "urls": ["https://a.example.com", "https://b.org"]});
    assert_eq!(ops::call("browser_rules_url_filter_blocks", request), Ok(json!([false, true])));
    let request = json!({"blocklist": ["example.com"], "url": "https://example.com"});
    assert_eq!(ops::call("browser_rules_url_filter_blocks", request), Ok(json!(true)));
    let request = json!({"blocklist": ["*.bad"]});
    assert_eq!(ops::call("browser_rules_url_filter_is_empty", request), Ok(json!(true)));
    assert!(matches!(
        ops::call("browser_rules_url_filter_blocks", json!({"blocklist": ["*"]})),
        Err(ops::OpError::Invalid(_))
    ));
}
