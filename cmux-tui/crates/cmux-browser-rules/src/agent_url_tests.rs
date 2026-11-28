//! The agent URL rule, against the vectors the Swift, C++ and browser host copies share
//! (schemas/agent-url-policy/vectors.json) and the doc comment's cases.

use crate::agent_url::*;
use crate::ops;
use serde_json::{Value, json};

#[test]
fn follows_the_shared_agent_url_vectors() {
    let vectors: Value =
        serde_json::from_str(include_str!("../../../../schemas/agent-url-policy/vectors.json"))
            .unwrap();
    let cases = vectors["cases"].as_array().unwrap();
    assert!(!cases.is_empty());
    for case in cases {
        let url = case["url"].as_str().unwrap();
        let refused = case["refused"].as_bool().unwrap();
        assert_eq!(refuses(url), refused, "{url:?}");
    }
}

#[test]
fn chromium_pages_and_first_party_pages_are_refused() {
    assert!(refuses("chrome://password-manager/passwords"));
    assert!(refuses("chrome://extensions"));
    assert!(refuses("about:settings"));
    assert!(!refuses("about:blank"));
    assert!(!refuses("about:srcdoc#x"));
    assert!(refuses("cmux://history"));
    assert!(refuses("cmux-page://cmux/settings"));
    assert!(refuses("cmux-page://cmux.history/"));
    assert!(refuses("cmux-page://shell/"));
    assert!(refuses("cmux-page:///x"));
    assert!(refuses("cmux-page://co%6D.example/"));
    assert!(!refuses("cmux-page://com.example.app/"));
    assert!(refuses("blob:chrome://settings/abc"));
    assert!(!refuses("blob:https://a.test/abc"));
    assert!(refuses("blob:blob:blob:https://a.test/"));
    assert!(!refuses("https://example.com/"));
    assert!(!refuses("no scheme here"));
    assert_eq!(REPLACEMENT_URL, "about:blank");
}

#[test]
fn reserved_page_hosts() {
    assert!(is_reserved_page_host("//CMUX./x"));
    assert!(is_reserved_page_host("//user@cmux:80/x"));
    assert!(!is_reserved_page_host("//user@dev.app.example:80/x"));
    assert!(is_reserved_page_host(""));
}

#[test]
fn the_op_answers_one_url_or_many() {
    assert_eq!(
        ops::call("browser_rules_agent_url_refuses", json!({"url": "chrome://settings"})),
        Ok(json!(true))
    );
    assert_eq!(
        ops::call(
            "browser_rules_agent_url_refuses",
            json!({"urls": ["about:blank", "devtools://x"]})
        ),
        Ok(json!([false, true]))
    );
}
