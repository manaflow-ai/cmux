//! The cookie calls' rules, pinned to `WebKitDriver+Cookies`'s behavior.

use crate::cookies::*;
use crate::ops;
use serde_json::{Value, json};

fn stored(name: &str, domain: &str, path: &str, secure: bool) -> StoredCookie {
    StoredCookie { name: name.into(), domain: domain.into(), path: path.into(), secure }
}

fn backed_up(name: &str, domain: &str, path: &str, expires: f64) -> BackedUpCookie {
    BackedUpCookie {
        name: name.into(),
        value: "v".into(),
        domain: domain.into(),
        path: path.into(),
        expires,
        ..BackedUpCookie::default()
    }
}

#[test]
fn url_facts_read_like_foundation() {
    let facts = url_facts("https://[::1]:8080/a%20b/").unwrap();
    assert_eq!(facts.scheme, "https");
    assert_eq!(facts.host.as_deref(), Some("::1"));
    assert_eq!(facts.path, "/a b");
    assert_eq!(url_facts("https://a.test/").unwrap().path, "/");
    assert_eq!(url_facts("https://a.test").unwrap().path, "");
    assert_eq!(url_facts("about:blank").unwrap().host, None);
    assert_eq!(url_facts("not a url"), None);
}

#[test]
fn a_cookie_is_in_a_sites_scope_both_ways() {
    assert!(in_scope(".example.com", "example.com"));
    assert!(in_scope("example.com", "www.example.com"));
    assert!(in_scope("www.example.com", "example.com"));
    assert!(in_scope("EXAMPLE.com.", "example.com"));
    assert!(!in_scope("notexample.com", "example.com"));
    assert!(!in_scope(".", "example.com"));
}

#[test]
fn a_cookie_matches_a_url_by_host_scheme_and_path() {
    let root = stored("a", ".example.com", "/", false);
    assert!(cookie_matches(&root, "https://www.example.com/x"));
    assert!(cookie_matches(&root, "http://example.com"));
    assert!(!cookie_matches(&root, "https://example.org/"));
    let secure = stored("s", "example.com", "/", true);
    assert!(!cookie_matches(&secure, "http://example.com/"));
    assert!(cookie_matches(&secure, "https://example.com/"));
    let docs = stored("d", "example.com", "/docs", false);
    assert!(cookie_matches(&docs, "https://example.com/docs"));
    assert!(cookie_matches(&docs, "https://example.com/docs/a"));
    assert!(!cookie_matches(&docs, "https://example.com/docsx"));
    let slash = stored("d", "example.com", "/docs/", false);
    assert!(cookie_matches(&slash, "https://example.com/docs/a"));
}

#[test]
fn cookies_for_no_readable_url_are_every_cookie() {
    let cookies = vec![stored("a", "a.test", "/", false), stored("b", "b.test", "/", false)];
    assert_eq!(cookies_for_urls(&cookies, &[]), vec![0, 1]);
    assert_eq!(cookies_for_urls(&cookies, &["not a url".into()]), vec![0, 1]);
    assert_eq!(cookies_for_urls(&cookies, &["https://b.test/".into()]), vec![1]);
}

#[test]
fn a_playwright_cookie_with_a_url_takes_its_host_and_directory() {
    let make = |value: Value| playwright_cookie(value.as_object().unwrap());
    let cookie =
        make(json!({"name": "n", "value": "v", "url": "https://a.test/dir/page"})).unwrap();
    assert_eq!((cookie.domain.as_str(), cookie.path.as_str()), ("a.test", "/dir"));
    assert_eq!(cookie.expires, -1.0);
    let cookie = make(json!({"name": "n", "value": "v", "url": "https://a.test/page"})).unwrap();
    assert_eq!(cookie.path, "/");
    // Foundation's `path` drops the trailing slash, so `/dir/` is read as the file `dir`.
    let cookie = make(json!({"name": "n", "value": "v", "url": "https://a.test/dir/"})).unwrap();
    assert_eq!(cookie.path, "/");
    let cookie =
        make(json!({"name": "n", "value": "v", "url": "https://a.test/x/y", "path": "/p"}))
            .unwrap();
    assert_eq!(cookie.path, "/p");
    let cookie = make(json!({
        "name": "n", "value": "v", "domain": ".a.test", "httpOnly": true, "secure": true,
        "sameSite": "Lax", "expires": 99
    }))
    .unwrap();
    assert!(cookie.http_only && cookie.secure);
    assert_eq!(
        (cookie.path.as_str(), cookie.same_site.as_deref(), cookie.expires),
        ("/", Some("Lax"), 99.0)
    );
    assert!(make(json!({"name": "n"})).unwrap_err().contains("name and a value"));
    assert!(make(json!({"name": "n", "value": "v"})).unwrap_err().contains("needs a url"));
    assert!(
        make(json!({"name": "n", "value": "v", "url": "about:blank"}))
            .unwrap_err()
            .contains("http(s) URL")
    );
}

#[test]
fn cookies_set_refuses_an_expired_cookie_and_a_non_object() {
    let ok = json!({"name": "n", "value": "v", "domain": "a.test", "expires": -1});
    assert_eq!(cookies_to_set(std::slice::from_ref(&ok), 100.0).unwrap().len(), 1);
    let expired = json!({"name": "n", "value": "v", "domain": "a.test", "expires": 100});
    assert!(cookies_to_set(&[ok, expired], 100.0).unwrap_err().contains("clearCookies()"));
    assert!(cookies_to_set(&[json!(1)], 0.0).unwrap_err().contains("array of objects"));
}

#[test]
fn a_clear_needs_an_http_page_and_matches_its_filter() {
    assert_eq!(clear_site(Some("https://WWW.A.test/x")), Ok("www.a.test".into()));
    assert!(clear_site(Some("about:blank")).unwrap_err().contains("shows a about: page"));
    assert!(clear_site(None).unwrap_err().contains("shows no page"));
    let cookies = vec![
        stored("a", ".a.test", "/", false),
        stored("b", "www.a.test", "/x", false),
        stored("a", "b.test", "/", false),
    ];
    assert_eq!(clear_matches(&cookies, "www.a.test", &ClearFilter::default()), vec![0, 1]);
    let named = ClearFilter { name: Some("a".into()), ..ClearFilter::default() };
    assert_eq!(clear_matches(&cookies, "www.a.test", &named), vec![0]);
    let empty = ClearFilter { name: Some(String::new()), path: Some("/x".into()), domain: None };
    assert_eq!(clear_matches(&cookies, "www.a.test", &empty), vec![1]);
}

#[test]
fn a_restore_keeps_newer_cookies_and_drops_expired_ones() {
    let cookies = vec![
        backed_up("a", "a.test", "/", -1.0),
        backed_up("b", "a.test", "/", 5.0),
        backed_up("c", "a.test", "/", 500.0),
    ];
    let existing = vec![stored("c", "a.test", "/", false)];
    assert_eq!(
        restore_plan(&cookies, &existing, 10.0),
        RestorePlan { restore: vec![0], kept: 1, expired: 1 }
    );
}

#[test]
fn same_site_labels_are_capitalized() {
    assert_eq!(same_site_label("lax"), "Lax");
    assert_eq!(same_site_label("STRICT"), "Strict");
    assert_eq!(same_site_label("no restriction"), "No Restriction");
}

#[test]
fn cookie_ops_answer_in_the_apps_shape() {
    let reply = ops::call(
        "browser_rules_automation_cookies_set",
        json!({"cookies": [{"name": "n", "value": "v", "url": "https://a.test/"}], "now": 0}),
    )
    .unwrap();
    assert_eq!(
        reply,
        json!({"cookies": [{"name": "n", "value": "v", "domain": "a.test", "path": "/",
            "expires": -1.0, "httpOnly": false, "secure": false}]})
    );
    let reply = ops::call("browser_rules_automation_cookies_clear_site", json!({"url": "data:,x"}))
        .unwrap();
    assert!(reply["error"].as_str().unwrap().contains("a data: page"));
    let reply = ops::call(
        "browser_rules_automation_cookies_clear_matches",
        json!({"cookies": [{"name": "a", "domain": ".a.test", "path": "/"}], "host": "a.test"}),
    )
    .unwrap();
    assert_eq!(reply, json!([0]));
}
